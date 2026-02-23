import Foundation

// MARK: - Shared Playground Utilities

/// The user ID used consistently across all Playground features.
let playgroundUserId = "playground-user-1"

private let _playgroundISOFormatter = ISO8601DateFormatter()
private let _playgroundDisplayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()

/// Formats an ISO8601 string into a medium-style date with time for display.
///
/// Shared by all Playground structs that need to display task creation dates.
///
/// - Parameter iso: An ISO8601 date string.
/// - Returns: A human-readable date string with time, or the original string if parsing fails.
func formatPlaygroundDate(_ iso: String) -> String {
    guard let date = _playgroundISOFormatter.date(from: iso) else { return iso }
    return _playgroundDisplayFormatter.string(from: date)
}
