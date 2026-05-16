import SwiftUI
import GRDB

/// Task detail page — route-pushed shell that owns `taskId` resolution,
/// async data loading, and the delete-confirm alert. Renders
/// `TaskDetailContentView` for all visible content.
///
/// iOS twin of web's `TaskDetailPage.tsx`.
struct TaskDetailView: View {
    let taskId: String
    let userId: String
    let onChanged: () -> Void
    let onDeleted: () -> Void
    /// Cross-tab navigation: when the user taps a board name in Usage,
    /// switch to the Boards tab and push BoardPlayView for that id.
    /// Plumbed in from MainTabView, which owns boardsPath + selectedTab.
    let onOpenBoard: (String) -> Void

    @State private var task: Task?
    @State private var placements: [BoardTask] = []
    @State private var affectedBoards: [Board] = []
    @State private var parentCompounds: [Task] = []
    @State private var compoundChildren: [Task] = []
    @State private var templates: [RecurringBoardTemplate] = []
    @State private var loadError: String?
    @State private var saveError: String?

    @State private var showDeleteConfirm: Bool = false
    @State private var deleteImpact: AppDatabase.TaskDeletionImpact?

    /// Drives in-detail navigation: tapping a parent compound chip or
    /// child task row pushes another TaskDetailView onto the stack.
    @State private var openedChildTaskId: TaskIdItem?

    var body: some View {
        Group {
            if let loadError {
                Text(loadError)
                    .foregroundColor(.red)
                    .padding()
            } else if let task {
                TaskDetailContentView(
                    task: task,
                    placements: placements,
                    affectedBoards: affectedBoards,
                    parentCompounds: parentCompounds,
                    compoundChildren: compoundChildren,
                    templates: templates,
                    saveError: saveError,
                    onEditSubmit: { patch in
                        _Concurrency.Task { await saveEdits(patch: patch) }
                    },
                    onDeleteTap: {
                        _Concurrency.Task { await prepareDelete() }
                    },
                    onOpenTask: { id in
                        openedChildTaskId = TaskIdItem(id: id)
                    },
                    onOpenBoard: onOpenBoard
                )
            } else {
                Text("Loading…").foregroundColor(.secondary).padding()
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            _Concurrency.Task { await reload() }
        }
        .navigationDestination(item: $openedChildTaskId) { item in
            TaskDetailView(
                taskId: item.id,
                userId: userId,
                onChanged: onChanged,
                onDeleted: onChanged,
                onOpenBoard: onOpenBoard
            )
        }
        .alert("Delete task?", isPresented: $showDeleteConfirm, presenting: deleteImpact) { _ in
            Button("Cancel", role: .cancel) {
                deleteImpact = nil
            }
            Button("Delete", role: .destructive) {
                _Concurrency.Task { await performDelete() }
            }
        } message: { impact in
            Text(deleteConfirmMessage(impact: impact))
        }
    }

    // MARK: - Reload

    private func reload() async {
        do {
            let snapshot = try await _Concurrency.Task.detached(priority: .userInitiated) {
                let loaded = try AppDatabase.shared.fetchTask(id: taskId)
                var bts: [BoardTask] = []
                var boards: [Board] = []
                var parents: [Task] = []
                var children: [Task] = []
                var tpls: [RecurringBoardTemplate] = []
                if let loaded = loaded, !loaded.isDeleted {
                    bts = try AppDatabase.shared.fetchBoardTasksForTask(taskId: taskId)
                    let boardIds = Array(Set(bts.map { $0.boardId }))
                    boards = try AppDatabase.shared.fetchBoards(ids: boardIds)
                    parents = try AppDatabase.shared.fetchCompoundParents(forTaskId: taskId)
                    children = try AppDatabase.shared.fetchCompoundChildrenTasks(parentTaskId: taskId)
                    tpls = try AppDatabase.shared.fetchTemplatesReferencingTask(taskId)
                }
                return (loaded, bts, boards, parents, children, tpls)
            }.value
            await MainActor.run {
                self.task = snapshot.0
                self.placements = snapshot.1
                self.affectedBoards = snapshot.2
                self.parentCompounds = snapshot.3
                self.compoundChildren = snapshot.4
                self.templates = snapshot.5
                self.loadError = nil
            }
        } catch {
            let message = "Failed to load task: \(error.localizedDescription)"
            await MainActor.run { self.loadError = message }
        }
    }

    // MARK: - Edit

    private func saveEdits(patch: EditTaskSheet.Patch) async {
        guard var t = task else { return }
        t.title = patch.title.trimmingCharacters(in: .whitespacesAndNewlines)
        t.description = patch.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : patch.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.type == .counting {
            if !patch.action.isEmpty { t.action = patch.action }
            if !patch.unit.isEmpty { t.unit = patch.unit }
            if let max = Int(patch.maxCountStr), max > 0 { t.maxCount = max }
        }
        if t.type == .achievement {
            t.achievementTrigger = patch.trigger
            if t.referencedTemplateId != nil {
                if let req = Int(patch.requiredCountStr), req > 0 { t.requiredCount = req }
            }
        }
        t.updatedAt = AppDatabase.currentTimestamp()
        t.version += 1

        let patched = t
        do {
            try await _Concurrency.Task.detached(priority: .userInitiated) {
                try AppDatabase.shared.saveTaskAndEnqueueUpdate(patched)
            }.value
            await MainActor.run {
                task = patched
                saveError = nil
                onChanged()
            }
        } catch {
            let message = "Failed to save: \(error.localizedDescription)"
            await MainActor.run { saveError = message }
        }
    }

    // MARK: - Delete

    private func prepareDelete() async {
        do {
            let id = taskId
            let impact = try await _Concurrency.Task.detached(priority: .userInitiated) {
                try AppDatabase.shared.computeTaskDeletionImpact(taskId: id)
            }.value
            await MainActor.run {
                deleteImpact = impact
                showDeleteConfirm = true
            }
        } catch {
            let message = "Failed to compute delete impact: \(error.localizedDescription)"
            await MainActor.run { saveError = message }
        }
    }

    private func performDelete() async {
        do {
            let id = taskId
            try await _Concurrency.Task.detached(priority: .userInitiated) {
                try AppDatabase.shared.deleteTaskWithCascade(taskId: id)
            }.value
            await MainActor.run { onDeleted() }
        } catch {
            let message = "Failed to delete: \(error.localizedDescription)"
            await MainActor.run { saveError = message }
        }
    }

    private func deleteConfirmMessage(impact: AppDatabase.TaskDeletionImpact) -> String {
        var lines: [String] = ["This can't be undone."]
        if impact.boardTaskCount > 0 {
            lines.append(
                "Removes from \(impact.boardTaskCount) board square\(impact.boardTaskCount == 1 ? "" : "s") across \(impact.affectedBoardIds.count) board\(impact.affectedBoardIds.count == 1 ? "" : "s").",
            )
        }
        if impact.childLinkCount > 0 {
            lines.append(
                "Detaches from \(impact.childLinkCount) compound parent\(impact.childLinkCount == 1 ? "" : "s").",
            )
        }
        if impact.parentLinkCount > 0 {
            lines.append(
                "Releases \(impact.parentLinkCount) subtask\(impact.parentLinkCount == 1 ? "" : "s") (subtasks stay in your library).",
            )
        }
        return lines.joined(separator: "\n")
    }
}
