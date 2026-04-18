import SwiftUI

/// CompositeWizardBuildStepView — Step 2 of the composite-task mini-wizard.
/// iOS twin of web's `BuildStep`. Hosts the subtask-card list and the
/// two "+ Add" buttons; Next is blocked until ≥2 cards report ready
/// and no duplicate existing-task selections exist.
struct CompositeWizardBuildStepView: View {
    @Binding var subtasks: [SubtaskItem]
    let libraryTasks: [OYBC.Task]
    let libraryCompositeTasks: [CompositeTask]
    let taskBoardCounts: [String: Int]
    let taskStepCounts: [String: Int]
    let compositeSubtaskCounts: [String: Int]
    let compositeLeafPreviews: [String: CompositeLeafPreview]
    let onRemove: (SubtaskItem) -> Void
    let onAddExisting: () -> Void
    let onAddInline: () -> Void
    let onBack: () -> Void
    let onNext: () -> Void

    // MARK: - Derived state

    /// Is this subtask item fully populated enough to ship in the
    /// composite? Mirrors `evaluateSubtaskReadiness` on the web and
    /// the card's own readiness computation.
    private func isReady(_ item: SubtaskItem) -> Bool {
        switch item.mode {
        case .existing:
            if item.selectionType == .task { return !item.selectedTaskId.isEmpty }
            return !item.selectedCompositeId.isEmpty
        case .inline_:
            let t = item.inlineTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            switch item.inlineType {
            case .normal:
                return !t.isEmpty
            case .counting:
                let a = item.inlineAction.trimmingCharacters(in: .whitespacesAndNewlines)
                let u = item.inlineUnit.trimmingCharacters(in: .whitespacesAndNewlines)
                let max = Int(item.inlineMaxCountStr) ?? 0
                return !a.isEmpty && !u.isEmpty && max >= 1
            case .progress:
                if t.isEmpty { return false }
                if item.inlineSteps.isEmpty { return false }
                for step in item.inlineSteps {
                    switch step.type {
                    case .normal:
                        if step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
                    case .counting:
                        if step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
                        if step.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
                        if (Int(step.maxCount) ?? 0) < 1 { return false }
                    default:
                        return false
                    }
                }
                return true
            }
        }
    }

    private var readyCount: Int {
        subtasks.filter { isReady($0) }.count
    }

    private var hasDuplicate: Bool {
        var seenTasks = Set<String>()
        var seenComposites = Set<String>()
        for s in subtasks where s.mode == .existing {
            if s.selectionType == .task, !s.selectedTaskId.isEmpty {
                if !seenTasks.insert(s.selectedTaskId).inserted { return true }
            }
            if s.selectionType == .composite, !s.selectedCompositeId.isEmpty {
                if !seenComposites.insert(s.selectedCompositeId).inserted { return true }
            }
        }
        return false
    }

    private var canAdvance: Bool {
        subtasks.count >= 2 && readyCount == subtasks.count && !hasDuplicate
    }

    private var statusText: String {
        if subtasks.count < 2 {
            return "Add at least 2 subtasks (\(subtasks.count) so far)."
        }
        if hasDuplicate {
            return "Remove the duplicate selection to continue."
        }
        let incomplete = subtasks.count - readyCount
        if incomplete > 0 {
            return "\(incomplete) card\(incomplete == 1 ? "" : "s") still need attention."
        }
        return "\(readyCount) subtask\(readyCount == 1 ? "" : "s") ready."
    }

    // MARK: - Per-card exclusion sets

    private func otherTaskIds(excluding item: SubtaskItem) -> Set<String> {
        Set(subtasks.compactMap { other in
            guard other.id != item.id,
                  other.mode == .existing, other.selectionType == .task,
                  !other.selectedTaskId.isEmpty else { return nil }
            return other.selectedTaskId
        })
    }

    private func otherCompositeIds(excluding item: SubtaskItem) -> Set<String> {
        Set(subtasks.compactMap { other in
            guard other.id != item.id,
                  other.mode == .existing, other.selectionType == .composite,
                  !other.selectedCompositeId.isEmpty else { return nil }
            return other.selectedCompositeId
        })
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .fontWeight(canAdvance ? .semibold : .regular)
                    .foregroundColor(canAdvance ? .green : .secondary)
            }

            if subtasks.isEmpty {
                emptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(subtasks) { item in
                        CompositeSubtaskCardView(
                            item: item,
                            libraryTasks: libraryTasks,
                            libraryCompositeTasks: libraryCompositeTasks,
                            taskBoardCounts: taskBoardCounts,
                            taskStepCounts: taskStepCounts,
                            compositeSubtaskCounts: compositeSubtaskCounts,
                            compositeLeafPreviews: compositeLeafPreviews,
                            excludedTaskIds: otherTaskIds(excluding: item),
                            excludedCompositeIds: otherCompositeIds(excluding: item),
                            onRemove: { onRemove(item) }
                        )
                    }
                }
            }

            VStack(spacing: 8) {
                Button("+ Add existing task", action: onAddExisting)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("+ Create new task", action: onAddInline)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }

            Divider()

            HStack {
                Button("‹ Back", action: onBack)
                    .buttonStyle(.bordered)
                Spacer()
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

    private var emptyState: some View {
        Text("No subtasks yet. Add at least two from your library or create them inline below.")
            .font(.subheadline)
            .italic()
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(.systemGray4), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
    }
}
