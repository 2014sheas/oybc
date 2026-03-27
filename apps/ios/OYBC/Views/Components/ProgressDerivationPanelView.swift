import SwiftUI

/// Panel for inspecting progress task steps and extracting them into the board pool.
///
/// Displays each TaskStep in order with its type badge, counting metadata, and
/// either an "Add to Pool" button (for steps already linked to a task) or an
/// "Extract & Add to Pool" button (for unlinked steps that need a new task created).
///
/// Mirrors the web `ProgressDerivationPanel` component.
///
/// - Parameters:
///   - task: The parent progress Task.
///   - taskSteps: Steps belonging to the parent task, ordered by stepIndex.
///   - allTasks: Full task library used to resolve `linkedTaskId` references.
///   - boardPool: Current board pool entries; used to show "In Pool" state for linked steps.
///   - isCreating: True while a database write is in progress; disables extract buttons.
///   - onExtractStep: Called with the step and parent task when the user taps "Extract & Add to Pool".
///   - onAddStepToPool: Called with the linked task when the user taps "Add to Pool".
struct ProgressDerivationPanelView: View {

    // MARK: - Parameters

    let task: Task
    let taskSteps: [TaskStep]
    let allTasks: [Task]
    let boardPool: [(taskId: String, title: String, type: String)]
    let isCreating: Bool
    let onExtractStep: (TaskStep, Task) -> Void
    let onAddStepToPool: (Task) -> Void

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

            if taskSteps.isEmpty {
                Text("No steps defined for this task.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(taskSteps.count) step\(taskSteps.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(taskSteps.sorted(by: { $0.stepIndex < $1.stepIndex }), id: \.id) { step in
                        stepRow(step)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    // MARK: - Step Row

    /// A single step row showing its index, title, type badge, and pool/extract action.
    ///
    /// - Parameter step: The TaskStep to display.
    @ViewBuilder
    private func stepRow(_ step: TaskStep) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text("\(step.stepIndex + 1).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 18, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(step.title)
                            .font(.subheadline)
                        Spacer()
                        TypeBadgeView(type: step.type.rawValue, size: .small)
                    }

                    // Counting step metadata
                    if step.type == .counting,
                       let action = step.action,
                       let maxCount = step.maxCount,
                       let unit = step.unit {
                        Text("\(action) \(maxCount) \(unit)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()

                // Pool/extract action based on link state
                if let linkedId = step.linkedTaskId {
                    if boardPool.contains(where: { $0.taskId == linkedId }) {
                        Text("In Pool \u{2713}")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    } else {
                        Button("Add to Pool") {
                            if let linkedTask = allTasks.first(where: { $0.id == linkedId }) {
                                onAddStepToPool(linkedTask)
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text("No Task")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            // Extract button — only for unlinked steps
            if step.linkedTaskId == nil {
                Button("Extract & Add to Pool") {
                    onExtractStep(step, task)
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(isCreating)
            }
        }
        .padding(8)
        .background(Color(.systemGray5))
        .cornerRadius(6)
    }
}
