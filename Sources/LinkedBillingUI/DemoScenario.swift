#if canImport(SwiftUI)
import Foundation
import LinkedBilling
import Observation

/// What the host app hands the demo: the compiled-in business rules and features.
public struct LinkedBillingDemoConfiguration: Sendable {
    public let policy: RoutingPolicy
    public let plan: StorePlan
    public let features: [FeatureDescriptor]
    public let profile: UserProfileID

    public init(policy: RoutingPolicy, plan: StorePlan, features: [FeatureDescriptor], profile: UserProfileID) {
        self.policy = policy
        self.plan = plan
        self.features = features
        self.profile = profile
    }
}

/// One step of the scripted month, after it has run.
public struct DemoStepRecord: Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let narrative: String
    public let clock: EpochMillis
    public let requests: [DemoRequestRecord]
    public let phaseAfter: LinkPhase
    public let note: String?
}

public struct DemoRequestRecord: Identifiable, Sendable {
    public let id: Int
    public let featureName: String
    public let result: GatewayResult
}

/// Drives a scripted month for one customer through the real `LinkedBillingGateway`,
/// `ConnectionReconciler` and `LinkSession`, against `SimulatedClaudeOrg`. Nothing
/// in the timeline is canned: each card shows what the gateway actually did.
@MainActor
@Observable
public final class LinkedBillingDemoModel {
    public let configuration: LinkedBillingDemoConfiguration
    public private(set) var steps: [DemoStepRecord] = []
    public private(set) var phase: LinkPhase = .notLinked
    public private(set) var totals = SpendTotals()
    /// Totals for every month with activity, newest first.
    public private(set) var monthTotals: [(month: BillingMonth, totals: SpendTotals)] = []
    public private(set) var entries: [LedgerEntry] = []
    public private(set) var isRunning = false
    public private(set) var nextStepIndex = 0

    private var clock: ManualClock
    private var org: SimulatedClaudeOrg
    private var gateway: LinkedBillingGateway
    private var reconciler: ConnectionReconciler
    private var requestCounter = 0

    static let start = BillingMonth.epochMillis(year: 2026, month: 11, day: 3, hour: 9)

    public init(configuration: LinkedBillingDemoConfiguration) {
        self.configuration = configuration
        let parts = Self.makeEngine(configuration)
        clock = parts.clock
        org = parts.org
        gateway = parts.gateway
        reconciler = parts.reconciler
    }

    private static func makeEngine(_ configuration: LinkedBillingDemoConfiguration)
        -> (clock: ManualClock, org: SimulatedClaudeOrg, gateway: LinkedBillingGateway, reconciler: ConnectionReconciler) {
        let clock = ManualClock(start)
        let org = SimulatedClaudeOrg(clock: clock)
        let gateway = LinkedBillingGateway(
            profile: configuration.profile, plan: configuration.plan, policy: configuration.policy,
            transport: org, clock: clock, sleeper: AdvancingSleeper(clock: clock))
        let reconciler = ConnectionReconciler(gateway: gateway, source: org)
        return (clock, org, gateway, reconciler)
    }

    public var totalSteps: Int { Self.script.count }
    public var isFinished: Bool { nextStepIndex >= Self.script.count }
    public var now: EpochMillis { clock.now() }

    public func reset() {
        guard !isRunning else { return }
        let parts = Self.makeEngine(configuration)
        clock = parts.clock
        org = parts.org
        gateway = parts.gateway
        reconciler = parts.reconciler
        steps = []
        phase = .notLinked
        totals = SpendTotals()
        monthTotals = []
        entries = []
        nextStepIndex = 0
        requestCounter = 0
    }

    public func runNextStep() async {
        guard !isRunning, nextStepIndex < Self.script.count else { return }
        isRunning = true
        defer { isRunning = false }
        let index = nextStepIndex
        guard Self.script.indices.contains(index) else { return }
        let step = Self.script[index]
        nextStepIndex += 1
        let record = await perform(step, index: index)
        steps.append(record)
        await refresh()
    }

    public func runAll() async {
        await run(steps: Self.script.count)
    }

