import Foundation
import GRDB
import Observation

/// Owns the list of recurring board windows the user should be prompted
/// to create. iOS twin of web's `usePendingRecurringBoards` hook
/// (Phase 6.1b).
///
/// Loading is imperative — the view calls `reload(userId:)` from
/// `.onAppear` (and again after a board is created/deleted via callbacks).
/// This matches the existing pattern used by `BoardListView` itself; a
/// reactive GRDB `ValueObservation` would be a future enhancement.
///
/// Uses `@Observable` so SwiftUI re-renders when `pending` changes.
@Observable
final class PendingRecurringBoardsViewModel {

    // MARK: - State

    /// Banner entries to render, longest-window-first (yearly → daily).
    /// Empty list = banner hidden.
    var pending: [PendingRecurringBoard] = []

    /// Last load error, surfaced via the banner's empty/silent fallback.
    /// We deliberately do NOT show a user-facing error for this — a
    /// failed banner detection should never block the Boards tab.
    var loadError: String?

    // MARK: - Loading

    /// Loads the user's preferences + non-deleted boards, runs the shared
    /// `findPendingRecurringBoards` algorithm, and publishes the result.
    /// Snapshots `now` once at the start so the value is stable across
    /// the awaited reads.
    func reload(userId: String) async {
        let now = Date()
        do {
            let result = try await AppDatabase.shared.read { db -> [PendingRecurringBoard] in
                let user = try User
                    .filter(Column("id") == userId)
                    .fetchOne(db)
                let boards = try Board
                    .filter(Column("userId") == userId && Column("isDeleted") == false)
                    .fetchAll(db)
                let prefs = user?.decodedPreferences ?? .defaults
                return findPendingRecurringBoards(boards: boards, prefs: prefs, now: now)
            }

            await MainActor.run {
                self.pending = result
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                // Keep `pending` as-is on failure — a transient DB error
                // shouldn't blank an already-populated banner.
                self.loadError = "Failed to load pending recurring boards: \(error.localizedDescription)"
            }
        }
    }

    /// Sync shim for view-side fire-and-forget callers (`.onAppear` and
    /// post-creation refresh callbacks). Wraps `reload(userId:)` in a
    /// detached `_Concurrency.Task`.
    func reloadAsync(userId: String) {
        _Concurrency.Task { await reload(userId: userId) }
    }
}
