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
/// (`BoardPlayView.risoPlaySquare` / `achievementCellIsCompleted`) live-derives
/// achievement completion from cross-board references rather than trusting the
/// lifetime `Task.isCompleted` cache the way web's `taskToSquareState` does —
/// this function reuses that exact iOS derivation, not a reinvented one.
enum BoardPreviewCells {

    /// - Parameters:
    ///   - board: The resolved board being previewed.
    ///   - boardTasks: This board's BoardTask placements (rows for other boards are defensively ignored).
    ///   - taskMap: Workspace task lookup, id → Task.
    ///   - childrenByCompound: Workspace compound-children lookup, keyed by parent compound task id.
    ///   - eventsByTaskId: Non-deleted TaskEvents grouped by taskId.
    ///   - allBoardsInWorkspace: Non-deleted workspace boards, needed only to resolve ACHIEVEMENT squares' cross-board reference. Pass `[]` if unavailable — a placed achievement square then reads incomplete, the same safe default `achievementCellIsCompleted` uses when its reference can't be resolved.
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

        var btByPosition: [String: BoardTask] = [:]
        for bt in boardTasks where bt.boardId == board.id {
            btByPosition["\(bt.row)-\(bt.col)"] = bt
        }

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
                    completed = achievementIsCompleted(task: task, parent: board, allBoardsInWorkspace: allBoardsInWorkspace)
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

    /// Local mirror of `BoardPlayView.achievementCellIsCompleted` — see that
    /// method's doc comment. Kept in lockstep by hand (both are small, direct
    /// ports of `DerivationPass`'s ACHIEVEMENT branch).
    private static func achievementIsCompleted(task: Task, parent: Board, allBoardsInWorkspace: [Board]) -> Bool {
        let trigger = task.achievementTrigger ?? .greenlog
        let meets: (Board) -> Bool = { b in
            switch trigger {
            case .bingo:
                return b.linesCompleted > 0
            case .greenlog:
                return b.status == .completed
            }
        }
        if let refBoardId = task.referencedBoardId {
            guard let ref = allBoardsInWorkspace.first(where: { $0.id == refBoardId && !$0.isDeleted }) else {
                return false
            }
            return meets(ref)
        }
        if let refTemplateId = task.referencedTemplateId {
            let spawns = allBoardsInWorkspace.filter { b in
                !b.isDeleted
                    && b.spawnedFromTemplateId == refTemplateId
                    && DateFormatting.isWithinTimeframe(b.startDate, startDate: parent.startDate, endDate: parent.endDate)
            }
            if spawns.isEmpty { return false }
            let metCount = spawns.filter(meets).count
            let required = task.requiredCount ?? 0
            return required > 0 && metCount >= required
        }
        return false
    }
}
