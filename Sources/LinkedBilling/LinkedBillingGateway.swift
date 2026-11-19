/// One request for Claude, as a feature sees it.
public struct InferenceRequest: Hashable, Sendable {
    public let feature: FeatureDescriptor
    /// Estimated cost on the feature's primary model, e.g. from
    /// `/v1/messages/count_tokens` (which accepts and ignores `billing_policy`).
    public let estimate: MicroUSD
    public let prompt: String

    public init(feature: FeatureDescriptor, estimate: MicroUSD, prompt: String) {
        self.feature = feature
        self.estimate = estimate
        self.prompt = prompt
    }
}

/// What the network layer reports for one attempt.
public enum TransportResult: Hashable, Sendable {
    case success(cost: MicroUSD, text: String)
    /// `partialReply` is non-nil when the refusal arrived after Claude had started a
    /// reply (`linked_organization_billing_unavailable` can do this).
    case refused(BillingRefusal, partialReply: String?)
}

/// Sends one `/v1/messages` call with the given payer. In production this lives in
/// your back end and authenticates as the OAuth app's operator service account; the
/// iOS app never holds that credential. Throwing means "sent, outcome unknown".
///
/// `profile` is the customer's user profile whenever one exists, *whoever pays*:
/// the docs ask for the `anthropic-user-profile-id` header on every call for a linked
/// customer, which is what attributes app-paid usage to that customer in the Console
/// and the usage API. `BillingEnvelope(payer:profile:)` builds the headers.
public protocol MessagesTransport: Sendable {
    func send(_ request: InferenceRequest, payer: Payer, profile: UserProfileID?, model: ModelID) async throws -> TransportResult
}

/// Wall-clock time source (UTC epoch millis). Injected so tests can drive time.
public protocol BillingClock: Sendable {
    func now() -> EpochMillis
}

/// Suspends for a while. Injected so retries are testable without real waiting.
public protocol BillingSleeper: Sendable {
    func sleep(millis: Int64) async throws
}

/// Retry bounds for one `send`. Every field is clamped in `init` and again whenever
/// it is set, so no value can make a loop range invalid or a wait unbounded.
public struct RetryLimits: Hashable, Sendable {
    /// Hard ceiling on attempts per `send`, across every kind of retry and fallback.
    public var maxAttempts: Int { didSet { maxAttempts = min(max(1, maxAttempts), 10) } }
    /// Retries after `503 overloaded_error`.
    public var maxOverloadRetries: Int { didSet { maxOverloadRetries = min(max(0, maxOverloadRetries), 5) } }
    /// Backoff after a 503 without a usable `retry-after`: base × 2^retry.
    public var overloadBackoffMillis: Int64 { didSet { overloadBackoffMillis = min(max(0, overloadBackoffMillis), 60_000) } }
    /// The longest single wait a `send` will sit through for a 503. A `retry-after`
    /// beyond it (this package clamps `retry-after` to an hour) fails the request as
    /// `.overloaded` instead of holding the caller.
    public var maxRetryWaitMillis: Int64 { didSet { maxRetryWaitMillis = min(max(0, maxRetryWaitMillis), 3_600_000) } }
    /// Delay before re-sending a `not_billable` refused inside the warm-up window.
    public var warmupRetryMillis: Int64 { didSet { warmupRetryMillis = min(max(0, warmupRetryMillis), 10_000) } }

    public init(maxAttempts: Int = 4, maxOverloadRetries: Int = 2,
                overloadBackoffMillis: Int64 = 500, maxRetryWaitMillis: Int64 = 30_000,
                warmupRetryMillis: Int64 = 2_000) {
        self.maxAttempts = min(max(1, maxAttempts), 10)
        self.maxOverloadRetries = min(max(0, maxOverloadRetries), 5)
        self.overloadBackoffMillis = min(max(0, overloadBackoffMillis), 60_000)
        self.maxRetryWaitMillis = min(max(0, maxRetryWaitMillis), 3_600_000)
        self.warmupRetryMillis = min(max(0, warmupRetryMillis), 10_000)
    }
}

