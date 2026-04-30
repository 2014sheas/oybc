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
    /// `DateFormatter` is NOT thread-safe, so we instantiate the
    /// local-format parsers per call. Parse is rare enough (display-layer
    /// only) that the allocation cost is negligible.
    static func parseISO(_ iso: String) -> Date? {
        if let d = isoParserWithFractional.date(from: iso) { return d }
        if let d = isoParserNoFractional.date(from: iso) { return d }

        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            let f = DateFormatter()
            f.calendar = Calendar.current
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = format
            if let d = f.date(from: iso) { return d }
        }

        return nil
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
}
