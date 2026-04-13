import Foundation

/// Shared date-display helpers. Mirrors the web `utils/dateFormat.ts`
/// module so production views on both platforms format dates the same
/// way — medium date style, user's current locale.
enum DateFormatting {
    /// Cached formatters. `DateFormatter` is expensive to instantiate and
    /// safe to share across threads once configured.
    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoParserNoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// Parses an ISO8601 string and returns a medium-style localised date
    /// (e.g. `"Apr 12, 2026"`). Returns `"—"` on parse failure.
    ///
    /// Accepts timestamps with or without fractional seconds since both
    /// shapes appear in the local DB (GRDB writes use `ISO8601DateFormatter`
    /// without fractional seconds; Firestore pulls include them).
    static func displayDate(from iso: String) -> String {
        let date = isoParser.date(from: iso) ?? isoParserNoFractional.date(from: iso)
        guard let date else { return "—" }
        return displayDateFormatter.string(from: date)
    }
}
