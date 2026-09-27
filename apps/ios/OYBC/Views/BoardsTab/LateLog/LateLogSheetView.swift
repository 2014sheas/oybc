import SwiftUI

/// Identifies which square opened the late-log sheet (`.sheet(item:)`
/// binding target) — `BoardPlayView`'s closed-board tap routing constructs
/// one of these in place of the normal tap dispatch.
struct LateLogSheetItem: Identifiable {
    let id: String // boardTaskId
    let boardTaskId: String
    let task: Task
}

// MARK: - LateLogSheetView (Board Edit redesign slice 4, D7/D15)
//
// The sheet a tap on a CLOSED board's square opens (i10/i11 in the design
// handoff). One view handles all three routable task types — NORMAL,
// COUNTING (plain/source or window-stamped derived), COMPOUND — since a
// closed board only ever routes here for those (a hub-linked derived counter
// or an ACHIEVEMENT square is a no-op at the tap site, never reaching this
// sheet). Pure presentation + local staging state; every write goes through
// the `on…` closures into `BoardPlayViewModel+LateLog.swift`.

/// One row in the COMPOUND variant's parts list.
struct LateLogCompoundPart: Identifiable {
    let id: String
    let title: String
    /// True for an event-owning child — a NORMAL child stages a completion,
    /// a plain COUNTING child stages a +1 (D7). Derived / nested-compound
    /// children are read-only rows ("non-event-owning children are
    /// read-only rows").
    let isStageable: Bool
    /// Already complete (in the sealed window) BEFORE this sheet opened.
    let alreadyDone: Bool
}

struct LateLogSheetView: View {
    /// "Sep 1 – 30" — the closed board's window label.
    let windowLabel: String
    let taskTitle: String

    enum Kind {
        case normal
        case counting(current: Int, max: Int, unit: String)
        case compound(parts: [LateLogCompoundPart])
    }
    let kind: Kind

    /// True when the square's current green/count comes from a late log the
    /// user can still undo (D15/OQ4) — swaps the primary button.
    var isUndoable: Bool = false

    // Every action is `async`: the sheet awaits it under `isBusy` (below).
    var onMarkDone: () async -> Void = {}
    var onUndo: () async -> Void = {}
    var onLogAmount: (Int) async -> Void = { _ in }
    var onCommitCompound: ([String]) async -> Void = { _ in }
    /// Compound pre-check: whether the staged child ids meet the rule
    /// (`BoardPlayViewModel.wouldLateLogCompoundRuleBeMet`). Disables
    /// "Mark done on board" until it does.
    var canCommitCompound: (Set<String>) -> Bool = { _ in true }
    var errorMessage: String?

    @State private var stagedChildIds: Set<String> = []
    @State private var customAmountDraft = ""
    @State private var customOpen = false
    /// True while an action's write is in flight — every action button is
    /// disabled (twin of web `LateLogSheet`'s `busy`), so a rapid double-tap
    /// can't submit twice. Set synchronously in `perform` BEFORE the Task
    /// starts, cleared in its `defer`. (The view model also refuses re-entry —
    /// `BoardPlayViewModel.runLateLogWrite` — so this is belt and braces.)
    @State private var isBusy = false

    /// Runs `action` under `isBusy`; a tap while busy is dropped.
    private func perform(_ action: @escaping () async -> Void) {
        guard !isBusy else { return }
        isBusy = true
        _Concurrency.Task { @MainActor in
            defer { isBusy = false }
            await action()
        }
    }

    var body: some View {
        ZStack {
            Color.risoPaper.ignoresSafeArea()
            VStack(spacing: 14) {
                headerPill
                switch kind {
                case .normal:
                    normalBody
                case let .counting(current, max, unit):
                    countingBody(current: current, max: max, unit: unit)
                case let .compound(parts):
                    compoundBody(parts: parts)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.risoBody(11, .semibold))
                        .foregroundStyle(Color.risoRed)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 18)
            .padding(.horizontal, Riso.gutter)
            .padding(.bottom, 24)
        }
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.risoPaper)
    }

    private var sheetHeight: CGFloat {
        switch kind {
        case .normal: return 190
        case .counting: return 260
        case let .compound(parts): return CGFloat(190 + parts.count * 44)
        }
    }

    // MARK: - Header

    private var headerPill: some View {
        VStack(spacing: 4) {
            Text(windowLabel)
                .font(.risoBody(10, .bold))
                .foregroundStyle(Color.risoMuted)
            HStack(spacing: 6) {
                Text(taskTitle)
                    .font(.risoHead(15, .bold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                Text("Closed")
                    .font(.risoHead(9, .bold))
                    .tracking(0.5)
                    .foregroundStyle(Color.risoInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.risoPaper2))
                    .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
            }
        }
    }

    // MARK: - Normal

    private var normalBody: some View {
        RisoButton(
            title: isUndoable ? "Undo late log" : "Mark done on board",
            kind: .primary,
            fullWidth: true,
            action: { perform(isUndoable ? onUndo : onMarkDone) }
        )
        .disabled(isBusy)
    }

    // MARK: - Counting

    @ViewBuilder
    private func countingBody(current: Int, max: Int, unit: String) -> some View {
        Text("\(current)/\(max)\(unit.isEmpty ? "" : " \(unit)")")
            .font(.risoHead(20, .extraBold))
            .foregroundStyle(Color.risoInk)
            .monospacedDigit()

        HStack(spacing: 8) {
            ForEach([1, 2, 5], id: \.self) { amount in
                RisoButton(title: "+\(amount)", kind: .neutral, small: true) {
                    perform { await onLogAmount(amount) }
                }
            }
            RisoButton(title: "Custom…", kind: .neutral, small: true) {
                customOpen = true
            }
        }
        .disabled(isBusy)
        if customOpen {
            HStack(spacing: 8) {
                RisoNumberField(placeholder: "Amount", text: $customAmountDraft)
                RisoButton(title: "Log", kind: .primary, small: true) {
                    if let amount = CounterLogAmount.parseCustom(customAmountDraft) {
                        perform { await onLogAmount(amount) }
                        customOpen = false
                        customAmountDraft = ""
                    }
                }
                .disabled(isBusy || CounterLogAmount.parseCustom(customAmountDraft) == nil)
            }
        }
        if isUndoable {
            RisoButton(title: "Undo late log", kind: .neutral, fullWidth: true) { perform(onUndo) }
                .disabled(isBusy)
        }
    }

    // MARK: - Compound

    @ViewBuilder
    private func compoundBody(parts: [LateLogCompoundPart]) -> some View {
        VStack(spacing: 8) {
            ForEach(parts) { part in
                let done = part.alreadyDone || stagedChildIds.contains(part.id)
                Button {
                    guard part.isStageable, !part.alreadyDone else { return }
                    if stagedChildIds.contains(part.id) {
                        stagedChildIds.remove(part.id)
                    } else {
                        stagedChildIds.insert(part.id)
                    }
                } label: {
                    HStack {
                        Image(systemName: done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(done ? Color.risoGreen : Color.risoMuted)
                        Text(part.title)
                            .font(.risoBody(13, .semibold))
                            .foregroundStyle(Color.risoInk)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(Color.risoPaper2)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!part.isStageable || part.alreadyDone)
            }
        }
        let canCommit = canCommitCompound(stagedChildIds) && !isBusy
        RisoButton(title: "Mark done on board", kind: .primary, fullWidth: true) {
            let staged = Array(stagedChildIds)
            perform { await onCommitCompound(staged) }
        }
        .disabled(!canCommit)
        .opacity(canCommit ? 1 : 0.45)
    }
}
