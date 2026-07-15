import Foundation
import GRDB
import Observation

/// Windowed Completion — the closing-out set (docs/WINDOWED_COMPLETION.md
/// §Sealing → Lifecycle → Detection). Reactive-by-reload: owns the user's
/// non-draft, non-indefinite boards whose window has ended but which aren't
/// sealed yet — the set the Boards-tab closing-out banner prompts to Log / Seal.
///
/// iOS twin of web's `useClosingOutBoards` hook. Same imperative-reload
/// pattern as `CoreBoardSlotsViewModel` (the view calls `reloadAsync(userId:)`
/// from `.onAppear` and again after a Seal action) rather than a reactive GRDB
/// `ValueObservation` — consistent with the rest of `BoardListView`'s data flow.
///
/// Lazy-detection only (mirrors the recurring-window banner + the backstop
/// auto-seal pass): closure is *observed* on Boards-tab open, never
/// background-scheduled.
@Observable
final class ClosingOutBoardsViewModel {

    // MARK: - State

    /// Closing-out boards to render, oldest-ended-first (so the longest-open
    /// closing window sits at the top). Empty list ⇒ banner hides itself.
    var boards: [Board] = []

    /// Last load error, surfaced as a silent fallback — same posture as
    /// `CoreBoardSlotsViewModel.loadError`: a failed computation should never
    /// block the Boards tab from rendering the board list.
    var loadError: String?

    /// Board id currently mid-seal (drives the row's "Sealing…" state).
    var sealingBoardId: String?

    // MARK: - DB injection

    /// Injected for tests; defaults to the production singleton.
    @ObservationIgnored private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Loading

    /// Loads the user's non-deleted boards and filters to the closing-out set
    /// via the shared `isBoardClosingOut` predicate. Snapshots `now` once at
    /// the start so the value is stable across the awaited read.
    func reload(userId: String) async {
        let now = Date()
        do {
            let result = try await database.read { db -> [Board] in
                let boards = try Board
                    .filter(Column("userId") == userId && Column("isDeleted") == false)
                    .fetchAll(db)
                let nowMs = now.timeIntervalSince1970 * 1000
                return boards
                    .filter { isBoardClosingOut($0, nowMs: nowMs) }
                    .sorted { a, b in
                        let am = a.endDate.flatMap { DateFormatting.parseISO($0) }?.timeIntervalSince1970 ?? 0
                        let bm = b.endDate.flatMap { DateFormatting.parseISO($0) }?.timeIntervalSince1970 ?? 0
                        return am < bm
                    }
            }

            await MainActor.run {
                self.boards = result
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                // Keep `boards` as-is on failure — a transient DB error
                // shouldn't blank an already-populated banner.
                self.loadError = "Failed to load closing-out boards: \(error.localizedDescription)"
            }
        }
    }

    /// Sync shim for view-side fire-and-forget callers (`.onAppear` and
    /// post-seal refresh). Wraps `reload(userId:)` in a detached
    /// `_Concurrency.Task`.
    func reloadAsync(userId: String) {
        _Concurrency.Task { await reload(userId: userId) }
    }

    // MARK: - Seal action

    /// Seals a board (docs §Sealing → Lifecycle step 3 — the user "Seal"
    /// action) off the main thread, then reloads the closing-out set so the
    /// row disappears once sealed. Marks `sealingBoardId` for the duration so
    /// the row can show a "Sealing…" state and disable its buttons.
    func seal(boardId: String, userId: String) {
        sealingBoardId = boardId
        let database = self.database
        _Concurrency.Task {
            _ = try? await _Concurrency.Task.detached(priority: .userInitiated) {
                try database.sealBoard(boardId: boardId)
            }.value
            await self.reload(userId: userId)
            await MainActor.run { self.sealingBoardId = nil }
        }
    }
}
