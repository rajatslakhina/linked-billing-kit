/// Tunables for the link state machine. Defaults follow the Claude Platform docs
/// where the docs give a number, and are labelled as this package's choice where not.
public struct LinkPolicy: Hashable, Sendable {
    /// After a code exchange, `user_profile_not_billable` is retryable for about 10 s
    /// (docs). Refusals inside this window do not degrade the link.
    public var warmupMillis: Int64
    /// First wait before re-trying the customer after `spend_limit_reached`. A
    /// customer can raise the cap or buy credit at any time, and the API does not
    /// tell you, so waiting for the month to end would subsidise them needlessly.
    /// (Package choice; a cap change takes about a minute to apply, per the docs.)
    public var capProbeMillis: Int64
    /// First wait before re-trying after `billing_unavailable` or `not_billable`.
    /// (Package choice.)
    public var refusalProbeMillis: Int64
    /// Probe intervals double after each failed probe, up to this ceiling.
    public var maxProbeMillis: Int64
    /// A probe that never reports (app killed, task cancelled) stops blocking further
    /// probes after this long. (Package choice.)
    public var probeTimeoutMillis: Int64

    public init(
        warmupMillis: Int64 = 10_000,
        capProbeMillis: Int64 = 15 * 60_000,
        refusalProbeMillis: Int64 = 30 * 60_000,
        maxProbeMillis: Int64 = 6 * 3_600_000,
        probeTimeoutMillis: Int64 = 2 * 60_000
    ) {
        // Clamp to sane, non-negative values so a bad config cannot produce a
        // probe schedule in the past or an interval that overflows when doubled.
        self.warmupMillis = min(max(0, warmupMillis), 120_000)
        self.capProbeMillis = max(1_000, capProbeMillis)
        self.refusalProbeMillis = max(1_000, refusalProbeMillis)
        self.maxProbeMillis = max(self.capProbeMillis, self.refusalProbeMillis, maxProbeMillis)
        self.probeTimeoutMillis = max(1_000, probeTimeoutMillis)
    }
}

/// Monotonic ordering token. Every request, status read and user action takes one
/// from the same `LinkState`, so "which happened first" is decided by issue order,
/// never by wall-clock timestamps that can tie or go backwards. This is what makes
/// results that arrive late (after an actor suspension) safe to apply.
public struct Ticket: Hashable, Comparable, Sendable {
    public let sequence: UInt64
    public static func < (lhs: Ticket, rhs: Ticket) -> Bool { lhs.sequence < rhs.sequence }
}

/// Why the customer's organization is being skipped right now.
public enum CustomerDenial: Hashable, Sendable {
    case notLinked
    case linkInProgress
    case unlinked(ConnectionStatus.RevocationReason?)
    case spendLimitReached(resetsAt: EpochMillis)
    case billingUnavailable
    case notBillable
}

public enum CustomerAdmission: Hashable, Sendable {
    /// Bill the customer.
    case admit
    /// Bill the customer, as the single request that tests whether a degraded link
    /// has recovered. Only one probe is admitted at a time.
    case probe
    case deny(CustomerDenial)
}

/// Health of a link that `connection_status` reports as connected (or that the app
/// just completed). `connected` "doesn't promise that a request will succeed"
/// (docs), so health comes from request outcomes, not from status reads.
public enum LinkedHealth: Hashable, Sendable {
    case warmingUp(until: EpochMillis)
    case billable
    case spendLimitReached(resetsAt: EpochMillis, nextProbeAt: EpochMillis)
    case billingUnavailable(nextProbeAt: EpochMillis)
    case notBillable(nextProbeAt: EpochMillis)

    var isDegraded: Bool {
        switch self {
        case .warmingUp, .billable: return false
        case .spendLimitReached, .billingUnavailable, .notBillable: return true
        }
    }
}

public enum LinkPhase: Hashable, Sendable {
    case notLinked
    case linkPending(startedAt: EpochMillis)
    case linked(LinkedHealth)
    case unlinked(reason: ConnectionStatus.RevocationReason?, detectedAt: EpochMillis)
}

/// Inputs to the state machine. Each carries the `Ticket` it was issued when the
/// underlying action *started*, so a result is judged against what was true then.
public enum LinkEvent: Hashable, Sendable {
    case linkStarted
    case linkCompleted
    case linkCancelled
    /// Your back end called `POST /v1/user_profiles/{id}/unlink`.
    case unlinkedByApp
    /// A `connection_status` read that was issued `ticket`.
    case statusObserved(ConnectionStatus, ticket: Ticket)
    /// A customer-billed request issued `ticket` was refused.
    case customerRefused(BillingRefusal, ticket: Ticket)
    /// A customer-billed request issued `ticket` succeeded.
    case customerBilled(ticket: Ticket)
    /// A customer-billed probe ended without an answer (transport error, cancelled).
    case probeAbandoned(ticket: Ticket)
}

