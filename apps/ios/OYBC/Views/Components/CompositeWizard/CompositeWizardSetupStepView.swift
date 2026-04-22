import SwiftUI

/// CompositeWizardSetupStepView — Step 1 of the composite-task mini-wizard.
/// iOS twin of web's `SetupStep`. Title + operator + conditional
/// threshold. Next is blocked until the title is non-empty.
struct CompositeWizardSetupStepView: View {
    @Binding var title: String
    @Binding var operatorType: OperatorType
    @Binding var threshold: Int

    /// Only used to tune the hint text ("of 3 subtasks" vs "of the
    /// subtasks you'll add next"). The stepper is no longer capped to
    /// this value — users can pick any N ≥ 1 upfront, and the Build
    /// step blocks Next until enough subtasks exist to satisfy it.
    let subtaskCount: Int
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

    private var thresholdMax: Int {
        // Soft cap — users can pick any reasonable N upfront, Build
        // validates. Stays ahead of both current count and current
        // threshold so the + button never disables in normal use.
        max(20, subtaskCount, threshold)
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

                Picker("Operator", selection: $operatorType) {
                    Text("All of").tag(OperatorType.and)
                    Text("Any of").tag(OperatorType.or)
                    Text("At least N of").tag(OperatorType.mOfN)
                }
                .pickerStyle(.segmented)

                if operatorType == .mOfN {
                    HStack(spacing: 10) {
                        Text("Required:")
                        Button("−") {
                            if threshold > 1 { threshold -= 1 }
                        }
                        .buttonStyle(.bordered)
                        .disabled(threshold <= 1)
                        Text("\(threshold)")
                            .frame(minWidth: 30)
                            .fontWeight(.semibold)
                        Button("+") {
                            if threshold < thresholdMax { threshold += 1 }
                        }
                        .buttonStyle(.bordered)
                        .disabled(threshold >= thresholdMax)
                        Text(subtaskCount > 0
                             ? "of \(subtaskCount) subtask\(subtaskCount == 1 ? "" : "s")"
                             : "of the subtasks you'll add next")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
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
