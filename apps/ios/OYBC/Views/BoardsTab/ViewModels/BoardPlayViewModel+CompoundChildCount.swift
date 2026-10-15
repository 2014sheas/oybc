import Foundation

// MARK: - BoardPlayViewModel + compound-child count stepper

extension BoardPlayViewModel {

    /// The compound sheet's stepper on a COUNTING child: `+1` logs the child's
    /// step, `-1` removes it. A counting child can't be tap-toggled (a
    /// completion event means nothing to a count, and a linked child's count is
    /// its counter's), so the sheet steps it instead. Same routing as
    /// `handleCompoundChildToggle`: a placement on THIS board goes through the
    /// orchestration; otherwise the board-window fallback
    /// (`incrementCompoundChildFallback`). A linked child always logs on its
    /// counter, by the counter's default amount, exactly like a placed linked
    /// square. Web twin: `useBoardPlay.handleCompoundChildIncrement`.
    ///
    /// - Parameters:
    ///   - childTask: The counting child.
    ///   - direction: `1` to log a step, `-1` to remove one.
    func handleCompoundChildIncrement(childTask: Task, direction: Int) {
        guard !isProcessing, childTask.type == .counting else { return }

        if let sourceId = sharedCounterSourceId(for: childTask) {
            let sourceTask = taskMap[sourceId]
            let resolvedName = Self.counterDisplayName(sourceTask)
            let counterName = resolvedName.isEmpty ? childTask.title : resolvedName
            let unit = sourceTask?.unit ?? ""
            let kind = resolveCountKind(sourceTask?.countKind)
            let amount = sourceTask?.defaultLogAmount ?? 1
            if direction > 0 {
                runSharedCounterIncrement(sourceTaskId: sourceId, counterName: counterName, unit: unit, kind: kind, amount: amount)
            } else {
                runSharedCounterDecrement(sourceTaskId: sourceId, counterName: counterName, unit: unit, kind: kind, amount: amount)
            }
            return
        }

        let current = windowedState(forTaskId: childTask.id).count
        let delta: CountValue = direction > 0 ? 1 : -min(1, current)
        guard delta != 0 else { return }

        // Placed on this board → the full orchestration (bingo detection stays consistent).
        if let childBt = boardTasks.first(where: { $0.taskId == childTask.id }) {
            runOrchestration(
                taskId: childTask.id,
                intent: .setWindowedCount(quantizeCount(current + delta)),
                boardTask: childBt
            )
            return
        }

        // Not placed here: the board-window fallback (event + cascade in one
        // transaction), then this board's flash from the cascade result.
        let now = AppDatabase.currentTimestamp()
        let windowStart = board?.startDate ?? childTask.startDate ?? now
        let windowEnd = self.windowEnd
        let currentBoardId = board?.id
        let database = self.database
        setProcessing(true)
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let results = try database.incrementCompoundChildFallback(
                    childTaskId: childTask.id, delta: delta,
                    windowStart: windowStart, windowEnd: windowEnd, boardId: currentBoardId, now: now
                )
                let flash = BoardFlashOutcome.resolve(cascade: currentBoardId.flatMap { results[$0] })
                await MainActor.run {
                    self.reload { self.setProcessing(false) }
                    self.emitFlash(flash, creditToast: nil)
                }
            } catch {
                dlog("⚠️ BoardPlayView compoundChildIncrement error: \(error)")
                await MainActor.run { self.setProcessing(false) }
            }
        }
    }
}
