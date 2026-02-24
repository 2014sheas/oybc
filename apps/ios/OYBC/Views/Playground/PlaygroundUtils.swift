import Foundation

// MARK: - Shared Playground Utilities

/// The user ID used consistently across all Playground features.
let playgroundUserId = "playground-user-1"

/// Number of seconds a success message is shown before it auto-dismisses.
let successDismissSeconds: Double = 3.0

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

/// Ensures the shared playground user record exists in the local database.
///
/// Creates the user with a fixed ID and email if it has not been inserted yet.
/// Safe to call multiple times — idempotent.
///
/// Any database errors are silently swallowed; they are non-fatal for Playground use.
func ensurePlaygroundUser() {
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            if try AppDatabase.shared.fetchUser(id: playgroundUserId) == nil {
                let user = User(
                    id: playgroundUserId,
                    email: "playground@oybc.local",
                    displayName: "Playground User",
                    photoURL: nil,
                    createdAt: AppDatabase.currentTimestamp(),
                    updatedAt: AppDatabase.currentTimestamp(),
                    lastSyncedAt: nil,
                    version: 1
                )
                try AppDatabase.shared.saveUser(user)
            }
        } catch {
            // Non-fatal in Playground context
        }
    }
}
