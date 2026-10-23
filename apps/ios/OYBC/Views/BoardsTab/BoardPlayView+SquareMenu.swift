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
    /// The input is the placement's apply-time `menu` (no windowed resolution per body pass),
    /// with the busy look and any optimistic count folded in.
    @ViewBuilder
    func squareMenu(boardTask: BoardTask, task: Task?, render: PlacementRender) -> some View {
        if let task, let input = viewModel.menuInput(for: render) {
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
