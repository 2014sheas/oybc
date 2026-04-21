import SwiftUI

/// CompositeWizardBuildStepView — Step 2 of the composite-task mini-wizard.
/// iOS twin of web's `BuildStep`. Hosts the subtask list plus the two
/// primary "add" buttons; `+ Add existing tasks` opens a sheet for
/// multi-check picking. Next is blocked until ≥2 subtasks are ready.
struct CompositeWizardBuildStepView: View {
    /// Wrapped subtask array. Observing the wrapper (not a plain binding)
    /// is what keeps `readyCount` / `canAdvance` / the Next-button state
    /// in sync when any child `SubtaskItem`'s `@Published` properties
    /// change — the wrapper re-broadcasts each child's `objectWillChange`
    /// upward.
    @ObservedObject var subtaskList: CompositeSubtaskList
    let libraryTasks: [OYBC.Task]
    let libraryCompositeTasks: [CompositeTask]
    let taskBoardCounts: [String: Int]
    let taskStepCounts: [String: Int]
    let compositeSubtaskCounts: [String: Int]
    let compositeLeafPreviews: [String: CompositeLeafPreview]
    let onRemove: (SubtaskItem) -> Void
    let onCommitLibraryDiff: (LibraryDiff) -> Void
    let onAddInline: () -> Void
    let onBack: () -> Void
    let onNext: () -> Void

    @State private var libraryOpen: Bool = false

    // MARK: - Derived state

    private func isReady(_ item: SubtaskItem) -> Bool {
        switch item.mode {
        case .existing:
            // Existing rows only exist when a concrete library id is
            // attached (the sheet's commit path never adds an empty one).
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
        subtaskList.items.filter { isReady($0) }.count
    }

    private var canAdvance: Bool {
        subtaskList.items.count >= 2 && readyCount == subtaskList.items.count
    }

    private var statusText: String {
        if subtaskList.items.count < 2 {
            return "Add at least 2 subtasks (\(subtaskList.items.count) so far)."
        }
        let incomplete = subtaskList.items.count - readyCount
        if incomplete > 0 {
            return "\(incomplete) card\(incomplete == 1 ? "" : "s") still need attention."
        }
        return "\(readyCount) subtask\(readyCount == 1 ? "" : "s") ready."
    }

    /// Ids currently included as existing-mode subtasks — drives the
    /// sheet's initial checkbox state.
    private var initialCheckedIds: Set<String> {
        var ids = Set<String>()
        for s in subtaskList.items where s.mode == .existing {
            if s.selectionType == .task, !s.selectedTaskId.isEmpty {
                ids.insert(s.selectedTaskId)
            } else if s.selectionType == .composite, !s.selectedCompositeId.isEmpty {
                ids.insert(s.selectedCompositeId)
            }
        }
        return ids
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

            if subtaskList.items.isEmpty {
                emptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(subtaskList.items) { item in
                        CompositeSubtaskCardView(
                            item: item,
                            libraryTasks: libraryTasks,
                            libraryCompositeTasks: libraryCompositeTasks,
                            taskBoardCounts: taskBoardCounts,
                            taskStepCounts: taskStepCounts,
                            compositeSubtaskCounts: compositeSubtaskCounts,
                            compositeLeafPreviews: compositeLeafPreviews,
                            onRemove: { onRemove(item) }
                        )
                    }
                }
            }

            VStack(spacing: 8) {
                Button("+ Add existing tasks") { libraryOpen = true }
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
        .sheet(isPresented: $libraryOpen) {
            LibraryPickerSheetView(
                libraryTasks: libraryTasks,
                libraryCompositeTasks: libraryCompositeTasks,
                initialCheckedIds: initialCheckedIds,
                taskBoardCounts: taskBoardCounts,
                taskStepCounts: taskStepCounts,
                compositeSubtaskCounts: compositeSubtaskCounts,
                compositeLeafPreviews: compositeLeafPreviews,
                onCommit: { diff in
                    onCommitLibraryDiff(diff)
                    libraryOpen = false
                },
                onCancel: { libraryOpen = false }
            )
        }
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
