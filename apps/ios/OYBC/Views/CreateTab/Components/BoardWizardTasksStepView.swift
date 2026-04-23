import SwiftUI

/// BoardWizardTasksStepView — Step 2 of the board-creation wizard
/// (iOS twin of web `BoardWizardTasksStep`).
///
/// Renders the user's task library with multi-select, a search input,
/// a type filter, and a `.sheet`-presented "+ New task" form. Row
/// layout matches the composite wizard's Build step exactly:
/// `[toggle] [BADGE letterOnly] title + subtitle | usage hint`, with
/// a 3pt leading blue bar + tinted background for the selected state.
/// Hairline dividers between rows — no per-row boxes.
///
/// Composites can't be added to a board directly. The composite row
/// uses a chevron instead of a checkbox and expands inline to show
/// its leaf tasks; each leaf is rendered with the same task-row
/// layout, indented. Replaces the older `CompositeDerivationPanelView`
/// + "+ Add to pool" treatment which read as a different UI language.
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

    // ── Usage-hint + leaf-preview data ───────────────────────────────
    // Ported from the composite wizard so both surfaces agree.

    private var taskBoardCounts: [String: Int] {
        var buckets: [String: Set<String>] = [:]
        for bt in library.allLibraryBoardTasks {
            buckets[bt.taskId, default: []].insert(bt.boardId)
        }
        return buckets.mapValues { $0.count }
    }

    private var taskStepCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for step in library.allLibraryTaskSteps {
            counts[step.taskId, default: 0] += 1
        }
        return counts
    }

    private var compositeSubtaskCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for node in library.allLibraryCompositeNodes where node.nodeType == .leaf {
            counts[node.compositeTaskId, default: 0] += 1
        }
        return counts
    }

    private struct LeafPreview: Equatable {
        let titles: [String]
        let totalLeaves: Int
    }

    private var compositeLeafPreviews: [String: LeafPreview] {
        var byComposite: [String: [CompositeNode]] = [:]
        for n in library.allLibraryCompositeNodes where n.nodeType == .leaf {
            byComposite[n.compositeTaskId, default: []].append(n)
        }
        let taskTitleById = Dictionary(uniqueKeysWithValues: library.libraryTasks.map { ($0.id, $0.title) })
        let compositeTitleById = Dictionary(uniqueKeysWithValues: library.libraryCompositeTasks.map { ($0.id, $0.title) })
        var out: [String: LeafPreview] = [:]
        for (cid, nodes) in byComposite {
            let sorted = nodes.sorted { $0.nodeIndex < $1.nodeIndex }
            var titles: [String] = []
            for leaf in sorted.prefix(3) {
                if let tid = leaf.taskId, let t = taskTitleById[tid] {
                    titles.append(t)
                } else if let cid2 = leaf.childCompositeTaskId, let c = compositeTitleById[cid2] {
                    titles.append(c)
                }
            }
            out[cid] = LeafPreview(titles: titles, totalLeaves: sorted.count)
        }
        return out
    }

    /// Flat task leaves per composite — composites can't be boarded
    /// directly, only their flat task leaves can. Nested composite
    /// leaves are intentionally skipped (boards don't accept them).
    private func leafTasks(for compositeId: String) -> [Task] {
        let leaves = library.allLibraryCompositeNodes
            .filter { $0.compositeTaskId == compositeId && $0.nodeType == .leaf }
            .sorted { $0.nodeIndex < $1.nodeIndex }
        let taskById = Dictionary(uniqueKeysWithValues: library.libraryTasks.map { ($0.id, $0) })
        return leaves.compactMap { leaf -> Task? in
            guard let tid = leaf.taskId else { return nil }
            return taskById[tid]
        }
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

            HStack(spacing: 8) {
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.systemGray6))
            .cornerRadius(8)

            // Scrollable pill row instead of .segmented — matches the
            // composite wizard; avoids the "Composite" truncation on
            // narrow iPhones.
            FilterTabsView(
                tabs: LibraryFilter.allCases.map { FilterTab(value: $0.rawValue, label: $0.rawValue) },
                activeTab: Binding(
                    get: { activeFilter.rawValue },
                    set: { newValue in
                        if let f = LibraryFilter(rawValue: newValue) {
                            activeFilter = f
                            expandedCompositeId = nil
                        }
                    }
                ),
                onTabChange: { _ in }
            )
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if visibleTasks.isEmpty && visibleComposites.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleTasks.enumerated()), id: \.element.id) { index, task in
                        taskRow(task)
                        if index < visibleTasks.count - 1 || !visibleComposites.isEmpty {
                            Divider().padding(.leading, 52)
                        }
                    }
                    ForEach(Array(visibleComposites.enumerated()), id: \.element.id) { index, ct in
                        compositeRow(ct)
                        if index < visibleComposites.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
            .frame(maxHeight: 520)
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
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(.systemGray4), style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
    }

    // MARK: - Rows

    @ViewBuilder
    private func taskRow(_ task: Task) -> some View {
        let isSelected = selectedTaskIds.contains(task.id)
        let isCenter = centerTaskId == task.id
        let subtitle = buildTaskSubtitle(task: task)
        let boards = taskBoardCounts[task.id] ?? 0
        let usage = boards == 0 ? "unused" : "\(boards) board\(boards == 1 ? "" : "s")"
        HStack(spacing: 0) {
            Button {
                toggleSelection(task.id)
            } label: {
                HStack(spacing: 0) {
                    // Leading accent bar — visible only when selected.
                    Rectangle()
                        .fill(isSelected ? Color.blue : Color.clear)
                        .frame(width: 3)
                    HStack(spacing: 12) {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(isSelected ? .blue : .secondary)
                        TypeBadgeView(type: task.type.rawValue, size: .small, letterOnly: true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            if !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(usage)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .background(isSelected ? Color.blue.opacity(0.10) : Color(.systemBackground))
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
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCenter ? "Center task" : "Mark as center task")
            }
        }
    }

    @ViewBuilder
    private func compositeRow(_ ct: CompositeTask) -> some View {
        let isExpanded = expandedCompositeId == ct.id
        let leafCount = compositeSubtaskCounts[ct.id] ?? 0
        let preview = compositeLeafPreviews[ct.id]
        let previewSubtitle: String = {
            guard let p = preview, !p.titles.isEmpty else { return "" }
            let hidden = p.totalLeaves - p.titles.count
            let joined = p.titles.joined(separator: ", ")
            return hidden > 0 ? "\(joined), +\(hidden) more" : joined
        }()
        let leaves = leafTasks(for: ct.id)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                expandedCompositeId = isExpanded ? nil : ct.id
            } label: {
                HStack(spacing: 0) {
                    // No leading bar on composite rows — chevron is the
                    // affordance; composites aren't themselves selected.
                    Rectangle().fill(Color.clear).frame(width: 3)
                    HStack(spacing: 12) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .foregroundColor(.secondary)
                            .font(.caption.bold())
                            .frame(width: 20)
                        TypeBadgeView(type: "composite", size: .small, letterOnly: true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ct.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            if !previewSubtitle.isEmpty {
                                Text(previewSubtitle)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text("\(leafCount) subtask\(leafCount == 1 ? "" : "s")")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .background(Color(.systemBackground))
            }
            .buttonStyle(.plain)

            if isExpanded {
                // Indented leaf list. Leaves use the same row layout as
                // top-level tasks so the expand feels like a natural
                // indent, not a different UI. Drops the old "Operator:
                // AND" header + "+ Add to pool" buttons which were
                // irrelevant when picking leaves for a board.
                VStack(spacing: 0) {
                    if leaves.isEmpty {
                        Text("This composite has no task leaves — nothing boardable here.")
                            .font(.footnote)
                            .italic()
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(leaves.enumerated()), id: \.element.id) { index, leaf in
                            taskRow(leaf)
                                .padding(.leading, 24)
                            if index < leaves.count - 1 {
                                Divider().padding(.leading, 76)
                            }
                        }
                    }
                }
                .background(Color(.systemGray6))
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
            if centerTaskId == taskId {
                centerTaskId = nil
            }
        } else {
            selectedTaskIds.insert(taskId)
        }
    }

    private func buildTaskSubtitle(task: Task) -> String {
        switch task.type {
        case .counting:
            guard let action = task.action,
                  let unit = task.unit,
                  let max = task.maxCount,
                  !action.isEmpty,
                  !unit.isEmpty else {
                return ""
            }
            let derived = "\(action) \(max) \(unit)"
            if derived.lowercased() == task.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                return ""
            }
            return derived
        case .progress:
            let n = taskStepCounts[task.id] ?? 0
            if n == 0 { return "" }
            return "\(n) step\(n == 1 ? "" : "s")"
        default:
            return ""
        }
    }
}
