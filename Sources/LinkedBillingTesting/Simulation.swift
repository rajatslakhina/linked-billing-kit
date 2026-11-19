import Foundation
import LinkedBilling

// Deterministic test doubles, public so the demo app and your own tests can use
// them. They model the documented behaviour of the linked-billing API closely enough
// to exercise every branch of the gateway; they are not a substitute for testing
// against the real API with a second organization on your app's Test users list.

extension NSLock {
    /// Scoped locking that works on every Foundation (Darwin and swift-corelibs).
    fileprivate func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// A clock you move by hand.
public final class ManualClock: BillingClock, @unchecked Sendable {
    // @unchecked: all access to `current` goes through `lock`.
    private let lock = NSLock()
    private var current: EpochMillis

    public init(_ start: EpochMillis) { current = start }

    public func now() -> EpochMillis {
        lock.locked { current }
    }

    public func advance(by millis: Int64) {
        lock.locked { current = Saturating.add(current, max(0, millis)) }
    }

    public func set(_ millis: EpochMillis) {
        lock.locked { current = millis }
    }
}

/// A sleeper that returns at once and moves a `ManualClock` forward instead, and
/// records every requested wait.
public final class AdvancingSleeper: BillingSleeper, @unchecked Sendable {
    // @unchecked: all access to `waits` goes through `lock`; `clock` is itself safe.
    private let clock: ManualClock
    private let lock = NSLock()
    private var waits: [Int64] = []

    public init(clock: ManualClock) { self.clock = clock }

    public func sleep(millis: Int64) async throws {
        try Task.checkCancellation()
        lock.locked { waits.append(millis) }
        clock.advance(by: millis)
    }

    public var requestedWaits: [Int64] {
        lock.locked { waits }
    }
}

/// A simulated customer organization plus the Claude API in front of it.
///
/// Customer-billed requests are checked in the order the docs describe:
/// connection → propagation window → eligibility → spend cap → credit → mid-reply
/// failure. App-billed (`bill_to: "self"`) requests always succeed unless
/// `appRefusal` is set.
public actor SimulatedClaudeOrg: MessagesTransport, ConnectionStatusSource {
    public struct Received: Hashable, Sendable {
        public let payer: Payer
        public let profile: UserProfileID?
        public let model: ModelID
        public let featureID: String
    }

    private let clock: ManualClock

    public private(set) var connected = false
    public private(set) var revocationReason: ConnectionStatus.RevocationReason = .other
    private var everConnected = false
    private var connectedAt: EpochMillis = 0
    /// Refuse with `not_billable` for this long after `link()` (real API: ~10 s).
    public var propagationMillis: Int64 = 0
    /// Marketplace-billed, subscription-only, or no billing set up yet.
    public var eligible = true
    public var spendCap: MicroUSD?
    public private(set) var spentThisMonth: MicroUSD = .zero
    private var spendMonth: BillingMonth?
    public var credit: MicroUSD = .dollars(1_000)
    /// The next N customer-billed requests get `503 overloaded_error`.
    public var overloadNext = 0
    public var overloadRetryAfterSeconds: Int64? = 1
    /// The next customer-billed request fails with `billing_unavailable` mid-reply.
    public var failNextMidReply = false
    public var appRefusal: BillingRefusal?
    /// The next N status reads throw.
    public var failStatusReads = 0
    /// Delay each `send` by this much real time.
    public var sendLatencyNanos: UInt64 = 0
    /// When set, each `send` waits until this many sends are inside `send` together,
    /// or `holdDeadlineNanos` after the first one started waiting, whichever comes
    /// first. That makes a burst's overlap real and measurable (`maxConcurrentSends`)
    /// rather than a matter of scheduling luck, and the deadline means it never hangs.
    public var holdUntilInFlight: Int?
    public var holdDeadlineNanos: UInt64 = 500_000_000
    private var held: [CheckedContinuation<Void, Never>] = []
    private var holdGeneration = 0
    private var inFlight = 0
    /// The most sends that were inside `send` at the same moment.
    public private(set) var maxConcurrentSends = 0

    public private(set) var received: [Received] = []

    public init(clock: ManualClock) { self.clock = clock }

    // MARK: Scripting

    public func link() {
        connected = true
        everConnected = true
        connectedAt = clock.now()
    }

    private func releaseHeld(ifGeneration generation: Int? = nil) {
        if let generation, generation != holdGeneration { return }
        holdGeneration &+= 1
        let waiting = held
        held.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    /// Start measuring `maxConcurrentSends` afresh.
    public func resetConcurrencyGauge() {
        maxConcurrentSends = inFlight
    }

    public func unlink(reason: ConnectionStatus.RevocationReason) {
        connected = false
        revocationReason = reason
    }

    public func configure(_ change: @Sendable (isolated SimulatedClaudeOrg) -> Void) {
        change(self)
    }

    // MARK: MessagesTransport

    public func send(_ request: InferenceRequest, payer: Payer, profile: UserProfileID?,
                     model: ModelID) async throws -> TransportResult {
        inFlight += 1
        maxConcurrentSends = max(maxConcurrentSends, inFlight)
        defer { inFlight -= 1 }
        if let target = holdUntilInFlight {
            if inFlight >= target {
                releaseHeld()
            } else {
                if held.isEmpty {
                    let generation = holdGeneration
                    let deadline = holdDeadlineNanos
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: deadline)
                        await self?.releaseHeld(ifGeneration: generation)
                    }
                }
                await withCheckedContinuation { held.append($0) }
            }
        }
        if sendLatencyNanos > 0 { try await Task.sleep(nanoseconds: sendLatencyNanos) }
        received.append(Received(payer: payer, profile: profile, model: model, featureID: request.feature.id))
        let cost = model == request.feature.model
            ? request.estimate
            : BillingRouter.subsidyChoice(feature: request.feature, estimate: request.estimate).1

        guard case .customer = payer else {
            if let appRefusal { return .refused(appRefusal, partialReply: nil) }
            return .success(cost: cost, text: reply(for: request, model: model))
        }
        if overloadNext > 0 {
            overloadNext -= 1
            return .refused(.overloaded(retryAfterSeconds: overloadRetryAfterSeconds), partialReply: nil)
        }
        let now = clock.now()
        guard connected else { return .refused(.notBillable, partialReply: nil) }
        guard now >= Saturating.add(connectedAt, propagationMillis) else { return .refused(.notBillable, partialReply: nil) }
        guard eligible else { return .refused(.notBillable, partialReply: nil) }

        let month = BillingMonth(containing: now)
        if spendMonth != month { spendMonth = month; spentThisMonth = .zero }
        if let spendCap, spentThisMonth >= spendCap { return .refused(.spendLimitReached, partialReply: nil) }
        guard credit >= cost else { return .refused(.spendLimitReached, partialReply: nil) }
        if failNextMidReply {
            failNextMidReply = false
            return .refused(.billingUnavailable, partialReply: "Here is the first half of a repl")
        }
        spentThisMonth = spentThisMonth + cost
        credit = credit - cost
        return .success(cost: cost, text: reply(for: request, model: model))
    }

    // MARK: ConnectionStatusSource

    public func fetchStatus(for profile: UserProfileID) async throws -> ConnectionStatus {
        if failStatusReads > 0 {
            failStatusReads -= 1
            throw SimulatedOutage()
        }
        if connected { return .connected }
        return everConnected ? .disconnected(revokedAt: nil, reason: revocationReason) : .notConnected
    }

    public struct SimulatedOutage: Error {}

    private func reply(for request: InferenceRequest, model: ModelID) -> String {
        "[\(model)] \(request.feature.displayName): done"
    }
}
