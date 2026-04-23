import SwiftUI

/// BoardWizardTasksStepView — Step 2 of the board-creation wizard
/// (iOS twin of web `BoardWizardTasksStep`).
///
/// Renders the user's task library with multi-select, a search input,
/// a type filter, and a `.sheet`-presented "+ New task" form.
/// Composite tasks expand to their leaf nodes via the existing
/// `CompositeDerivationPanelView` so leaves can be selected
/// individually.
///
/// The view is fully controlled — `selectedTaskIds`, `centerTaskId`,
/// and the navigation callbacks are owned by the wizard's state
/// controller. Internal `@State` is limited to UI-only concerns
/// (search query, active filter, expanded composite, sheet open
/// state).
struct BoardWizardTasksStepView: View {

    // MARK: - Parameters

    /// User's task library (Observable). The view only reads —
    /// reloads are triggered by the parent via `onLibraryReloadRequested`.
    let library: TaskLibraryViewModel

    /// Currently-selected task ids — controlled by the wizard.
    @Binding var selectedTaskIds: Set<String>

    /// Number of tasks the chosen board geometry requires.
    let tasksRequired: Int

    /// When true, every selected row shows a star radio for picking the
    /// center task. Driven by Step 1's center-type choice.
    let centerTaskMode: Bool

    /// The currently-marked center task id, or `nil` if none picked.
    @Binding var centerTaskId: String?

    /// Authenticated user id used by the inline new-task sheet.
    let userId: String

    /// Fired after a non-composite task is created from the sheet —
    /// the wizard should auto-add the new id to `selectedTaskIds`.
    let onTaskCreated: (_ taskId: String, _ title: String, _ type: String) -> Void

    /// Fired after a composite task is created from the sheet — the
    /// wizard should reload the library so the composite shows up.
    let onCompositeCreated: (CompositeTask) -> Void

    /// Called after either creation callback so the parent's library
    /// view-model can refresh in the same turn the sheet dismisses.
    let onLibraryReloadRequested: () -> Void

    /// Navigates to the previous wizard step.
    let onBack: () -> Void

    /// Navigates to the next wizard step. Disabled when validation fails.
    let onNext: () -> Void

    // MARK: - Internal state

    @State private var searchQuery: String = ""
    @State private var activeFilter: LibraryFilter = .all
    @State private var expandedCompositeId: String? = nil
    @State private var isSheetPresented: Bool = false

    // MARK: - Derived

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matches(_ title: String) -> Bool {
        trimmedQuery.isEmpty || title.lowercased().contains(trimmedQuery)
    }

    private var visibleTasks: [Task] {
        let pool: [Task]
        switch activeFilter {
        case .all:       pool = library.libraryTasks
        case .normal:    pool = library.libraryTasks.filter { $0.type == .normal }
        case .counting:  pool = library.libraryTasks.filter { $0.type == .counting }
        case .progress:  pool = library.libraryTasks.filter { $0.type == .progress }
        case .composite: pool = []
        }
        return pool.filter { matches($0.title) }
    }

    private var visibleComposites: [CompositeTask] {
        switch activeFilter {
        case .all, .composite:
            return library.libraryCompositeTasks.filter { matches($0.title) }
        default:
            return []
        }
    }

    private var selectedCount: Int { selectedTaskIds.count }
    private var isCountSatisfied: Bool { selectedCount >= tasksRequired }
    private var isCenterSatisfied: Bool {
        if !centerTaskMode { return true }
        guard let id = centerTaskId else { return false }
        return selectedTaskIds.contains(id)
    }
    private var canAdvance: Bool { isCountSatisfied && isCenterSatisfied }

