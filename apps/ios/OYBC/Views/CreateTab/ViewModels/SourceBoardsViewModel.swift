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

    /// Precomputed thumbnail cell states for each eligible board,
    /// keyed by board id. Filled by `reload(userId:)` so the picker
    /// can render thumbnails without per-card async fetches.
    var thumbnailStatesByBoardId: [String: [ThumbnailCellState]] = [:]

    /// Precomputed completion ratio for each eligible board
    /// (`(completed, total)`), keyed by board id.
    var completionByBoardId: [String: (completed: Int, total: Int)] = [:]

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
            let result = try await AppDatabase.shared.read { db -> (
                boards: [Board],
                thumbnails: [String: [ThumbnailCellState]],
                completion: [String: (Int, Int)]
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
                    return (eligible, [:], [:])
                }

                let boardIds = Set(eligible.map { $0.id })
                let allPlacements = try BoardTask
                    .filter(boardIds.contains(Column("boardId")))
                    .fetchAll(db)
                if allPlacements.isEmpty {
                    var emptyThumbs: [String: [ThumbnailCellState]] = [:]
                    var emptyCompl: [String: (Int, Int)] = [:]
                    for b in eligible {
                        emptyThumbs[b.id] = Array(
                            repeating: .empty,
                            count: b.boardSize * b.boardSize
                        )
                        emptyCompl[b.id] = (0, b.boardSize * b.boardSize)
                    }
                    return (eligible, emptyThumbs, emptyCompl)
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

                var thumbnails: [String: [ThumbnailCellState]] = [:]
                var completion: [String: (Int, Int)] = [:]
                for board in eligible {
                    let size = board.boardSize
                    var states: [ThumbnailCellState] = Array(
                        repeating: .empty,
                        count: size * size
                    )
                    // Mirror web's `computeCellStates`: any odd-geometry
                    // board with a center-square type (FREE / CUSTOM_FREE
                    // / CHOSEN) gets a center marker on the computed
                    // center cell regardless of whether a placement
                    // exists there. CenterSquareType.none → no marker.
                    let usesChosenCenter = board.centerSquareType == .chosen
                        || board.centerSquareType == .free
                        || board.centerSquareType == .customFree
                    let centerIndex: Int = (size % 2 == 1 && usesChosenCenter)
                        ? (size / 2) * size + (size / 2)
                        : -1

                    var done = 0
                    for p in placementsByBoard[board.id] ?? [] {
                        let idx = p.row * size + p.col
                        guard idx >= 0 && idx < states.count else { continue }
                        let task = tasksById[p.taskId]
                        // Completion is counted independently of cell
                        // state so the center cell's completion still
                        // contributes to the ratio shown beside the
                        // thumbnail (matches web's `countCompleted`).
                        if task?.isCompleted == true {
                            done += 1
                        }
                        if p.isCenter || idx == centerIndex {
                            states[idx] = .center
                        } else if task?.isCompleted == true {
                            states[idx] = .done
                        } else if task != nil {
                            states[idx] = .pending
                        }
                    }
                    // FREE / CUSTOM_FREE: no placement at the center; we
                    // still want the orange marker so the user can spot
                    // those boards visually.
                    if centerIndex >= 0 && states[centerIndex] == .empty {
                        states[centerIndex] = .center
                    }
                    thumbnails[board.id] = states
                    completion[board.id] = (done, size * size)
                }

                return (eligible, thumbnails, completion)
            }

            await MainActor.run {
                guard mySeq == latestBoardsSeq else { return }
                self.eligibleBoards = result.boards
                self.thumbnailStatesByBoardId = result.thumbnails
                self.completionByBoardId = result.completion
                self.loadError = nil
            }
        } catch {
            await MainActor.run {
                guard mySeq == latestBoardsSeq else { return }
                self.loadError = "Failed to load source boards: \(error.localizedDescription)"
                self.eligibleBoards = []
                self.thumbnailStatesByBoardId = [:]
                self.completionByBoardId = [:]
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
