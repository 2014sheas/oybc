import Foundation

/// Allocation-free parser for the ISO-8601 shapes OYBC itself writes and
/// receives, ahead of the `ISO8601DateFormatter` / `DateFormatter` fallbacks in
/// `DateFormatting.parseISO`.
///
/// Why it exists (#570): every row decode, window compare and derivation pass
/// parses several timestamps, and `NSISO8601DateFormatter.dateFromString:` ->
/// ICU `SimpleDateFormat::parse` rebuilds number-format state on every call. On
/// the 2026-10-07 launch-watchdog crash that parse was the hot instruction
/// inside a GRDB write. Parsing a fixed grammar by hand is orders of magnitude
/// cheaper and takes no lock.
///
/// Contract: whenever this returns a `Date`, it is **bit-for-bit identical**
/// (same `timeIntervalSinceReferenceDate`) to what the formatter chain returns
/// for the same string. It never decides that a string is invalid - it returns
/// nil ("not handled") for anything outside the grammar below, and the caller
/// falls back to the formatters, which stay the single source of truth for
/// unusual input (lenient day rollover, offsets, junk, other calendars, ...).
///
/// Recognised grammar (byte-exact, nothing else):
/// - `yyyy-MM-dd'T'HH:mm:ss` + optional `.` + 1-9 fractional digits, then
///   either `Z` (UTC) or nothing (a *local* wall-clock string, the shape board
///   `startDate` / `endDate` use).
/// - year within `supportedYears`, a real calendar day, hour 0-23, minute and
///   second 0-59.
///
/// Fractional seconds truncate to milliseconds (digits beyond the third are
/// dropped, fewer are zero-padded), exactly as ICU does.
///
/// Local strings are interpreted in `TimeZone.current` under a Gregorian
/// `Calendar.current` - the same inputs `LocalISOParser` reads. A wall-clock
/// time within `transitionGuard` of a UTC-offset change (DST gap or overlap)
/// is left to the formatter, which owns the gap/overlap resolution.
enum ISO8601FastParser {

    /// Years the fast path answers for. Outside it (and before the 1582
    /// Gregorian cutover especially) the formatters decide.
    static let supportedYears = 1970...2200

    /// Half-width (seconds) of the window around a local wall-clock time that
    /// must contain no UTC-offset change for the fast path to answer. Wider
    /// than any real offset difference (-12h...+14h) plus the gap between the
    /// naive and real instants.
    private static let transitionGuard = 16 * 3600

    /// Which timestamp shapes a call accepts - mirrors what the caller's
    /// reference formatter would accept, so the fast path never answers for a
    /// shape the reference would have rejected.
    struct Shape: OptionSet {
        let rawValue: UInt8
        /// `...Z` with an optional fraction.
        static let utc = Shape(rawValue: 1 << 0)
        /// `...Z` with no fraction (the `ISO8601DateFormatter` default options).
        static let utcWholeSeconds = Shape(rawValue: 1 << 1)
        /// Zone-less local wall clock, optional fraction.
        static let local = Shape(rawValue: 1 << 2)
    }

    /// Parses `iso` when it is a canonical UTC (`...Z`) or local (zone-less)
    /// timestamp.
    ///
    /// - Parameter iso: Any string.
    /// - Returns: The instant, or nil when the string is outside the fast
    ///   grammar (the caller must then use the formatter chain).
    static func parse(_ iso: String) -> Date? {
        parse(iso, accepting: [.utc, .local])
    }

    /// Parses `iso` when it matches one of the accepted `shapes`.
    ///
    /// - Parameters:
    ///   - iso: Any string.
    ///   - shapes: The shapes the caller's reference parser would accept.
    ///   - timeZone: Zone a local string is read in; nil (the production value)
    ///     reads `TimeZone.current` only when a local string actually needs it.
    ///     Tests pass an explicit zone.
    /// - Returns: The instant, or nil when not handled by the fast path.
    static func parse(_ iso: String, accepting shapes: Shape, timeZone: TimeZone? = nil) -> Date? {
        var copy = iso
        return copy.withUTF8 { parse($0, accepting: shapes, timeZone: timeZone) }
    }

    // MARK: - Scanner

