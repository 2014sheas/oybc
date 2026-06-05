import SwiftUI
import GRDB

/// Tasks tab — dedicated surface for browsing, searching, filtering,
/// and editing the user's task library. iOS twin of web's `TasksPage`.
///
/// Composes:
/// - Toolbar trailing `+` button that presents `NewTaskSheetView` as
///   a modal. Keeps the library (filter row + list) as the primary
///   page content so it doesn't get pushed below the fold.
/// - `TasksFilterControlsView` (search + type chips + status / usage
///   dropdowns + sort dropdown), pinned above the list so the user
///   keeps filter access while scrolling.
/// - A `List` of `TaskRowView` rows with **leading-swipe Edit** (blue,
///   full-swipe enabled) and **trailing-swipe Delete** (red, no full
///   swipe — the destructive action requires a deliberate tap, not a
///   gesture commit). Mirrors Mail.app convention. Tapping a row
///   pushes `TaskDetailView` onto the navigation stack.
///
/// Library data comes from `TaskLibraryViewModel`; filter/sort state
/// + board-status lookups for the usage filter come from
/// `TasksTabViewModel`.
struct TasksTabView: View {
    let userId: String
    /// Bound from MainTabView so the row's `NavigationLink` reads the
    /// same `tasksPath` the parent owns. Lets us reset on tab switch
    /// (parity with how `boardsPath` resets after `onBoardCompleted`).
    @Binding var path: NavigationPath
    /// Cross-tab navigation: passed down to each TaskDetailView so the
    /// Usage section's board taps can jump the user to the Boards tab.
    let onOpenBoard: (String) -> Void

    @State private var library = TaskLibraryViewModel()
    @State private var vm = TasksTabViewModel()
    @State private var showNewTaskSheet = false

    /// Task + its precomputed deletion impact, bundled so the confirm
    /// sheet is driven by a single Identifiable. Presenting off two
    /// separate `@State` (the task plus a companion impact) let the sheet
    /// render before the impact landed — a blank modal that then crashed.
    private struct PendingTaskDeletion: Identifiable {
        let task: Task
        let impact: AppDatabase.TaskDeletionImpact
        var id: String { task.id }
    }

    // ── Quick-action state ────────────────────────────────────────────
    /// Task currently being edited via swipe-Edit. `.sheet(item:)` opens
    /// `EditTaskSheet` when this is non-nil.
    @State private var editingTask: Task?
    /// Loaded lazily when `editingTask` is set for an Achievement task.
    @State private var editPickerBoards: [Board] = []
    @State private var editPickerTemplates: [RecurringBoardTemplate] = []
    /// Set once the impact computation finishes; presenting the confirm
    /// sheet off this single item guarantees the impact is available when
    /// the sheet renders.
    @State private var pendingDelete: PendingTaskDeletion?
    /// Monotonic token for in-flight impact computations. Each
    /// `prepareDelete(for:)` bumps it; the completion only assigns
    /// `pendingDelete` if its token is still current, so a slow earlier
    /// request can't overwrite a newer one (rapid swipe-delete on
    /// different rows) and re-introduce the content-swap-under-sheet bug.
    @State private var prepareDeleteToken = 0
    /// Set by a successful delete; consumed by the confirm sheet's
    /// `onDismiss`. Reloading the library mutates the `List` data source,
    /// and doing that *during* the sheet-dismiss transition crashed
    /// UICollectionView with a stale batch-delete. We instead wait for
    /// `onDismiss` (sheet fully gone) before reloading. Only a successful
    /// delete flips this, so cancel/dismiss don't trigger a reload.
    @State private var reloadAfterDeleteDismiss = false
    @State private var quickActionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TasksFilterControlsView(
                search: $vm.search,
                typeFilter: $vm.typeFilter,
                statusFilter: $vm.statusFilter,
                usageFilter: $vm.usageFilter,
                sortBy: $vm.sortBy,
                showExpired: $vm.showExpired
            )
            .padding(16)

