import SwiftUI

/// CompositeWizardReviewStepView — Step 3 of the composite-task mini-wizard.
/// iOS twin of web's `ReviewStep`. Minimal summary + Create button for
/// stage 2; fuller polish (summary card, library callout, retry UI)
/// lands in stage 4.
struct CompositeWizardReviewStepView: View {
    let title: String
    let operatorType: OperatorType
    let threshold: Int
    let subtasks: [SubtaskItem]
    let isSubmitting: Bool
    let errorMessage: String?
    let onBack: () -> Void
    let onCreate: () -> Void

    private var operatorLabel: String {
        switch operatorType {
        case .and: return "All of"
        case .or: return "Any of"
        case .mOfN: return "At least \(threshold) of"
        }
    }

    private var inlineCount: Int {
        subtasks.filter { $0.mode == .inline_ }.count
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review")
                .font(.title3)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                summaryRow(label: "Title", value: trimmedTitle.isEmpty ? "(unset)" : trimmedTitle)
                summaryRow(label: "Completion rule", value: operatorLabel)
                summaryRow(
                    label: "Subtasks",
                    value: "\(subtasks.count) total"
                    + (inlineCount > 0 ? " · \(inlineCount) will also be added to your library" : "")
                )
            }
            .padding(12)
            .background(Color(.systemGray6))
            .cornerRadius(8)

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
            }

            Divider()

            HStack {
                Button("‹ Back", action: onBack)
                    .buttonStyle(.bordered)
                    .disabled(isSubmitting)
                Spacer()
                Button(isSubmitting ? "Creating…" : "Create Composite", action: onCreate)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(isSubmitting)
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

    @ViewBuilder
    private func summaryRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
