import SwiftUI

/// Form state for a single step in a progress task creation form.
///
/// Uses loose String types for numeric fields (`maxCount`) so that the
/// UI can display partial input without forcing type coercion mid-edit.
/// Mirrors the web `StepFormState` interface in `ProgressStepRow.tsx`.
struct ProgressStepFormState: Identifiable {
    let id = UUID()
    var title: String = ""
    var type: TaskType = .normal
    var action: String = ""
    var unit: String = ""
    var maxCount: String = ""
}

/// Inline validation error state for a single progress step.
///
/// All fields are optional — nil means no error for that field.
/// Mirrors the web `StepFormErrors` interface in `ProgressStepRow.tsx`.
struct ProgressStepFormErrors {
    var title: String? = nil
    var action: String? = nil
    var maxCount: String? = nil
    var unit: String? = nil

    /// Returns true if any field has an error message.
    var hasErrors: Bool {
        title != nil || action != nil || maxCount != nil || unit != nil
    }
}

/// Reusable row for a single progress task step.
///
/// Renders the step header (number + optional Remove button), a title field,
/// a Normal/Counting type picker, and — when counting is selected — the
/// `CountingStepFieldsView` sub-fields. Mirrors the web `ProgressStepRow`
/// component in `ProgressStepRow.tsx`.
///
/// - Parameters:
///   - index: Zero-based step index; displayed as "Step index+1".
///   - step: Binding to the step form state for this row.
///   - stepCount: Total number of steps; controls whether Remove is shown.
///   - errors: Optional inline field errors for this step.
///   - onRemove: Called when the user taps Remove.
struct ProgressStepRowView: View {
    let index: Int
    @Binding var step: ProgressStepFormState
    let stepCount: Int
    var errors: ProgressStepFormErrors? = nil
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Step \(index + 1)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if stepCount > 1 {
                    Button("Remove") { onRemove() }
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }

            TextField(
                step.type == .counting ? "Step title (auto-generated if blank)" : "Step title (required)",
                text: $step.title
            )
            .textFieldStyle(.roundedBorder)
            if let titleError = errors?.title {
                Text(titleError)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Picker("Type", selection: $step.type) {
                Text("Normal").tag(TaskType.normal)
                Text("Counting").tag(TaskType.counting)
            }
            .pickerStyle(.segmented)

            if step.type == .counting {
                CountingStepFieldsView(
                    action: $step.action,
                    maxCount: $step.maxCount,
                    unit: $step.unit,
                    actionError: errors?.action,
                    maxCountError: errors?.maxCount,
                    unitError: errors?.unit
                )
            }
        }
        .padding(8)
        .background(Color(.systemGray5))
        .cornerRadius(6)
    }
}
