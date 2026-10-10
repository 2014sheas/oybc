import Foundation

// MARK: - BoardPlayViewModel + "Counts toward" board surfaces

extension BoardPlayViewModel {

    /// Whether a play cell draws the two-dot shared-counter mark: a linked /
    /// promoted counting square (the shared-counter detection), or — PR 4 — any
    /// task that counts toward a shared counter (`countsTowardCounterId`), of any
    /// type. Twin of web's `useBoardPlayData` shared-counter set.
    ///
    /// - Parameter task: The cell's task (nil for an empty / free cell).
    /// - Returns: True when the mark applies (the cell hides it once complete).
    func showsSharedCounterMark(for task: Task?) -> Bool {
        guard let t = task else { return false }
        if t.countsTowardCounterId != nil { return true }
        return t.type == .counting && sharedCounterSourceId(for: t) != nil
    }
}

// MARK: - Completion moment (PR 4 C4)

extension SharedCounterCreditToastPayload {
    /// What the credit toast's Undo reverses.
    enum UndoKind: Equatable {
        /// A hand log: the counter's last log entry (`undoLastCounterLog`).
        case counterLog
        /// A counts-toward completion: the tapped task's completion itself —
        /// the cascade then tombstones the credit. NEVER `undoLastCounterLog`.
        case uncomplete(taskId: String, boardTaskId: String?)
    }
}

extension BoardPlayViewModel {

    /// The "also counted on …" toast for a completion that credited a counter
    /// other boards place — reuses the shared-counter toast copy
    /// (`sharedCreditToastText`) with an `.uncomplete` Undo. Nil when the task
    /// does not count toward a counter, the intent did not complete it, or no
    /// other board is credited. Reads the database (call off the main actor).
    ///
    /// - Parameters:
    ///   - database: The injected database.
    ///   - taskId: The completed task.
    ///   - intent: The completion intent — only `.setCompleted(true)` credits.
    ///   - boardTaskId: The tapped placement on this board, nil for a compound-child fallback.
    ///   - currentBoardId: The board being played (excluded from the credited list).
    nonisolated static func countsTowardCreditToast(
        database: AppDatabase, taskId: String, intent: AppDatabase.CompletionIntent, boardTaskId: String?, currentBoardId: String?
    ) -> SharedCounterCreditToastPayload? {
        guard case .setCompleted(true) = intent, let task = try? database.fetchTask(id: taskId), !task.isDeleted,
              let rootId = task.countsTowardCounterId,
              let root = try? database.fetchTask(id: rootId), !root.isDeleted,
              let boards = try? database.creditedBoards(forCounterRoot: rootId, excludingBoardId: currentBoardId),
              !boards.isEmpty
        else { return nil }
        let amount = CountValue(CountsToward.amount(of: task))
        let kind = resolveCountKind(root.countKind)
        return SharedCounterCreditToastPayload(
            sourceTaskId: rootId, amount: amount, unit: "", isIncrement: true,
            message: sharedCreditToastText(
                counterName: CounterSettings.counterDisplayName(root), amount: amount, kind: kind,
                otherBoards: boards, isIncrement: true
            ),
            undo: .uncomplete(taskId: taskId, boardTaskId: boardTaskId)
        )
    }

    /// The credit toast's Undo: a hand-log credit reverses the counter's last
    /// log; a counts-toward credit un-completes the task (no-op when it is no
    /// longer complete in this window).
    func undoCreditToast(_ undo: SharedCounterCreditToastPayload.UndoKind, sourceTaskId: String) {
        switch undo {
        case .counterLog:
            undoSharedCounterLog(sourceTaskId: sourceTaskId)
        case let .uncomplete(taskId, boardTaskId):
            guard windowedState(forTaskId: taskId).isCompleted else { return }
            if let boardTaskId, let placement = boardTasks.first(where: { $0.id == boardTaskId }) {
                handleNormalTap(boardTask: placement)
            } else if let task = taskMap[taskId] {
                handleCompoundChildToggle(childTask: task)
            }
        }
    }
}
