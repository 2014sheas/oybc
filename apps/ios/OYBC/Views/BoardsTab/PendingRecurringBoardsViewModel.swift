import Foundation
import GRDB
import Observation

/// Owns the per-enabled-timeframe core-board slot list for the
/// persistent "Core Boards" section on the Boards tab. iOS twin of
/// web's `useCoreBoardSlots` hook.
///
/// Replaces the earlier `PendingRecurringBoardsViewModel` (which only
/// emitted "needs creation" entries) — the section now shows every
/// enabled timeframe regardless of whether the current window has a
/// board yet, so the per-timeframe browser is always reachable from
/// the home screen.
///
/// File kept at the original path (`PendingRecurringBoardsViewModel.swift`)
/// so the Xcode project doesn't need to be regenerated. Source-of-truth
/// type is `CoreBoardSlotsViewModel`; a thin typealias preserves the
/// old name for any consumer that might still reference it during the
/// migration window.
///
/// Loading is imperative — the view calls `reload(userId:)` from
/// `.onAppear` (and again after a board is created/deleted via
/// callbacks). Same pattern as `BoardListView` itself; a reactive GRDB
/// `ValueObservation` would be a future enhancement.
@Observable
final class CoreBoardSlotsViewModel {

    // MARK: - State

    /// Slot entries to render, daily-first. Empty list ⇒ no recurring
    /// timeframes enabled at all ⇒ section hides itself.
    var slots: [CoreBoardSlot] = []

    /// Per-timeframe bingo + greenlog streaks, computed alongside the slots
    /// from the same boards/prefs snapshot. The grid reads `streaks[tf]?.greenlog`
    /// for each card's badge. Parallel to `slots` (keeps `CoreBoardSlot` a pure
    /// mirror of the shared `getCoreBoardSlots` shape).
    var streaks: [Timeframe: StreakPair] = [:]

    /// Last load error, surfaced as a silent fallback. We deliberately
    /// do NOT show a user-facing error — a failed slot computation
    /// should never block the Boards tab from rendering board rows.
    var loadError: String?

    // MARK: - DB injection

    /// Injected for tests; defaults to the production singleton.
    @ObservationIgnored private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Loading

    /// Loads the user's preferences + non-deleted boards, runs the shared
    /// `getCoreBoardSlots` algorithm, and publishes the result.
    /// Snapshots `now` once at the start so the value is stable across
    /// the awaited reads.
    func reload(userId: String) async {
        let now = Date()
        do {
            let result = try await database.read { db -> (slots: [CoreBoardSlot], streaks: [Timeframe: StreakPair]) in
                let user = try User
                    .filter(Column("id") == userId)
                    .fetchOne(db)
                let boards = try Board
                    .filter(Column("userId") == userId && Column("isDeleted") == false)
                    .fetchAll(db)
                let prefs = user?.decodedPreferences ?? .defaults
                let slots = getCoreBoardSlots(boards: boards, prefs: prefs, now: now)
                let streaks = computeAllStreaks(boards: boards, weekStartDay: prefs.weekStartDay.rawValue, now: now)
                return (slots, streaks)
            }

            await MainActor.run {
                self.slots = result.slots
                self.streaks = result.streaks
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                // Keep `slots` as-is on failure — a transient DB error
                // shouldn't blank an already-populated section.
                self.loadError = "Failed to load core board slots: \(error.localizedDescription)"
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

/// Back-compat typealias for any consumer that still references the
/// old type name during the migration window. Safe to drop once all
/// callers use `CoreBoardSlotsViewModel` directly.
typealias PendingRecurringBoardsViewModel = CoreBoardSlotsViewModel
