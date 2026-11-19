/// Reads `connection_status` for one user profile. In production: your back end calls
/// `GET /v1/user_profiles/{id}?oauth_app_id=…` with the
/// `user-profiles-search-2026-08-30` beta header, as the operator service account.
public protocol ConnectionStatusSource: Sendable {
    /// Throw for a 503 or a network failure; the reconciler backs off.
    func fetchStatus(for profile: UserProfileID) async throws -> ConnectionStatus
}

/// How often to read `connection_status`, by phase.
///
/// Unlinking in the Claude Console sends you "no webhook event and no email" (docs),
/// so polling is the only way to notice. Polling every profile every minute doesn't
/// scale across a customer base, so the cadence follows the phase. It is fast where
/// a change is likely and matters (a link that just started refusing with
/// `not_billable`), and slow where nothing is expected. A pending link isn't polled
/// fast: no status read can complete it (only the code exchange does), and an
/// abandoned flow expires on its own after `LinkPolicy.pendingTimeoutMillis`. Every delay carries ±10% jitter so a fleet of
/// clients that started together doesn't poll in lockstep.
public struct PollSchedule: Hashable, Sendable {
    /// A link flow in progress. Polled like an idle profile (see above).
    public var pendingMillis: Int64 = 24 * 3_600_000
    /// Linked and `not_billable`: the most likely cause is an ended connection.
    public var suspectMillis: Int64 = 5 * 60_000
    /// Linked and either healthy or capped/unavailable (a status read can't fix those).
    public var linkedMillis: Int64 = 6 * 3_600_000
    /// Not linked or unlinked: only a link from another device changes this.
    public var idleMillis: Int64 = 24 * 3_600_000
    /// After a failed read: base × 2^failures, capped.
    public var failureBaseMillis: Int64 = 30_000
    public var failureMaxMillis: Int64 = 3_600_000

    public init() {}

    /// The delay before the next read. `jitterDraw` is any random `UInt64`; it is used
    /// with integer arithmetic only, so no input can trap.
    public func delay(for phase: LinkPhase, consecutiveFailures: Int, jitterDraw: UInt64) -> Int64 {
        let base: Int64
        if consecutiveFailures > 0 {
            var backoff = max(1, failureBaseMillis)
            for _ in 0..<min(consecutiveFailures - 1, 20) where backoff < failureMaxMillis {
                backoff = Saturating.multiply(backoff, 2)
            }
            base = min(backoff, max(1, failureMaxMillis))
        } else {
            switch phase {
            case .linkPending: base = pendingMillis
            case .linked(.notBillable): base = suspectMillis
            case .linked: base = linkedMillis
            case .notLinked, .unlinked: base = idleMillis
            }
        }
        let clampedBase = max(1, base)
        let span = clampedBase / 10 // ±10%
        guard span > 0 else { return clampedBase }
        // 2*span+1 > 0 and fits: span <= Int64.max / 10.
        let offset = Int64(jitterDraw % UInt64(2 * span + 1)) - span
        return Saturating.add(clampedBase, offset) // base near Int64.max must not wrap
    }
}

public enum ReconcileResult: Hashable, Sendable {
    case observed(ConnectionStatus, phaseChanged: Bool)
    case failed(consecutiveFailures: Int)
    case notLinkable // the gateway has no user profile
}

/// Keeps the gateway's link state honest when nothing tells you a link ended.
///
/// Single-flight: concurrent `reconcileNow()` calls share one read. Pass `fresh: true`
/// when you need a read that *started after* your call (for example right after a
/// `not_billable`): it waits out any older read in flight and then reads again. Each
/// read takes a
/// `Ticket` from the gateway *before* it suspends, so a read that started before the
/// user re-linked can't revert the new link when it lands (the reentrancy test pins
/// this).
public actor ConnectionReconciler {
    private let gateway: LinkedBillingGateway
    private let source: any ConnectionStatusSource
    public let schedule: PollSchedule

    public private(set) var consecutiveFailures = 0
    private var inFlight: (id: UInt64, task: Task<ReconcileResult, Never>)?
    private var nextID: UInt64 = 1

    public init(gateway: LinkedBillingGateway, source: any ConnectionStatusSource,
                schedule: PollSchedule = PollSchedule()) {
        self.gateway = gateway
        self.source = source
        self.schedule = schedule
    }

    public func reconcileNow(fresh: Bool = false) async -> ReconcileResult {
        if let current = inFlight {
            let shared = await current.task.value
            guard fresh else { return shared }
            // A read another caller started after `current` began after our call too.
            if let newer = inFlight, newer.id != current.id { return await newer.task.value }
        }
        return await startRead()
    }

    private func startRead() async -> ReconcileResult {
        let id = nextID
        nextID &+= 1
        let task = Task { await self.performRead() }
        inFlight = (id, task)
        let result = await task.value
        // Only clear our own entry; never one a later call installed.
        if self.inFlight?.id == id { self.inFlight = nil }
        return result
    }

    /// Delay until the next scheduled read, given a random draw for jitter.
    public func nextDelay(jitterDraw: UInt64) async -> Int64 {
        let phase = await gateway.currentPhase()
        return schedule.delay(for: phase, consecutiveFailures: consecutiveFailures, jitterDraw: jitterDraw)
    }

    private func performRead() async -> ReconcileResult {
        guard let profile = gateway.profile else { return .notLinkable }
        let ticket = await gateway.beginStatusRead()
        do {
            let status = try await source.fetchStatus(for: profile)
            consecutiveFailures = 0
            let changed = await gateway.observeStatus(status, ticket: ticket)
            return .observed(status, phaseChanged: changed)
        } catch {
            consecutiveFailures = min(consecutiveFailures + 1, 1_000)
            return .failed(consecutiveFailures: consecutiveFailures)
        }
    }
}
