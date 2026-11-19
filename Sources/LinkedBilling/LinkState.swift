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
/// from the same `LinkState` (including the expiry of an abandoned link flow), so "which happened first" is decided by issue order,
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
/// It keeps three things apart, and derives `phase` from them:
/// - **`base`**: what the user and your back end did (link, cancel, unlink) or what a
///   `connected` read showed; changed only by those authoritative events.
/// - **`health`**: what request outcomes say about billing, updated by the newest
///   *issued* outcome only (it keeps updating even while a read says unlinked).
/// - **connectivity evidence**: the newest negative read (`disconnected` /
///   `not_connected`) versus the newest proof that the connection was alive (a
///   success, a 402, or a `connected` read). Whichever was *issued* later decides.
///
/// Every input is folded in with a ticket comparison against a running maximum, so
/// the final state doesn't depend on the order results *arrive* in. Time-driven
/// changes (an abandoned link flow expiring) are folded by `settle(at:)`, which every
/// ticket-issuing entry point calls first, so the expiry is ordered before any ticket
/// issued after it and after any ticket issued before it.
///
/// Two cases are inherently ambiguous, because a link flow's start doesn't change the
/// connection a read in flight is reporting on. They are resolved by a fresh read:
/// - A `connected` read issued just *before* the user starts a link flow. If it lands
///   first it links the profile (and the flow's start leaves the link in place); if
///   the flow starts first, the read is stale.
/// - A negative read issued just before the user starts a flow on a link that still
///   reads as linked. If it lands first the link reads unlinked and the flow starts
///   (`.linkPending`); if it lands after, the start leaves the link in place and the
///   read then unlinks it. Either way the customer is no longer billed.
/// Completing the flow gives the same state in every order. After a cancel or an
/// expired flow, take a fresh read (`ConnectionReconciler.linkCancelled()` does both
/// for a cancel; the reconciler's polling delay wakes at a pending flow's expiry).
///
/// Invariants (each has a test, and a mutant in `scripts/mutation-check.sh`):
/// 1. A result issued before the latest link/unlink action never changes `base`,
///    `health` or the evidence. The one
///    thing a stale read still records is that a `disconnected` profile was once
///    linked, a permanent fact that decides whether an abandoned flow reads as
///    `.notLinked` or `.unlinked`.
/// 2. Of two request outcomes, the one issued later wins: a success issued before
///    the refusal that degraded the link never un-degrades it, and a refusal issued
///    before a recovering success never re-degrades it, in any arrival order.
/// 3. While degraded, at most one probe is in flight; a lost probe expires.
/// 4. `spend_limit_reached` is never probed later than 00:00 UTC on the 1st.
/// 5. `connection_status` of `unknown` never changes state; `connected` never
///    overrides request-observed health; between a negative read and a request that
///    proved the connection alive (a success, a 402 or a `connected` read), the one
///    issued later decides
///    whether the link reads as unlinked, in any arrival order.
public struct LinkState: Sendable {
    /// User- and back-end-driven part of the state.
    private enum Base: Sendable {
        case notLinked
        case pending(startedAt: EpochMillis)
        /// A link flow that was cancelled or expired at `at`. Whether it reads as
        /// `.notLinked` or `.unlinked` is derived from `everLinked` when `phase` is read,
        /// not fixed at cancel time, so a `disconnected` read that lands after the cancel
        /// gives the same answer as one that landed before it.
        case abandoned(at: EpochMillis)
        case linked
        case unlinked(reason: ConnectionStatus.RevocationReason?, at: EpochMillis)
    }

    public let policy: LinkPolicy

    private var base: Base
    private var health: LinkedHealth
    private var nextSequence: UInt64 = 1
    /// Ticket of the latest link/unlink action. Older results are stale.
    private var authoritative = Ticket(sequence: 0)
    /// Ticket of the newest request outcome (success or billing refusal) applied.
    private var latestOutcome = Ticket(sequence: 0)
    /// Newest proof the connection was alive when issued: a success, a 402, or a
    /// `connected` read. (That a 402 implies a live connection is inferred from the
    /// docs, which refuse ended or unlinked connections with 403 `not_billable`.)
    private var connectedEvidence = Ticket(sequence: 0)
    /// Newest `disconnected` / `not_connected` read since the last link/unlink action.
    private var negativeRead: (ticket: Ticket, status: ConnectionStatus, at: EpochMillis)?
    private var probe: (ticket: Ticket, startedAt: EpochMillis)?
    private var failedProbes: Int = 0
    private var everLinked: Bool
    /// End of the ~10 s propagation window after the latest code exchange. Kept apart
    /// from `health` so that whether a `not_billable` falls inside the window depends
    /// only on when it was *sent*, not on which other outcome happened to land first.
    private var warmupUntil: EpochMillis?