/// One attempt inside a `send`, for logs, tests and the demo's timeline.
public struct GatewayAttempt: Hashable, Sendable {
    public let decision: RouteDecision
    public let result: AttemptResult
}

public enum AttemptResult: Hashable, Sendable {
    case served(cost: MicroUSD)
    case refused(BillingRefusal, discardedPartialReply: Bool)
    /// The transport threw after sending; billing unknown.
    case transportFailed
    /// The router paused, or a reservation was refused: nothing was sent.
    case notSent
}

public enum GatewayFailure: Hashable, Sendable {
    /// The transport threw. The request may have been served and billed; it is not
    /// retried, because re-sending could bill twice.
    case transportFailed
    /// Still 503 after `maxOverloadRetries`.
    case overloaded
    /// A refusal that is a caller bug or an app-side billing problem, not a customer
    /// billing signal. Never masked by falling back to another payer.
    case rejected(BillingRefusal)
    case attemptsExhausted
    case cancelled
}

public enum GatewayOutcome: Hashable, Sendable {
    case served(text: String, payer: Payer, model: ModelID, cost: MicroUSD)
    case paused(PauseReason)
    case failed(GatewayFailure)
}

public struct GatewayResult: Hashable, Sendable {
    public let outcome: GatewayOutcome
    public let attempts: [GatewayAttempt]
    /// A `not_billable` refusal was seen outside the warm-up window. Its causes include an ended connection,
    /// which nothing notifies you about, so read `connection_status` soon.
    public let statusCheckRecommended: Bool
}

