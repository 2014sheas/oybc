import SwiftUI

/// The counting body of the square sheet: the windowed count anchored to THIS
/// board, the bar, the tap-to-log chips, the inline Undo strip and "− Remove…".
/// Closed boards swap the chips for the lock row.
struct SquareSheetCountingView: View {
    let content: SquareSheetContent
    let count: SquareSheetContent.ChildCount
    let strip: SquareLogStrip?
    @Binding var entry: SquareSheetEntry?
    let actions: SquareSheetActions

    private var isGoalMet: Bool { count.goal > 0 && count.current >= count.goal }
    private var showsStrip: Bool { strip?.isVisible(boardTaskId: content.boardTaskId, scopeTaskId: content.taskId) ?? false }
    private var entryOpen: SquareSheetEntry? { entry.flatMap { $0.scopeTaskId == content.taskId ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(formatCount(count.current, kind: count.kind))
                    .font(.risoHead(SquareSheetFormat.heroCountSize(count.kind), .extraBold))
                    .tracking(-0.9)
                    .monospacedDigit()
                    .foregroundStyle(Color.risoBlue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(SquareSheetFormat.countLine(goal: count.goal, unit: count.unit, kind: count.kind, board: content.boardName))
                    .font(.risoHead(13, .bold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                if let status = SquareSheetFormat.countStatus(current: count.current, goal: count.goal) {
                    RisoStatusPill(status: status)
                }
            }
            .padding(.top, 14)

            RisoProgressBar(
                value: count.goal > 0 ? min(count.current, count.goal) / count.goal : 0,
                color: isGoalMet ? .risoGreen : .risoBlue, height: 12
            )
            .padding(.top, 10)

            if let closed = content.closed {
                SquareSheetClosedRow(closed: closed, onLateLog: actions.onLateLog)
                    .padding(.top, 14)
            } else {
                openControls
            }
        }
    }

    @ViewBuilder
    private var openControls: some View {
        HStack(alignment: .firstTextBaseline) {
            SquareSheetEyebrow(text: "Tap to log")
            Spacer()
            if let rest = SquareSheetFormat.restLine(current: count.current, goal: count.goal, kind: count.kind, board: content.boardName) {
                Text(rest)
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
            }
        }
        .padding(.top, 14)

        TapLogChipRow(chips: count.chips, disabled: content.isBusy, busyLook: content.showsBusyLook, unit: countKindNeedsUnit(count.kind) ? count.unit : "") { chip in
            if let value = chip.value {
                actions.onLog(content.taskId, value, false)
            } else {
                entry = SquareSheetEntry(scopeTaskId: content.taskId, isRemove: false)
            }
        }
        .tutorialAnchor(.logChips)
        .padding(.top, 6)

        if let open = entryOpen {
            SquareSheetEntryRow(kind: count.kind, unit: count.unit, isRemove: open.isRemove, onSubmit: { amount in
                entry = nil
                if open.isRemove { actions.onRemove(content.taskId, amount) } else { actions.onLog(content.taskId, amount, true) }
            }, onCancel: { entry = nil })
            .padding(.top, 10)
        }

        if showsStrip, let strip {
            UndoStrip(text: strip.text, disabled: content.isBusy, busyLook: content.showsBusyLook, onUndo: actions.onUndo)
                .tutorialAnchor(.undoStrip)
                .padding(.top, 10)
        }

        HStack {
            Button { entry = SquareSheetEntry(scopeTaskId: content.taskId, isRemove: true) } label: {
                Text("− Remove…")
                    .font(.risoHead(12, .bold))
                    .foregroundStyle(Color.risoMuted)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(content.isBusy || count.current <= 0)
            .opacity(content.showsBusyLook || count.current <= 0 ? 0.45 : 1)
            Spacer()
        }
        .padding(.top, 6)
    }
}
