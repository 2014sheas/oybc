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

    /// Precomputed completion ratio for each eligible board
    /// (`(completed, total)`), keyed by board id.
    var completionByBoardId: [String: (completed: Int, total: Int)] = [:]

    /// TRUE mini-preview cells per eligible board (bugfix/board-preview-real-cells
    /// perf follow-up), batch-built ONCE per `reload(userId:)` call via
    /// `BoardPreviewCells.fetchWorkspaceData`/`buildMany` — NOT one fetch per
    /// row. `FromBoardPickerView` reads this directly rather than mounting
    /// `RisoBoardPreviewGrid` per row (which would re-run workspace-wide
    /// reads on every scroll-triggered re-render of a `LazyVStack`).
    var previewCellsByBoardId: [String: BoardPreviewCellsResult] = [:]

    /// Placements on the currently-loaded source board, row-major.
    /// Empty when no source is selected or the source has no placements.
    var placements: [SourceBoardPlacement] = []

    /// Compound-leaf ids (non-deleted, primitive only) keyed by parent
    /// compound id, for the currently-loaded source board only.
    /// Drives both menu-item visibility (hide `Add all subtasks` when
    /// the compound has no leaves) and the action itself (pass the
    /// resolved ids to the parent so we don't fall back to the
    /// wizard's library, which may not contain the source's compound).
    var compoundLeafIdsByParent: [String: [String]] = [:]

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

    // MARK: - DB injection

    /// Injected for tests; defaults to the production singleton.
    @ObservationIgnored private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Loading — eligible boards

    /// Loads the source-picker list.
    func reload(userId: String) async {
        let mySeq = await MainActor.run { () -> UInt64 in
            latestBoardsSeq &+= 1
            return latestBoardsSeq
        }

        do {
            let result = try await database.read { db -> (
                boards: [Board],
                completion: [String: (Int, Int)],
                allPlacements: [BoardTask]
            ) in
                // Re-run the eligibility filter inside the read so the
                // boards + their placements come from one consistent
                // snapshot. The static variant takes the current `db`
                // handle so the eligibility list, all_placements, and
                // tasks all read from the same transaction — a write
                // between two separate reads could otherwise yield
                // mismatched data.
                let eligible = try AppDatabase.fetchEligibleSourceBoards(db, userId: userId)
                if eligible.isEmpty {
                    return (eligible, [:], [])
                }

                let boardIds = Set(eligible.map { $0.id })
                let allPlacements = try BoardTask
                    .filter(boardIds.contains(Column("boardId")))
                    .fetchAll(db)
                if allPlacements.isEmpty {
                    var emptyCompl: [String: (Int, Int)] = [:]
                    for b in eligible {
                        emptyCompl[b.id] = (0, b.boardSize * b.boardSize)
                    }
                    return (eligible, emptyCompl, [])
                }

                let taskIds = Set(allPlacements.map { $0.taskId })
                let tasks = try Task
                    .filter(taskIds.contains(Column("id")) && Column("isDeleted") == false)
                    .fetchAll(db)
                var tasksById: [String: Task] = [:]
                for t in tasks { tasksById[t.id] = t }

                var placementsByBoard: [String: [BoardTask]] = [:]
                for p in allPlacements {
                    placementsByBoard[p.boardId, default: []].append(p)
                }

                // Completion ratio per board. Counted independently of any
                // cell geometry (matches web's `countCompleted`).
                var completion: [String: (Int, Int)] = [:]
                for board in eligible {
                    let size = board.boardSize
                    var done = 0
                    for p in placementsByBoard[board.id] ?? [] {
                        let idx = p.row * size + p.col
                        guard idx >= 0 && idx < size * size else { continue }
                        if tasksById[p.taskId]?.isCompleted == true {
                            done += 1
                        }
                    }
                    completion[board.id] = (done, size * size)
                }

                return (eligible, completion, allPlacements)
            }

            // Batch-build TRUE preview cells for every eligible board — ONE
            // workspace-scoped fetch reused across every board's `build(...)`
            // call (bugfix/board-preview-real-cells perf follow-up), instead
            // of `FromBoardPickerView` mounting a self-loading grid per row.
            // Reuses `allPlacements` from the read above rather than a second
            // `board_tasks` fetch.
            let previewCells: [String: BoardPreviewCellsResult]
            if result.boards.isEmpty {
                previewCells = [:]
            } else {
                let workspace = BoardPreviewCells.fetchWorkspaceData(userId: userId, database: database)
                previewCells = BoardPreviewCells.buildMany(
                    boards: result.boards, boardTasks: result.allPlacements, workspace: workspace
                )
            }

            await MainActor.run {
                guard mySeq == latestBoardsSeq else { return }
                self.eligibleBoards = result.boards
                self.completionByBoardId = result.completion
                self.previewCellsByBoardId = previewCells
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                guard mySeq == latestBoardsSeq else { return }
                self.loadError = "Failed to load source boards: \(error.localizedDescription)"
                self.eligibleBoards = []
                self.completionByBoardId = [:]
                self.previewCellsByBoardId = [:]
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
                self.compoundLeafIdsByParent = [:]
            }
            return
        }

        do {
            let result = try await database.read { db -> (
                placements: [SourceBoardPlacement],
                compoundLeaves: [String: [String]]
            ) in
                let placements = try BoardTask
                    .filter(Column("boardId") == boardId)
                    .fetchAll(db)
                if placements.isEmpty { return ([], [:]) }

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
                let resolved = sorted.map {
                    SourceBoardPlacement(placement: $0, task: tasksById[$0.taskId])
                }

                // Compound-leaf precompute — same snapshot as placements
                // so a sync write between two reads can't yield
                // mismatched data. Walks compound_children for every
                // compound-typed placement; keeps only primitive
                // (non-compound) children since nested compounds aren't
                // boardable as a unit through `Add all subtasks`.
                let compoundIds = resolved.compactMap { entry -> String? in
                    guard entry.task?.type == .compound else { return nil }
                    return entry.task?.id
                }
                var leavesByParent: [String: [String]] = [:]
                if !compoundIds.isEmpty {
                    let links = try CompoundChild
                        .filter(compoundIds.contains(Column("compoundTaskId")) && Column("isDeleted") == false)
                        .order(Column("childIndex"))
                        .fetchAll(db)
                    let childIds = Set(links.map { $0.childTaskId })
                    if !childIds.isEmpty {
                        let childTasks = try Task
                            .filter(childIds.contains(Column("id")) && Column("isDeleted") == false)
                            .fetchAll(db)
                        var childById: [String: Task] = [:]
                        for c in childTasks { childById[c.id] = c }
                        for link in links {
                            guard let child = childById[link.childTaskId] else { continue }
                            // Skip nested compounds — `Add all subtasks`
                            // flattens to primitive leaves only.
                            if child.type == .compound { continue }
                            leavesByParent[link.compoundTaskId, default: []].append(child.id)
                        }
                    }
                }

                return (resolved, leavesByParent)
            }

            await MainActor.run {
                guard mySeq == latestPlacementsSeq else { return }
                self.placements = result.placements
                self.compoundLeafIdsByParent = result.compoundLeaves
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                guard mySeq == latestPlacementsSeq else { return }
                self.loadError = "Failed to load source-board placements: \(error.localizedDescription)"
                self.placements = []
                self.compoundLeafIdsByParent = [:]
            }
        }
    }

    /// Sync shim for view-side fire-and-forget callers.
    func loadPlacementsAsync(forBoardId boardId: String?) {
        _Concurrency.Task { await loadPlacements(forBoardId: boardId) }
    }
}
