import Foundation

// MARK: - BoardPlayViewModel + square sheet Undo

extension BoardPlayViewModel {

    /// The recipe that reverses the log the square sheet is about to make on
    /// `task` — captured BEFORE the write (a restore needs the count it started
    /// from). Every route reuses an existing undo path.
    ///
    /// - Parameters:
    ///   - task: The counting task logged on (the square's own, or a compound child).
    ///   - placement: Its placement on THIS board, if any.
    ///   - delta: The signed change about to be written (used when the child is unplaced).
    /// - Returns: The undo recipe.
    func squareLogUndo(for task: Task, placement: BoardTask?, delta: CountValue) -> SquareLogUndo {
        if let sourceId = sharedCounterSourceId(for: task) { return .counterLog(sourceTaskId: sourceId) }
        if let placement {
            return .restoreCount(taskId: task.id, boardTaskId: placement.id, count: windowedState(forTaskId: task.id).count)
        }
        return .childDelta(taskId: task.id, delta: delta)
    }

    /// Reverses one square-sheet log. A write in flight makes it a no-op (the
    /// sheet disables Undo while busy).
    ///
    /// - Parameter undo: What `squareLogUndo` captured.
    func undoSquareLog(_ undo: SquareLogUndo) {
        guard !isProcessing else { return }
        switch undo {
        case let .counterLog(sourceTaskId):
            undoSharedCounterLog(sourceTaskId: sourceTaskId)
        case let .restoreCount(taskId, boardTaskId, count):
            guard let placement = boardTasks.first(where: { $0.id == boardTaskId }) else { return }
            runOrchestration(taskId: taskId, intent: .setWindowedCount(count), boardTask: placement)
        case let .childDelta(taskId, delta):
            guard let child = taskMap[taskId] else { return }
            runCompoundChildFallbackDelta(childTask: child, delta: -delta)
        case let .restoreNormal(boardTaskId, wasDone):
            guard let placement = boardTasks.first(where: { $0.id == boardTaskId }) else { return }
            setNormalCompleted(boardTask: placement, completed: wasDone)
        case let .restoreToggle(taskId, wasDone):
            // Explicit revert to the prior state — a no-op when it already holds.
            guard let child = taskMap[taskId], compoundChildIsCompleted(child) != wasDone else { return }
            handleCompoundChildToggle(childTask: child)
        }
    }

    /// Sets a Normal square's completed state explicitly (the Normal Undo toast
    /// restores the PRIOR state; it must not toggle whatever is current).
    ///
    /// - Parameters:
    ///   - boardTask: The square's placement.
    ///   - completed: The state to restore.
    /// - Returns: False when a write is in flight (the caller keeps its toast and retries).
    @discardableResult
    func setNormalCompleted(boardTask: BoardTask, completed: Bool) -> Bool {
        guard !isProcessing else { return false }
        guard windowedState(forTaskId: boardTask.taskId).isCompleted != completed else { return true }
        runOrchestration(taskId: boardTask.taskId, intent: .setCompleted(completed), boardTask: boardTask)
        return true
    }
}
