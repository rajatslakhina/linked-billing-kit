/// The billing month in UTC.
///
/// Linked-billing spend caps reset "until 00:00 UTC on the first day of the next
/// month" (Claude Platform docs, *Spend caps*). Getting that boundary wrong in a
/// device's local time zone means either hammering a capped customer with refused
/// requests for hours, or quietly subsidising them for hours after their cap reset.
/// So the package computes it in UTC, with integer civil-calendar arithmetic
/// (Howard Hinnant's `days_from_civil` / `civil_from_days`) instead of a `Calendar`
/// whose time zone could be left at the device default.
public struct BillingMonth: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int64
    /// 1...12
    public let month: Int64

    static let millisPerDay: Int64 = 86_400_000

    /// The UTC month that contains `millis`. Total over the whole `Int64` range.
    public init(containing millis: EpochMillis) {
        // Floor division so instants before 1970 land in the right day.
        let days = millis >= 0
            ? millis / Self.millisPerDay
            : -((-(millis + 1)) / Self.millisPerDay) - 1
        let civil = Self.civil(fromDays: days)
        self.year = civil.year
        self.month = civil.month
    }

    init(year: Int64, month: Int64) {
        self.year = year
        self.month = month
    }

    /// 00:00:00.000 UTC on the first day of this month.
    public var start: EpochMillis {
        Saturating.multiply(Self.days(year: year, month: month, day: 1), Self.millisPerDay)
    }

    public var next: BillingMonth {
        month == 12 ? BillingMonth(year: year + 1, month: 1) : BillingMonth(year: year, month: month + 1)
    }

    /// 00:00 UTC on the first of the following month: when a refused spend cap resets.
    public var end: EpochMillis { next.start }

    public static func < (lhs: BillingMonth, rhs: BillingMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    public var description: String {
        "\(year)-\(month < 10 ? "0" : "")\(month)"
    }

    /// UTC epoch millis for a civil date and time. Out-of-range fields are clamped
    /// (month 1...12, day 1...31, hour 0...23, minute 0...59), never trapped on.
    public static func epochMillis(year: Int64, month: Int64, day: Int64,
                                   hour: Int64 = 0, minute: Int64 = 0) -> EpochMillis {
        let y = min(max(year, -1_000_000), 1_000_000)
        let days = Self.days(year: y, month: min(max(month, 1), 12), day: min(max(day, 1), 31))
        let minutes = min(max(hour, 0), 23) * 60 + min(max(minute, 0), 59)
        return Saturating.add(Saturating.multiply(days, millisPerDay), minutes * 60_000)
    }

    // MARK: Civil-calendar arithmetic (proleptic Gregorian)

    static func days(year y0: Int64, month m: Int64, day d: Int64) -> Int64 {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromDays z0: Int64) -> (year: Int64, month: Int64) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m)
    }
}
