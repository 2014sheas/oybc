import SwiftUI

/// Shared compound completion-rule picker: the "All of" / "Any of" / "At
/// least N" pill-chip row, plus the conditional "How many?" threshold
/// stepper shown only when the rule is `.atLeastN`.
///
/// Used by both compound builders — the create panel
/// (`RisoCompoundFieldsView`) and the inline pool-row editor
/// (`RisoPoolRowEditorView`) — so the two can never visually drift apart.
/// Styling is pixel-identical to the original inline chips/stepper this
/// replaced in `RisoCompoundFieldsView`.
struct RisoCompoundRulePicker: View {
    @Binding var rule: CompoundRuleChoice
    @Binding var threshold: Int
    /// Current live sub-task count — clamps the stepper's max to
    /// `max(2, subCount)` and drives the "of N sub-tasks" caption.
    let subCount: Int

    /// The displayed threshold, clamped into the valid range for the
    /// current sub-task count. Display-only — the caller's `threshold`
    /// binding is only written back through the stepper's own setter or
    /// user interaction, never implicitly by this getter.
    private var effectiveThreshold: Int {
        let maxN = Swift.max(2, subCount)
        return Swift.min(Swift.max(1, threshold), maxN)
    }

    var body: some View {
        // 9pt, not 5 — in the original (pre-extraction) `RisoCompoundFieldsView`
        // layout the rule chips and the "How many?" stepper were separate
        // top-level children of the panel's outer spacing-9 VStack (only the
        // chips-row's OWN label used a tighter 5pt gap, which the caller still
        // owns above this view). Matching 9pt here keeps both compound
        // builders pixel-identical to the pre-rework baseline.
        VStack(alignment: .leading, spacing: 9) {
            ruleChipsRow
            if rule == .atLeastN {
                HStack(alignment: .center, spacing: 9) {
                    Text("How many?").risoSectionLabel()
                    Spacer()
                    RisoInlineStepperView(
                        value: Binding(
                            get: { effectiveThreshold },
                            set: { threshold = Swift.min(Swift.max(1, $0), Swift.max(2, subCount)) }
                        ),
                        min: 1,
                        max: Swift.max(2, subCount)
                    )
                    Text("of \(subCount == 0 ? "…" : "\(subCount)") sub-tasks")
                        .font(.risoBody(11, .semibold))
                        .foregroundStyle(Color.risoMuted)
                }
            }
        }
    }

    // MARK: - Rule chips row

    private var ruleChipsRow: some View {
        HStack(spacing: 6) {
            ForEach(CompoundRuleChoice.allCases, id: \.rawValue) { choice in
                ruleChip(choice)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func ruleChip(_ choice: CompoundRuleChoice) -> some View {
        let isOn = rule == choice
        return Button {
            rule = choice
        } label: {
            Text(choice.rawValue)
                .font(.risoHead(11, .bold))
                .foregroundStyle(isOn ? Color.risoPaper : Color.risoInk)
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(Capsule().fill(isOn ? Color.risoGreen : Color.risoPaper))
                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
        }
        .buttonStyle(.plain)
    }
}
