import SwiftUI

/// CompositeSubtaskCardView — Persistent edit surface for one subtask of
/// a composite. iOS twin of web's `SubtaskCard`.
///
/// Replaces the legacy "fill fields → tap Done → collapse to chip"
/// dance with a card that is always in its editable form. A live
/// readiness check drives both a green-border success state and a plain-
/// English "what's missing" message, so users don't need to submit to
/// discover problems.
///
/// When a user taps a different inline type while the current fields
/// are dirty, the card swaps into a small inline confirmation panel
/// instead of silently wiping the fields.
struct CompositeSubtaskCardView: View {

    @ObservedObject var item: SubtaskItem

    /// Library contents plus the ids picked by OTHER cards. The card filters
    /// its own dropdown so duplicate selections are impossible at source.
    let libraryTasks: [OYBC.Task]
    let libraryCompositeTasks: [CompositeTask]
    /// taskId → number of boards the task is currently on.
    let taskBoardCounts: [String: Int]
    /// taskId → number of non-deleted steps (progress tasks only).
    let taskStepCounts: [String: Int]
    /// compositeTaskId → leaf (subtask) count.
    let compositeSubtaskCounts: [String: Int]
    /// compositeTaskId → first few leaf titles for the picker subtitle.
    let compositeLeafPreviews: [String: CompositeLeafPreview]
    let excludedTaskIds: Set<String>
    let excludedCompositeIds: Set<String>

    /// Called when the user taps remove.
    let onRemove: () -> Void

    // MARK: - Readiness

    /// Plain-English readiness result. `message` is nil when the card is
    /// ready so callers can render either "✓ Ready" or the message
    /// uniformly.
    private struct Readiness {
        let ready: Bool
        let message: String?
    }