    /// Run up to `count` more steps (the demo's `-steps N` launch argument).
    public func run(steps count: Int) async {
        var remaining = max(0, count)
        while remaining > 0, !isFinished, !isRunning {
            await runNextStep()
            remaining -= 1
        }
    }

    public func displayName(forFeatureID id: String) -> String {
        configuration.features.first(where: { $0.id == id })?.displayName ?? id
    }

    // MARK: Script

    private enum Action: Sendable {
        case advance(minutes: Int64)
        case setMonthStart(year: Int64, month: Int64)
        case summarizeMonth(year: Int64, month: Int64)
        case linkViaOAuth(propagationMillis: Int64, capDollars: Int64)
        case orgChange(@Sendable (isolated SimulatedClaudeOrg) -> Void)
        case consoleUnlink
        case request(featureIndex: Int, estimateCents: Int64, times: Int)
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
             actions: [.request(featureIndex: 0, estimateCents: 80, times: 1)]),
        Step(title: "Allowance spent, still not linked",
             narrative: "This request won't fit the allowance. With no linked org, the app subsidises it on the cheaper model.",
             actions: [.advance(minutes: 30), .request(featureIndex: 0, estimateCents: 70, times: 1)]),
        Step(title: "Admin links their Claude org",
             narrative: "LinkSession checks the callback (host, state, TTL, single use). The admin sets a $2 cap. The first request lands inside the ~10 s propagation window, gets 403 not_billable, and is retried once.",
             actions: [.advance(minutes: 60), .linkViaOAuth(propagationMillis: 1_500, capDollars: 2),
                       .request(featureIndex: 1, estimateCents: 50, times: 1)]),
        Step(title: "Code execution and app-side work",
             narrative: "The API won't bill a customer for code execution, so the app pays. The safety check is the app's own work and is never billed to the customer.",
             actions: [.advance(minutes: 10), .request(featureIndex: 2, estimateCents: 30, times: 1),
                       .request(featureIndex: 3, estimateCents: 5, times: 1)]),
        Step(title: "Burst hits the $2 spend cap",
             narrative: "The org pays until its cap. Then 402 spend_limit_reached. The app can't read the cap, so it falls back to subsidy and schedules a probe instead of waiting for 1 December.",
             actions: [.advance(minutes: 5), .request(featureIndex: 1, estimateCents: 50, times: 4)]),
        Step(title: "Admin raises the cap (no notification)",
             narrative: "Sixteen minutes later the probe is due. One request tests the customer again, succeeds, and the link is billable again.",
             actions: [.orgChange({ $0.spendCap = .dollars(10) }), .advance(minutes: 16),
                       .request(featureIndex: 0, estimateCents: 40, times: 1)]),
        Step(title: "Anthropic is briefly overloaded",
             narrative: "503 overloaded_error means billing couldn't be confirmed and nothing was charged. The gateway honours retry-after and retries the same payer.",
             actions: [.advance(minutes: 20), .orgChange({ $0.overloadNext = 1 }),
                       .request(featureIndex: 1, estimateCents: 30, times: 1)]),
        Step(title: "Admin unlinks in the Console",
             narrative: "No webhook, no email. The next request gets 403 not_billable and falls back to subsidy. Because not_billable can mean an ended link, the gateway asks for a status read, and the reconciler sees disconnected.",
             actions: [.advance(minutes: 45), .consoleUnlink, .advance(minutes: 5),
                       .request(featureIndex: 0, estimateCents: 40, times: 1), .reconcileIfRecommended]),
        Step(title: "Subsidy budget runs out",
             narrative: "The app's goodwill budget is $3 a month per customer. Reservations are counted, so a burst can't overshoot it. Then the feature pauses with a reason the UI can act on.",
             actions: [.advance(minutes: 30), .request(featureIndex: 0, estimateCents: 300, times: 5)]),
        Step(title: "00:00 UTC, 1 December",
             narrative: "Budgets roll over on the UTC month boundary, not the device's time zone. The allowance covers usage again, and relinking would restore customer billing.",
             actions: [.summarizeMonth(year: 2026, month: 11), .setMonthStart(year: 2026, month: 12),
                       .request(featureIndex: 0, estimateCents: 40, times: 1)]),
    ]

    private func perform(_ step: Step, index: Int) async -> DemoStepRecord {
        var requests: [DemoRequestRecord] = []
        var note: String?
        var lastRecommended = false
        for action in step.actions {
            switch action {
            case let .advance(minutes):
                clock.advance(by: minutes * 60_000)
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
            case let .request(featureIndex, cents, times):
                guard configuration.features.indices.contains(featureIndex) else { continue }
                let feature = configuration.features[featureIndex]
                for _ in 0..<max(0, times) {
                    let request = InferenceRequest(feature: feature, estimate: MicroUSD(cents * 10_000),
                                                   prompt: "demo")
                    let result = await gateway.send(request)
                    lastRecommended = result.statusCheckRecommended
                    requestCounter += 1
                    requests.append(DemoRequestRecord(id: requestCounter, featureName: feature.displayName,
                                                      result: result))
                    clock.advance(by: 30_000)
                }
            case .reconcileIfRecommended:
                guard lastRecommended else { continue }
                switch await reconciler.reconcileNow() {
                case let .observed(status, changed):
                    note = "Reconciler read connection_status: \(Self.describe(status))\(changed ? " → link state updated" : "")."
                case let .failed(failures):
                    note = "Status read failed (\(failures) in a row); retrying with backoff."
                case .notLinkable:
                    note = nil
                }
            }
        }
        let phase = await gateway.link.phase
        return DemoStepRecord(id: index, title: step.title, narrative: step.narrative, clock: clock.now(),
                              requests: requests, phaseAfter: phase, note: note)
    }

    private func link(propagationMillis: Int64, capDollars: Int64) async -> String {
        await gateway.apply(.linkStarted)
        let state = "st_" + String(repeating: "q7Xk", count: 6)
        guard let authorize = URL(string: "https://auth.claude.com/oauth/authorize?request_uri=urn:demo"),
              let callback = URL(string: "linkedbillingdemo://oauth/callback?code=demo-code&state=\(state)"),
              let forged = URL(string: "linkedbillingdemo://oauth/callback?code=evil&state=st_wrong-state-value-000000")
        else { return "Could not build demo URLs." }
        do {
            let session = try LinkSession(
                authorizeURL: authorize, state: state,
                redirect: .init(scheme: "linkedbillingdemo", host: "oauth", path: "/callback"),
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
            return "Callback accepted; a forged callback was \(forgedText). Code exchanged by the back end; wording says \"linked\", not \"billing active\"."
        } catch {
            await gateway.apply(.linkCancelled)
            return "Authorize URL refused: \(error)"
        }
    }

    private func refresh() async {
        phase = await gateway.link.phase
        let ledger = await gateway.ledger
        totals = ledger.totals(for: BillingMonth(containing: clock.now()))
        monthTotals = ledger.months.map { ($0, ledger.totals(for: $0)) }
        entries = ledger.recentEntries
    }

    nonisolated static func describe(_ status: ConnectionStatus) -> String {
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

    /// The router's decision for each feature under each link condition, with the
    /// configured plan, an empty ledger and the included allowance already used.
    public func matrix() -> [(feature: FeatureDescriptor, decisions: [RouteDecision])] {
        var ledger = SpendLedger()
        let now = Self.start
        if case let .subscription(included) = configuration.plan {
            ledger.record(featureID: "allowance", payer: .app, budget: .included, model: "n/a",
                          outcome: .billed(included), reservation: nil, at: now)
        }
        let resets = BillingMonth(containing: now).end
        let admissions: [(UserProfileID?, CustomerAdmission)] = [
            (configuration.profile, .admit),
            (configuration.profile, .deny(.spendLimitReached(resetsAt: resets))),
            (configuration.profile, .deny(.unlinked(.revokedByAdmin))),
            (nil, .deny(.notLinked)),
        ]
        return configuration.features.map { feature in
            let decisions = admissions.map { profile, admission in
                BillingRouter.route(feature: feature, estimate: MicroUSD(400_000), profile: profile,
                                    admission: admission, plan: configuration.plan,
                                    policy: configuration.policy, ledger: ledger, at: now)
            }
            return (feature, decisions)
        }
    }
}
#endif
