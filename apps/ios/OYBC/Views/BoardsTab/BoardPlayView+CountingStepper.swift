import SwiftUI

// MARK: - BoardPlayView + CountingStepper

/// The counting-stepper sheet's content and its "Task details" hand-off,
/// split out of `BoardPlayView.swift` (frozen at its file-size cap — an
/// extraction, not a cap bump). The `.sheet` itself stays in the main file's
/// body chain; the `@State` it reads is `internal` for this split.
extension BoardPlayView {

    /// Sheet `onDismiss` drain: opens the task-detail sheet requested from
    /// the stepper's "Task details" row, now that the stepper has unmounted.
    func drainPendingTaskDetail() {
        guard let id = pendingTaskDetailTaskId else { return }
        pendingTaskDetailTaskId = nil
        taskDetailSheetTaskId = TaskIdItem(id: id)
    }

    /// Stepper sheet content for the tapped counting square (nil-safe: an
    /// unresolved board-task renders nothing).
    @ViewBuilder
    var countingStepperSheetContent: some View {
        if let btId = countingStepperBoardTaskId,
           let bt = boardTasks.first(where: { $0.id == btId }),
           let task = taskMap[bt.taskId] {
            let maxVal = task.maxCount ?? 0
            let isLinked = task.sharedCounterId != nil
            // Windowed Completion — the stepper shows the WINDOWED count
            // (`windowedCount` owns the linked-counter rule).
            let displayed = windowedCount(task)
            // P2: shared hint — other ACTIVE boards where a member task
            // lives, excluding the current board.
            let sharedHint: String? = sharedStepperHint(for: task)
            // R3: resolve the shared-counter SOURCE (if any) to gate the
            // amount-chip row and seed its "+{default}" chip.
            let sourceId = viewModel.sharedCounterSourceId(for: task)
            let isSharedCounter = sourceId != nil
            let defaultLogAmount = sourceId.flatMap { taskMap[$0]?.defaultLogAmount }
            RisoCountingStepperSheet(
                taskTitle: task.title,
                currentCount: displayed,
                maxCount: maxVal,
                unitText: task.unit ?? "",
                isLinkedCounter: isLinked,
                sharedHint: sharedHint,
                isSharedCounter: isSharedCounter,
                defaultLogAmount: defaultLogAmount,
                onOpenTask: {
                    pendingTaskDetailTaskId = task.id
                    countingStepperBoardTaskId = nil
                },
                onIncrement: { amount, persistAsDefault in
                    viewModel.handleCountingTap(boardTask: bt, task: task, amount: amount, persistAsDefault: persistAsDefault)
                },
                onDecrement: { amount, persistAsDefault in
                    viewModel.handleCountingDecrement(boardTask: bt, task: task, amount: amount, persistAsDefault: persistAsDefault)
                }
            )
        }
    }
}
