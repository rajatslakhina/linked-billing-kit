/// Tunables for the link state machine. Defaults follow the Claude Platform docs
/// where the docs give a number, and are labelled as this package's choice where not.
/// Every field is clamped in `init` and again whenever it is set, so no value can
/// produce a probe time in the past or an interval that overflows when doubled.
public struct LinkPolicy: Hashable, Sendable {
    /// After a code exchange, `user_profile_not_billable` is retryable for about 10 s
    /// (docs). Refusals inside this window do not degrade the link.
    public var warmupMillis: Int64 { didSet { warmupMillis = min(max(0, warmupMillis), 120_000) } }
    /// First wait before re-trying the customer after `spend_limit_reached`. A
    /// customer can raise the cap or buy credit at any time, and the API does not
    /// tell you, so waiting for the month to end would subsidise them needlessly.
    /// (Package choice; a cap change takes about a minute to apply, per the docs.)
    public var capProbeMillis: Int64 { didSet { capProbeMillis = max(1_000, capProbeMillis) } }
    /// First wait before re-trying after `billing_unavailable` or `not_billable`.
    /// (Package choice.)
    public var refusalProbeMillis: Int64 { didSet { refusalProbeMillis = max(1_000, refusalProbeMillis) } }
    /// Probe intervals double after each failed probe, up to this ceiling.
    public var maxProbeMillis: Int64 { didSet { maxProbeMillis = max(1_000, maxProbeMillis) } }
    /// A probe that never reports (app killed, task cancelled) stops blocking further
    /// probes after this long. Set it above your transport's request timeout, or a
    /// slow probe that is still running will be joined by a second one. (Package
    /// choice: 10 min, above a long non-streaming Messages call.)
    public var probeTimeoutMillis: Int64 { didSet { probeTimeoutMillis = max(1_000, probeTimeoutMillis) } }
    /// A link flow that hasn't completed after this long is treated as abandoned. The
    /// pushed authorization request expires after 10 minutes (docs), and nothing tells
    /// your app when a user simply closes the sign-in sheet.
    public var pendingTimeoutMillis: Int64 { didSet { pendingTimeoutMillis = min(max(1_000, pendingTimeoutMillis), 3_600_000) } }

