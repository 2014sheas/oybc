import SwiftUI

/// The Goal + Counting pair every new counting sub-task is configured with:
/// required-starred labels, the kit's `RisoNumberField` for the goal and a
/// `RisoTextField` for the counted noun. One view for the compound CREATE
/// panel (`RisoCompoundFieldsView`, under its "Do" input) and the compound
/// EDIT editor (`RisoCompoundEditFieldsView`, under the quick-add row whose
/// text is the action). Web twin: `CountingSubConfigRow`.
struct RisoCountingSubConfigRow: View {
    /// The Goal field's text (the counting child's `maxCount`), parsed at the shown kind.
    @Binding var goal: String
    /// The Counting field's text (the counted noun, stored as `unit`).
    @Binding var unit: String
    /// The new sub-task's kind (picked). Ignored while `linked` is set.
    @Binding var kind: CountKind
    /// Set while the sub-task auto-links: the family's kind tag replaces the
    /// picker and the Goal follows the root's kind (D5).
    var linked: LinkableCounterSuggestion? = nil

    private var shownKind: CountKind { linked?.countKind ?? kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let linked {
                KindTagView(kind: linked.countKind, counterName: linked.name, lifetime: linked.lifetime)
            } else {
                KindPickerView(selection: $kind, lock: .none)
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    requiredLabel("Goal")
                    GoalEntryView(kind: shownKind, text: $goal, placeholder: shownKind == .duration ? "0h 0m" : "100")
                }
                if countKindNeedsUnit(shownKind) {
                    VStack(alignment: .leading, spacing: 5) {
                        requiredLabel("Counting")
                        RisoTextField(placeholder: "push-ups", text: $unit)
                    }
                }
            }
        }
    }

    /// Section label + red "*" — the create panel's required-field convention.
    private func requiredLabel(_ text: String) -> some View {
        HStack(spacing: 3) {
            Text(text)
                .risoSectionLabel()
            Text("*")
                .font(.risoBody(11, .bold))
                .foregroundStyle(Color.risoRed)
        }
    }
}
