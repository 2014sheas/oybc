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
    let onCompositeCreated: (OYBC.Task) -> Void

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
    /// Source task + draft max-count for the "derive smaller version"
    /// quick action on counting rows. `nil` when the deriver sheet is
    /// closed. Set by the contextMenu Button; cleared on save/cancel.
    @State private var derivingFromTask: OYBC.Task? = nil
    @State private var deriveMaxCountInput: String = ""

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
        // Under the unified compound model, all compound tasks (progress and
        // composite) are rendered in the composites region below, so the
        // primitives pool never includes compounds.
        case .all:       pool = library.libraryTasks.filter { $0.type != .compound }
        case .normal:    pool = library.libraryTasks.filter { $0.type == .normal }
        case .counting:  pool = library.libraryTasks.filter { $0.type == .counting }
        case .progress:  pool = []
        case .composite: pool = []
        }
        return pool.filter { matches($0.title) }
    }

    /// Compound-typed tasks shown in the composites region.
    /// "All" shows every compound; "Composite" filter shows isOrdered=false;
    /// "Progress" filter shows isOrdered=true. This makes every compound
    /// reachable, selectable as a whole, and expandable into its leaves.
    private var visibleComposites: [OYBC.Task] {
        switch activeFilter {
        case .all:
            return library.libraryTasks
                .filter { $0.type == .compound }
                .filter { matches($0.title) }
        case .composite:
            return library.libraryTasks
                .filter { $0.type == .compound && $0.isOrdered != true }
                .filter { matches($0.title) }
        case .progress:
            return library.libraryTasks
                .filter { $0.type == .compound && $0.isOrdered == true }
                .filter { matches($0.title) }
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

    /// Subtask counts for compound (formerly composite + progress) tasks.
    /// Both "Composite" and "Progress" tabs render counts from the same
    /// `compound_children` source; the only thing that differs is which
    /// subset of compound tasks gets shown in the row list.
    private var compositeSubtaskCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for (compoundId, children) in library.compoundChildrenByCompound {
            counts[compoundId] = children.count
        }
        return counts
    }

    private struct LeafPreview: Equatable {
        let titles: [String]
        let totalLeaves: Int
    }

    /// First-3 child titles + total subtask count, keyed by parent
    /// compoundTaskId. Children are looked up by `childTaskId` against
    /// `library.libraryTasks` (composites are themselves Tasks under the
    /// unified model, so a single map handles both primitive and nested
    /// compound children).
    private var compositeLeafPreviews: [String: LeafPreview] {
        let taskTitleById = Dictionary(uniqueKeysWithValues: library.libraryTasks.map { ($0.id, $0.title) })
        var out: [String: LeafPreview] = [:]
        for (compoundId, children) in library.compoundChildrenByCompound {
            // children are pre-sorted by childIndex in the view-model.
            var titles: [String] = []
            for child in children.prefix(3) {
                if let title = taskTitleById[child.childTaskId] {
                    titles.append(title)
                }
            }
            out[compoundId] = LeafPreview(titles: titles, totalLeaves: children.count)
        }
        return out
    }

    /// Flat task leaves per compound — only primitive (non-compound)
    /// children are returned, since boards don't accept nested compounds
    /// as inline taps. Caller filters out nested compound children
    /// (they show up as their own "compound row" elsewhere in the tab).
    private func leafTasks(for compoundId: String) -> [OYBC.Task] {
        let children = library.compoundChildrenByCompound[compoundId] ?? []
        let taskById = Dictionary(uniqueKeysWithValues: library.libraryTasks.map { ($0.id, $0) })
        return children.compactMap { child -> OYBC.Task? in
            guard let task = taskById[child.childTaskId] else { return nil }
            // Skip nested compounds — only flat task leaves can be placed
            // directly on a board (mirrors legacy CompositeNode.taskId-only
            // semantics).
            if task.type == .compound { return nil }
            return task
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
        // Quick "Derive smaller version" sheet — opened from a counting
        // row's contextMenu. Two-field form (read-only summary + new
        // maxCount) so the user can scale the source down to a sub-counter
        // (e.g., "Read 100 pages" → "Read 20 pages") without bouncing
        // through the full New Task form.
        .sheet(item: derivePickerItemBinding) { _ in
            deriveCounterSheet
        }
    }

    /// `Identifiable` adapter wrapping `derivingFromTask` so we can use
    /// `.sheet(item:)` (which auto-dismisses when nil and triggers a
    /// fresh state on each open).
    private var derivePickerItemBinding: Binding<DeriveCounterPayload?> {
        Binding(
            get: {
                if let t = derivingFromTask { return DeriveCounterPayload(task: t) }
                return nil
            },
            set: { newValue in
                if newValue == nil { derivingFromTask = nil }
            }
        )
    }

    private struct DeriveCounterPayload: Identifiable {
        let task: OYBC.Task
        var id: String { task.id }
    }

    @ViewBuilder
    private var deriveCounterSheet: some View {
        if let source = derivingFromTask {
            NavigationStack {
                Form {
                    Section("Derived from") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.title)
                                .font(.headline)
                            if let action = source.action,
                               let unit = source.unit,
                               let max = source.maxCount {
                                Text("\(action) \(max) \(unit)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Section("New target") {
                        TextField("Max count", text: $deriveMaxCountInput)
                            .keyboardType(.numberPad)
                        if let action = source.action, let unit = source.unit,
                           let parsed = Int(deriveMaxCountInput.trimmingCharacters(in: .whitespacesAndNewlines)),
                           parsed > 0 {
                            Text("Title: \(action) \(parsed) \(unit)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .navigationTitle("Derive smaller version")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            derivingFromTask = nil
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saveDerivedCounter(source: source)
                        }
                        .disabled(!isDeriveInputValid(source: source))
                    }
                }
            }
        }
    }

    private func isDeriveInputValid(source: OYBC.Task) -> Bool {
        guard source.action != nil, source.unit != nil, source.maxCount != nil else { return false }
        guard let parsed = Int(deriveMaxCountInput.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return parsed > 0
    }

    /// Atomically writes a new counting Task derived from `source` (same
    /// action+unit, scaled-down maxCount), enqueues a sync entry, and adds
    /// the new task id to the wizard's selection. Mirrors the iOS
    /// CreateFormViewModel counting-create path but bypasses the form so
    /// it's a single-tap quick action from the contextMenu.
    private func saveDerivedCounter(source: OYBC.Task) {
        guard let action = source.action,
              let unit = source.unit,
              let parsed = Int(deriveMaxCountInput.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed > 0
        else { return }

        let now = AppDatabase.currentTimestamp()
        let newId = AppDatabase.generateUUID()
        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = "\(trimmedAction) \(parsed) \(trimmedUnit)"

        let newTask = OYBC.Task(
            id: newId,
            userId: userId,
            title: title,
            description: nil,
            type: .counting,
            action: trimmedAction,
            unit: trimmedUnit,
            maxCount: parsed,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false
        )
        do {
            try AppDatabase.shared.write { db in
                try newTask.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "tasks",
                    entityId: newId,
                    operationType: .create,
                    payload: newTask,
                    now: now
                ).save(db)
            }
            onTaskCreated(newId, title, "counting")
            onLibraryReloadRequested()
        } catch {
            // Swallow + dismiss; the user can retry. A toast surface lives
            // on the parent's wizard banner; threading it through here would
            // require extra plumbing for an edge-case path.
        }
        derivingFromTask = nil
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
            // No inner ScrollView — the parent (MainTabView's ScrollView,
            // or the wizard host) owns scrolling. Wrapping a LazyVStack in
            // its own ScrollView created a nested-scroll feel where the
            // outer page and the inner list fought for the gesture.
            // LazyVStack inside a parent ScrollView still lazy-loads rows
            // as they enter the visible region, so we keep the perf win
            // without the doubled chrome.
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
                    // Checkbox removed; selection is communicated entirely
                    // through this bar + the tinted row background.
                    Rectangle()
                        .fill(isSelected ? Color.blue : Color.clear)
                        .frame(width: 3)
                    HStack(spacing: 12) {
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
            // Long-press surfaces the same actions a tap performs (toggle
            // selection) plus center-task pinning when the wizard is in
            // center-task mode. Counting rows additionally surface a
            // "Derive smaller version…" shortcut so the user can spawn a
            // sub-counter (e.g., "Read 20 pages" from "Read 100 pages")
            // without leaving the wizard. Same affordance pattern as
            // BoardPlayView's .contextMenu modifiers.
            .contextMenu {
                Button(
                    isSelected ? "Remove from board" : "Add to board",
                    systemImage: isSelected ? "minus.circle" : "plus.circle"
                ) {
                    toggleSelection(task.id)
                }
                if task.type == .counting,
                   task.action != nil, task.unit != nil, task.maxCount != nil {
                    Button("Derive smaller version…", systemImage: "scalemass") {
                        derivingFromTask = task
                        deriveMaxCountInput = ""
                    }
                }
                if centerTaskMode && isSelected {
                    Button(
                        isCenter ? "Unset as center task" : "Set as center task",
                        systemImage: isCenter ? "star.slash" : "star"
                    ) {
                        centerTaskId = isCenter ? nil : task.id
                    }
                }
            }

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
    private func compositeRow(_ ct: OYBC.Task) -> some View {
        let isExpanded = expandedCompositeId == ct.id
        let isCompoundSelected = selectedTaskIds.contains(ct.id)
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
            // Compound header — two independent interaction zones:
            //  1. Row body (select toggle) — adds/removes the compound task itself.
            //  2. Disclosure button (chevron) — expands/collapses the leaf list.
            HStack(spacing: 0) {
                Button {
                    toggleSelection(ct.id)
                } label: {
                    HStack(spacing: 0) {
                        // Leading accent bar — visible only when selected.
                        Rectangle()
                            .fill(isCompoundSelected ? Color.blue : Color.clear)
                            .frame(width: 3)
                        HStack(spacing: 12) {
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
                    .background(isCompoundSelected ? Color.blue.opacity(0.10) : Color(.systemBackground))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCompoundSelected ? [.isSelected] : [])
                // Long-press surfaces compound-specific shortcuts that a tap
                // can't express: select the whole compound, expand the leaf
                // list, one-shot select every leaf, or pick individual
                // leaves via a submenu without expanding the row first.
                .contextMenu {
                    Button(
                        isCompoundSelected ? "Remove from board" : "Add to board",
                        systemImage: isCompoundSelected ? "minus.circle" : "plus.circle"
                    ) {
                        toggleSelection(ct.id)
                    }
                    Button(
                        isExpanded ? "Collapse subtasks" : "Expand subtasks",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    ) {
                        expandedCompositeId = isExpanded ? nil : ct.id
                    }
                    if !leaves.isEmpty {
                        Button("Add all subtasks to board", systemImage: "plus.square.on.square") {
                            for leaf in leaves {
                                if !selectedTaskIds.contains(leaf.id) {
                                    selectedTaskIds.insert(leaf.id)
                                }
                            }
                        }
                        // Per-subtask quick-add submenu — lets the user pick a
                        // single leaf without expanding the row in the list.
                        Menu("Add a subtask") {
                            ForEach(leaves, id: \.id) { leaf in
                                let leafIsSelected = selectedTaskIds.contains(leaf.id)
                                Button(
                                    leafIsSelected
                                        ? "✓ \(leaf.title)"
                                        : leaf.title
                                ) {
                                    if !leafIsSelected {
                                        selectedTaskIds.insert(leaf.id)
                                    }
                                }
                                .disabled(leafIsSelected)
                            }
                        }
                    }
                }

                // Disclosure button — separated by a hairline divider so
                // tap targets are visually distinct.
                Divider()
                    .frame(width: 1)

                Button {
                    expandedCompositeId = isExpanded ? nil : ct.id
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption.bold())
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse subtasks" : "Expand subtasks")
            }

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
        case .compound where task.isOrdered == true:
            // Former Progress tasks: show "N step(s)" subtitle from compound
            // children (the unified replacement for legacy task_steps).
            let n = library.compoundChildrenByCompound[task.id]?.count ?? 0
            if n == 0 { return "" }
            return "\(n) step\(n == 1 ? "" : "s")"
        default:
            return ""
        }
    }
}
