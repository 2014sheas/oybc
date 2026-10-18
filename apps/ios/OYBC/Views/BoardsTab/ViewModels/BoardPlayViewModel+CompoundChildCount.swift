import Foundation

// MARK: - BoardPlayViewModel + compound-child counting logs

extension BoardPlayViewModel {

    /// The square sheet's tap-to-log on a COUNTING compound child (and the
    /// reverse for Undo). A counting child can't be tap-toggled (a completion
    /// event means nothing to a count, and a linked child's count is its
    /// counter's), so its checklist `+` logs an amount instead. Same routing as
    /// `handleCompoundChildToggle`: a placement on THIS board goes through the
    /// orchestration; otherwise the board-window fallback
    /// (`incrementCompoundChildFallback`). A linked child always logs on its
    /// counter. Web twin: `useBoardPlay.handleCompoundChildIncrement`.
    ///
    /// - Parameters:
    ///   - childTask: The counting child.
    ///   - direction: `1` to log, `-1` to remove.
    ///   - amount: The amount to log; `nil` is the counter's default amount
    ///     (linked) or 1 (plain).
    ///   - persistAsDefault: An explicit "Other…" entry becomes the counter's default.
    func handleCompoundChildIncrement(childTask: Task, direction: Int, amount: CountValue? = nil, persistAsDefault: Bool = false) {
        guard !isProcessing, childTask.type == .counting else { return }

        if let sourceId = sharedCounterSourceId(for: childTask) {
            let sourceTask = taskMap[sourceId]
            let resolvedName = Self.counterDisplayName(sourceTask)
            let counterName = resolvedName.isEmpty ? childTask.title : resolvedName
            let unit = sourceTask?.unit ?? ""
            let kind = resolveCountKind(sourceTask?.countKind)
            let step = amount ?? sourceTask?.defaultLogAmount ?? 1
            if direction > 0 {
                runSharedCounterIncrement(sourceTaskId: sourceId, counterName: counterName, unit: unit, kind: kind, amount: step, persistAsDefault: persistAsDefault)
            } else {
                runSharedCounterDecrement(sourceTaskId: sourceId, counterName: counterName, unit: unit, kind: kind, amount: step, persistAsDefault: persistAsDefault)
            }
            return
        }

        let current = windowedState(forTaskId: childTask.id).count
        let step = amount ?? 1
        let delta: CountValue = direction > 0 ? step : -min(step, current)
        guard delta != 0 else { return }

        // Placed on this board → the full orchestration (bingo detection stays consistent).
        if let childBt = boardTasks.first(where: { $0.taskId == childTask.id }) {
            runOrchestration(
                taskId: childTask.id,
                intent: .setWindowedCount(quantizeCount(current + delta)),
                boardTask: childBt, persistDefault: persistAsDefault && direction > 0 ? step : nil
            )
            return
        }
        runCompoundChildFallbackDelta(childTask: childTask, delta: delta, persistDefault: persistAsDefault && direction > 0 ? step : nil)
    }

    /// Not placed here: the board-window fallback (event + cascade in one
    /// transaction), then this board's flash from the cascade result.
    ///
    /// - Parameters:
    ///   - childTask: The counting child.
    ///   - delta: Signed change to its windowed count.
    ///   - persistDefault: An explicit "Other…" amount to remember as the child's default.
    func runCompoundChildFallbackDelta(childTask: Task, delta: CountValue, persistDefault: CountValue? = nil) {
        let now = AppDatabase.currentTimestamp()
        let windowStart = board?.startDate ?? childTask.startDate ?? now
        let windowEnd = self.windowEnd
        let currentBoardId = board?.id
        let database = self.database
        setProcessing(true)
        addPendingCount(delta, forFamily: Self.countFamilyKey(childTask))
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let results = try database.incrementCompoundChildFallback(
                    childTaskId: childTask.id, delta: delta,
                    windowStart: windowStart, windowEnd: windowEnd, boardId: currentBoardId, now: now
                )
                if let amount = persistDefault {
                    do { try database.setCounterDefaultLogAmount(sourceTaskId: childTask.id, amount: amount) } catch { dlog("BoardPlayVM: persist default failed: \(error)") }
                }
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
