/// Which of the app's own budgets an app-paid request draws on.
public enum AppBudget: Hashable, Sendable, CaseIterable {
    /// Usage the user already paid for through an App Store subscription.
    case included
    /// Goodwill spend: the app pays because the customer's org can't right now.
    case subsidy
    /// The app's own operational usage (evals, moderation, onboarding). Unbudgeted
    /// here, but recorded so it is never confused with customer-directed usage.
    case operational
}

/// What one request did to money, as far as the app can know.
public enum LedgerOutcome: Hashable, Sendable {
    case billed(MicroUSD)
    /// Refused by the API: nobody was billed (docs: refusals are not billed).
    case refused(BillingRefusal)
    /// The transport failed after sending. The request may or may not have been
    /// served and billed; the ledger says so rather than guessing.
    case unknown
}

public struct LedgerEntry: Hashable, Sendable, Identifiable {
    public let id: UInt64
    public let featureID: String
    public let payer: Payer
    public let budget: AppBudget?
    public let model: ModelID
    public let at: EpochMillis
    public let outcome: LedgerOutcome
}

/// Month-to-date totals for one customer.
public struct SpendTotals: Hashable, Sendable {
    public var customerBilled: MicroUSD = .zero
    public var appIncluded: MicroUSD = .zero
    public var appSubsidy: MicroUSD = .zero
    public var appOperational: MicroUSD = .zero
    /// Requests whose billing the app could not determine (transport failures).
    public var unknownOutcomes: Int = 0

    public init() {}

    func spent(_ budget: AppBudget) -> MicroUSD {
        switch budget {
        case .included: return appIncluded
        case .subsidy: return appSubsidy
        case .operational: return appOperational
        }
    }

    mutating func add(_ amount: MicroUSD, payer: Payer, budget: AppBudget?) {
        switch (payer, budget) {
        case (.customer, _): customerBilled = customerBilled + amount
        case (.app, .included?): appIncluded = appIncluded + amount
        case (.app, .subsidy?): appSubsidy = appSubsidy + amount
        case (.app, .operational?), (.app, nil): appOperational = appOperational + amount
        }
    }
}

public struct ReservationID: Hashable, Sendable {
    let raw: UInt64
}

/// The app's own record of who paid for what.
///
/// A successful response "doesn't say who was billed" (docs), so this ledger is the
/// only source of truth for both the customer-facing usage screen and the app's
/// subsidy budget. Two properties matter:
///
/// - **Reservations.** Budget checks count money that is *reserved* by in-flight
///   requests, not just money already spent. Without that, N concurrent requests can
///   each see the same remaining budget and overshoot it N-fold.
/// - **Bounded memory.** Totals are kept for the last `monthsRetained` UTC months
///   and the entry log is a ring of `entryCapacity` items.
public struct SpendLedger: Sendable {
    public let entryCapacity: Int
    public let monthsRetained: Int

    private var totals: [BillingMonth: SpendTotals] = [:]
    private var reserved: [ReservationID: (month: BillingMonth, budget: AppBudget, amount: MicroUSD)] = [:]
    /// Running sum of `reserved` per (month, budget), so a budget check is O(1)
    /// rather than a scan of every in-flight request.
    private var reservedTotals: [ReservedKey: MicroUSD] = [:]

    private struct ReservedKey: Hashable {
        let month: BillingMonth
        let budget: AppBudget
    }
    private var ring: [LedgerEntry] = []
    private var ringStart = 0
    private var nextID: UInt64 = 1

    public init(entryCapacity: Int = 256, monthsRetained: Int = 3) {
        self.entryCapacity = min(max(1, entryCapacity), 100_000)
        self.monthsRetained = min(max(1, monthsRetained), 24)
        ring.reserveCapacity(min(self.entryCapacity, 1024))
    }

    // MARK: Budgets

    public func totals(for month: BillingMonth) -> SpendTotals { totals[month] ?? SpendTotals() }

    /// Months that have recorded activity, newest first (at most `monthsRetained`,
    /// plus the current month).
    public var months: [BillingMonth] { totals.keys.sorted(by: >) }

