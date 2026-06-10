import SwiftUI

/// CompositeWizardSetupStepView — Step 1 of the composite-task mini-wizard.
/// iOS twin of web's `SetupStep`. Title + operator selection + Ordered steps
/// toggle. The required-N stepper for `M_OF_N` lives on the Build step so
/// the user can pick the number with the full subtask list visible — picking
/// it here without any subtasks yet was out of place.
struct CompositeWizardSetupStepView: View {
    @Binding var title: String
    @Binding var operatorType: OperatorType
    /// Whether subtasks must be completed in strict sequential order.
    /// When true, hides the operator picker and forces AND semantics.
    @Binding var isOrdered: Bool
    let onCancel: () -> Void
    let onNext: () -> Void

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var titleError: String? {
        if trimmedTitle.isEmpty { return nil } // no nag on empty-and-untouched
        if trimmedTitle.count > 200 {
            return "Title must be 200 characters or less."
        }
        return nil
    }

    private var canAdvance: Bool {
        !trimmedTitle.isEmpty && titleError == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title (required)", text: $title)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Text("\(title.count)/200")
                        .font(.caption)
                        .foregroundColor(title.count > 200 ? .red : .secondary)
                }
                if let err = titleError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Completion rule")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Toggle("Ordered steps", isOn: $isOrdered)
                    .font(.subheadline)

                if isOrdered {
                    // Ordered mode forces AND — show the hint instead of the
                    // operator picker. Matches web behavior exactly.
                    Text("Complete subtasks in order.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Operator", selection: $operatorType) {
                        Text("All of").tag(OperatorType.and)
                        Text("Any of").tag(OperatorType.or)
                        Text("At least N of").tag(OperatorType.mOfN)
                    }
                    .pickerStyle(.segmented)

                    if operatorType == .mOfN {
                        Text("You'll set the required count with your subtasks.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Next ›", action: onNext)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
            }
        }
        .padding(14)
        .background(Color(.systemBackground))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
    }
}