/// Routes, sends, falls back and records: the server-side half of linked billing.
///
/// It owns the link state machine and the spend ledger for one customer, so every
/// decision and every state change happens inside one actor. The only suspension
/// points are the transport call and retry sleeps. Everything learned after a
/// suspension is applied through `Ticket`s and ledger reservations, so interleaved
/// `send` calls can't undo each other's evidence or overshoot a budget (see the
/// reentrancy tests).
public actor LinkedBillingGateway {
    public let profile: UserProfileID?
    public private(set) var link: LinkState
    public private(set) var ledger: SpendLedger
    public private(set) var plan: StorePlan
    public let policy: RoutingPolicy
    public let limits: RetryLimits

    private let transport: any MessagesTransport
    private let clock: any BillingClock
    private let sleeper: any BillingSleeper

    public init(profile: UserProfileID?, link: LinkState = LinkState(), ledger: SpendLedger = SpendLedger(),
                plan: StorePlan = .noSubscription, policy: RoutingPolicy, limits: RetryLimits = RetryLimits(),
                transport: any MessagesTransport, clock: any BillingClock, sleeper: any BillingSleeper) {
        self.profile = profile
        self.link = link
        self.ledger = ledger
        self.plan = plan
        self.policy = policy
        self.limits = limits
        self.transport = transport
        self.clock = clock
        self.sleeper = sleeper
    }

    // MARK: Inputs from outside the request path

    /// StoreKit changed (purchase, renewal, refund). Takes effect on the next decision.
    public func updatePlan(_ plan: StorePlan) { self.plan = plan }

    /// Link lifecycle events from the OAuth flow or your back end.
    @discardableResult
    public func apply(_ event: LinkEvent) -> Bool {
        link.apply(event, at: clock.now())
    }

    /// Start a `connection_status` read. Pass the ticket back with the result. Time-driven
    /// changes (an abandoned link flow expiring) are folded first, so a read that starts
    /// after the expiry always counts.
    public func beginStatusRead() -> Ticket { link.issueTicket(at: clock.now()) }

    @discardableResult
    public func observeStatus(_ status: ConnectionStatus, ticket: Ticket) -> Bool {
        link.apply(.statusObserved(status, ticket: ticket), at: clock.now())
    }

    /// The link's phase as of now, with an abandoned link flow already expired. Prefer
    /// this to `link.phase` for UI and scheduling.
    public func currentPhase() -> LinkPhase {
        link.phase(at: clock.now())
    }

    /// What the router would decide right now, without sending or reserving.
    public func preview(_ request: InferenceRequest) -> RouteDecision {
        decide(request, at: clock.now())
    }

    // MARK: Request path

    public func send(_ request: InferenceRequest) async -> GatewayResult {
        var attempts: [GatewayAttempt] = []
        var overloadRetries = 0
        var warmupRetried = false
        var statusCheck = false
        // Set when this request must stop trying the customer even though the shared
        // state still admits them (a second refusal inside the warm-up window).
        var customerBlocked: CustomerDenial?

        func finish(_ outcome: GatewayOutcome) -> GatewayResult {
            GatewayResult(outcome: outcome, attempts: attempts, statusCheckRecommended: statusCheck)
        }

        for _ in 0..<max(1, limits.maxAttempts) {
            guard !Task.isCancelled else { return finish(.failed(.cancelled)) }
            let now = clock.now()
            let decision = decide(request, at: now, customerBlocked: customerBlocked)

            switch decision {
            case let .pause(reason):
                attempts.append(GatewayAttempt(decision: decision, result: .notSent))
                return finish(.paused(reason))

            case let .billCustomer(profile, model, isProbe):
                let ticket = link.issueTicket(at: now)
                if isProbe, !link.beginProbe(ticket: ticket, at: now) {
                    // Unreachable while `decide` and `beginProbe` run in one actor turn,
                    // but if it ever happens, re-route rather than send a second probe.
                    continue
                }
                let payer = Payer.customer(profile)
                let result: TransportResult
                do {
                    result = try await transport.send(request, payer: payer, profile: profile, model: model)
                } catch {
                    if isProbe { link.apply(.probeAbandoned(ticket: ticket), at: clock.now()) }
                    ledger.record(featureID: request.feature.id, payer: payer, budget: nil, model: model,
                                  outcome: .unknown, reservation: nil, at: clock.now())
                    attempts.append(GatewayAttempt(decision: decision, result: .transportFailed))
                    return finish(.failed(.transportFailed))
                }
                let after = clock.now()
                switch result {
                case let .success(cost, text):
                    link.apply(.customerBilled(ticket: ticket), at: after)
                    ledger.record(featureID: request.feature.id, payer: payer, budget: nil, model: model,
                                  outcome: .billed(cost), reservation: nil, at: after)
                    attempts.append(GatewayAttempt(decision: decision, result: .served(cost: cost)))
                    return finish(.served(text: text, payer: payer, model: model, cost: cost))

                case let .refused(refusal, partial):
                    link.apply(.customerRefused(refusal, ticket: ticket, sentAt: now), at: after)
                    ledger.record(featureID: request.feature.id, payer: payer, budget: nil, model: model,
                                  outcome: .refused(refusal), reservation: nil, at: after)
                    attempts.append(GatewayAttempt(decision: decision,
                                                   result: .refused(refusal, discardedPartialReply: partial != nil)))
                    // Recommend a status read only when the refusal could mean an ended link:
                    // inside the warm-up window it is expected propagation delay.
                    if refusal == .notBillable, !link.isInWarmup(sentAt: now) { statusCheck = true }

                    if case let .overloaded(retryAfter) = refusal {
                        let wait = overloadDelay(retryAfterSeconds: retryAfter, retry: overloadRetries)
                        guard overloadRetries < limits.maxOverloadRetries, wait <= limits.maxRetryWaitMillis else {
                            return finish(.failed(.overloaded))
                        }
                        overloadRetries += 1
                        guard (try? await sleeper.sleep(millis: wait)) != nil else { return finish(.failed(.cancelled)) }
                        continue
                    }
                    guard refusal.isCustomerBillingSignal else { return finish(.failed(.rejected(refusal))) }

                    if refusal == .notBillable, link.isInWarmup(sentAt: now) {
                        // Inside the ~10 s propagation window the state ignored the
                        // refusal; re-send to the customer once, after a short wait.
                        // A second refusal stops trying the customer for this request.
                        guard !warmupRetried else {
                            customerBlocked = .notBillable
                            continue
                        }
                        warmupRetried = true
                        guard (try? await sleeper.sleep(millis: limits.warmupRetryMillis)) != nil else {
                            return finish(.failed(.cancelled))
                        }
                    }
                    continue // re-route: admission now reflects the refusal
                }

            case let .billApp(model, budget, _, estimate):
                guard let reservation = ledger.reserve(estimate, from: budget, limit: limit(for: budget), at: now) else {
                    attempts.append(GatewayAttempt(decision: decision, result: .notSent))
                    return finish(.paused(.reservationRefused))
                }
                let result: TransportResult
                do {
                    // Attribute app-paid usage to the customer it serves; the app's own
                    // operational usage isn't theirs, so it carries no profile.
                    let attributed = budget == .operational ? nil : profile
                    result = try await transport.send(request, payer: .app, profile: attributed, model: model)
                } catch {
                    ledger.record(featureID: request.feature.id, payer: .app, budget: budget, model: model,
                                  outcome: .unknown, reservation: reservation, at: clock.now())
                    attempts.append(GatewayAttempt(decision: decision, result: .transportFailed))
                    return finish(.failed(.transportFailed))
                }
                let after = clock.now()
                switch result {
                case let .success(cost, text):
                    ledger.record(featureID: request.feature.id, payer: .app, budget: budget, model: model,
                                  outcome: .billed(cost), reservation: reservation, at: after)
                    attempts.append(GatewayAttempt(decision: decision, result: .served(cost: cost)))
                    return finish(.served(text: text, payer: .app, model: model, cost: cost))
                case let .refused(refusal, partial):
                    ledger.record(featureID: request.feature.id, payer: .app, budget: budget, model: model,
                                  outcome: .refused(refusal), reservation: reservation, at: after)
                    attempts.append(GatewayAttempt(decision: decision,
                                                   result: .refused(refusal, discardedPartialReply: partial != nil)))
                    if case let .overloaded(retryAfter) = refusal {
                        let wait = overloadDelay(retryAfterSeconds: retryAfter, retry: overloadRetries)
                        guard overloadRetries < limits.maxOverloadRetries, wait <= limits.maxRetryWaitMillis else {
                            return finish(.failed(.overloaded))
                        }
                        overloadRetries += 1
                        guard (try? await sleeper.sleep(millis: wait)) != nil else { return finish(.failed(.cancelled)) }
                        continue
                    }
                    // App-paid refusals are about *your* org (credit, limits), never
                    // the customer's link, so they don't touch LinkState.
                    return finish(.failed(.rejected(refusal)))
                }
            }
        }
        return finish(.failed(.attemptsExhausted))
    }

    // MARK: Helpers

    private func decide(_ request: InferenceRequest, at now: EpochMillis,
                        customerBlocked: CustomerDenial? = nil) -> RouteDecision {
        let admission = customerBlocked.map { CustomerAdmission.deny($0) } ?? link.admission(at: now)
        return BillingRouter.route(feature: request.feature, estimate: request.estimate, profile: profile,
                                   admission: admission, plan: plan, policy: policy,
                                   ledger: ledger, at: now)
    }

    private func limit(for budget: AppBudget) -> MicroUSD {
        switch budget {
        case .included:
            if case let .subscription(included) = plan { return included }
            return .zero
        case .subsidy:
            return policy.subsidyPerMonth
        case .operational:
            return MicroUSD(.max)
        }
    }

    private func overloadDelay(retryAfterSeconds: Int64?, retry: Int) -> Int64 {
        if let retryAfterSeconds {
            // parseRetryAfter clamps to 0...3600, so this cannot overflow.
            return Saturating.multiply(retryAfterSeconds, 1_000)
        }
        var delay = limits.overloadBackoffMillis
        for _ in 0..<min(max(0, retry), 10) { delay = Saturating.multiply(delay, 2) }
        return delay
    }
}