    private static func parse(_ bytes: UnsafeBufferPointer<UInt8>, accepting shapes: Shape, timeZone: TimeZone?) -> Date? {
        let count = bytes.count
        // 19 = "yyyy-MM-ddTHH:mm:ss"; +1 ".d" minimum fraction, +9 digits, +1 "Z".
        guard count >= 19, count <= 30 else { return nil }
        guard bytes[4] == 0x2D, bytes[7] == 0x2D, bytes[10] == 0x54, bytes[13] == 0x3A, bytes[16] == 0x3A else { return nil }

        let year = number(bytes, 0, 4)
        let month = number(bytes, 5, 2)
        let day = number(bytes, 8, 2)
        let hour = number(bytes, 11, 2)
        let minute = number(bytes, 14, 2)
        let second = number(bytes, 17, 2)
        guard supportedYears.contains(year), (1...12).contains(month), hour >= 0, hour <= 23,
              minute >= 0, minute <= 59, second >= 0, second <= 59,
              day >= 1, day <= daysInMonth(year: year, month: month) else { return nil }

        // Tail after the seconds: "", ".ddd", "Z" or ".dddZ".
        var millis = 0
        var hasFraction = false
        var index = 19
        if index < count, bytes[index] == 0x2E {
            var digits = 0
            index += 1
            while index < count, digits < 9, let digit = digitValue(bytes[index]) {
                if digits < 3 { millis = millis * 10 + digit }
                digits += 1
                index += 1
            }
            guard digits >= 1 else { return nil }
            hasFraction = true
            if digits < 3 { millis *= digits == 1 ? 100 : 10 }
        }
        let isUTC: Bool
        if index == count {
            isUTC = false
        } else if index == count - 1, bytes[index] == 0x5A {
            isUTC = true
        } else {
            return nil
        }

        let naiveSeconds = daysFromCivil(year: year, month: month, day: day) * 86_400
            + hour * 3600 + minute * 60 + second

        if isUTC {
            guard shapes.contains(.utc) || (!hasFraction && shapes.contains(.utcWholeSeconds)) else { return nil }
            return date(seconds: naiveSeconds, millis: millis)
        }
        guard shapes.contains(.local) else { return nil }
        guard let offset = localOffset(naiveSeconds: naiveSeconds, timeZone: timeZone) else { return nil }
        return date(seconds: naiveSeconds - offset, millis: millis)
    }

    /// The UTC offset (seconds) in force for the local wall-clock time
    /// `naiveSeconds` (that wall clock read as if it were UTC), or nil when the
    /// fast path must not answer: a non-Gregorian current calendar, or a
    /// UTC-offset change near enough that the wall-clock time could be skipped
    /// or repeated.
    private static func localOffset(naiveSeconds: Int, timeZone: TimeZone?) -> Int? {
        guard Calendar.current.identifier == .gregorian else { return nil }
        let timeZone = timeZone ?? TimeZone.current
        let before = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(naiveSeconds - transitionGuard)))
        let after = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(naiveSeconds + transitionGuard)))
        return before == after ? before : nil
    }

    /// The `Date` for `seconds` + `millis` since 1970, computed through the
    /// same millisecond-double division ICU performs so the bits match the
    /// formatters' result.
    private static func date(seconds: Int, millis: Int) -> Date {
        Date(timeIntervalSince1970: Double(seconds * 1000 + millis) / 1000.0)
    }

    // MARK: - Digits and calendar arithmetic

    /// Value of an ASCII digit, or nil.
    @inline(__always)
    private static func digitValue(_ byte: UInt8) -> Int? {
        let value = Int(byte) &- 0x30
        return value >= 0 && value <= 9 ? value : nil
    }

    /// The `count`-digit decimal number at `start`, or -1 when any byte is not a digit.
    @inline(__always)
    private static func number(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ count: Int) -> Int {
        var value = 0
        for offset in 0..<count {
            guard let digit = digitValue(bytes[start + offset]) else { return -1 }
            value = value * 10 + digit
        }
        return value
    }

    /// Days in `month` of `year` (proleptic Gregorian leap rule).
    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 of a proleptic-Gregorian civil date (Hinnant's
    /// `days_from_civil`); valid for the supported years.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = y / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
