import SwiftUI

/// The Goal + Counting pair every new counting sub-task is configured with:
/// required-starred labels, the kit's `RisoNumberField` for the goal and a
/// `RisoTextField` for the counted noun. One view for the compound CREATE
/// panel (`RisoCompoundFieldsView`, under its "Do" input) and the compound
/// EDIT editor (`RisoCompoundEditFieldsView`, under the quick-add row whose
/// text is the action). Web twin: `CountingSubConfigRow`.
struct RisoCountingSubConfigRow: View {
    /// The Goal field's text (the counting child's `maxCount`).
    @Binding var goal: String
    /// The Counting field's text (the counted noun, stored as `unit`).
    @Binding var unit: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                requiredLabel("Goal")
                RisoNumberField(placeholder: "100", text: $goal)
                    .frame(width: 70)
            }
            VStack(alignment: .leading, spacing: 5) {
                requiredLabel("Counting")
                RisoTextField(placeholder: "push-ups", text: $unit)
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
