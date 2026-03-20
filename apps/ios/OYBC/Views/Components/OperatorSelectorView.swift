import SwiftUI

/// Three-button group for selecting a composite task operator.
///
/// Provides mutually exclusive selection between AND ("All of"),
/// OR ("Any of"), and M_OF_N ("At least N of") operators.
/// Active button has a filled blue background; inactive buttons are outlined.
/// Mirrors the web `OperatorSelector` component in `OperatorSelector.tsx`.
///
/// - Parameters:
///   - selectedOperator: Binding to the currently selected `OperatorType`.
///   - onOperatorChange: Called with the new `OperatorType` when a button is tapped.
struct OperatorSelectorView: View {

    // MARK: - Parameters

    @Binding var selectedOperator: OperatorType
    var onOperatorChange: ((OperatorType) -> Void)? = nil

    // MARK: - Private Helpers

    private struct OperatorOption {
        let value: OperatorType
        let label: String
    }

    private let options: [OperatorOption] = [
        OperatorOption(value: .and,   label: "All of"),
        OperatorOption(value: .or,    label: "Any of"),
        OperatorOption(value: .mOfN,  label: "At least N of"),
    ]

    // MARK: - Body

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.label) { option in
                let isActive = selectedOperator == option.value
                Button {
                    selectedOperator = option.value
                    onOperatorChange?(option.value)
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
        @State private var op: OperatorType = .and
        var body: some View {
            VStack(spacing: 16) {
                OperatorSelectorView(selectedOperator: $op)
                Text("Selected: \(op.rawValue)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }
    return Preview()
}
