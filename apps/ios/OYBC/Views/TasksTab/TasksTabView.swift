import SwiftUI

/// Tasks tab — dedicated surface for browsing, searching, filtering,
/// and editing the user's task library. iOS twin of web's `TasksPage`.
///
/// Composes:
/// - `CreateHubQuickAddView` pinned at the top (moved here from the
///   Create hub as part of the same refactor — the quick-add belongs
///   with the library it writes to).
/// - `TasksFilterControlsView` (search + type chips + status / usage
///   dropdowns + sort dropdown).
/// - Scrolling list of `TaskRowView` rows. Tapping a row pushes
///   `TaskDetailView` onto the navigation stack.
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

    @State private var library = TaskLibraryViewModel()
    @State private var vm = TasksTabViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Tasks")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                CreateHubQuickAddView(
                    userId: userId,
                    onTaskCreated: {
                        library.loadLibrary(userId: userId)
                        vm.reloadAsync()
                    }
                )

                TasksFilterControlsView(
                    search: $vm.search,
                    typeFilter: $vm.typeFilter,
                    statusFilter: $vm.statusFilter,
                    usageFilter: $vm.usageFilter,
                    sortBy: $vm.sortBy
                )

                let filtered = vm.filteredTasks(library: library)
                if filtered.isEmpty {
                    emptyState(hasAnyTasks: !library.libraryTasks.isEmpty)
                } else {
                    let placementCounts = vm.placementCounts(boardTasks: library.allLibraryBoardTasks)
                    let activeCounts = vm.activePlacementCounts(boardTasks: library.allLibraryBoardTasks)
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filtered, id: \.id) { task in
                            TaskRowView(
                                task: task,
                                placementCount: placementCounts[task.id] ?? 0,
                                activePlacementCount: activeCounts[task.id] ?? 0,
                                childCount: library.compoundChildrenByCompound[task.id]?.count ?? 0,
                                onTap: { path.append(task.id) }
                            )
                        }
                    }
                }
            }
            .padding(16)
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
                    // Pop the detail view off the stack so the user
                    // returns to the list.
                    if !path.isEmpty { path.removeLast() }
                }
            )
        }
        .onAppear {
            library.loadLibrary(userId: userId)
            vm.reloadAsync()
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
                Text("Use the quick-add form above, or build a board on the Create tab — tasks you make there appear here too.")
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
