import Foundation

// MARK: - Board preview cells (bugfix/board-preview-real-cells)
//
// Swift twin of `apps/web/src/components/home/boardPreviewCells.ts`. Keep
// both in lockstep. Builds the TRUE mini-preview grid for a board — real
// `boardSize`, real `BoardTask.row/col` placement, real per-cell completion
// — using the exact same derivation `BoardPlayView`'s `risoPlaySquare` uses
// for the live play grid, so a preview can never show a state the real
// board doesn't have.

/// One rendered cell of a board mini-preview, row-major over `size*size`.
enum BoardPreviewCell: Equatable {
    /// A real placed square; `completed` is the SAME derivation the play
    /// surface uses (windowed events / compound evaluation / sealed
    /// snapshot / derived-counter lifetime cache / achievement cross-board
    /// reference — see `BoardPreviewCells.build`).
    case task(completed: Bool)
    /// The odd-board FREE/CUSTOM_FREE center — always renders "filled" on
    /// the real grid, same as `BoardPlayView`'s static FREE cell.
    case freeCenter
    /// No BoardTask placed at this position.
    case empty
}

/// Result of `BoardPreviewCells.build` — the row-major grid a mini-preview renders.
struct BoardPreviewCellsResult: Equatable {
    /// Grid edge length (`board.boardSize`).
    let size: Int
    /// Row-major, length `size * size`.
    let cells: [BoardPreviewCell]
}

/// Builds the TRUE mini-preview grid for a board. Mirrors
/// `apps/web/src/components/home/boardPreviewCells.ts`'s `buildBoardPreviewCells`
/// — see that file's doc comment for the rule list (sealed short-circuit,
/// windowed live evaluation, FREE center, empty cells). The one
/// platform-specific addition is the ACHIEVEMENT branch: iOS's play grid
/// live-derives achievement completion from cross-board references rather
/// than trusting the lifetime `Task.isCompleted` cache the way web's
/// `taskToSquareState` does. Board-integrity PR-3 — this now calls straight
/// into `DerivationPass.computeBoardGrid`'s per-cell ACHIEVEMENT resolution
/// (the ONE implementation of that branch on iOS) rather than hand-copying
/// the trigger/reference logic a third time.
enum BoardPreviewCells {

    /// - Parameters:
    ///   - board: The resolved board being previewed.
    ///   - boardTasks: This board's BoardTask placements (rows for other boards are defensively ignored).
    ///   - taskMap: Workspace task lookup, id → Task.
    ///   - childrenByCompound: Workspace compound-children lookup, keyed by parent compound task id.
    ///   - eventsByTaskId: Non-deleted TaskEvents grouped by taskId.
    ///   - allBoardsInWorkspace: Non-deleted workspace boards, needed only to resolve ACHIEVEMENT squares' cross-board reference. Pass `[]` if unavailable — a placed achievement square then reads incomplete, the same safe default `DerivationPass.computeBoardGrid` uses when its reference can't be resolved.
    /// - Returns: The row-major preview grid.
    static func build(
        board: Board,
        boardTasks: [BoardTask],
        taskMap: [String: Task],
        childrenByCompound: [String: [CompoundChild]],
        eventsByTaskId: [String: [TaskEvent]],
        allBoardsInWorkspace: [Board] = []
    ) -> BoardPreviewCellsResult {
        let size = board.boardSize
        let isSealed = board.sealedAt != nil
        let sealedCellSet = Set(isSealed ? (board.sealedCompletedCells ?? []) : [])
        let windowContext = CompoundWindowContext(windowStart: board.startDate, eventsByTaskId: eventsByTaskId)

        // Board-integrity PR-2 (Part 2): resolve through
        // `PlacementIntegrity.resolvePlacements` first — a raw duplicate
        // row at one cell would otherwise render whichever row happens to
        // iterate last (arbitrary), instead of the deterministic winner
        // the live play grid (`BoardPlayView.btByPosition`) and derivation
        // agree on. Second occurrence of the exact `btByPosition` pattern
        // the spec calls out, feeding board mini-previews across
        // `BoardListView` / `CoreBoardBrowserViewModel` / `SourceBoardsViewModel`.
        let ownBoardTasks = PlacementIntegrity.resolvePlacements(
            boardTasks.filter { $0.boardId == board.id },
            boardSize: size
        )
        var btByPosition: [String: BoardTask] = [:]
        for bt in ownBoardTasks {
            btByPosition["\(bt.row)-\(bt.col)"] = bt
        }

        // Board-integrity PR-3 — kernel per-cell state, keyed by
        // boardTaskId, consulted ONLY for the ACHIEVEMENT branch below.
        // Compound/primitive/sealed resolution stays inline (same judgment
        // rule `BoardPlayView.kernelCellStates` follows) — this removes the
        // "mirror-of-mirror" (this file used to hand-copy
        // `BoardPlayView.achievementCellIsCompleted`, itself a hand-copy of
        // `DerivationPass`'s ACHIEVEMENT branch).
        let kernelCells: [String: DerivationPass.CellState] = {
            let built = DerivationPass.computeBoardGrid(
                board: board,
                boardTasksOnBoard: ownBoardTasks,
                childrenByCompound: childrenByCompound,
                taskById: taskMap,
                allBoards: allBoardsInWorkspace,
                windowContext: WindowEvaluationContext(eventsByTaskId: eventsByTaskId)
            )
            var out: [String: DerivationPass.CellState] = [:]
            for c in built.cells {
                // boardTaskId is non-optional — every CellState maps to a
                // real placement (FREE-center auto-fill emits no CellState).
                out[c.boardTaskId] = c
            }
            return out
        }()

        let hasFreeCenter = size % 2 == 1 && (board.centerSquareType == .free || board.centerSquareType == .customFree)
        let centerRow = size / 2
        let centerCol = size / 2

        var cells: [BoardPreviewCell] = []
        cells.reserveCapacity(size * size)

        for row in 0..<size {
            for col in 0..<size {
                guard let bt = btByPosition["\(row)-\(col)"] else {
                    let isCenter = size % 2 == 1 && row == centerRow && col == centerCol
                    cells.append(isCenter && hasFreeCenter ? .freeCenter : .empty)
                    continue
                }

                guard let task = taskMap[bt.taskId] else {
                    cells.append(.empty)
                    continue
                }

                let cellIndex = row * size + col
                let completed: Bool
                if isSealed {
                    completed = sealedCellSet.contains(cellIndex)
                } else if task.type == .compound {
                    completed = CompoundEvaluation.evaluate(
                        compound: task,
                        childrenByCompound: childrenByCompound,
                        taskById: taskMap,
                        windowContext: windowContext
                    )
                } else if task.type == .achievement {
                    completed = kernelCells[bt.id]?.isCompleted ?? false
                } else if task.sharedCounterId != nil {
                    // Windowed Completion carve-out — derived counters stay on
                    // their propagation-stamped lifetime cache, never windowed.
                    completed = task.isCompleted
                } else {
                    completed = resolveTaskWindowState(
                        task: task,
                        events: eventsByTaskId[task.id] ?? [],
                        windowStart: board.startDate
                    ).isCompleted
                }
                cells.append(.task(completed: completed))
            }
        }

        return BoardPreviewCellsResult(size: size, cells: cells)
    }