    /// Spent plus currently reserved for `budget` in `month`.
    public func committed(_ budget: AppBudget, in month: BillingMonth) -> MicroUSD {
        totals(for: month).spent(budget) + (reservedTotals[ReservedKey(month: month, budget: budget)] ?? .zero)
    }

    /// Reserve `amount` against `budget` if it fits under `limit`. Returns `nil` when it
    /// does not, so a caller can't accidentally spend past a budget.
    public mutating func reserve(_ amount: MicroUSD, from budget: AppBudget, limit: MicroUSD,
                                 at now: EpochMillis) -> ReservationID? {
        let month = BillingMonth(containing: now)
        // Bounded even if a caller leaks reservations: refuse rather than grow.
        guard reserved.count < Self.maxReservations else { return nil }
        guard committed(budget, in: month) + amount <= limit else { return nil }
        let id = ReservationID(raw: nextID)
        nextID &+= 1
        reserved[id] = (month, budget, amount)
        let key = ReservedKey(month: month, budget: budget)
        reservedTotals[key] = (reservedTotals[key] ?? .zero) + amount
        return id
    }

    /// Release a reservation without spending it (refused, or never sent).
    public mutating func release(_ id: ReservationID) {
        _ = takeReservation(id)
    }

    /// Remove a reservation and its contribution to the running totals.
    private mutating func takeReservation(_ id: ReservationID) -> (month: BillingMonth, budget: AppBudget, amount: MicroUSD)? {
        guard let held = reserved.removeValue(forKey: id) else { return nil }
        let key = ReservedKey(month: held.month, budget: held.budget)
        let remaining = (reservedTotals[key] ?? .zero) - held.amount
        reservedTotals[key] = remaining == .zero ? nil : remaining
        return held
    }

    // MARK: Recording

    /// Record a request's outcome. If `reservation` is given it is consumed: a billed
    /// amount is charged to the reservation's month (the month the decision was made
    /// in), so a request that straddles midnight on the 1st can't escape both months.
    @discardableResult
    public mutating func record(featureID: String, payer: Payer, budget: AppBudget?, model: ModelID,
                                outcome: LedgerOutcome, reservation: ReservationID?,
                                at now: EpochMillis) -> LedgerEntry {
        var month = BillingMonth(containing: now)
        if let reservation, let held = takeReservation(reservation) {
            month = held.month
        }
        var monthTotals = totals[month] ?? SpendTotals()
        switch outcome {
        case let .billed(amount): monthTotals.add(amount, payer: payer, budget: budget)
        case .refused: break
        case .unknown: monthTotals.unknownOutcomes = min(monthTotals.unknownOutcomes + 1, Int.max - 1)
        }
        totals[month] = monthTotals
        pruneMonths(keepingFrom: BillingMonth(containing: now))

        let entry = LedgerEntry(id: nextID, featureID: featureID, payer: payer, budget: budget,
                                model: model, at: now, outcome: outcome)
        nextID &+= 1
        append(entry)
        return entry
    }

    /// Newest first.
    public var recentEntries: [LedgerEntry] {
        guard !ring.isEmpty else { return [] }
        var out: [LedgerEntry] = []
        out.reserveCapacity(ring.count)
        for offset in 0..<ring.count {
            let index = (ringStart + ring.count - 1 - offset) % ring.count
            out.append(ring[index])
        }
        return out
    }

    public var reservationCount: Int { reserved.count }

    /// Upper bound on concurrent reservations.
    public static let maxReservations = 10_000

    private mutating func append(_ entry: LedgerEntry) {
        if ring.count < entryCapacity {
            ring.append(entry)
        } else {
            // ring.count == entryCapacity >= 1, so ringStart is a valid index.
            ring[ringStart] = entry
            ringStart = (ringStart + 1) % entryCapacity
        }
    }

    private mutating func pruneMonths(keepingFrom current: BillingMonth) {
        guard totals.count > monthsRetained else { return }
        let keep = Set(totals.keys.sorted(by: >).prefix(monthsRetained)).union([current])
        totals = totals.filter { keep.contains($0.key) }
    }
}
