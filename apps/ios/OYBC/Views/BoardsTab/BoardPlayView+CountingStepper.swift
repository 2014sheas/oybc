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
            // R3: the shared-counter SOURCE (if any) gates the Discrete chip
            // row; its remembered amount (else the square's own) seeds the
            // selection (counter kinds §5).
            let sourceId = viewModel.sharedCounterSourceId(for: task)
            RisoCountingStepperSheet(
                taskTitle: task.title,
                currentCount: displayed,
                maxCount: maxVal,
                unitText: task.unit ?? "",
                countKind: resolveFamilyCountKind(task, lookup: { taskMap[$0] }),
                isLinkedCounter: isLinked,
                isSharedCounter: sourceId != nil,
                defaultLogAmount: (sourceId.flatMap { taskMap[$0] } ?? task).defaultLogAmount,
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
