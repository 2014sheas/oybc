import Foundation

/// Shared date-display helpers. Mirrors the web `utils/dateFormat.ts`
/// module so production views on both platforms format dates the same
/// way — medium / abbreviated date style, user's current locale.
enum DateFormatting {
    /// `ISO8601DateFormatter` is documented thread-safe (iOS 7+/macOS 10.9+),
    /// so it's safe to cache these instances at file scope.
    private static let isoParserWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoParserNoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses an ISO8601 timestamp. Accepts both internet-style timestamps
    /// with a timezone suffix (Firestore sync payloads) and the local
    /// `yyyy-MM-dd'T'HH:mm:ss.SSS` / `yyyy-MM-dd'T'HH:mm:ss` shapes that
    /// the board-creation wizard's `wizardLocalISOString(_:)` writes for
    /// calendar-bound board start/end dates (intentionally timezone-less
    /// so boundaries match the user's wall clock).
    ///
    /// This is THE parse entry point (the global `parseISO8601Date(_:)` forwards
    /// here). Canonical shapes - UTC `...Z` and zone-less local, with 0-9
    /// fractional digits - are answered by `ISO8601FastParser` (#570: the
    /// formatters rebuild ICU state per parse and were the hot instruction in
    /// the 2026-10-07 launch-watchdog crash). Anything else - offsets, lenient
    /// day rollover, junk, a DST gap/overlap, a non-Gregorian calendar - falls
    /// through to the formatters, which remain the reference; the fast path's
    /// answer is bit-for-bit what they return.
    ///
    /// The local-format fallback goes through `LocalISOParser` (cached
    /// `DateFormatter`s behind a lock, rebuilt when `TimeZone.current` /
    /// `Calendar.current` change).
    static func parseISO(_ iso: String) -> Date? {
        if let d = ISO8601FastParser.parse(iso) { return d }
        if let d = isoParserWithFractional.date(from: iso) { return d }
        if let d = isoParserNoFractional.date(from: iso) { return d }
        return LocalISOParser.shared.parse(iso)
    }

    /// Parses a zoned internet date-time (`...Z` / offset, with or without
    /// fractional seconds) - for callers that never accept zone-less local
    /// strings (relative-time labels, entitlement expiry). Same fast path and
    /// formatter fallback as `parseISO(_:)`, minus the local-time shapes.
    ///
    /// - Parameter iso: An internet date-time string.
    /// - Returns: The instant, or nil when it is not a zoned ISO timestamp.
    static func parseInternetISO(_ iso: String) -> Date? {
        if let d = ISO8601FastParser.parse(iso, accepting: .utc) { return d }
        return isoParserWithFractional.date(from: iso) ?? isoParserNoFractional.date(from: iso)
    }

    /// Encodes `date` as a canonical UTC event timestamp with millisecond
    /// precision (`yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`) — the exact shape JS
    /// `Date.prototype.toISOString()` emits. Reuses the cached fractional
    /// internet-date-time formatter above (UTC is `ISO8601DateFormatter`'s
    /// default time zone), so a round-trip through `parseISO(_:)` is lossless
    /// at millisecond precision.
    ///
    /// - Parameter date: The instant to encode.
    /// - Returns: The UTC ISO8601 string with fractional seconds.
    static func utcISOString(_ date: Date) -> String {
        isoParserWithFractional.string(from: date)
    }

    /// Parses an ISO8601 string and returns an abbreviated localised date
    /// (e.g. `"Apr 12, 2026"`). Returns `"—"` on parse failure.
    ///
    /// Uses `Date.formatted(date:time:)` for output, which is thread-safe
    /// and locale-aware out of the box (iOS 15+).
    static func displayDate(from iso: String) -> String {
        guard let date = parseISO(iso) else { return "—" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Inclusive timestamp-window check used by Phase 6.3 derivation +
    /// cycle detection. Mirrors the shared TS `isWithinTimeframe` helper
    /// in `packages/shared/src/algorithms/calendarBoundaries.ts`.
    ///
    /// Parses all three strings via `parseISO` so the comparison is
    /// time-based (not lexicographic). Lexicographic compare is unsafe
    /// because `Board.startDate`/`endDate` can be either local-ISO (no
    /// timezone suffix) or full UTC-with-`Z` (sync round-trip), and the
    /// two encodings don't sort correctly as strings — a UTC `2026-04-30T23:59:59.000Z`
    /// sorts *before* a local `2026-04-30T23:59:59.000` even though they
    /// represent different instants.
    ///
    /// Returns `false` if the candidate or start fails to parse — conservative
    /// degrade (matches the shared helper's silent NaN-comparison behaviour for
    /// unparseable inputs).
    ///
    /// A `nil` `endDate` denotes an unbounded window `[startDate, ∞)` — the
    /// model for INDEFINITE boards — in which case only the lower bound is
    /// checked. Mirror of the shared `isWithinTimeframe`.
    static func isWithinTimeframe(
        _ candidate: String,
        startDate: String,
        endDate: String?
    ) -> Bool {
        guard let c = parseISO(candidate),
              let s = parseISO(startDate) else { return false }
        guard let endDate else { return c >= s }
        guard let e = parseISO(endDate) else { return false }
        return c >= s && c <= e
    }
}

/// Parses the timezone-less local ISO shapes (`yyyy-MM-dd'T'HH:mm:ss.SSS`,
/// `yyyy-MM-dd'T'HH:mm:ss`) on the user's wall clock. `DateFormatter` is not
/// thread-safe, so the two cached instances are only touched under `lock`; they
/// are rebuilt whenever the current time zone or calendar differs from the ones
/// they were built for — the same semantics as the per-call formatters this
/// replaced (`TimeZone.current` / `Calendar.current` read at parse time).
final class LocalISOParser {
    static let shared = LocalISOParser()

    private let lock = NSLock()
    private var builtTimeZone: String?
    private var builtCalendar: Calendar.Identifier?
    private var fractional: DateFormatter?
    private var basic: DateFormatter?
    /// Formatter (re)builds so far — lets a test prove the cache is reused.
    private(set) var buildCount = 0

    /// - Parameter iso: A local ISO string.
    /// - Returns: The instant on the current wall clock, or nil when it matches neither shape.
    func parse(_ iso: String) -> Date? {
        let timeZone = TimeZone.current
        let calendar = Calendar.current
        lock.lock()
        defer { lock.unlock() }
        if timeZone.identifier != builtTimeZone || calendar.identifier != builtCalendar || fractional == nil || basic == nil {
            fractional = Self.makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSS", timeZone: timeZone, calendar: calendar)
            basic = Self.makeFormatter("yyyy-MM-dd'T'HH:mm:ss", timeZone: timeZone, calendar: calendar)
            builtTimeZone = timeZone.identifier
            builtCalendar = calendar.identifier
            buildCount += 1
        }
        return fractional?.date(from: iso) ?? basic?.date(from: iso)
    }

    private static func makeFormatter(_ format: String, timeZone: TimeZone, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }
}
