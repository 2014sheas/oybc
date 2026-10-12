import Foundation

// MARK: - BoardPlayViewModel + Bingo / Greenlog moment

/// Builds the moment overlay's inputs from the data the play surface already
/// holds — the replay (via the shared kernel twin) and one end-state face per
/// grid slot — so the overlay never reads the database itself.
extension BoardPlayViewModel {

    /// The replay for the loaded board, or nil when no board is loaded.
    func momentReplay() -> BoardMomentReplay? {
        guard let board else { return nil }
        return computeBoardMomentReplay(
            board: board, boardTasks: boardTasks,
            childrenByCompound: compoundChildrenByCompound, taskById: taskMap,
            eventsByTaskId: windowEventsByTaskId, allBoards: allBoardsInWorkspace
        )
    }

    /// One `MomentCellInput` per grid slot, row-major: placed squares with
    /// their end-state counts, the FREE centre, or an empty slot.
    func momentCellInputs(replay: BoardMomentReplay) -> [MomentCellInput] {
        guard let board else { return [] }
        let size = board.boardSize
        let placements = PlacementIntegrity.resolvePlacements(boardTasks, boardSize: size)
        var byIdx: [Int: BoardTask] = [:]
        for bt in placements { byIdx[bt.row * size + bt.col] = bt }
        let completed = Set(replay.order.map(\.idx))
        return (0..<(size * size)).map { idx in
            if idx == replay.freeIdx { return MomentCellInput(idx: idx, slot: .free) }
            guard let bt = byIdx[idx], let task = taskMap[bt.taskId] else { return MomentCellInput(idx: idx, slot: .empty) }
            var input = MomentCellInput(
                idx: idx, title: task.title, taskType: CellTaskType(task: task),
                endCompleted: completed.contains(idx)
            )
            if task.type == .counting {
                input.currentCount = task.sharedCounterId != nil
                    ? resolveLinkedCounterDisplay(
                        task: task, eventsByTaskId: windowEventsByTaskId, sealedAt: board.sealedAt,
                        window: LinkedCounterWindow(board: board)
                    ).displayed
                    : windowedState(of: task).count
                input.maxCount = task.maxCount ?? 0
                input.countKind = resolveFamilyCountKind(task, lookup: { taskMap[$0] })
            } else if task.type == .compound {
                let links = compoundChildrenByCompound[task.id] ?? []
                input.compoundChildCount = links.count
                input.compoundDoneCount = links.filter { link in
                    guard let child = taskMap[link.childTaskId] else { return false }
                    return compoundChildIsCompleted(child)
                }.count
                switch task.operatorType {
                case .or: input.compoundRequiredCount = 1
                case .mOfN: input.compoundRequiredCount = Swift.max(1, task.threshold ?? 1)
                case .and, nil: input.compoundRequiredCount = links.count
                }
            }
            return input
        }
    }
}