    public init(phase: LinkPhase = .notLinked, policy: LinkPolicy = LinkPolicy()) {
        self.policy = policy
        switch phase {
        case .notLinked:
            base = .notLinked; health = .billable; everLinked = false
        case let .linkPending(startedAt):
            base = .pending(startedAt: startedAt); health = .billable; everLinked = false
        case let .linked(health):
            base = .linked; self.health = health; everLinked = true
            if case let .warmingUp(until) = health { warmupUntil = until }
        case let .unlinked(reason, at):
            base = .unlinked(reason: reason, at: at); health = .billable; everLinked = true
        }
    }

    /// The link as the rest of the app sees it, derived from base, health and evidence.
    public var phase: LinkPhase {
        switch base {
        case .notLinked:
            if let read = negativeRead, case let .disconnected(_, reason) = read.status {
                return .unlinked(reason: reason, detectedAt: read.at)
            }
            return .notLinked
        case let .pending(startedAt):
            return .linkPending(startedAt: startedAt)
        case let .abandoned(at):
            if let read = negativeRead {
                switch read.status {
                case let .disconnected(_, reason): return .unlinked(reason: reason, detectedAt: read.at)
                // As on a linked base: the server has no connection, so nothing to relink.
                case .notConnected: return .notLinked
                case .connected, .unknown: break // never stored as a negative read
                }
            }
            return everLinked ? .unlinked(reason: nil, detectedAt: at) : .notLinked
        case let .unlinked(reason, at):
            return .unlinked(reason: reason, detectedAt: at)
        case .linked:
            if let read = negativeRead, read.ticket > connectedEvidence {
                switch read.status {
                case let .disconnected(_, reason): return .unlinked(reason: reason, detectedAt: read.at)
                case .notConnected, .connected, .unknown: return .notLinked
                }
            }
            return .linked(health)
        }
    }

    /// Fold time-driven changes as of `now`: a link flow older than
    /// `LinkPolicy.pendingTimeoutMillis` becomes abandoned, and the abandonment takes a
    /// ticket (so status reads issued before it are stale, and reads issued after it
    /// count). Call it before issuing a ticket at `now`; `issueTicket(at:)`, `apply` and
    /// the gateway all do.
    public mutating func settle(at now: EpochMillis) {
        guard case let .pending(startedAt) = base else { return }
        let expiry = Saturating.add(startedAt, policy.pendingTimeoutMillis)
        guard now >= expiry else { return }
        endUserLevelChange()
        base = .abandoned(at: expiry)
    }

    /// `settle(at: now)`, then issue the next ordering token. Prefer this to
    /// `issueTicket()` whenever you know the time.
    public mutating func issueTicket(at now: EpochMillis) -> Ticket {
        settle(at: now)
        return issueTicket()
    }

    /// Issue the next ordering token, without settling time-driven changes first.
    public mutating func issueTicket() -> Ticket {
        let ticket = Ticket(sequence: nextSequence)
        // UInt64 wraps only after 1.8e19 issues; &+= documents that it is not a trap.
        nextSequence &+= 1
        return ticket
    }

    public var probeInFlight: Bool { probe != nil }

    /// Kept for source compatibility. It never ends the window on its own (it reads the
    /// event-driven `phase`); use `isWarmingUp(at:)`.
    @available(*, deprecated, message: "Use isWarmingUp(at:), which ends the window on time.")
    public var isWarmingUp: Bool {
        if case .linked(.warmingUp) = phase { return true }
        return false
    }

    /// Whether the link reads as still inside the propagation window at `now`.
    public func isWarmingUp(at now: EpochMillis) -> Bool {
        if case .linked(.warmingUp) = phase(at: now) { return true }
        return false
    }

    /// Whether a request sent at `sentAt` falls inside the propagation window after
    /// the latest code exchange (where `not_billable` is retried, not trusted).
    public func isInWarmup(sentAt: EpochMillis) -> Bool {
        guard let warmupUntil else { return false }
        return sentAt < warmupUntil
    }

