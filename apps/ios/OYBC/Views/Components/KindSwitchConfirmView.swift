import SwiftUI

/// Copy + rounding behind the Continuous → Discrete confirm
/// (docs/COUNTER_KINDS.md §5). Web twin: `kindSwitchModel.ts`.
enum KindSwitchCopy {
    /// D4 / §5: only the rounding direction confirms.
    static func needsConfirm(from: CountKind, to: CountKind) -> Bool {
        from == .continuous && to == .discrete
    }

    /// The confirm's copy — the one consequence body the no-explanatory-copy
    /// rule allows.
    ///
    /// - Parameter p: The switch preview.
    /// - Returns: Heading, the before → after rows, and the consequence body.
    static func lines(_ p: KindSwitchPreview) -> (title: String, rows: [(String, String)], body: String) {
        let family = p.linkedCount == 0
            ? ""
            : " Follows on \(p.linkedCount) linked square\(p.linkedCount == 1 ? "" : "s")."
        return (
            "Switch to \(p.to.label)?",
            [(p.titleBefore, p.titleAfter),
             ("\(formatCount(p.loggedBefore, kind: p.from)) logged", "\(formatCount(p.loggedAfter, kind: p.to)) logged")],
            "Switching back restores the exact values.\(family)"
        )
    }

    /// The Goal field's text after a confirmed switch (rounded for a whole kind).
    ///
    /// - Parameters:
    ///   - goalText: The Goal field's current text, typed at `from`.
    ///   - from: The kind the text was typed at.
    ///   - to: The confirmed kind.
    /// - Returns: The rounded goal text, or `goalText` unchanged when it does not parse.
    static func switchedGoalText(_ goalText: String, from: CountKind, to: CountKind) -> String {
        guard let goal = parseCountInput(goalText, kind: from),
              let rounded = planCountKindSwitch(maxCount: goal, defaultLogAmount: nil, from: from, to: to)?.maxCount
        else { return goalText }
        return formatCountForInput(rounded, kind: to)
    }
}

/// Continuous → Discrete confirm sheet (docs/COUNTER_KINDS.md §5; handoff
/// "Switch confirm", iOS frame). Web twin: `KindSwitchConfirmDialog.tsx`.
struct KindSwitchConfirmView: View {
    let preview: KindSwitchPreview
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        let lines = KindSwitchCopy.lines(preview)
        VStack(alignment: .leading, spacing: 14) {
            Text(lines.title)
                .font(.risoHead(22, .extraBold))
                .foregroundStyle(Color.risoInk)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 10) {
                        Text(row.0).strikethrough().foregroundStyle(Color.risoMuted)
                        Text("→").foregroundStyle(Color.risoMuted).accessibilityHidden(true)
                        Text(row.1).foregroundStyle(Color.risoInk)
                    }
                    .font(.risoHead(15, .bold))
                }
            }
            Text(lines.body)
                .font(.risoBody(12, .semibold))
                .foregroundStyle(Color.risoMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 9) {
                RisoButton(title: "Cancel", kind: .neutral, fullWidth: true, action: onCancel)
                RisoButton(title: "Switch", kind: .blue, fullWidth: true, action: onConfirm)
            }
        }
        .padding(.horizontal, Riso.gutter)
        .padding(.top, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.risoPaper)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.risoPaper)
    }
}

extension View {
    /// The one confirm seam for every editing sheet (Ruling U7): presents the
    /// dialog while `pending` is set; `onConfirm` receives the preview so the
    /// sheet sets its kind and rounds its goal with
    /// `KindSwitchCopy.switchedGoalText`. Twin of `useKindSwitchRequest`.
    func kindSwitchConfirm(
        pending: Binding<KindSwitchPreview?>,
        onConfirm: @escaping (KindSwitchPreview) -> Void
    ) -> some View {
        sheet(item: pending) { p in
            KindSwitchConfirmView(
                preview: p,
                onCancel: { pending.wrappedValue = nil },
                onConfirm: {
                    onConfirm(p)
                    pending.wrappedValue = nil
                }
            )
        }
    }
}