            if let err = quickActionError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            let filtered = vm.filteredTasks(library: library)
            if filtered.isEmpty {
                emptyState(hasAnyTasks: !library.libraryTasks.isEmpty)
                    .padding(16)
                Spacer()
            } else {
                let placementCounts = vm.placementCounts(boardTasks: library.allLibraryBoardTasks)
                let activeCounts = vm.activePlacementCounts(boardTasks: library.allLibraryBoardTasks)
                List {
                    ForEach(filtered, id: \.id) { task in
                        // Plain Button (not NavigationLink) so we can
                        // route through the same path-append the LazyVStack
                        // version used — keeps the existing
                        // `navigationDestination(for: String.self)` wiring
                        // below untouched.
                        Button {
                            path.append(task.id)
                        } label: {
                            TaskRowView(
                                task: task,
                                placementCount: placementCounts[task.id] ?? 0,
                                activePlacementCount: activeCounts[task.id] ?? 0,
                                childCount: library.compoundChildrenByCompound[task.id]?.count ?? 0
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                editingTask = task
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // `allowsFullSwipe: false` — destructive
                            // commit requires a deliberate tap on the
                            // revealed button, not a gesture flick.
                            Button(role: .destructive) {
                                prepareDelete(for: task)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Tasks")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("+ Create task") {
                    showNewTaskSheet = true
                }
                .accessibilityLabel("Create task")
            }
        }
        .sheet(isPresented: $showNewTaskSheet) {
            NewTaskSheetView(
                userId: userId,
                onTaskCreated: { _, _, _ in
                    library.loadLibrary(userId: userId)
                    vm.reloadAsync()
                },
                onCompositeCreated: { _ in
                    library.loadLibrary(userId: userId)
                    vm.reloadAsync()
                },
                onLibraryReloadRequested: {
                    library.loadLibrary(userId: userId)
                    vm.reloadAsync()
                },
                submitLabel: "Add to library"
            )
        }
        .sheet(item: $editingTask) { task in
            EditTaskSheet(
                task: task,
                availableBoards: editPickerBoards,
                availableTemplates: editPickerTemplates,
                onSubmit: { patch in
                    _Concurrency.Task { await saveEdits(task: task, patch: patch) }
                },
                onCancel: { editingTask = nil }
            )
        }
        .onChange(of: editingTask?.id) { _, newId in
            guard newId != nil else {
                editPickerBoards = []
                editPickerTemplates = []
                return
            }
            guard editingTask?.type == .achievement else { return }
            let uid = userId
            _Concurrency.Task {
                do {
                    let boards = try await _Concurrency.Task.detached(priority: .userInitiated) {
                        try AppDatabase.shared.fetchBoards(userId: uid)
                    }.value
                    let templates = try await _Concurrency.Task.detached(priority: .userInitiated) {
                        try AppDatabase.shared.fetchRecurringBoardTemplates(userId: uid)
                    }.value
                    await MainActor.run {
                        editPickerBoards = boards
                        editPickerTemplates = templates
                    }
                } catch {
                    // Non-fatal: picker loads empty; user can save without re-targeting.
                }
            }
        }
        .sheet(item: $pendingDelete, onDismiss: {
            // Reload only after the sheet has fully dismissed. Mutating the
            // List's data source mid-transition crashed UICollectionView
            // with a stale batch-delete; deferring to onDismiss removes the
            // competing animation. Guarded so only a successful delete
            // (which actually changed the data) triggers the reload.
            guard reloadAfterDeleteDismiss else { return }
            reloadAfterDeleteDismiss = false
            reloadLibraryAndStatuses()
        }) { pending in
            TaskDeleteConfirmView(
                task: pending.task,
                impact: pending.impact,
                onConfirm: {
                    _Concurrency.Task { await performDelete(taskId: pending.task.id) }
                },
                onCancel: {
                    pendingDelete = nil
                }
            )
        }
        .navigationDestination(for: String.self) { taskId in
            TaskDetailView(
                taskId: taskId,
                userId: userId,
                onChanged: {
                    library.loadLibrary(userId: userId)
                    vm.reloadAsync()
                },
                onDeleted: {
                    library.loadLibrary(userId: userId)
                    vm.reloadAsync()
                    if !path.isEmpty { path.removeLast() }
                },
                onOpenBoard: onOpenBoard
            )
        }
        .onAppear {
            library.loadLibrary(userId: userId)
            vm.reloadAsync()
        }
    }

    // MARK: - Quick-action handlers

    /// Async-compute the deletion impact (including the affected-boards
    /// list) before opening the confirm sheet, so the sheet can render
    /// the per-board name + status pill synchronously without
    /// flickering loading state.
    private func prepareDelete(for task: Task) {
        quickActionError = nil
        let id = task.id
        prepareDeleteToken += 1
        let token = prepareDeleteToken
        _Concurrency.Task {
            do {
                let impact = try await _Concurrency.Task.detached(priority: .userInitiated) {
                    try AppDatabase.shared.computeTaskDeletionImpact(taskId: id)
                }.value
                await MainActor.run {
                    // A newer prepareDelete superseded this one — drop the
                    // stale result so it can't present the wrong task.
                    guard token == prepareDeleteToken else { return }
                    pendingDelete = PendingTaskDeletion(task: task, impact: impact)
                }
            } catch {
                await MainActor.run {
                    guard token == prepareDeleteToken else { return }
                    quickActionError = "Failed to compute delete impact: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Run the cascade delete off-main. On success we only dismiss the
    /// sheet here — the library reload (which mutates the List) is deferred
    /// to the sheet's `onDismiss` so it can't run during the dismiss
    /// transition and crash UICollectionView.
    private func performDelete(taskId: String) async {
        do {
            try await _Concurrency.Task.detached(priority: .userInitiated) {
                try AppDatabase.shared.deleteTaskWithCascade(taskId: taskId)
            }.value
            await MainActor.run {
                reloadAfterDeleteDismiss = true
                pendingDelete = nil
            }
        } catch {
            await MainActor.run {
                // Dismiss the confirm sheet: it disables its controls and
                // shows "Deleting…" after the tap, so leaving it up on
                // failure strands the user with frozen buttons while the
                // error renders behind it. Dropping the sheet reveals the
                // error text in the parent view.
                pendingDelete = nil
                quickActionError = "Failed to delete task: \(error.localizedDescription)"
            }
        }
    }

    /// Sequenced reload after a delete, run from the confirm sheet's
    /// `onDismiss`. Awaiting library then statuses (rather than firing both
    /// fire-and-forget) keeps the two `@Observable` updates from coalescing
    /// into a single inconsistent batch update against the List.
    private func reloadLibraryAndStatuses() {
        _Concurrency.Task {
            await library.reload(userId: userId)
            await vm.reload()
        }
    }

    /// Save the row-level edit patch off-main. Mirrors the patch logic
    /// in `TaskDetailView.saveEdits` — full M1 field set including timeboxed
    /// and Achievement re-target with cycle detection.
    private func saveEdits(task: Task, patch: EditTaskSheet.Patch) async {
        var t = task
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
                    await MainActor.run { quickActionError = "Please select a specific board to watch." }
                    return
                }
                if let cycleError = await checkCycleForTask(
                    taskId: t.id,
                    referencedBoardId: patch.selectedBoardId,
                    referencedTemplateId: nil
                ) {
                    await MainActor.run { quickActionError = cycleError }
                    return
                }
                t.referencedBoardId = patch.selectedBoardId
                t.referencedTemplateId = nil
                t.requiredCount = nil
            } else {
                guard !patch.selectedTemplateId.isEmpty else {
                    await MainActor.run { quickActionError = "Please select a recurring template to watch." }
                    return
                }
                guard let req = Int(patch.requiredCountStr), req > 0 else {
                    await MainActor.run { quickActionError = "Required count must be a whole number greater than 0." }
                    return
                }
                if let cycleError = await checkCycleForTask(
                    taskId: t.id,
                    referencedBoardId: nil,
                    referencedTemplateId: patch.selectedTemplateId
                ) {
                    await MainActor.run { quickActionError = cycleError }
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
                editingTask = nil
                library.loadLibrary(userId: userId)
                vm.reloadAsync()
            }
        } catch {
            await MainActor.run {
                quickActionError = "Failed to save: \(error.localizedDescription)"
            }
        }
    }

    /// Cycle detection helper for the Tasks-tab inline edit path.
    private func checkCycleForTask(
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
                return "This reference would create a cycle: \(path.joined(separator: " → "))"
            }
        } catch {
            return "Cycle check failed: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func emptyState(hasAnyTasks: Bool) -> some View {
        VStack(alignment: .center, spacing: 8) {
            if hasAnyTasks {
                Text("No tasks match your filters.")
                    .font(.system(size: 16, weight: .semibold))
                Text("Try clearing the search, switching the type chip back to “All”, or resetting Status / Usage to “Any”.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("No tasks yet.")
                    .font(.system(size: 16, weight: .semibold))
                Text("Tap the + button above to add one, or build a board on the Create tab — tasks you make there appear here too.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(.separator), style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
    }
}