/// The client's model of one customer's linked-billing connection: a pure,
/// synchronous state machine. It has no I/O and no clock; callers pass `now`.
///
/// Invariants (each has a test, and a mutant in `scripts/mutation-check.sh`):
/// 1. A result issued before the latest link/unlink action never changes state.
/// 2. Of two request outcomes, the one issued later wins: a success issued before
///    the refusal that degraded the link never un-degrades it, and a refusal issued
///    before a recovering success never re-degrades it.
/// 3. While degraded, at most one probe is in flight; a lost probe expires.
/// 4. `spend_limit_reached` is never probed later than 00:00 UTC on the 1st.
/// 5. `connection_status` of `unknown` never changes state; `connected` never
///    overrides request-observed health.
public struct LinkState: Sendable {
    public private(set) var phase: LinkPhase
    public let policy: LinkPolicy

    private var nextSequence: UInt64 = 1
    /// Ticket of the latest link/unlink action. Older results are stale.
    private var authoritative = Ticket(sequence: 0)
    /// Ticket of the newest request outcome (success or billing refusal) applied.
    private var latestOutcome = Ticket(sequence: 0)
    private var probe: (ticket: Ticket, startedAt: EpochMillis)?
    private var failedProbes: Int = 0
    private var everLinked: Bool

    public init(phase: LinkPhase = .notLinked, policy: LinkPolicy = LinkPolicy()) {
        self.phase = phase
        self.policy = policy
        switch phase {
        case .linked, .unlinked: everLinked = true
        case .notLinked, .linkPending: everLinked = false
        }
    }

    /// Issue the next ordering token.
    public mutating func issueTicket() -> Ticket {
        let ticket = Ticket(sequence: nextSequence)
        // UInt64 wraps only after 1.8e19 issues; &+= documents that it is not a trap.
        nextSequence &+= 1
        return ticket
    }

    public var probeInFlight: Bool { probe != nil }

    // MARK: Admission

    /// May the next request bill the customer? Read-only; call `beginProbe` when you
    /// act on a `.probe` answer.
    public func admission(at now: EpochMillis) -> CustomerAdmission {
        switch phase {
        case .notLinked: return .deny(.notLinked)
        case .linkPending: return .deny(.linkInProgress)
        case let .unlinked(reason, _): return .deny(.unlinked(reason))
        case let .linked(health):
            switch health {
            case .billable, .warmingUp:
                return .admit
            case let .spendLimitReached(resetsAt, nextProbeAt):
                return probeAdmission(due: min(nextProbeAt, resetsAt), now: now,
                                      otherwise: .spendLimitReached(resetsAt: resetsAt))
            case let .billingUnavailable(nextProbeAt):
                return probeAdmission(due: nextProbeAt, now: now, otherwise: .billingUnavailable)
            case let .notBillable(nextProbeAt):
                return probeAdmission(due: nextProbeAt, now: now, otherwise: .notBillable)
            }
        }
    }

    private func probeAdmission(due: EpochMillis, now: EpochMillis, otherwise: CustomerDenial) -> CustomerAdmission {
        if let probe {
            // One probe at a time, unless the one in flight has been lost.
            guard now >= Saturating.add(probe.startedAt, policy.probeTimeoutMillis) else {
                return .deny(otherwise)
            }
        }
        guard now >= due else { return .deny(otherwise) }
        return .probe
    }

    /// Record that the request issued `ticket` is the probe. Returns `false` (and
    /// records nothing) if the state no longer admits a probe at `now`, so two
    /// callers that both read `.probe` cannot both send one.
    public mutating func beginProbe(ticket: Ticket, at now: EpochMillis) -> Bool {
        guard admission(at: now) == .probe else { return false }
        probe = (ticket, now)
        return true
    }

    // MARK: Transitions

