import SwiftUI
import GRDB

/// Sheet wrapper for the task detail surface. Presents the same content as
/// `TaskDetailView` but wrapped in a `NavigationStack` with a "Done" toolbar
/// button. Callers mount it via `.sheet(item:)` driven by a `TaskIdItem?`.
///
/// Chip-to-detail navigation inside the sheet uses "replace" semantics
/// (per the plan's pinned decision): `onOpenTask` swaps `currentTaskId`
/// and triggers a fresh `reload()` rather than pushing onto a nav stack.
///
/// iOS twin of web's `TaskDetailSheet.tsx`.
struct TaskDetailSheetView: View {
    /// Allow the sheet to swap to a different task without dismissing,
    /// using the replace semantics pinned in the plan.
    @State private var currentTaskId: String
    let onClose: () -> Void
    /// Callback for when a board is tapped in the Usage section. The
    /// caller is expected to dismiss this sheet (via `onClose`) AND
    /// route to the new board (e.g. by appending to the Boards-tab
    /// nav path). Called BEFORE `onClose` so the caller can sequence
    /// both effects in one closure.
    let onOpenBoard: (String) -> Void

    init(
        taskId: String,
        onClose: @escaping () -> Void,
        onOpenBoard: @escaping (String) -> Void
    ) {
        _currentTaskId = State(initialValue: taskId)
        self.onClose = onClose
        self.onOpenBoard = onOpenBoard
    }

    // MARK: - Async state

    @State private var task: Task?
    @State private var placements: [BoardTask] = []
    @State private var affectedBoards: [Board] = []
    @State private var parentCompounds: [Task] = []
    @State private var compoundChildren: [Task] = []
    @State private var templates: [RecurringBoardTemplate] = []
    // Achievement re-target picker data
    @State private var allBoardsForPicker: [Board] = []
    @State private var allTemplatesForPicker: [RecurringBoardTemplate] = []
    @State private var loadError: String?
    @State private var saveError: String?

    @State private var showDeleteConfirm: Bool = false
    @State private var deleteImpact: AppDatabase.TaskDeletionImpact?

    // MARK: - Body