    // MARK: - Batch loading (perf follow-up, bugfix/board-preview-real-cells)
    //
    // `build(...)` itself is pure/DB-free. These helpers own the DB side —
    // extracted so a screen rendering MANY boards (`BoardListView`,
    // `CoreBoardBrowserViewModel`, `SourceBoardsViewModel`/
    // `FromBoardPickerView`) fetches the four workspace-scoped datasets ONCE
    // and reuses them for every board's `build(...)` call, instead of each
    // board's card independently fetching all tasks / all compound children
    // / all boards / all events (an N-cards-N-times-the-reads bug — a
    // per-card self-loading wrapper, `RisoBoardPreviewGrid`, briefly existed
    // and was deleted once every remaining caller turned out to be a list;
    // `RisoBoardCard.previewCells` is now required, no self-load fallback).

    /// The four workspace-scoped datasets `build(...)` needs, pre-fetched and
    /// pre-grouped. Independent of any one board — reused across every
    /// board's `build(...)` call in `buildMany(...)`.
    struct WorkspaceData {
        let taskMap: [String: Task]
        let childrenByCompound: [String: [CompoundChild]]
        let allBoardsInWorkspace: [Board]
        let eventsByTaskId: [String: [TaskEvent]]

        /// Empty placeholder — for a view/view-model's initial state before
        /// its first `fetchWorkspaceData` call resolves.
        static let empty = WorkspaceData(taskMap: [:], childrenByCompound: [:], allBoardsInWorkspace: [], eventsByTaskId: [:])
    }

    /// Fetches `WorkspaceData` via `AppDatabase` reads — call ONCE per screen
    /// load (not per board/card). Safe to call off the main thread; each
    /// underlying `fetch*` call already wraps its own GRDB `read`. Sequential
    /// (not one transaction) — the same tradeoff `BoardPlayViewModel.fetchTaskData`
    /// already accepts for this class of read.
    static func fetchWorkspaceData(userId: String, database: AppDatabase = .shared) -> WorkspaceData {
        let allTasks = (try? database.fetchTasks(userId: userId)) ?? []
        let allCompoundChildren = (try? database.fetchAllCompoundChildren()) ?? []
        let allBoardsInWorkspace = (try? database.fetchBoards(userId: userId)) ?? []
        let events = (try? database.fetchNonDeletedTaskEvents(userId: userId)) ?? []

        var taskMap: [String: Task] = [:]
        for t in allTasks { taskMap[t.id] = t }

        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in allCompoundChildren where !c.isDeleted {
            childrenByCompound[c.compoundTaskId, default: []].append(c)
        }

        var eventsByTaskId: [String: [TaskEvent]] = [:]
        for e in events { eventsByTaskId[e.taskId, default: []].append(e) }

        return WorkspaceData(
            taskMap: taskMap,
            childrenByCompound: childrenByCompound,
            allBoardsInWorkspace: allBoardsInWorkspace,
            eventsByTaskId: eventsByTaskId
        )
    }

    /// Builds preview cells for MANY boards from one shared `boardTasks`
    /// array + one shared `WorkspaceData` — the batch counterpart to `build`.
    /// `boardTasks` may cover the whole workspace (each `build` call filters
    /// to its own `board.id` internally) or just the boards being rendered.
    ///
    /// - Returns: `board.id` → `BoardPreviewCellsResult`.
    static func buildMany(
        boards: [Board],
        boardTasks: [BoardTask],
        workspace: WorkspaceData
    ) -> [String: BoardPreviewCellsResult] {
        var out: [String: BoardPreviewCellsResult] = [:]
        out.reserveCapacity(boards.count)
        for board in boards {
            out[board.id] = build(
                board: board,
                boardTasks: boardTasks,
                taskMap: workspace.taskMap,
                childrenByCompound: workspace.childrenByCompound,
                eventsByTaskId: workspace.eventsByTaskId,
                allBoardsInWorkspace: workspace.allBoardsInWorkspace
            )
        }
        return out
    }
}
