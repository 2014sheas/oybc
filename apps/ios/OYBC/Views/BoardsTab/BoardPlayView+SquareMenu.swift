import SwiftUI
import UIKit

// MARK: - BoardPlayView + the unified hold menu

// The `contextMenu` body for a placed square (docs/TASK_DETAIL_REDESIGN.md §PR 3):
// one vocabulary per type, fed by the pure `SquareMenu.entries(for:)` list. Menu
// writes give the same Undo a tap gives — Normal → the Normal toast, counting /
// compound → a toast with the log text (no sheet is open to hold a strip).
// Web twin: `components/boardPlay/squareMenu/`.
extension BoardPlayView {

    // MARK: Body

    /// The menu rows for a square. The header is a section title ("‹title› · ‹meta›"):
    /// a system `contextMenu` can't host a custom header view, and a custom `preview:`
    /// would replace the held square's own preview — so the system cell preview stays.
    @ViewBuilder
    func squareMenu(boardTask: BoardTask, task: Task?) -> some View {
        if let task {
            let input = squareMenuInput(boardTask: boardTask, task: task)
            Section(SquareMenu.headerText(input)) {
                ForEach(Array(SquareMenu.entries(for: input).enumerated()), id: \.offset) { _, entry in
                    switch entry {
                    case .divider:
                        Divider()
                    case let .item(item):
                        Button {
                            runSquareMenuAction(item.action, boardTask: boardTask, task: task)
                        } label: {
                            Label {
                                Text(item.label)
                                if let meta = item.meta { Text(meta) }
                            } icon: {
                                Image(systemName: item.icon)
                            }
                        }
                        .disabled(!item.isEnabled)
                    }
                }
            }
        }
    }

    // MARK: Input

    /// Facts a counting task's menu rows need (the quick amount's remembered default
    /// follows the shared source for discrete counters, else the task's own).
    private func squareMenuCounting(_ t: Task) -> SquareMenuInput.Counting {
        let kind = resolveFamilyCountKind(t, lookup: { taskMap[$0] })
        let source = viewModel.sharedCounterSourceId(for: t).flatMap { taskMap[$0] }
        return SquareMenuInput.Counting(
            kind: kind, unit: t.unit ?? "", current: windowedCount(t), goal: t.maxCount ?? 0,
            rememberedDefault: kind == .discrete ? source?.defaultLogAmount : (source ?? t).defaultLogAmount
        )
    }

    func squareMenuInput(boardTask bt: BoardTask, task: Task) -> SquareMenuInput {
        let body: SquareMenuInput.Body
        switch task.type {
        case .normal:
            let index = bt.row * (board?.boardSize ?? 3) + bt.col
            let isDone = isSealed ? (board?.sealedCompletedCells?.contains(index) ?? false) : windowedIsCompleted(task)
            // From the precomputed set — the menu never reads the database while it builds.
            body = .normal(isDone: isDone, sealBlocked: SquareMenu.sealBlocked(
                isDone: isDone, isClosed: isBoardLocked, taskId: task.id, cached: menuSealBlockedIds
            ))
        case .counting:
            body = .counting(squareMenuCounting(task))
        case .compound:
            let children: [Task] = (viewModel.compoundChildrenByCompound[task.id] ?? []).compactMap { link in
                guard let raw = taskMap[link.childTaskId], !raw.isDeleted else { return nil }
                return PlacementParams.withChildTarget(raw, childTargets: bt.childTargets)
            }
            let candidates = children.map {
                TaskDetailKernel.SubtaskCandidate(id: $0.id, type: $0.type, isCompleted: viewModel.compoundChildIsCompleted($0))
            }
            let next = TaskDetailKernel.nextSubtask(candidates)
            var nextId: String?
            switch next {
            case let .toggle(childId)?, let .log(childId)?: nextId = childId
            case nil: nextId = nil
            }
            let nextChild = children.first { $0.id == nextId }
            body = .compound(SquareMenuInput.Compound(
                next: next, nextChildTitle: nextChild?.title,
                nextChild: nextChild.flatMap { $0.type == .counting ? squareMenuCounting($0) : nil },
                doneCount: candidates.filter(\.isCompleted).count, total: candidates.count
            ))
        case .achievement:
            let a = viewModel.squareAchievement(bt, task)
            body = .achievement(isMet: a.isMet, watchedName: a.watchedName, openBoardId: a.openBoardId)
        }
        return SquareMenuInput(
            title: task.title, kind: RisoTaskKind(taskType: task.type), body: body,
            isClosed: isBoardLocked, lateLogRoutable: isLateLogRoutable(task: task), isBusy: viewModel.isProcessing
        )
    }

    // MARK: Actions

    private func runSquareMenuAction(_ action: SquareMenuAction, boardTask bt: BoardTask, task: Task) {
        switch action {
        case .toggleNormal:
            guard !viewModel.isProcessing else { return }
            toggleNormalSquare(boardTask: bt, task: task)
        case let .log(amount):
            showMenuLogToast(viewModel.performSquareLog(placement: bt, taskId: bt.taskId, amount: amount, persistAsDefault: false, removing: false))
        case .logOther:
            openSquareSheet(bt, entry: SquareSheetEntry(scopeTaskId: bt.taskId, isRemove: false))
        case .remove:
            openSquareSheet(bt, entry: SquareSheetEntry(scopeTaskId: bt.taskId, isRemove: true))
        case let .completeNextSubtask(childId):
            showMenuLogToast(viewModel.performChildToggle(placement: bt, childId: childId))
        case let .logChild(childId, amount):
            showMenuLogToast(viewModel.performSquareLog(placement: bt, taskId: childId, amount: amount, persistAsDefault: false, removing: false))
        case .allSubtasks, .details:
            openSquareSheet(bt, entry: nil)
        case let .openBoard(id):
            onOpenBoard(id)
        case .lateLog:
            routeLateLogTap(routable: true, boardTask: bt, task: task)
        case .openLibrary:
            taskDetailSheetTaskId = TaskIdItem(id: bt.taskId)
        }
    }

    private func openSquareSheet(_ bt: BoardTask, entry: SquareSheetEntry?) {
        squareSheetEntry = entry
        squareSheetBoardTaskId = bt.id
    }

    /// A menu write's Undo toast: the log text and an Undo that reverses exactly that write.
    private func showMenuLogToast(_ strip: SquareLogStrip?) {
        guard let strip else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            creditToast = CreditToastState(
                sourceTaskId: strip.scopeTaskId, amount: 0, unit: "", verb: .logged, message: strip.text,
                undo: .counterLog, toastKey: UUID().uuidString, squareUndo: strip.undo
            )
        }
    }
}
