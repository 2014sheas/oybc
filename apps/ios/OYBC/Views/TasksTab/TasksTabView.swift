import SwiftUI

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
                                childCount: library.compoundChildrenByCompound[task.id]?.count ?? 0,
                                onTap: { /* swallowed: outer Button handles tap */ }
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
                onSubmit: { patch in
                    _Concurrency.Task { await saveEdits(task: task, patch: patch) }
                },
                onCancel: { editingTask = nil }
            )
        }
        .sheet(item: $pendingDelete) { pending in
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

    /// Run the cascade delete off-main and reload the library on success.
    private func performDelete(taskId: String) async {
        do {
            try await _Concurrency.Task.detached(priority: .userInitiated) {
                try AppDatabase.shared.deleteTaskWithCascade(taskId: taskId)
            }.value
            await MainActor.run {
                pendingDelete = nil
                library.loadLibrary(userId: userId)
                vm.reloadAsync()
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

    /// Save the row-level edit patch off-main. Mirrors the patch logic
    /// in `TaskDetailView.saveEdits` so the two surfaces behave the
    /// same — extracting the shared bit is a follow-up once a third
    /// caller appears.
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