    /// Apply an event. Returns `true` if the phase changed.
    @discardableResult
    public mutating func apply(_ event: LinkEvent, at now: EpochMillis) -> Bool {
        let before = phase
        switch event {
        case .linkStarted:
            if case .linked = phase { break } // re-approving an active link changes nothing
            phase = .linkPending(startedAt: now)
        case .linkCompleted:
            authoritative = issueTicket()
            everLinked = true
            clearProbe(resetFailures: true)
            phase = .linked(.warmingUp(until: Saturating.add(now, policy.warmupMillis)))
        case .linkCancelled:
            guard case .linkPending = phase else { break }
            phase = everLinked ? .unlinked(reason: nil, detectedAt: now) : .notLinked
        case .unlinkedByApp:
            authoritative = issueTicket()
            clearProbe(resetFailures: true)
            phase = .unlinked(reason: .revokedByAppOwner, detectedAt: now)
        case let .statusObserved(status, ticket):
            guard ticket > authoritative else { break } // read began before a link/unlink
            applyStatus(status, now: now)
        case let .customerRefused(refusal, ticket):
            applyRefusal(refusal, ticket: ticket, now: now)
        case let .customerBilled(ticket):
            applySuccess(ticket: ticket, now: now)
        case let .probeAbandoned(ticket):
            if probe?.ticket == ticket { clearProbe(resetFailures: false) }
        }
        return phase != before
    }

    private mutating func applyStatus(_ status: ConnectionStatus, now: EpochMillis) {
        switch status {
        case .unknown:
            return
        case .connected:
            switch phase {
            case .linked, .linkPending:
                // Connected says nothing about billability; a pending OAuth flow is
                // still the user's to finish or cancel.
                return
            case .notLinked, .unlinked:
                // Linked from elsewhere (another device or the web).
                everLinked = true
                clearProbe(resetFailures: true)
                phase = .linked(.billable)
            }
        case let .disconnected(_, reason):
            switch phase {
            case .linkPending:
                return // the old link ended; the new one is in progress
            case .unlinked:
                return
            case .linked, .notLinked:
                everLinked = true
                clearProbe(resetFailures: true)
                phase = .unlinked(reason: reason, detectedAt: now)
            }
        case .notConnected:
            switch phase {
            case .linkPending, .notLinked:
                return
            case .linked, .unlinked:
                clearProbe(resetFailures: true)
                phase = .notLinked
            }
        }
    }

    private mutating func applyRefusal(_ refusal: BillingRefusal, ticket: Ticket, now: EpochMillis) {
        guard ticket > authoritative, case let .linked(health) = phase else { return }
        guard refusal.isCustomerBillingSignal else {
            // Overloaded / caller bugs say nothing about the customer. A probe that
            // hit one simply did not answer the question.
            if probe?.ticket == ticket { clearProbe(resetFailures: false) }
            return
        }
        // Invariant 2: an outcome older than the newest applied one is stale.
        guard ticket > latestOutcome else {
            if probe?.ticket == ticket { clearProbe(resetFailures: false) }
            return
        }

        if case let .warmingUp(until) = health, refusal == .notBillable, now < until {
            return // the docs' ~10 s propagation window: retry, don't degrade
        }
        let wasProbe = probe?.ticket == ticket
        if wasProbe { failedProbes = min(failedProbes + 1, 16) }
        clearProbe(resetFailures: false)
        latestOutcome = ticket

        switch refusal {
        case .spendLimitReached:
            let resetsAt = BillingMonth(containing: now).end
            let next = min(Saturating.add(now, backoff(policy.capProbeMillis)), resetsAt)
            phase = .linked(.spendLimitReached(resetsAt: resetsAt, nextProbeAt: next))
        case .billingUnavailable:
            phase = .linked(.billingUnavailable(nextProbeAt: Saturating.add(now, backoff(policy.refusalProbeMillis))))
        case .notBillable:
            phase = .linked(.notBillable(nextProbeAt: Saturating.add(now, backoff(policy.refusalProbeMillis))))
        case .overloaded, .userProfileRequired, .invalidRequest, .other:
            return // unreachable: filtered by isCustomerBillingSignal above
        }
    }

    private mutating func applySuccess(ticket: Ticket, now: EpochMillis) {
        guard ticket > authoritative, case .linked = phase else { return }
        // Invariant 2: only a request issued after the newest applied outcome counts.
        // (A stale success from before a degrading refusal is not evidence of recovery.)
        guard ticket > latestOutcome else {
            if probe?.ticket == ticket { clearProbe(resetFailures: false) }
            return
        }
        latestOutcome = ticket
        clearProbe(resetFailures: true)
        phase = .linked(.billable)
    }

    private mutating func clearProbe(resetFailures: Bool) {
        probe = nil
        if resetFailures { failedProbes = 0 }
    }

    /// base × 2^failedProbes, saturating, capped at `maxProbeMillis`.
    private func backoff(_ base: Int64) -> Int64 {
        var interval = base
        var remaining = failedProbes
        while remaining > 0, interval < policy.maxProbeMillis {
            interval = Saturating.multiply(interval, 2)
            remaining -= 1
        }
        return min(interval, policy.maxProbeMillis)
    }
}
