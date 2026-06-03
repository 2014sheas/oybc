import Foundation
import GRDB
import Observation

/// One placement on the source board's grid — a `BoardTask` paired
/// with the `Task` it references. Mirror of web's `SourceBoardPlacement`
/// shape (see `useSourceBoardPlacements.ts`).
///
/// `task` is `nil` when the placement points at a soft-deleted task;
/// the grid renders an empty cell rather than crashing.
struct SourceBoardPlacement: Identifiable {
    let placement: BoardTask
    let task: Task?

    var id: String { placement.id }
}

/// Owns the data for the wizard's `From a board…` filter chip:
///   - `eligibleBoards`: source-picker list (active + recently-completed)
///   - `placements`: the chosen source board's grid (BoardTask + Task pairs)
///
/// iOS twin of web's `useSourceBoards` + `useSourceBoardPlacements`
/// hooks. Loading is imperative — the view calls `reload(userId:)` on
/// `.onAppear` and `loadPlacements(forBoardId:)` whenever the user
/// picks a source. Mirrors the pattern used by `ParentBoardTasksViewModel`.
@Observable
final class SourceBoardsViewModel {

    // MARK: - State

    /// Boards eligible to be browsed as a source. Sorted recently-active
    /// first by the AppDatabase helper.
    var eligibleBoards: [Board] = []

    /// Placements on the currently-loaded source board, row-major.
    /// Empty when no source is selected or the source has no placements.
    var placements: [SourceBoardPlacement] = []

    /// Last load error — silently swallowed at the view layer (this
    /// filter is a convenience; blocking the wizard on failure would
    /// be too disruptive).
    var loadError: String?

    // MARK: - Race-condition guards
    //
    // Two independent reloads can race: the eligibility list (driven by
    // `.onAppear`) and the placements load (driven by user tapping a
    // source card). Each has its own seq counter; results commit only
    // when their seq is still the latest.
    @ObservationIgnored private var latestBoardsSeq: UInt64 = 0
    @ObservationIgnored private var latestPlacementsSeq: UInt64 = 0

    // MARK: - Loading — eligible boards

    /// Loads the source-picker list.
    func reload(userId: String) async {
        let mySeq = await MainActor.run { () -> UInt64 in
            latestBoardsSeq &+= 1
            return latestBoardsSeq
        }

        do {
            let result = try AppDatabase.shared.fetchEligibleSourceBoards(userId: userId)
            await MainActor.run {
                guard mySeq == latestBoardsSeq else { return }
                self.eligibleBoards = result
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                guard mySeq == latestBoardsSeq else { return }
                self.loadError = "Failed to load source boards: \(error.localizedDescription)"
                self.eligibleBoards = []
            }
        }
    }

    /// Sync shim for view-side fire-and-forget callers.
    func reloadAsync(userId: String) {
        _Concurrency.Task { await reload(userId: userId) }
    }

    // MARK: - Loading — placements for a chosen source

    /// Loads placements + resolved tasks for the chosen source board.
    /// Pass `nil` to clear (e.g. when the user backs out to the picker).
    func loadPlacements(forBoardId boardId: String?) async {
        let mySeq = await MainActor.run { () -> UInt64 in
            latestPlacementsSeq &+= 1
            return latestPlacementsSeq
        }

        guard let boardId else {
            await MainActor.run {
                guard mySeq == latestPlacementsSeq else { return }
                self.placements = []
            }
            return
        }

        do {
            let result = try await AppDatabase.shared.read { db -> [SourceBoardPlacement] in
                let placements = try BoardTask
                    .filter(Column("boardId") == boardId)
                    .fetchAll(db)
                if placements.isEmpty { return [] }

                let taskIds = Set(placements.map { $0.taskId })
                let tasks = try Task
                    .filter(taskIds.contains(Column("id")) && Column("isDeleted") == false)
                    .fetchAll(db)
                var tasksById: [String: Task] = [:]
                for t in tasks { tasksById[t.id] = t }

                // Row-major ordering so the grid renderer maps placements
                // to cells without re-sorting.
                let sorted = placements.sorted {
                    $0.row != $1.row ? $0.row < $1.row : $0.col < $1.col
                }
                return sorted.map { SourceBoardPlacement(placement: $0, task: tasksById[$0.taskId]) }
            }

            await MainActor.run {
                guard mySeq == latestPlacementsSeq else { return }
                self.placements = result
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                guard mySeq == latestPlacementsSeq else { return }
                self.loadError = "Failed to load source-board placements: \(error.localizedDescription)"
                self.placements = []
            }
        }
    }

    /// Sync shim for view-side fire-and-forget callers.
    func loadPlacementsAsync(forBoardId boardId: String?) {
        _Concurrency.Task { await loadPlacements(forBoardId: boardId) }
    }
}
