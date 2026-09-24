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
    /// Injected database (ROADMAP B3 seam); defaults to the app singleton.
    let database: AppDatabase

    init(
        taskId: String,
        onClose: @escaping () -> Void,
        onOpenBoard: @escaping (String) -> Void,
        database: AppDatabase = .shared
    ) {
        _currentTaskId = State(initialValue: taskId)
        self.onClose = onClose
        self.onOpenBoard = onOpenBoard
        self.database = database
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
                        .font(.risoBody(14, .semibold))
                        .foregroundStyle(Color.risoRed)
                        .padding()
                } else if let task {
                    RisoTaskDetailContentView(
                        task: task,
                        placements: placements,
                        affectedBoards: affectedBoards,
                        parentCompounds: parentCompounds,
                        compoundChildren: compoundChildren,
                        templates: templates,
                        database: database,
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
                    Text("Loading…")
                        .font(.risoBody(14, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .padding()
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    RisoToolbarPill(title: "Done") { onClose() }
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
            let db = database
            let snapshot = try await _Concurrency.Task.detached(priority: .userInitiated) {
                let loaded = try db.fetchTask(id: id)
                var bts: [BoardTask] = []
                var boards: [Board] = []
                var parents: [Task] = []
                var children: [Task] = []
                var tpls: [RecurringBoardTemplate] = []
                if let loaded = loaded, !loaded.isDeleted {
                    bts = try db.fetchBoardTasksForTask(taskId: id)
                    let boardIds = Array(Set(bts.map { $0.boardId }))
                    boards = try db.fetchBoards(ids: boardIds)
                    parents = try db.fetchCompoundParents(forTaskId: id)
                    children = try db.fetchCompoundChildrenTasks(parentTaskId: id)
                    tpls = try db.fetchTemplatesReferencingTask(id)
                }
                // Load picker data for Achievement re-target — only when
                // the loaded task is actually an achievement. Skipping for
                // other task types avoids two extra GRDB reads per sheet
                // open. The `loaded != nil && type == .achievement` gate
                // also guarantees we never call `fetchBoards(userId: "")`.
                var pickerBoards: [Board] = []
                var pickerTemplates: [RecurringBoardTemplate] = []
                if let loaded = loaded, loaded.type == .achievement {
                    pickerBoards = try db.fetchBoards(userId: loaded.userId)
                    pickerTemplates = try db.fetchRecurringBoardTemplates(userId: loaded.userId)
                }
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

    /// Save the edit sheet's patch through `AppDatabase.applyTaskEditPatch`
    /// (validation + Achievement cycle check + save/cascade in one write).
    private func saveEdits(patch: EditTaskSheet.Patch) async {
        let db = database
        let id = currentTaskId
        do {
            let saved = try await _Concurrency.Task.detached(priority: .userInitiated) {
                try db.applyTaskEditPatch(taskId: id, patch: patch)
            }.value
            await MainActor.run {
                task = saved
                saveError = nil
            }
        } catch {
            let message = AppDatabase.taskEditErrorMessage(error)
            await MainActor.run { saveError = message }
        }
    }

    // MARK: - Delete

    private func prepareDelete() async {
        do {
            let id = currentTaskId
            let db = database
            let impact = try await _Concurrency.Task.detached(priority: .userInitiated) {
                try db.computeTaskDeletionImpact(taskId: id)
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
            let db = database
            try await _Concurrency.Task.detached(priority: .userInitiated) {
                try db.deleteTaskWithCascade(taskId: id)
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
