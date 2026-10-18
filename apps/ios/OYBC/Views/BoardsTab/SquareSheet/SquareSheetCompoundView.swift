import SwiftUI

/// The compound body of the square sheet: the done-count, one bar segment per
/// child and the checklist. A counting child's box is a `+` that unfolds the
/// tap-to-log chips inline (one child open at a time) — counting children are
/// driven, never toggled.
struct SquareSheetCompoundView: View {
    let content: SquareSheetContent
    let compound: SquareSheetContent.Compound
    let strip: SquareLogStrip?
    @Binding var entry: SquareSheetEntry?
    let actions: SquareSheetActions

    @State private var openChildId: String?

    /// - Parameter initialOpenChildId: Snapshot seam — the counting child opened on appear.
    init(
        content: SquareSheetContent, compound: SquareSheetContent.Compound, strip: SquareLogStrip?,
        entry: Binding<SquareSheetEntry?>, actions: SquareSheetActions, initialOpenChildId: String? = nil
    ) {
        self.content = content
        self.compound = compound
        self.strip = strip
        _entry = entry
        self.actions = actions
        _openChildId = State(initialValue: initialOpenChildId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(compound.doneCount)")
                    .font(.risoHead(52, .extraBold))
                    .tracking(-0.9)
                    .monospacedDigit()
                    .foregroundStyle(Color.risoTeal)
                Text(SquareSheetFormat.subtaskLine(total: compound.children.count, board: content.boardName))
                    .font(.risoHead(13, .bold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                if let status = SquareSheetFormat.compoundStatus(doneCount: compound.doneCount, isComplete: compound.isComplete) {
                    RisoStatusPill(status: status)
                }
            }
            .padding(.top, 14)

            HStack(spacing: 4) {
                ForEach(compound.children) { child in
                    Capsule()
                        .fill(child.isDone ? Color.risoTeal : Color.clear)
                        .frame(height: 12)
                        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                }
            }
            .padding(.top, 10)

            VStack(spacing: 6) {
                ForEach(compound.children) { child in row(child) }
            }
            .padding(.top, 14)

            if let closed = content.closed {
                SquareSheetClosedRow(closed: closed, onLateLog: actions.onLateLog)
                    .padding(.top, 14)
            }
        }
    }

    private func row(_ child: SquareSheetContent.Child) -> some View {
        let isOpen = openChildId == child.id && child.counting != nil && content.closed == nil
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                box(child, isOpen: isOpen)
                RisoTypeBadge(kind: child.kind, style: .letterSquare)
                Button { actions.onOpenLibrary(child.id) } label: {
                    HStack(spacing: 6) {
                        Text(child.title)
                            .font(.risoHead(14, .bold))
                            .foregroundStyle(Color.risoInk)
                            .opacity(child.isDone ? 0.75 : 1)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let count = child.counting {
                            Text(count.meta)
                                .font(.risoBody(12, .extraBold))
                                .monospacedDigit()
                                .foregroundStyle(Color.risoBlue)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.risoMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(child.title) in library")
            }
            .padding(.vertical, 8)
            .padding(.leading, 10)
            .padding(.trailing, 8)

            if isOpen, let count = child.counting { expansion(child, count) }
            // A toggle child's write leaves its own inline strip.
            if child.counting == nil, let strip, strip.isVisible(boardTaskId: content.boardTaskId, scopeTaskId: child.id) {
                UndoStrip(text: strip.text, compact: true, disabled: content.isBusy, busyLook: content.showsBusyLook, onUndo: actions.onUndo)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .risoCard(keyline: Riso.Keyline.dense, fill: .risoPaper2)
    }

    /// 28pt checklist box: a toggle (check when done) or a counting `+`.
    private func box(_ child: SquareSheetContent.Child, isOpen: Bool) -> some View {
        let fill: Color = child.isDone ? .risoGreen : (isOpen ? .risoGold : .clear)
        let locked = content.isBusy || content.closed != nil || (child.isDone && child.sealBlocked)
        let looksLocked = content.showsBusyLook || content.closed != nil || (child.isDone && child.sealBlocked)
        return Button {
            if child.counting != nil {
                openChildId = isOpen ? nil : child.id
            } else {
                actions.onToggleChild(child.id)
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(fill)
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                if child.isDone {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(Color.risoOnColor)
                } else if child.counting != nil {
                    Text("+").font(.risoHead(16, .extraBold)).foregroundStyle(Color.risoInkStatic)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Opening a counting child's chips is not a write; only a toggle is gated by busy / closed.
        .disabled(child.counting == nil ? locked : content.closed != nil)
        .opacity(child.counting == nil && looksLocked ? 0.45 : 1)
        .accessibilityLabel(SquareSheetFormat.childBoxLabel(child, isOpen: isOpen))
    }

    @ViewBuilder
    private func expansion(_ child: SquareSheetContent.Child, _ count: SquareSheetContent.ChildCount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RisoProgressBar(
                value: count.goal > 0 ? min(count.current, count.goal) / count.goal : 0,
                color: count.goal > 0 && count.current >= count.goal ? .risoGreen : .risoBlue, height: 8
            )
            TapLogChipRow(chips: count.chips, size: .compact, disabled: content.isBusy, busyLook: content.showsBusyLook) { chip in
                if let value = chip.value {
                    actions.onLog(child.id, value, false)
                } else {
                    entry = SquareSheetEntry(scopeTaskId: child.id, isRemove: false)
                }
            }
            if let open = entry, open.scopeTaskId == child.id {
                SquareSheetEntryRow(kind: count.kind, unit: count.unit, isRemove: false, compact: true, onSubmit: { amount in
                    entry = nil
                    actions.onLog(child.id, amount, true)
                }, onCancel: { entry = nil })
            }
            if let strip, strip.isVisible(boardTaskId: content.boardTaskId, scopeTaskId: child.id) {
                UndoStrip(text: strip.text, compact: true, disabled: content.isBusy, busyLook: content.showsBusyLook, onUndo: actions.onUndo)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.risoPaper)
        .overlay(alignment: .top) { Rectangle().fill(Color.risoInk.opacity(0.14)).frame(height: 1.5) }
    }
}
