import SwiftUI

/// Panel for deriving counting subtasks from a parent counting task.
///
/// Displays parent task metadata, a partial count allocation field with live validation,
/// a derived subtask title preview, and a button to write the new task to the database
/// and add it to the board pool.
///
/// Mirrors the web `CountingDerivationPanel` component.
///
/// - Parameters:
///   - task: The parent counting Task.
///   - partialCountStr: Binding to the raw text entry for the partial count.
///   - isCreating: True while a database write is in progress; disables the action button.
///   - onCreateSubtask: Called with the parent task and the validated partial count when
///     the user taps "Add to Board Pool".
struct CountingDerivationPanelView: View {

    // MARK: - Parameters

    let task: Task
    @Binding var partialCountStr: String
    let isCreating: Bool
    let onCreateSubtask: (Task, Int) -> Void

    // MARK: - Computed

    /// Validated partial count. nil when the string is not a valid positive integer.
    private var partialCount: Int? {
        let trimmed = partialCountStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    /// Whether the partial count is within the allowed range for the task's maxCount.
    private var isPartialCountValid: Bool {
        guard let count = partialCount, let maxCount = task.maxCount else { return false }
        return count <= maxCount
    }

    /// Live-previewed derived subtask title.
    ///
    /// Replicates `generateCounterTaskTitle` from packages/shared: "\(action) \(count) \(unit)".
    private var derivedCountingTitle: String? {
        guard task.type == .counting,
              let action = task.action,
              let unit = task.unit,
              let count = partialCount else { return nil }
        return "\(action) \(count) \(unit)"
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(task.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                TypeBadgeView(type: task.type.rawValue, size: .small)
            }

            // Parent task metadata chips
            VStack(alignment: .leading, spacing: 4) {
                if let action = task.action, let unit = task.unit, let maxCount = task.maxCount {
                    HStack(spacing: 0) {
                        metaChip(label: "Action", value: action)
                        Text(" · ")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        metaChip(label: "Unit", value: unit)
                        Text(" · ")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        metaChip(label: "Parent total", value: "\(maxCount)")
                    }
                }
            }

            Divider()

            // Partial count allocation
            VStack(alignment: .leading, spacing: 6) {
                Text("Allocate partial count")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                HStack {
                    TextField("Partial count", text: $partialCountStr)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .frame(maxWidth: 140)

                    if let maxCount = task.maxCount {
                        Text("of \(maxCount)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                // Validation feedback
                if !partialCountStr.isEmpty {
                    if partialCount == nil {
                        Text("Enter a positive integer.")
                            .font(.caption)
                            .foregroundColor(.red)
                    } else if !isPartialCountValid, let maxCount = task.maxCount {
                        Text("Must be \(maxCount) or less.")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }

            // Live preview
            if isPartialCountValid, let previewTitle = derivedCountingTitle {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Derived Subtask Preview")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(previewTitle)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.12))
                        .cornerRadius(6)
                }
            }

            // Create subtask action
            Button(action: {
                if let count = partialCount {
                    onCreateSubtask(task, count)
                }
            }) {
                Text(isCreating ? "Adding..." : "Add to Board Pool")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isPartialCountValid || isCreating)
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    // MARK: - Helpers

    /// Inline key/value chip for the metadata row.
    ///
    /// - Parameters:
    ///   - label: Short label shown in secondary color.
    ///   - value: Value shown in primary color.
    @ViewBuilder
    private func metaChip(label: String, value: String) -> some View {
        HStack(spacing: 2) {
            Text("\(label): ")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}
