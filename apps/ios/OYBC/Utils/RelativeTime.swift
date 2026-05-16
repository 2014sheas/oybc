import Foundation

/// Thin wrapper around `RelativeDateTimeFormatter` for concise age strings
/// like "just now", "5m ago", "3d ago". iOS twin of web's `relativeTime.ts`.
///
/// Kept pure (no SwiftUI, no side-effects) so it can be used safely from
/// both view bodies and off-main-thread helpers.
enum RelativeTime {

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.dateTimeStyle = .named
        return f
    }()

    private static let isoParser = ISO8601DateFormatter()

    /// Returns a human-readable relative string for the given ISO 8601 date
    /// string, or `nil` when the input is `nil` or unparseable.
    ///
    /// - Parameter iso: Optional ISO 8601 timestamp string.
    /// - Returns: A string like "just now", "5m ago", "3d ago", or `nil`.
    static func formatRelativeTime(_ iso: String?) -> String? {
        guard let iso, let date = isoParser.date(from: iso) else { return nil }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