    private var readiness: Readiness {
        switch item.mode {
        case .existing:
            if item.selectionType == .task {
                if item.selectedTaskId.isEmpty {
                    return Readiness(ready: false, message: "Pick a task or composite from your library.")
                }
                return Readiness(ready: true, message: nil)
            } else {
                if item.selectedCompositeId.isEmpty {
                    return Readiness(ready: false, message: "Pick a task or composite from your library.")
                }
                return Readiness(ready: true, message: nil)
            }
        case .inline_:
            switch item.inlineType {
            case .normal:
                if item.inlineTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return Readiness(ready: false, message: "Add a title for this task.")
                }
                return Readiness(ready: true, message: nil)
            case .counting:
                let a = item.inlineAction.trimmingCharacters(in: .whitespacesAndNewlines)
                let u = item.inlineUnit.trimmingCharacters(in: .whitespacesAndNewlines)
                let max = Int(item.inlineMaxCountStr) ?? 0
                if a.isEmpty { return Readiness(ready: false, message: "Add an action (e.g. \"Run\").") }
                if u.isEmpty { return Readiness(ready: false, message: "Add a unit (e.g. \"miles\").") }
                if max < 1 { return Readiness(ready: false, message: "Add a max count of at least 1.") }
                return Readiness(ready: true, message: nil)
            case .progress:
                let t = item.inlineTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { return Readiness(ready: false, message: "Add a title for this progress task.") }
                if item.inlineSteps.isEmpty {
                    return Readiness(ready: false, message: "Add at least one step.")
                }
                for step in item.inlineSteps {
                    switch step.type {
                    case .normal:
                        if step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            return Readiness(ready: false, message: "Each normal step needs a title.")
                        }
                    case .counting:
                        if step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            return Readiness(ready: false, message: "Each counting step needs an action.")
                        }
                        if step.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            return Readiness(ready: false, message: "Each counting step needs a unit.")
                        }
                        if (Int(step.maxCount) ?? 0) < 1 {
                            return Readiness(ready: false, message: "Each counting step needs a max count of at least 1.")
                        }
                    default:
                        break
                    }
                }
                return Readiness(ready: true, message: nil)
            }
        }
    }

    private var hasInlineDirtyFields: Bool {
        let t = item.inlineTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        switch item.inlineType {
        case .normal:
            return !t.isEmpty
        case .counting:
            return !t.isEmpty
                || !item.inlineAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !item.inlineUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !item.inlineMaxCountStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .progress:
            if !t.isEmpty { return true }
            for step in item.inlineSteps {
                if !step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
                if !step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
                if !step.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
                if !step.maxCount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
            }
            return false
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if item.mode == .existing {
                existingContent
            } else if let pending = item.pendingTypeSwitch {
                switchConfirmPanel(target: pending)
            } else {
                inlineContent
            }

            readinessFooter
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(readiness.ready
                      ? Color.green.opacity(0.06)
                      : Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(readiness.ready
                        ? Color.green.opacity(0.55)
                        : Color(.systemGray4), lineWidth: 1.5)
        )
    }

    private var header: some View {
        HStack {
            Text(item.mode == .existing ? "EXISTING TASK" : "NEW TASK (INLINE)")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            Spacer()
            Button("Remove", action: onRemove)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Existing content

    @ViewBuilder
    private var existingContent: some View {
        // Rich inline picker: expands to a searchable / filterable list
        // with typed rows, collapses to a summary after selection.
        // Mirrors web's `ExistingTaskPicker`.
        let currentSelectedId: String =
            item.selectionType == .task ? item.selectedTaskId : item.selectedCompositeId
        ExistingTaskPickerView(
            selectedId: currentSelectedId,
            libraryTasks: libraryTasks,
            libraryCompositeTasks: libraryCompositeTasks,
            excludedTaskIds: excludedTaskIds,
            excludedCompositeIds: excludedCompositeIds,
            taskBoardCounts: taskBoardCounts,
            taskStepCounts: taskStepCounts,
            compositeSubtaskCounts: compositeSubtaskCounts,
            compositeLeafPreviews: compositeLeafPreviews,
            onSelect: { id, kind in
                if kind == .composite {
                    item.selectionType = .composite
                    item.selectedCompositeId = id
                    item.selectedTaskId = ""
                } else {
                    item.selectionType = .task
                    item.selectedTaskId = id
                    item.selectedCompositeId = ""
                }
            }
        )
    }

    // MARK: - Inline content

    @ViewBuilder
    private var inlineContent: some View {
        Picker("Type", selection: typeBinding) {
            ForEach(InlineSubtaskType.allCases) { t in
                Text(t.rawValue).tag(t)
            }
        }
        .pickerStyle(.segmented)

        TextField(
            item.inlineType == .counting
                ? "Title (auto-generated from action + count + unit if blank)"
                : "Title",
            text: $item.inlineTitle
        )
        .textFieldStyle(.roundedBorder)

        switch item.inlineType {
        case .normal:
            EmptyView()
        case .counting:
            CountingStepFieldsView(
                action: $item.inlineAction,
                maxCount: $item.inlineMaxCountStr,
                unit: $item.inlineUnit
            )
        case .progress:
            progressStepsContent
        }
    }

    /// Custom binding on the inline type picker: when fields are dirty and
    /// the user picks a different type, stash the target as `pendingTypeSwitch`
    /// so the confirm panel renders instead of silently wiping.
    private var typeBinding: Binding<InlineSubtaskType> {
        Binding(
            get: { item.inlineType },
            set: { next in
                if next == item.inlineType { return }
                if hasInlineDirtyFields {
                    item.pendingTypeSwitch = next
                } else {
                    applyTypeSwitch(to: next)
                }
            }
        )
    }

    @ViewBuilder
    private func switchConfirmPanel(target: InlineSubtaskType) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Switching to **\(target.rawValue)** will clear the fields you've filled for **\(item.inlineType.rawValue)**.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Keep \(item.inlineType.rawValue)") {
                    item.pendingTypeSwitch = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Switch to \(target.rawValue)") {
                    applyTypeSwitch(to: target)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }

    /// Applies the requested type switch: wipes the old-type fields and
    /// clears any pending-switch flag.
    private func applyTypeSwitch(to target: InlineSubtaskType) {
        item.inlineType = target
        item.inlineTitle = ""
        item.inlineAction = ""
        item.inlineUnit = ""
        item.inlineMaxCountStr = ""
        item.inlineSteps = target == .progress ? [ProgressStepFormState()] : []
        item.pendingTypeSwitch = nil
    }

    @ViewBuilder
    private var progressStepsContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Steps")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            ForEach(Array(item.inlineSteps.indices), id: \.self) { index in
                ProgressStepRowView(
                    index: index,
                    step: Binding(
                        get: { item.inlineSteps[index] },
                        set: { item.inlineSteps[index] = $0 }
                    ),
                    stepCount: item.inlineSteps.count,
                    onRemove: { item.inlineSteps.remove(at: index) }
                )
            }
            Button("+ Add Step") {
                item.inlineSteps.append(ProgressStepFormState())
            }
            .font(.caption)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
        )
    }

    // MARK: - Readiness footer

    @ViewBuilder
    private var readinessFooter: some View {
        HStack(spacing: 6) {
            Text(readiness.ready ? "✓" : "•")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(readiness.ready ? .green : .secondary)
            Text(readiness.ready ? "Ready" : (readiness.message ?? ""))
                .font(.caption)
                .foregroundColor(readiness.ready ? .green : .secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(readiness.ready
                      ? Color.green.opacity(0.1)
                      : Color(.systemGray6))
        )
    }
}