    /// Synthetic pool tuple list used to plug into
    /// `CompositeDerivationPanelView`'s pool-aware leaf-state logic.
    /// The panel only checks `taskId` membership, so the title/type
    /// fields can be empty without affecting behavior.
    private var pseudoPool: [(taskId: String, title: String, type: String)] {
        library.libraryTasks
            .filter { selectedTaskIds.contains($0.id) }
            .map { (taskId: $0.id, title: $0.title, type: $0.type.rawValue) }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            list
            footer
        }
        .padding(16)
        .background(Color(.systemBackground))
        .sheet(isPresented: $isSheetPresented) {
            NewTaskSheetView(
                userId: userId,
                onTaskCreated: { taskId, title, type in
                    onTaskCreated(taskId, title, type)
                },
                onCompositeCreated: { ct in
                    onCompositeCreated(ct)
                },
                onLibraryReloadRequested: onLibraryReloadRequested
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Selected: ")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                +
                Text("\(selectedCount) / \(tasksRequired)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(isCountSatisfied ? .green : .orange)

                if centerTaskMode {
                    let satisfied = isCenterSatisfied
                    Text(satisfied ? "★ Center picked" : "★ Center required")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background((satisfied ? Color.green : Color.orange).opacity(0.15))
                        .foregroundColor(satisfied ? .green : .orange)
                        .clipShape(Capsule())
                }

                Spacer()

                Button {
                    isSheetPresented = true
                } label: {
                    Label("New task", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("Create a new task")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search your tasks…", text: $searchQuery)
                    .textFieldStyle(.plain)
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .cornerRadius(8)

            Picker("Filter", selection: $activeFilter) {
                ForEach(LibraryFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: activeFilter) {
                expandedCompositeId = nil
            }
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if visibleTasks.isEmpty && visibleComposites.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(visibleTasks, id: \.id) { task in
                        taskRow(task)
                    }
                    ForEach(visibleComposites, id: \.id) { ct in
                        compositeRow(ct)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 480)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            if !trimmedQuery.isEmpty {
                Text("No tasks match \"\(searchQuery)\".")
            } else {
                Text("Your task library is empty.")
                    .fontWeight(.medium)
                Text("Tap \"New task\" above to create your first one.")
                    .font(.caption)
            }
        }
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(.systemGray4), style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
    }

    // MARK: - Rows

    private func taskRow(_ task: Task) -> some View {
        let isSelected = selectedTaskIds.contains(task.id)
        let isCenter = centerTaskId == task.id
        return HStack(spacing: 8) {
            Button {
                toggleSelection(task.id)
            } label: {
                HStack(spacing: 8) {
                    checkbox(checked: isSelected)
                    Text(task.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TypeBadgeView(type: task.type.rawValue, size: .small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.blue.opacity(0.08) : Color(.systemGray6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            if centerTaskMode && isSelected {
                Button {
                    centerTaskId = isCenter ? nil : task.id
                } label: {
                    Image(systemName: isCenter ? "star.fill" : "star")
                        .foregroundColor(isCenter ? .orange : .secondary)
                        .font(.title3)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCenter ? "Center task" : "Mark as center task")
            }
        }
    }

    private func compositeRow(_ ct: CompositeTask) -> some View {
        let isExpanded = expandedCompositeId == ct.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                expandedCompositeId = isExpanded ? nil : ct.id
                if !isExpanded {
                    library.loadDeriveNodes(for: ct.id)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .frame(width: 22, height: 22)
                    Text(ct.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TypeBadgeView(type: "composite", size: .small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray6))
                )
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Composites can't be boarded directly. Pick the individual subtasks you want to include.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .italic()

                    CompositeDerivationPanelView(
                        compositeTask: ct,
                        compositeNodes: library.deriveCompositeNodes,
                        tasks: library.libraryTasks,
                        compositeTasks: library.libraryCompositeTasks,
                        boardPool: pseudoPool,
                        onAddLeafToPool: { taskId, _, _ in
                            toggleSelection(taskId)
                        }
                    )
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray5))
                )
                .padding(.horizontal, 16)
                .padding(.top, -2)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()

            Button("‹ Back") { onBack() }
                .buttonStyle(.bordered)

            Button("Next ›") { onNext() }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private func toggleSelection(_ taskId: String) {
        let wasSelected = selectedTaskIds.contains(taskId)
        if wasSelected {
            selectedTaskIds.remove(taskId)
            // If user is deselecting the current center task, clear the center mark.
            if centerTaskId == taskId {
                centerTaskId = nil
            }
        } else {
            selectedTaskIds.insert(taskId)
        }
    }

    private func checkbox(checked: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(checked ? Color.blue : Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(checked ? Color.blue : Color(.systemGray3), lineWidth: 1.5)
                )
                .frame(width: 22, height: 22)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }
}