    public init(
        warmupMillis: Int64 = 10_000,
        capProbeMillis: Int64 = 15 * 60_000,
        refusalProbeMillis: Int64 = 30 * 60_000,
        maxProbeMillis: Int64 = 6 * 3_600_000,
        probeTimeoutMillis: Int64 = 10 * 60_000,
        pendingTimeoutMillis: Int64 = 10 * 60_000
    ) {
        // Clamp to sane, non-negative values so a bad config cannot produce a
        // probe schedule in the past or an interval that overflows when doubled.
        self.warmupMillis = min(max(0, warmupMillis), 120_000)
        self.capProbeMillis = max(1_000, capProbeMillis)
        self.refusalProbeMillis = max(1_000, refusalProbeMillis)
        self.maxProbeMillis = max(self.capProbeMillis, self.refusalProbeMillis, maxProbeMillis)
        self.probeTimeoutMillis = max(1_000, probeTimeoutMillis)
        self.pendingTimeoutMillis = min(max(1_000, pendingTimeoutMillis), 3_600_000)
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
    /// A customer-billed request issued `ticket` was refused. `sentAt` is when it was
    /// sent: the ~10 s warm-up window is judged by send time, not by when a slow
    /// response happened to arrive. (Defaults to the time the event is applied.)
    case customerRefused(BillingRefusal, ticket: Ticket, sentAt: EpochMillis? = nil)
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
///    overrides request-observed health; a `disconnected`/`not_connected` read issued
///    before a request that proved the connection alive (a success or a 402) doesn't
///    unlink it, whichever of the two arrives first.
public struct LinkState: Sendable {
    public private(set) var phase: LinkPhase
    public let policy: LinkPolicy

    private var nextSequence: UInt64 = 1
    /// Ticket of the latest link/unlink action. Older results are stale.
    private var authoritative = Ticket(sequence: 0)
    /// Ticket of the newest request outcome (success or billing refusal) applied.
    private var latestOutcome = Ticket(sequence: 0)
    /// Ticket of the newest request that proves the connection was alive when it was
    /// issued: a success, or a 402 (the API checks the connection before the cap and
    /// the org's billing).
    private var connectedEvidence = Ticket(sequence: 0)
    /// Set when a status read (not a user action) ended the link: the read's ticket.
    /// A request issued after that read which then proves the connection alive
    /// restores the link, so the order in which a read and an outcome *arrive*
    /// doesn't decide the result.
    private var unlinkedByRead: Ticket?
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

    public var isWarmingUp: Bool {
        if case .linked(.warmingUp) = phase { return true }
        return false
    }

    // MARK: Admission

    /// May the next request bill the customer? Read-only; call `beginProbe` when you
    /// act on a `.probe` answer.
    public func admission(at now: EpochMillis) -> CustomerAdmission {
        switch phase {
        case .notLinked: return .deny(.notLinked)
        case let .linkPending(startedAt):
            if now >= Saturating.add(startedAt, policy.pendingTimeoutMillis) {
                return .deny(everLinked ? .unlinked(nil) : .notLinked) // abandoned
            }
            return .deny(.linkInProgress)
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
        if case let .linkPending(startedAt) = phase, now >= Saturating.add(startedAt, policy.pendingTimeoutMillis) {
            phase = everLinked ? .unlinked(reason: nil, detectedAt: now) : .notLinked // abandoned flow
        }
        switch event {
        case .linkStarted:
            if case .linked = phase { break } // re-approving an active link changes nothing
            phase = .linkPending(startedAt: now)
        case .linkCompleted:
            authoritative = issueTicket()
            unlinkedByRead = nil
            everLinked = true
            clearProbe(resetFailures: true)
            phase = .linked(.warmingUp(until: Saturating.add(now, policy.warmupMillis)))
        case .linkCancelled:
            guard case .linkPending = phase else { break }
            phase = everLinked ? .unlinked(reason: nil, detectedAt: now) : .notLinked
        case .unlinkedByApp:
            authoritative = issueTicket()
            unlinkedByRead = nil
            clearProbe(resetFailures: true)
            phase = .unlinked(reason: .revokedByAppOwner, detectedAt: now)
        case let .statusObserved(status, ticket):
            guard ticket > authoritative else { break } // read began before a link/unlink
            applyStatus(status, ticket: ticket, now: now)
        case let .customerRefused(refusal, ticket, sentAt):
            applyRefusal(refusal, ticket: ticket, sentAt: sentAt ?? now, now: now)
        case let .customerBilled(ticket):
            applySuccess(ticket: ticket, now: now)
        case let .probeAbandoned(ticket):
            if probe?.ticket == ticket { clearProbe(resetFailures: false) }
        }
        return phase != before
    }

    private mutating func applyStatus(_ status: ConnectionStatus, ticket: Ticket, now: EpochMillis) {
        // A negative read issued before a request that proved the connection alive
        // (paid for, or refused with a 402) is older evidence: don't let it unlink.
        let olderThanEvidence = ticket < connectedEvidence
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
                unlinkedByRead = nil
                everLinked = true
                clearProbe(resetFailures: true)
                phase = .linked(.billable)
            }
        case let .disconnected(_, reason):
            if olderThanEvidence { return }
            switch phase {
            case .linkPending:
                return // the old link ended; the new one is in progress
            case .unlinked:
                return
            case .linked, .notLinked:
                if case .linked = phase { unlinkedByRead = ticket }
                everLinked = true
                clearProbe(resetFailures: true)
                phase = .unlinked(reason: reason, detectedAt: now)
            }
        case .notConnected:
            if olderThanEvidence { return }
            switch phase {
            case .linkPending, .notLinked:
                return
            case .linked, .unlinked:
                if case .linked = phase { unlinkedByRead = ticket }
                clearProbe(resetFailures: true)
                phase = .notLinked
            }
        }
    }

    /// A read unlinked us, but a request issued *after* that read has now proved the
    /// connection alive (a success or a 402): the read was stale by the time it
    /// landed. Put the link back so the outcome can be applied.
    private mutating func restoreIfUnlinkedByOlderRead(_ ticket: Ticket) {
        guard let read = unlinkedByRead, ticket > read, ticket > authoritative else { return }
        switch phase {
        case .unlinked, .notLinked:
            unlinkedByRead = nil
            phase = .linked(.billable)
        case .linked, .linkPending:
            return
        }
    }

    private mutating func applyRefusal(_ refusal: BillingRefusal, ticket: Ticket, sentAt: EpochMillis, now: EpochMillis) {
        if refusal == .spendLimitReached || refusal == .billingUnavailable { restoreIfUnlinkedByOlderRead(ticket) }
        guard ticket > authoritative, case let .linked(health) = phase else { return }
        guard refusal.isCustomerBillingSignal else {
            // Overloaded / caller bugs say nothing about the customer. A probe that
            // hit one simply did not answer the question.
            if probe?.ticket == ticket { clearProbe(resetFailures: false) }
            return
        }
        // A 402 proves the connection was alive when the request was issued, even if
        // the outcome itself turns out to be stale below.
        if refusal == .spendLimitReached || refusal == .billingUnavailable {
            connectedEvidence = max(connectedEvidence, ticket)
        }
        // Invariant 2: an outcome older than the newest applied one is stale.
        guard ticket > latestOutcome else {
            if probe?.ticket == ticket { clearProbe(resetFailures: false) }
            return
        }

        if case let .warmingUp(until) = health, refusal == .notBillable, sentAt < until {
            return // the docs' ~10 s propagation window: retry, don't degrade
        }
        let wasProbe = probe?.ticket == ticket
        if wasProbe {
            failedProbes = min(failedProbes + 1, 16)
            clearProbe(resetFailures: false)
        }
        // A non-probe refusal leaves an in-flight probe in place: that probe is
        // still the one request allowed to test recovery.
        latestOutcome = ticket

        switch refusal {
        case .spendLimitReached:
            // The cap that refused it belongs to the month the request was sent in. If that
            // month has already ended by arrival, `next` is due immediately.
            let resetsAt = BillingMonth(containing: sentAt).end
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
        restoreIfUnlinkedByOlderRead(ticket)
        guard ticket > authoritative, case .linked = phase else { return }
        connectedEvidence = max(connectedEvidence, ticket) // the org paid: it was connected
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
        // The ceiling never drops below the first interval, whatever order the policy's
        // fields were set in.
        let ceiling = max(policy.maxProbeMillis, base)
        var interval = base
        var remaining = failedProbes
        while remaining > 0, interval < ceiling {
            interval = Saturating.multiply(interval, 2)
            remaining -= 1
        }
        return min(interval, ceiling)
    }
}
