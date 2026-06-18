import SwiftUI
import GRDB

/// Tasks tab — Riso-styled library browser.
///
/// Reskinned in the "Riso" direction: cream paper background, Bricolage
/// Grotesque headings, Archivo body copy, ink keylines, hard-shadow buttons,
/// and type letter-square badges. All filter/sort/grouping/detail/delete/
/// edit/create logic is preserved from the pre-Riso implementation.
///
/// **Presentation decision**: row taps push `TaskDetailView` via the existing
/// `NavigationPath` (keeping the cross-tab "open board from detail" path
/// intact). A bottom-sheet approach would require a separate sheet layer on
/// top of the existing edit/delete/new-task sheets; the push path is simpler
/// and already wired correctly for board navigation. Noted as a divergence
/// from the prototype's sheet tap in the phase summary.
///
/// iOS twin of web's `TasksPage.tsx`.
struct TasksTabView: View {
    let userId: String
    @Binding var path: NavigationPath
    let onOpenBoard: (String) -> Void

    @State private var library = TaskLibraryViewModel()
    @State private var vm = TasksTabViewModel()
    @State private var showNewTaskSheet = false
    @State private var expandedCompoundIds: Set<String> = []

    private struct PendingTaskDeletion: Identifiable {
        let task: Task
        let impact: AppDatabase.TaskDeletionImpact
        var id: String { task.id }
    }

    @State private var editingTask: Task?
    @State private var editPickerBoards: [Board] = []
    @State private var editPickerTemplates: [RecurringBoardTemplate] = []
    @State private var pendingDelete: PendingTaskDeletion?
    @State private var prepareDeleteToken = 0
    @State private var reloadAfterDeleteDismiss = false
    @State private var quickActionError: String?

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            RisoPaperBackground()

            let filtered = vm.filteredTasks(library: library)
            let placementCounts = vm.placementCounts(boardTasks: library.allLibraryBoardTasks)
            let activeCounts = vm.activePlacementCounts(boardTasks: library.allLibraryBoardTasks)
            let independentlyPlaced = TasksTabViewModel.independentlyPlacedTaskIds(
                childTaskIds: library.childTaskIds,
                placementCounts: placementCounts
            )
            let autoExpand = TasksTabViewModel.autoExpandCompoundIds(
                search: vm.search,
                library: library,
                groupByCompound: vm.groupByCompound,
                independentlyPlaced: independentlyPlaced
            )
            let effectiveExpanded = expandedCompoundIds.union(autoExpand)