    /// The phase as of `now`: like `phase`, but with time already applied. A link flow
    /// older than `LinkPolicy.pendingTimeoutMillis` reads as abandoned, and a warm-up
    /// window that has ended reads as `.billable`. Use this for UI and scheduling;
    /// `phase` only moves when an event is applied.
    public func phase(at now: EpochMillis) -> LinkPhase {
        if case let .pending(startedAt) = base, now >= Saturating.add(startedAt, policy.pendingTimeoutMillis) {
            return everLinked ? .unlinked(reason: nil, detectedAt: Saturating.add(startedAt, policy.pendingTimeoutMillis)) : .notLinked
        }
        let current = phase
        if case let .linked(.warmingUp(until)) = current, now >= until { return .linked(.billable) }
        return current
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

    /// Apply an event. Returns `true` if `phase(at: now)` changed, so time-driven changes
    /// that `phase(at:)` already showed don't count.
    @discardableResult
    public mutating func apply(_ event: LinkEvent, at now: EpochMillis) -> Bool {
        let before = phase(at: now)
        settle(at: now)
        switch event {
        case .linkStarted:
            // Re-approving a link that reads as linked (e.g. a scope change) leaves it in
            // place: the flow doesn't change the connection. A link that a status read
            // found unlinked starts a real flow, so it reads `.linkPending` until the
            // code exchange, not billable.
            if case .linked = phase { break }
            endUserLevelChange()
            base = .pending(startedAt: now)
        case .linkCompleted:
            endUserLevelChange()
            everLinked = true
            clearProbe(resetFailures: true)
            base = .linked
            let until = Saturating.add(now, policy.warmupMillis)
            warmupUntil = until
            health = .warmingUp(until: until)
        case .linkCancelled:
            guard case .pending = base else { break }
            endUserLevelChange()
            base = .abandoned(at: now)
        case .unlinkedByApp:
            endUserLevelChange()
            warmupUntil = nil
            clearProbe(resetFailures: true)
            base = .unlinked(reason: .revokedByAppOwner, at: now)
        case let .statusObserved(status, ticket):
            // `disconnected` means the profile had a connection that ended: a permanent
            // fact about the profile, recorded even when the read itself is stale.
            if case .disconnected = status { everLinked = true }
            guard ticket > authoritative else { break } // read began before a link/unlink
            applyStatus(status, ticket: ticket, now: now)
        case let .customerRefused(refusal, ticket, sentAt):
            applyRefusal(refusal, ticket: ticket, sentAt: sentAt ?? now, now: now)
        case let .customerBilled(ticket):
            applySuccess(ticket: ticket, now: now)
        case let .probeAbandoned(ticket):
            if probe?.ticket == ticket { clearProbe(resetFailures: false) }
        }
        return phase(at: now) != before
    }

    private mutating func applyStatus(_ status: ConnectionStatus, ticket: Ticket, now: EpochMillis) {
        switch status {
        case .unknown:
            return
        case .connected:
            // Positive evidence: outvotes any older negative read. It says nothing
            // about billability, so health is left alone.
            connectedEvidence = max(connectedEvidence, ticket)
            switch base {
            case .linked, .pending:
                return // a pending OAuth flow is still the user's to finish or cancel
            case .notLinked, .abandoned, .unlinked:
                // Linked from elsewhere (another device or the web).
                everLinked = true
                clearProbe(resetFailures: true)
                warmupUntil = nil
                base = .linked
                health = .billable
            }
        case .disconnected, .notConnected:
            if case .pending = base { return } // an old link ended; the new one is in progress
            // Keep only the newest negative read; `phase` compares it with the newest
            // positive evidence.
            if let current = negativeRead, current.ticket > ticket { return }
            negativeRead = (ticket, status, now)
        }
    }

    private mutating func applyRefusal(_ refusal: BillingRefusal, ticket: Ticket, sentAt: EpochMillis, now: EpochMillis) {
        guard ticket > authoritative, case .linked = base else { return }
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
        if refusal == .notBillable, isInWarmup(sentAt: sentAt) {
            // The docs' ~10 s propagation window: retry, don't degrade. A probe that hit
            // it didn't answer the question, so it frees the slot.
            if probe?.ticket == ticket { clearProbe(resetFailures: false) }
            return
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
            health = .spendLimitReached(resetsAt: resetsAt, nextProbeAt: next)
        case .billingUnavailable:
            health = .billingUnavailable(nextProbeAt: Saturating.add(now, backoff(policy.refusalProbeMillis)))
        case .notBillable:
            health = .notBillable(nextProbeAt: Saturating.add(now, backoff(policy.refusalProbeMillis)))
        case .overloaded, .userProfileRequired, .invalidRequest, .other:
            return // unreachable: filtered by isCustomerBillingSignal above
        }
    }

    private mutating func applySuccess(ticket: Ticket, now: EpochMillis) {
        guard ticket > authoritative, case .linked = base else { return }
        connectedEvidence = max(connectedEvidence, ticket) // the org paid: it was connected
        // Invariant 2: only a request issued after the newest applied outcome counts.
        // (A stale success from before a degrading refusal is not evidence of recovery.)
        guard ticket > latestOutcome else {
            if probe?.ticket == ticket { clearProbe(resetFailures: false) }
            return
        }
        latestOutcome = ticket
        clearProbe(resetFailures: true)
        health = .billable
    }

    /// A link, unlink, start, cancel or expiry: everything issued before it is stale,
    /// and any negative read belongs to the previous flow.
    private mutating func endUserLevelChange() {
        authoritative = issueTicket()
        negativeRead = nil
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