    var body: some View {
        NavigationStack {
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
                        allBoardsForPicker: allBoardsForPicker,
                        allTemplatesForPicker: allTemplatesForPicker,
                        onEditSubmit: { patch in
                            _Concurrency.Task { await saveEdits(patch: patch) }
                        },
                        onDeleteTap: {
                            _Concurrency.Task { await prepareDelete() }
                        },
                        onOpenTask: { taskId in
                            // Replace semantics: swap the task ID and reload.
                            currentTaskId = taskId
                            _Concurrency.Task { await reload() }
                        },
                        onOpenBoard: onOpenBoard
                    )
                } else {
                    Text("Loading…").foregroundColor(.secondary).padding()
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onClose() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            _Concurrency.Task { await reload() }
        }
        .onChange(of: currentTaskId) { _, _ in
            _Concurrency.Task { await reload() }
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
            let id = currentTaskId
            let snapshot = try await _Concurrency.Task.detached(priority: .userInitiated) {
                let loaded = try AppDatabase.shared.fetchTask(id: id)
                var bts: [BoardTask] = []
                var boards: [Board] = []
                var parents: [Task] = []
                var children: [Task] = []
                var tpls: [RecurringBoardTemplate] = []
                if let loaded = loaded, !loaded.isDeleted {
                    bts = try AppDatabase.shared.fetchBoardTasksForTask(taskId: id)
                    let boardIds = Array(Set(bts.map { $0.boardId }))
                    boards = try AppDatabase.shared.fetchBoards(ids: boardIds)
                    parents = try AppDatabase.shared.fetchCompoundParents(forTaskId: id)
                    children = try AppDatabase.shared.fetchCompoundChildrenTasks(parentTaskId: id)
                    tpls = try AppDatabase.shared.fetchTemplatesReferencingTask(id)
                }
                let pickerBoards = try AppDatabase.shared.fetchBoards(userId: loaded?.userId ?? "")
                let pickerTemplates = try AppDatabase.shared.fetchRecurringBoardTemplates(userId: loaded?.userId ?? "")
                return (loaded, bts, boards, parents, children, tpls, pickerBoards, pickerTemplates)
            }.value
            await MainActor.run {
                self.task = snapshot.0
                self.placements = snapshot.1
                self.affectedBoards = snapshot.2
                self.parentCompounds = snapshot.3
                self.compoundChildren = snapshot.4
                self.templates = snapshot.5
                self.allBoardsForPicker = snapshot.6
                self.allTemplatesForPicker = snapshot.7
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

            if patch.refMode == .board {
                guard !patch.selectedBoardId.isEmpty else {
                    await MainActor.run { saveError = "Please select a specific board to watch." }
                    return
                }
                let cycleError = await checkCycle(
                    taskId: t.id,
                    referencedBoardId: patch.selectedBoardId,
                    referencedTemplateId: nil
                )
                if let cycleError {
                    await MainActor.run { saveError = cycleError }
                    return
                }
                t.referencedBoardId = patch.selectedBoardId
                t.referencedTemplateId = nil
                t.requiredCount = nil
            } else {
                guard !patch.selectedTemplateId.isEmpty else {
                    await MainActor.run { saveError = "Please select a recurring template to watch." }
                    return
                }
                guard let req = Int(patch.requiredCountStr), req > 0 else {
                    await MainActor.run { saveError = "Required count must be a whole number greater than 0." }
                    return
                }
                let cycleError = await checkCycle(
                    taskId: t.id,
                    referencedBoardId: nil,
                    referencedTemplateId: patch.selectedTemplateId
                )
                if let cycleError {
                    await MainActor.run { saveError = cycleError }
                    return
                }
                t.referencedTemplateId = patch.selectedTemplateId
                t.referencedBoardId = nil
                t.requiredCount = req
            }
        }

        // Timeboxed fields
        if let tf = patch.timeframe {
            t.timeframe = tf
            t.startDate = patch.startDate
            t.endDate = patch.endDate
        } else if patch.clearTimeboxed {
            t.timeframe = nil
            t.startDate = nil
            t.endDate = nil
        }

        t.updatedAt = AppDatabase.currentTimestamp()
        t.version += 1

        let patched = t
        do {
            try await _Concurrency.Task.detached(priority: .userInitiated) {
                try AppDatabase.shared.saveTaskAndCascade(patched)
            }.value
            await MainActor.run {
                task = patched
                saveError = nil
            }
        } catch {
            let message = "Failed to save: \(error.localizedDescription)"
            await MainActor.run { saveError = message }
        }
    }

    /// Cycle check for Achievement re-target.
    private func checkCycle(
        taskId: String,
        referencedBoardId: String?,
        referencedTemplateId: String?
    ) async -> String? {
        do {
            let result = try await _Concurrency.Task.detached(priority: .userInitiated) {
                let placements = try AppDatabase.shared.fetchBoardTasksForTask(taskId: taskId)
                let parentBoardIds = Array(Set(placements.map { $0.boardId }))
                let allBoardTasks = try AppDatabase.shared.fetchAllBoardTasks()
                let allTasks = try AppDatabase.shared.read { db -> [Task] in
                    try Task.filter(Column("isDeleted") == false).fetchAll(db)
                }
                let allBoards = try AppDatabase.shared.read { db -> [Board] in
                    try Board.filter(Column("isDeleted") == false).fetchAll(db)
                }
                let candidate = CycleCheckCandidate(
                    parentBoardIds: parentBoardIds,
                    referencedBoardId: referencedBoardId,
                    referencedTemplateId: referencedTemplateId
                )
                let context = CycleCheckContext(
                    allBoardTasks: allBoardTasks,
                    allTasks: allTasks,
                    allBoards: allBoards
                )
                return CycleDetection.hasCycle(candidate: candidate, context: context)
            }.value

            switch result {
            case .ok:
                return nil
            case .cycle(let path):
                let pathStr = path.joined(separator: " → ")
                return "This reference would create a cycle: \(pathStr)"
            }
        } catch {
            return "Cycle check failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Delete

    private func prepareDelete() async {
        do {
            let id = currentTaskId
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
            let id = currentTaskId
            try await _Concurrency.Task.detached(priority: .userInitiated) {
                try AppDatabase.shared.deleteTaskWithCascade(taskId: id)
            }.value
            // After delete, close the sheet.
            await MainActor.run { onClose() }
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