            List {
                // ── Scrolling header (not sticky) ────────────────────
                Group {
                    headerRow
                        .listRowInsets(EdgeInsets(top: 16, leading: Riso.gutter, bottom: 0, trailing: Riso.gutter))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                    // Controls (search + chips + sort + filters)
                    RisoTasksControlsView(
                        search: $vm.search,
                        typeFilter: $vm.typeFilter,
                        statusFilter: $vm.statusFilter,
                        usageFilter: $vm.usageFilter,
                        sortBy: $vm.sortBy,
                        showExpired: $vm.showExpired,
                        groupByCompound: $vm.groupByCompound,
                        resultCount: filtered.count
                    )
                    .listRowInsets(EdgeInsets(top: 12, leading: Riso.gutter, bottom: 8, trailing: Riso.gutter))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                    if let err = quickActionError {
                        Text(err)
                            .font(.risoBody(13, .regular))
                            .foregroundStyle(Color.risoRed)
                            .listRowInsets(EdgeInsets(top: 0, leading: Riso.gutter, bottom: 4, trailing: Riso.gutter))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }

                // ── Empty state ─────────────────────────────────────
                if filtered.isEmpty {
                    emptyState(hasAnyTasks: !library.libraryTasks.isEmpty)
                        .listRowInsets(EdgeInsets(top: 8, leading: Riso.gutter, bottom: 8, trailing: Riso.gutter))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    // ── Task rows ────────────────────────────────────
                    ForEach(filtered, id: \.id) { task in
                        let children = library.compoundChildrenByCompound[task.id] ?? []
                        let isExpandable = vm.groupByCompound
                            && task.type == .compound
                            && !children.isEmpty
                        let isExpanded = isExpandable && effectiveExpanded.contains(task.id)

                        if isExpandable {
                            Button {
                                path.append(task.id)
                            } label: {
                              RisoCompoundGroupRowView(
                                task: task,
                                placementCount: placementCounts[task.id] ?? 0,
                                activePlacementCount: activeCounts[task.id] ?? 0,
                                childCount: children.count,
                                isExpandable: true,
                                isExpanded: isExpanded,
                                onToggleExpand: {
                                    if expandedCompoundIds.contains(task.id) {
                                        expandedCompoundIds.remove(task.id)
                                    } else {
                                        expandedCompoundIds.insert(task.id)
                                    }
                                },
                                children: children.map { link in
                                    (link: link, task: library.task(byId: link.childTaskId))
                                },
                                childPlacementCounts: placementCounts,
                                childActivePlacementCounts: activeCounts,
                                onChildTap: { childId in path.append(childId) }
                            )
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 4, leading: Riso.gutter, bottom: 4, trailing: Riso.gutter))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    editingTask = task
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                // NOTE: deliberately NOT `role: .destructive`.
                                // A destructive swipe button makes SwiftUI's List
                                // auto-animate the row's removal on tap (it assumes
                                // the model row is going away), but we only open a
                                // confirm sheet here — the task isn't removed yet.
                                // The collection view then animates a delete the
                                // data source doesn't reflect → "invalid number of
                                // items in section" crash. A plain red-tinted button
                                // runs the action without the phantom removal.
                                Button {
                                    prepareDelete(for: task)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        } else {
                            Button {
                                path.append(task.id)
                            } label: {
                                RisoTaskRowView(
                                    task: task,
                                    placementCount: placementCounts[task.id] ?? 0,
                                    activePlacementCount: activeCounts[task.id] ?? 0,
                                    childCount: library.compoundChildrenByCompound[task.id]?.count ?? 0
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 4, leading: Riso.gutter, bottom: 4, trailing: Riso.gutter))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    editingTask = task
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                // NOTE: deliberately NOT `role: .destructive`.
                                // A destructive swipe button makes SwiftUI's List
                                // auto-animate the row's removal on tap (it assumes
                                // the model row is going away), but we only open a
                                // confirm sheet here — the task isn't removed yet.
                                // The collection view then animates a delete the
                                // data source doesn't reflect → "invalid number of
                                // items in section" crash. A plain red-tinted button
                                // runs the action without the phantom removal.
                                Button {
                                    prepareDelete(for: task)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                    }

                    // Bottom breathing room
                    Color.clear
                        .frame(height: 20)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .navigationBarHidden(true)
        // ── Sheets ────────────────────────────────────────────────────
        .sheet(isPresented: $showNewTaskSheet) {
            NewTaskSheetView(
                userId: userId,
                onTaskCreated: { _, _, _ in
                    library.loadLibrary(userId: userId)
                    vm.reloadAsync()
                },
                onLibraryReloadRequested: {
                    library.loadLibrary(userId: userId)
                    vm.reloadAsync()
                }
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
                    // Non-fatal: picker loads empty.
                }
            }
        }
        .sheet(item: $pendingDelete, onDismiss: {
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
        // ── Navigation destination ────────────────────────────────────
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

    // MARK: - Header

    /// Scrolling header row: kicker "YOUR LIBRARY" + "Tasks" title + gold + button.
    @ViewBuilder
    private var headerRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your library")
                    .risoKicker()
                Text("Tasks")
                    .risoH1()
            }
            Spacer(minLength: 12)
            RisoIconButton(systemImage: "plus") {
                showNewTaskSheet = true
            }
            .accessibilityLabel("New task")
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private func emptyState(hasAnyTasks: Bool) -> some View {
        VStack(alignment: .center, spacing: 10) {
            if hasAnyTasks {
                Text("No tasks match your filters.")
                    .font(.risoBody(15, .semibold))
                    .foregroundStyle(Color.risoInk)
                Text("Try clearing the search, switching the type chip to All, or resetting Status / Usage.")
                    .font(.risoBody(13, .regular))
                    .foregroundStyle(Color.risoMuted)
                    .multilineTextAlignment(.center)
            } else {
                Text("No tasks yet.")
                    .font(.risoBody(15, .semibold))
                    .foregroundStyle(Color.risoInk)
                Text("Tap + to add one, or build a board on the Create tab — tasks you make there appear here too.")
                    .font(.risoBody(13, .regular))
                    .foregroundStyle(Color.risoMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .risoCard(keyline: Riso.Keyline.dense, fill: .risoPaper2)
    }

    // MARK: - Quick-action handlers

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
                pendingDelete = nil
                quickActionError = "Failed to delete task: \(error.localizedDescription)"
            }
        }
    }

    private func reloadLibraryAndStatuses() {
        _Concurrency.Task {
            await library.reload(userId: userId)
            await vm.reload()
        }
    }

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
                if let cycleError = await checkCycleForTask(taskId: t.id, referencedBoardId: patch.selectedBoardId, referencedTemplateId: nil) {
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
                if let cycleError = await checkCycleForTask(taskId: t.id, referencedBoardId: nil, referencedTemplateId: patch.selectedTemplateId) {
                    await MainActor.run { quickActionError = cycleError }
                    return
                }
                t.referencedTemplateId = patch.selectedTemplateId
                t.referencedBoardId = nil
                t.requiredCount = req
            }
        }
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
            case .ok: return nil
            case .cycle(let path): return "This reference would create a cycle: \(path.joined(separator: " → "))"
            }
        } catch {
            return "Cycle check failed: \(error.localizedDescription)"
        }
    }
}
