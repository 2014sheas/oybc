import SwiftUI

/// A single option definition for `TaskTypeSelectorView`.
struct TaskTypeOption {
    /// Underlying value used for comparison and callbacks.
    let value: String
    /// Human-readable label displayed on the button.
    let label: String
}

/// Mutually exclusive button group for selecting a task type.
///
/// Active button is rendered with a filled blue background; inactive
/// buttons show an outlined style. Mirrors the web `TaskTypeSelector`
/// component in `TaskTypeSelector.tsx`.
///
/// - Parameters:
///   - types: Available type option definitions.
///   - selectedType: Binding to the currently selected type value.
///   - onTypeChange: Called with the new type value when a button is tapped.
struct TaskTypeSelectorView: View {

    // MARK: - Parameters

    let types: [TaskTypeOption]
    @Binding var selectedType: String
    var onTypeChange: ((String) -> Void)? = nil

    // MARK: - Body

    var body: some View {
        HStack(spacing: 8) {
            ForEach(types, id: \.value) { option in
                let isActive = selectedType == option.value
                Button {
                    selectedType = option.value
                    onTypeChange?(option.value)
                } label: {
                    Text(option.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isActive ? .white : .blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isActive ? Color.blue : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.blue, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isActive ? [.isSelected] : [])
            }
        }
    }
}

#Preview {
    struct Preview: View {
        @State private var selected = "normal"
        var body: some View {
            TaskTypeSelectorView(
                types: [
                    TaskTypeOption(value: "normal", label: "Normal"),
                    TaskTypeOption(value: "counting", label: "Counting"),
                    TaskTypeOption(value: "progress", label: "Progress"),
                    TaskTypeOption(value: "composite", label: "Composite"),
                ],
                selectedType: $selected
            )
            .padding()
        }
    }
    return Preview()
}
