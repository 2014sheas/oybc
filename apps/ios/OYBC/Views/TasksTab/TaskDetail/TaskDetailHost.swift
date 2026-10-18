import SwiftUI

/// Binds Task Detail's pure screen to `TaskDetailViewModel` and owns what both shells
/// share: the Edit sheet, the counter-settings sheet and the delete confirm. The two
/// shells (`TaskDetailView`, `TaskDetailSheetView`) stay thin around it.
struct TaskDetailHost: View {

    @ObservedObject var vm: TaskDetailViewModel
    let taskId: String
    let presentation: TaskDetailPresentation
    @Binding var tab: TaskDetailTab
    var onBack: () -> Void = {}
    var onDone: () -> Void = {}
    var onReturn: () -> Void = {}
    var onOpenTask: (String) -> Void = { _ in }
    var onOpenCounter: (String) -> Void = { _ in }
    var onOpenBoard: (String) -> Void = { _ in }
    var onChanged: () -> Void = {}
    var onDeleted: () -> Void = {}

    @State private var showEdit = false
    @State private var showCounterSettings = false
    @State private var showDeleteConfirm = false
    @State private var deleteImpact: AppDatabase.TaskDeletionImpact?

    var body: some View {
        Group {
            if let loadError = vm.loadError {
                Text(loadError).font(.risoBody(14, .semibold)).foregroundStyle(Color.risoRed).padding()
            } else if let model = vm.model {
                TaskDetailScreen(
                    model: model, strip: vm.strip, isBusy: vm.isBusy, busyLook: vm.showsBusyLook, presentation: presentation, tab: $tab,
                    actions: actions, saveError: vm.saveError
                )
            } else {
                Text("Loading…").font(.risoBody(14, .semibold)).foregroundStyle(Color.risoMuted).padding()
            }
        }
        .onAppear { _Concurrency.Task { await vm.hostAppeared(taskId: taskId) } }
        .onChange(of: taskId) { _, id in _Concurrency.Task { await vm.load(taskId: id) } }
        .sheet(isPresented: $showEdit) { editSheet }
        .sheet(isPresented: $showCounterSettings) { counterSettingsSheet }
        .alert("Delete task?", isPresented: $showDeleteConfirm, presenting: deleteImpact) { _ in
            Button("Cancel", role: .cancel) { deleteImpact = nil }
            Button("Delete", role: .destructive) {
                _Concurrency.Task { if await vm.performDelete() { onDeleted() } }
            }
        } message: { impact in
            Text(TaskDetailViewModel.deleteConfirmMessage(impact))
        }
    }

    private var actions: TaskDetailActions {
        TaskDetailActions(
            onBack: onBack, onDone: onDone, onReturn: onReturn,
            onEdit: { showEdit = true },
            onMarkDone: { vm.toggleNormal() },
            onLog: { id, amount, persist in vm.log(taskId: id, amount: amount, persistAsDefault: persist) },
            onRemove: { id, amount in vm.log(taskId: id, amount: amount, removing: true) },
            onToggleChild: { vm.toggleChild($0) },
            onUndo: { vm.undo() },
            onOpenTask: onOpenTask, onOpenCounter: onOpenCounter, onOpenBoard: onOpenBoard,
            onOpenCounterSettings: { showCounterSettings = true },
            onDelete: { _Concurrency.Task { if let impact = await vm.computeDeleteImpact() { deleteImpact = impact; showDeleteConfirm = true } } }
        )
    }

    @ViewBuilder
    private var editSheet: some View {
        if let task = vm.task {
            EditTaskSheet(
                task: task, availableBoards: vm.pickerBoards, availableTemplates: vm.pickerTemplates, database: vm.database,
                // Same ordered fetch the detail already made — no re-fetch.
                seededCompoundChildren: vm.compoundChildren,
                onSubmit: { patch in
                    showEdit = false
                    _Concurrency.Task { if await vm.saveEdits(patch: patch) { onChanged() } }
                },
                onCancel: { showEdit = false }
            )
        }
    }

    /// The COUNTER sheet in edit mode on the counter root (never the task editor).
    @ViewBuilder
    private var counterSettingsSheet: some View {
        if let root = vm.counterRoot, let userId = vm.task?.userId {
            CounterDetailView.editSheet(
                root: root, userId: userId, tasks: vm.userTasks, database: vm.database,
                onNavigateToCounter: { id in showCounterSettings = false; onOpenCounter(id) },
                onSaved: {
                    showCounterSettings = false
                    _Concurrency.Task { await vm.refresh(); onChanged() }
                }
            )
        }
    }
}
