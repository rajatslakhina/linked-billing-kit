import Foundation
import LinkedBilling

/// One B2B customer's month, scripted: the scenario the demo app plays and the tests
/// pin. Each step drives the real `LinkedBillingGateway`, `ConnectionReconciler` and
/// `LinkSession` against `SimulatedClaudeOrg`; nothing in a `StepRecord` is canned.
public actor ScriptedMonth {
    /// The four kinds of feature the script exercises, plus the business rules.
    public struct Configuration: Sendable {
        public let policy: RoutingPolicy
        public let plan: StorePlan
        public let profile: UserProfileID
        /// Customer-directed, subsidisable on a cheaper model.
        public let summarize: FeatureDescriptor
        /// Customer-directed, subsidisable on a cheaper model.
        public let draft: FeatureDescriptor
        /// Uses code execution (never customer-billable).
        public let analysis: FeatureDescriptor
        /// The app's own usage (never customer-billable).
        public let safety: FeatureDescriptor

        public init(policy: RoutingPolicy, plan: StorePlan, profile: UserProfileID,
                    summarize: FeatureDescriptor, draft: FeatureDescriptor,
                    analysis: FeatureDescriptor, safety: FeatureDescriptor) {
            self.policy = policy
            self.plan = plan
            self.profile = profile
            self.summarize = summarize
            self.draft = draft
            self.analysis = analysis
            self.safety = safety
        }

        public var features: [FeatureDescriptor] { [summarize, draft, analysis, safety] }
    }

    public struct RequestRecord: Identifiable, Sendable {
        public let id: Int
        public let featureName: String
        public let result: GatewayResult
    }

    public struct StepRecord: Identifiable, Sendable {
        public let id: Int
        public let title: String
        public let narrative: String
        public let clock: EpochMillis
        public let requests: [RequestRecord]
        public let phaseAfter: LinkPhase
        public let note: String?
    }

    /// What a UI needs to render after a step.
    public struct Snapshot: Sendable {
        public let phase: LinkPhase
        public let now: EpochMillis
        public let thisMonth: SpendTotals
        /// Every month with activity, newest first.
        public let months: [(month: BillingMonth, totals: SpendTotals)]
        /// Newest first.
        public let entries: [LedgerEntry]
    }

    public static let start = BillingMonth.epochMillis(year: 2026, month: 11, day: 3, hour: 9)
    public static var stepCount: Int { script.count }

    public let configuration: Configuration
    private let clock: ManualClock
    private let org: SimulatedClaudeOrg
    private let gateway: LinkedBillingGateway
    private let reconciler: ConnectionReconciler
    private var nextStep = 0
    private var requestCounter = 0

    public init(configuration: Configuration) {
        self.configuration = configuration
        let clock = ManualClock(Self.start)
        let org = SimulatedClaudeOrg(clock: clock)
        let gateway = LinkedBillingGateway(
            profile: configuration.profile, plan: configuration.plan, policy: configuration.policy,
            transport: org, clock: clock, sleeper: AdvancingSleeper(clock: clock))
        self.clock = clock
        self.org = org
        self.gateway = gateway
        self.reconciler = ConnectionReconciler(gateway: gateway, source: org)
    }

    public var isFinished: Bool { nextStep >= Self.script.count }

    /// Run the next step; `nil` once the month is over.
    public func runNextStep() async -> StepRecord? {
        guard Self.script.indices.contains(nextStep) else { return nil }
        let index = nextStep
        nextStep += 1
        return await perform(Self.script[index], index: index)
    }

    public func snapshot() async -> Snapshot {
        let ledger = await gateway.ledger
        let now = clock.now()
        return Snapshot(phase: await gateway.currentPhase(), now: now,
                        thisMonth: ledger.totals(for: BillingMonth(containing: now)),
                        months: ledger.months.map { ($0, ledger.totals(for: $0)) },
                        entries: ledger.recentEntries)
    }

    // MARK: Script

    private enum Role: Sendable { case summarize, draft, analysis, safety }

    private enum Action: Sendable {
        case advance(minutes: Int64)
        case setMonthStart(year: Int64, month: Int64)
        case summarizeMonth(year: Int64, month: Int64)
        case linkViaOAuth(propagationMillis: Int64, capDollars: Int64)
        case orgChange(@Sendable (isolated SimulatedClaudeOrg) -> Void)
        case consoleUnlink
        case request(Role, cents: Int64, times: Int)
        /// Fired concurrently. The simulator holds each reply until every request that
        /// is sent is in flight (or 0.5 s pass), so the overlap is real; the step's note
        /// reports how many were in flight at once.
        case concurrentBurst(Role, cents: Int64, count: Int)
        case reconcileIfRecommended
    }

    private struct Step: Sendable {
        let title: String
        let narrative: String
        let actions: [Action]
    }

    private static let script: [Step] = [
        Step(title: "Subscriber, not linked yet",
             narrative: "The user pays through the App Store, so the app pays for usage up to the $1 included allowance.",
             actions: [.request(.summarize, cents: 80, times: 1)]),
        Step(title: "Allowance spent, still not linked",
             narrative: "This request won't fit the allowance. With no linked org, the app subsidises it on the cheaper model.",
             actions: [.advance(minutes: 30), .request(.summarize, cents: 70, times: 1)]),
        Step(title: "Admin links their Claude org",
             narrative: "LinkSession rejects a forged callback and accepts the real one. The admin sets a $2 cap. The first request lands inside the ~10 s propagation window, gets 403 not_billable, and is retried once.",
             actions: [.advance(minutes: 60), .linkViaOAuth(propagationMillis: 1_500, capDollars: 2),
                       .request(.draft, cents: 50, times: 1)]),
        Step(title: "Code execution and app-side work",
             narrative: "The API won't bill a customer for code execution, so the app pays. The safety check is the app's own work and is never billed to the customer.",
             actions: [.advance(minutes: 10), .request(.analysis, cents: 30, times: 1),
                       .request(.safety, cents: 5, times: 1)]),
        Step(title: "Burst hits the $2 spend cap",
             narrative: "The org pays until its cap. Then 402 spend_limit_reached. The app can't read the cap, so it falls back to subsidy and schedules a probe instead of waiting for 1 December.",
             actions: [.advance(minutes: 5), .request(.draft, cents: 50, times: 4)]),
        Step(title: "Admin raises the cap (no notification)",
             narrative: "Sixteen minutes later the probe is due. One request tests the customer again, succeeds, and the link is billable again.",
             actions: [.orgChange({ $0.spendCap = .dollars(10) }), .advance(minutes: 16),
                       .request(.summarize, cents: 40, times: 1)]),
        Step(title: "Anthropic is briefly overloaded",
             narrative: "503 overloaded_error means billing couldn't be confirmed and nothing was charged. The gateway honours retry-after and retries the same payer.",
             actions: [.advance(minutes: 20), .orgChange({ $0.overloadNext = 1 }),
                       .request(.draft, cents: 30, times: 1)]),
        Step(title: "Admin unlinks in the Console",
             narrative: "No webhook, no email. The next request gets 403 not_billable and falls back to subsidy. Because not_billable can mean an ended link, the gateway asks for a status read, and the reconciler sees disconnected.",
             actions: [.advance(minutes: 45), .consoleUnlink, .advance(minutes: 5),
                       .request(.summarize, cents: 40, times: 1), .reconcileIfRecommended]),
        Step(title: "Concurrent burst meets the subsidy budget",
             narrative: "Five requests fire at once against a $3 monthly subsidy. Each reserves its cost before it is sent, so even with all of them in flight together only three fit; two pause with a reason instead of all five seeing the same remaining budget.",
             actions: [.advance(minutes: 30), .concurrentBurst(.summarize, cents: 300, count: 5)]),
        Step(title: "00:00 UTC, 1 December",
             narrative: "Budgets roll over on the UTC month boundary, not the device's time zone. The allowance covers usage again, and relinking would restore customer billing.",
             actions: [.summarizeMonth(year: 2026, month: 11), .setMonthStart(year: 2026, month: 12),
                       .request(.summarize, cents: 40, times: 1)]),
    ]

    private func feature(_ role: Role) -> FeatureDescriptor {
        switch role {
        case .summarize: return configuration.summarize
        case .draft: return configuration.draft
        case .analysis: return configuration.analysis
        case .safety: return configuration.safety
        }
    }

    private func perform(_ step: Step, index: Int) async -> StepRecord {
        var requests: [RequestRecord] = []
        var note: String?
        var lastRecommended = false
        for action in step.actions {
            switch action {
            case let .advance(minutes):
                clock.advance(by: Saturating.multiply(minutes, 60_000))
            case let .setMonthStart(year, month):
                clock.set(BillingMonth.epochMillis(year: year, month: month, day: 1))
            case let .summarizeMonth(year, month):
                let ledger = await gateway.ledger
                let closedMonth = BillingMonth(containing: BillingMonth.epochMillis(year: year, month: month, day: 1))
                let closed = ledger.totals(for: closedMonth)
                note = "\(closedMonth) closed: customer org \(closed.customerBilled), App Store allowance \(closed.appIncluded), subsidy \(closed.appSubsidy) of \(configuration.policy.subsidyPerMonth), app's own usage \(closed.appOperational)."
            case let .linkViaOAuth(propagation, cap):
                note = await link(propagationMillis: propagation, capDollars: cap)
            case let .orgChange(change):
                await org.configure(change)
            case .consoleUnlink:
                await org.unlink(reason: .revokedByAdmin)
            case let .request(role, cents, times):
                let feature = feature(role)
                for _ in 0..<max(0, times) {
                    let result = await gateway.send(InferenceRequest(
                        feature: feature, estimate: MicroUSD(Saturating.multiply(cents, 10_000)), prompt: "demo"))
                    lastRecommended = result.statusCheckRecommended
                    requestCounter += 1
                    requests.append(RequestRecord(id: requestCounter, featureName: feature.displayName, result: result))
                    clock.advance(by: 30_000)
                }
            case let .concurrentBurst(role, cents, count):
                let feature = feature(role)
                let request = InferenceRequest(feature: feature, estimate: MicroUSD(Saturating.multiply(cents, 10_000)),
                                               prompt: "demo")
                let gateway = self.gateway
                await org.configure { $0.holdUntilInFlight = count }
                await org.resetConcurrencyGauge()
                let org = self.org
                let results = await withTaskGroup(of: GatewayResult.self) { group in
                    for _ in 0..<max(0, count) { group.addTask { await gateway.send(request) } }
                    var collected: [GatewayResult] = []
                    for await result in group {
                        // A paused request never reaches the transport, so the hold
                        // stops waiting for it; the rest release once all are in flight.
                        if !Self.isServed(result) { await org.lowerHoldTarget() }
                        collected.append(result)
                    }
                    return collected
                }
                let peak = await org.maxConcurrentSends
                await org.configure { $0.holdUntilInFlight = nil }
                let served = results.filter(Self.isServed).count
                note = "\(peak) of the \(served) sent requests were in flight at the same moment; their reservations kept the other \(results.count - served) from being sent."
                // Served first, then paused, so the card reads in a stable order.
                for result in results.sorted(by: { Self.isServed($0) && !Self.isServed($1) }) {
                    requestCounter += 1
                    requests.append(RequestRecord(id: requestCounter, featureName: feature.displayName, result: result))
                }
                clock.advance(by: 30_000)
            case .reconcileIfRecommended:
                guard lastRecommended else { continue }
                switch await reconciler.reconcileNow(fresh: true) {
                case let .observed(status, changed):
                    note = "Reconciler read connection_status: \(Self.describe(status))\(changed ? " → link state updated" : "")."
                case let .failed(failures):
                    note = "Status read failed (\(failures) in a row); retrying with backoff."
                case .notLinkable:
                    note = nil
                }
            }
        }
        return StepRecord(id: index, title: step.title, narrative: step.narrative, clock: clock.now(),
                          requests: requests, phaseAfter: await gateway.currentPhase(), note: note)
    }

    private static func isServed(_ result: GatewayResult) -> Bool {
        if case .served = result.outcome { return true }
        return false
    }

    private func link(propagationMillis: Int64, capDollars: Int64) async -> String {
        await gateway.apply(.linkStarted)
        let state = "st_" + String(repeating: "q7Xk", count: 6)
        guard let authorize = URL(string: "https://auth.claude.com/oauth/authorize?request_uri=urn:demo"),
              let callback = URL(string: "https://app.example.com/claude/billing/callback?code=demo-code&state=\(state)"),
              let forged = URL(string: "https://app.example.com/claude/billing/callback?code=evil&state=st_wrong-state-value-000000")
        else { return "Could not build demo URLs." }
        do {
            let session = try LinkSession(
                authorizeURL: authorize, state: state,
                redirect: .init(scheme: "https", host: "app.example.com", path: "/claude/billing/callback"),
                createdAt: clock.now())
            // A forged callback first: wrong state. It is rejected and does not burn the session.
            let forgedResult = session.handleCallback(forged, at: clock.now())
            clock.advance(by: 20_000)
            let result = session.handleCallback(callback, at: clock.now())
            guard case .code = result else {
                await gateway.apply(.linkCancelled)
                return "Callback rejected: \(result)"
            }
            await org.configure { org in
                org.propagationMillis = propagationMillis
                org.spendCap = .dollars(capDollars)
            }
            await org.link()
            await gateway.apply(.linkCompleted)
            let forgedText: String
            if case .rejected(.stateMismatch) = forgedResult { forgedText = "rejected (state mismatch)" } else { forgedText = "\(forgedResult)" }
            return "Callback accepted; a forged callback was \(forgedText). The back end exchanges the code; the UI says \"linked\", not \"billing active\"."
        } catch {
            await gateway.apply(.linkCancelled)
            return "Authorize URL refused: \(error)"
        }
    }

    public static func describe(_ status: ConnectionStatus) -> String {
        switch status {
        case .connected: return "connected"
        case .notConnected: return "not_connected"
        case .unknown: return "unknown"
        case let .disconnected(_, reason):
            switch reason {
            case .revokedByAdmin: return "disconnected (revoked_by_admin)"
            case .revokedByAppOwner: return "disconnected (revoked_by_app_owner)"
            case .other: return "disconnected (other)"
            }
        }
    }

    // MARK: Router matrix

    public enum MatrixColumn: String, CaseIterable, Identifiable, Sendable {
        case billable = "Linked"
        case capped = "Cap reached"
        case unlinked = "Unlinked"
        case notLinked = "Never linked"
        public var id: String { rawValue }
    }

    public struct MatrixRow: Identifiable, Sendable {
        public let feature: FeatureDescriptor
        /// One decision per `MatrixColumn`, in `allCases` order.
        public let decisions: [RouteDecision]
        public var id: String { feature.id }
    }

    /// The router's decision for a $0.40 request per feature and link condition, using
    /// the configured plan and a ledger in which the included allowance is already used
    /// and nothing else is spent.
    public static func matrix(for configuration: Configuration) -> [MatrixRow] {
        var ledger = SpendLedger()
        let now = start
        if case let .subscription(included) = configuration.plan {
            ledger.record(featureID: "allowance", payer: .app, budget: .included, model: "n/a",
                          outcome: .billed(included), reservation: nil, at: now)
        }
        let resets = BillingMonth(containing: now).end
        let columns: [(UserProfileID?, CustomerAdmission)] = [
            (configuration.profile, .admit),
            (configuration.profile, .deny(.spendLimitReached(resetsAt: resets))),
            (configuration.profile, .deny(.unlinked(.revokedByAdmin))),
            (nil, .deny(.notLinked)),
        ]
        return configuration.features.map { feature in
            MatrixRow(feature: feature, decisions: columns.map { profile, admission in
                BillingRouter.route(feature: feature, estimate: MicroUSD(400_000), profile: profile,
                                    admission: admission, plan: configuration.plan,
                                    policy: configuration.policy, ledger: ledger, at: now)
            })
        }
    }
}
