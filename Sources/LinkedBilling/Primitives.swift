// Small value types every other file builds on. Nothing here allocates per call
// or traps: every arithmetic operation that could overflow saturates instead.

/// Milliseconds since the Unix epoch, UTC. Every time-dependent decision in the
/// package takes `now` as an argument, so tests and the demo can drive time.
public typealias EpochMillis = Int64

/// Saturating arithmetic. `Int64` traps on overflow in Swift; a billing system that
/// crashes because a customer sent a huge cost estimate is worse than one that clamps.
public enum Saturating {
    @inlinable
    public static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        // Overflow is only possible when both operands share a sign.
        return a < 0 ? .min : .max
    }

    @inlinable
    public static func subtract(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.subtractingReportingOverflow(b)
        guard overflow else { return result }
        // a - b overflows only when a and b have opposite signs.
        return a < 0 ? .min : .max
    }

    @inlinable
    public static func multiply(_ a: Int64, _ b: Int64) -> Int64 {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return result }
        return (a < 0) == (b < 0) ? .max : .min
    }
}

/// Money, in millionths of a US dollar. Linked-billing spend caps are whole USD,
/// but per-request costs are fractions of a cent, so integers of micro-dollars keep
/// the ledger exact (no floating-point drift across a month of requests).
///
/// The value is clamped at zero: a cost or a budget is never negative.
public struct MicroUSD: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let value: Int64

    public init(_ value: Int64) { self.value = max(0, value) }

    public static let zero = MicroUSD(0)

    /// Whole dollars, saturating (a cap of `Int64.max` dollars does not trap).
    public static func dollars(_ whole: Int64) -> MicroUSD {
        MicroUSD(Saturating.multiply(whole, 1_000_000))
    }

    public static func + (lhs: MicroUSD, rhs: MicroUSD) -> MicroUSD {
        MicroUSD(Saturating.add(lhs.value, rhs.value))
    }

    /// Floors at zero rather than going negative.
    public static func - (lhs: MicroUSD, rhs: MicroUSD) -> MicroUSD {
        MicroUSD(Saturating.subtract(lhs.value, rhs.value))
    }

    public static func < (lhs: MicroUSD, rhs: MicroUSD) -> Bool { lhs.value < rhs.value }

    /// `$12.34` style, rounded down to the cent. For display only.
    public var description: String {
        let cents = value / 10_000
        let whole = cents / 100
        let rest = cents % 100
        return "$\(whole).\(rest < 10 ? "0" : "")\(rest)"
    }
}

/// A Claude Platform user profile ID (`uprof_…`). The API rejects a malformed ID
/// with a 400 that carries no error code, which is easy to misread as a billing
/// failure; validating at the boundary turns that into a type error instead.
public struct UserProfileID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// Returns `nil` unless the value is `uprof_` followed by 1...128 ASCII letters,
    /// digits, `_` or `-`. The upper bound keeps a hostile value out of headers and logs.
    public init?(_ rawValue: String) {
        let prefix = "uprof_"
        guard rawValue.hasPrefix(prefix) else { return nil }
        let suffix = rawValue.utf8.dropFirst(prefix.utf8.count)
        guard (1...128).contains(suffix.count) else { return nil }
        let allowed = suffix.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || // 0-9
            (byte >= 0x41 && byte <= 0x5A) || // A-Z
            (byte >= 0x61 && byte <= 0x7A) || // a-z
            byte == 0x5F || byte == 0x2D      // _ -
        }
        guard allowed else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// A model identifier, kept opaque so the package never hardcodes a model list.
public struct ModelID: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}
