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

    /// Phase 6.2 — true when the wizard is in recurring-template mode.
    /// Drives the count-line "min" suffix wording. The pool is always
    /// loose-fit; the spawn shuffles + slices, so any extras become the
    /// random subset for each window.
    let isRecurring: Bool

    /// When true, every selected row shows a star radio for picking the
    /// center task. Driven by Step 1's center-type choice.
    let centerTaskMode: Bool

    /// The currently-marked center task id, or `nil` if none picked.
    @Binding var centerTaskId: String?

    /// Authenticated user id used by the inline new-task sheet.
    let userId: String

    /// Phase 6.1: current wizard timeframe. Drives whether the "From
    /// parent boards" filter chip is shown (only for daily/weekly/
    /// monthly — yearly + custom hide it) and what timeframe to feed
    /// `ParentBoardTasksViewModel`.
    let currentTimeframe: Timeframe

    /// Phase 6.Y — resolved start/end dates the wizard will write on
    /// the board. Threaded into NewTaskSheetView so any new task
    /// created from inside the wizard inherits the same window. Nil
    /// when dates can't be resolved (e.g., CUSTOM with no user input);
    /// the new task then inherits timeframe but not dates.
    var currentStartDate: String? = nil
    var currentEndDate: String? = nil

    /// Fired after a non-composite task is created from the sheet —
    /// the wizard should auto-add the new id to `selectedTaskIds`.
    let onTaskCreated: (_ taskId: String, _ title: String, _ type: String) -> Void

    /// Fired after a composite task is created from the sheet — the
    /// wizard should reload the library so the composite shows up.
    let onCompositeCreated: (OYBC.Task) -> Void

    /// Called after either creation callback so the parent's library
    /// view-model can refresh in the same turn the sheet dismisses.
    let onLibraryReloadRequested: () -> Void

    /// Bug #85 — Called alongside `onTaskCreated` when a task is created
    /// in deferred-persist mode (no DB write). The wizard stores the
    /// payload for the board-save transaction. Nil disables deferred mode
    /// (immediate persist). iOS twin of web `onPendingCreated` prop.
    var onPendingCreated: ((_ payload: PendingTaskPayload) -> Void)? = nil

    /// Bug #85 — In-memory pending tasks owned by the wizard. Keyed by
    /// `task.id`. Passed here so the Tasks step can surface newly-created
    /// (not-yet-persisted) tasks as selected rows in the visible list —
    /// without this, a created task appears to vanish because the Dexie /
    /// GRDB live query hasn't seen it yet. When nil, pending tasks are
    /// not shown (safe fallback — the selection count is still correct).
    var pendingTasks: [String: PendingTaskPayload]? = nil

    /// Navigates to the previous wizard step.
    let onBack: () -> Void

    /// Navigates to the next wizard step. Disabled when validation fails.
    let onNext: () -> Void

    // MARK: - Internal state

    @State private var searchQuery: String = ""
    @State private var activeFilter: LibraryFilter = .all
    @State private var expandedCompositeId: String? = nil
    @State private var isSheetPresented: Bool = false
    /// Issue #73 — Default true. When on, primitive tasks that are children
    /// of a compound are hidden from the flat list. Compounds already render
    /// as expandable rows in the composites section below; this toggle hides
    /// their leaf primitives from the top list so they aren't double-counted.
    @State private var groupByCompound: Bool = true
    /// Phase 6.1: parent-board tasks for the "From parent boards" filter.
    /// Reloaded on appear and whenever `currentTimeframe` changes.
    @State private var parentTasksVM = ParentBoardTasksViewModel()
    /// Source task + draft max-count for the "derive smaller version"
    /// quick action on counting rows. `nil` when the deriver sheet is
    /// closed. Set by the contextMenu Button; cleared on save/cancel.
    @State private var derivingFromTask: OYBC.Task? = nil
    @State private var deriveMaxCountInput: String = ""
    /// Drives a task-detail sheet when the user taps "Open in library" from
    /// a row's context menu.
    @State private var openedTaskInLibrary: TaskIdItem? = nil

    // ── From-a-board picker state ─────────────────────────────────────
    /// VM for `From a board…` — owns eligible boards + the currently
    /// loaded source's placements. Reloaded on appear; `loadPlacements`
    /// fires when the user picks a source.
    @State private var sourceBoardsVM = SourceBoardsViewModel()
    /// `nil` = picker mode; set = grid mode for that board id. Source
    /// can be swapped via the grid header's chevron without losing the
    /// running `selectedTaskIds` set.
    @State private var pickedSourceBoardId: String? = nil
    /// Task ids copied via the grid this session — drives the amber
    /// "copied" tint on source squares whose original we already
    /// copied. Session-scoped (cleared on remount).
    @State private var copiedTaskIds: Set<String> = []
    /// Source task whose CopyTaskSheet is currently presented; nil = closed.
    @State private var copyingTask: OYBC.Task? = nil

    // MARK: - Derived

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matches(_ title: String) -> Bool {
        trimmedQuery.isEmpty || title.lowercased().contains(trimmedQuery)
    }

    /// Phase 6.Y — Timeboxed Tasks: hide expired tasks from every
    /// wizard pool branch. Same default as the Tasks-tab list. No
    /// "show expired" toggle here — the wizard is "tasks I might want
    /// on this new board", and an expired task by definition
    /// shouldn't be added to a fresh board. A user who needs to
    /// backfill an expired task can re-extend its window from the
    /// Tasks tab first. Mirrors web's `BoardWizardTasksStep`.
    private func notExpired(_ t: Task) -> Bool {
        !TasksTabViewModel.isTaskExpired(t)
    }

    /// Issue #73 — When groupByCompound is on, returns false for any task
    /// that is a direct child of a compound (i.e., already surfaced in the
    /// composites region below the flat list). Mirrors web's `notGroupedChild`
    /// predicate in `BoardWizardTasksStep.tsx`. Uses the wizard rule: ALL
    /// children hidden when grouping on (no independent-placement exception —
    /// the wizard doesn't have BoardTask placements for tasks not yet placed).
    private func notGroupedChild(_ t: Task) -> Bool {
        guard groupByCompound else { return true }
        return !library.childTaskIds.contains(t.id)
    }

    /// Bug #85 — Effective task pool: live library tasks merged with any
    /// in-memory pending tasks (created this session, not yet in GRDB).
    /// Pending tasks are appended after library tasks; ids are deduplicated
    /// so a task that somehow appears in both is shown only once.
    private var effectiveAllTasks: [Task] {
        guard let pending = pendingTasks, !pending.isEmpty else {
            return library.libraryTasks
        }
        var seen = Set(library.libraryTasks.map { $0.id })
        var combined = library.libraryTasks
        for payload in pending.values {
            if !seen.contains(payload.task.id) {
                combined.append(payload.task)
                seen.insert(payload.task.id)
            }
        }
        return combined
    }

    private var visibleTasks: [Task] {
        let pool: [Task]
        switch activeFilter {
        // Under the unified compound model, all compound tasks (progress and
        // composite) are rendered in the composites region below, so the
        // primitives pool never includes compounds.
        // Bug #85 — use effectiveAllTasks to include pending tasks.
        // Issue #73 — notGroupedChild hides primitives that are children of
        // a compound (they're already accessible by expanding the parent row).
        case .all:       pool = effectiveAllTasks.filter { notExpired($0) && notGroupedChild($0) && $0.type != .compound }
        case .normal:    pool = effectiveAllTasks.filter { notExpired($0) && notGroupedChild($0) && $0.type == .normal }
        case .counting:  pool = effectiveAllTasks.filter { notExpired($0) && notGroupedChild($0) && $0.type == .counting }
        case .progress:  pool = []
        case .composite: pool = []
        // Phase 6.1: source is the parent-board-tasks query, not the
        // user's library. Compounds surfaced through this filter render
        // here too (no separate composites region) since the user is
        // picking from an already-curated parent set.
        case .fromParents: pool = parentTasksVM.tasks.filter { notExpired($0) }
        // From-a-board branch renders the picker / grid instead of the
        // list, so visibleTasks returns [] here — see the `list`
        // ViewBuilder for the routing.
        case .fromBoard: pool = []
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
            // Bug #85 — include pending compound tasks.
            return effectiveAllTasks
                .filter { notExpired($0) && $0.type == .compound }
                .filter { matches($0.title) }
        case .composite:
            return effectiveAllTasks
                .filter { notExpired($0) && $0.type == .compound && $0.isOrdered != true }
                .filter { matches($0.title) }
        case .progress:
            return effectiveAllTasks
                .filter { notExpired($0) && $0.type == .compound && $0.isOrdered == true }
                .filter { matches($0.title) }
        // .fromParents: compounds surfaced through this filter render in
        // the primitives region (visibleTasks), not as separate
        // expandable composites — the user is picking from an
        // already-curated parent set.
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

    /// Suffix on the count line: " min" / "" — only shown when
    /// `isRecurring` (one-off boards keep the bare count to preserve
    /// existing copy). The pool is always loose-fit; the spawn picks
    /// N from the larger pool each window.
    private var countSuffix: String {
        return isRecurring ? " min" : ""
    }

    // ── Usage-hint + leaf-preview data ───────────────────────────────
    // Ported from the composite wizard so both surfaces agree.

    private var taskBoardCounts: [String: Int] {
        var buckets: [String: Set<String>] = [:]
        for bt in library.allLibraryBoardTasks {
            buckets[bt.taskId, default: []].insert(bt.boardId)
        }
        return buckets.mapValues { $0.count }
    }

    /// Bug #85 — Effective compound-children map merging the live
    /// `library.compoundChildrenByCompound` (DB-backed) with any
    /// in-memory pending `childLinks` (newly-created compound tasks
    /// inside the wizard that aren't yet persisted). Without this,
    /// a pending compound rendered with 0 steps and couldn't expand.
    private var effectiveChildrenByCompound: [String: [CompoundChild]] {
        guard let pending = pendingTasks, !pending.isEmpty else {
            return library.compoundChildrenByCompound
        }
        var merged = library.compoundChildrenByCompound
        for payload in pending.values where !payload.childLinks.isEmpty {
            // childLinks are pre-sorted by childIndex in
            // CreateFormViewModel — use as-is to match the library shape.
            merged[payload.task.id] = payload.childLinks
        }
        return merged
    }

    /// Bug #85 — Per-id task lookup that includes pending parent + child
    /// tasks alongside the live library. Pending tasks aren't in
    /// `library.libraryTasks` until the board-save txn commits.
    private var effectiveTaskById: [String: OYBC.Task] {
        var by: [String: OYBC.Task] = Dictionary(uniqueKeysWithValues: library.libraryTasks.map { ($0.id, $0) })
        if let pending = pendingTasks {
            for payload in pending.values {
                by[payload.task.id] = payload.task
                for childTask in payload.childTasks {
                    by[childTask.id] = childTask
                }
            }
        }
        return by
    }

    /// Subtask counts for compound (formerly composite + progress) tasks.
    /// Both "Composite" and "Progress" tabs render counts from the same
    /// `compound_children` source; the only thing that differs is which
    /// subset of compound tasks gets shown in the row list. Sources
    /// from the effective map so pending compounds get their real count.
    private var compositeSubtaskCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for (compoundId, children) in effectiveChildrenByCompound {
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
    /// the effective task-by-id map so pending compounds' inline children
    /// resolve correctly. Composites are themselves Tasks under the
    /// unified model, so a single map handles both primitive and nested
    /// compound children.
    private var compositeLeafPreviews: [String: LeafPreview] {
        let taskById = effectiveTaskById
        var out: [String: LeafPreview] = [:]
        for (compoundId, children) in effectiveChildrenByCompound {
            // children are pre-sorted by childIndex in the view-model.
            var titles: [String] = []
            for child in children.prefix(3) {
                if let title = taskById[child.childTaskId]?.title {
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
    /// Sources from the effective children + task maps so pending
    /// compounds expand correctly.
    private func leafTasks(for compoundId: String) -> [OYBC.Task] {
        let children = effectiveChildrenByCompound[compoundId] ?? []
        let taskById = effectiveTaskById
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
        .onAppear {
            // Phase 6.1: load parent-board tasks for the wizard's current
            // timeframe so the "From parent boards" filter chip has data
            // ready when the user taps it. Cheap when there are no parents
            // (the VM short-circuits to []).
            parentTasksVM.reloadAsync(userId: userId, childTimeframe: currentTimeframe)
        }
        .onChange(of: currentTimeframe) { _, newTimeframe in
            // If the user goes back to step 1 and changes the timeframe,
            // refresh the parents list so a re-entry into step 2 sees the
            // right candidates. The reload is fire-and-forget; while it's
            // in flight `parentTasksVM.tasks` still holds the previous
            // timeframe's parent tasks (visible only if the user re-taps
            // the .fromParents chip during the load window). The VM uses
            // a monotonic latestSeq guard so the in-flight reload's result
            // is dropped if a newer reload starts before it commits —
            // critical because daily↔monthly both have parents but their
            // parent SETS differ (daily includes weekly/monthly; monthly
            // does not), so a stale commit would surface tasks that
            // shouldn't appear on the new child board.
            parentTasksVM.reloadAsync(userId: userId, childTimeframe: newTimeframe)

            // Coerce the active filter back to .all if the user picked
            // .fromParents on a timeframe with parents (e.g., daily) and
            // then switched to a parentless timeframe (yearly / custom).
            // Without this, the chip disappears from the tab row but
            // activeFilter remains .fromParents — leaving no pill visually
            // selected and showing the "No parent boards" empty state
            // instead of the user's library.
            let newHasParents = !(parentTimeframesByChild[newTimeframe] ?? []).isEmpty
            if !newHasParents && activeFilter == .fromParents {
                activeFilter = .all
            }
        }
        .sheet(isPresented: $isSheetPresented) {
            NewTaskSheetView(
                userId: userId,
                onTaskCreated: { taskId, title, type in
                    onTaskCreated(taskId, title, type)
                },
                onCompositeCreated: { ct in
                    onCompositeCreated(ct)
                },
                onLibraryReloadRequested: onLibraryReloadRequested,
                defaultTimeframe: currentTimeframe,
                defaultStartDate: currentStartDate,
                defaultEndDate: currentEndDate,
                deferPersist: onPendingCreated != nil,
                onPendingCreated: onPendingCreated
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
        // Task detail sheet — opened from a row's context menu "Open in library".
        .sheet(item: $openedTaskInLibrary) { item in
            // Wizard context: tapping a board in Usage would discard
            // wizard state, so we intentionally only dismiss the sheet
            // (no navigation). The user can finish the wizard and
            // navigate to the board manually.
            TaskDetailSheetView(
                taskId: item.id,
                onClose: { openedTaskInLibrary = nil },
                onOpenBoard: { _ in openedTaskInLibrary = nil }
            )
        }
        // Copy sheet for the From-a-board grid's `⎘ Add a copy of this
        // task…` action. Marks the source as "copied this session" for
        // the amber tint indicator + auto-links the new task into
        // selection on success.
        .sheet(item: $copyingTask) { source in
            CopyTaskSheet(
                source: source,
                userId: userId,
                onCopied: { newTask in
                    copiedTaskIds.insert(source.id)
                    if !selectedTaskIds.contains(newTask.id) {
                        toggleSelection(newTask.id)
                    }
                    copyingTask = nil
                },
                onCancel: { copyingTask = nil }
            )
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
                        TextField("Goal", text: $deriveMaxCountInput)
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
    ///
    /// Dispatches the GRDB write to a background queue and bounces the
    /// success / dismiss callbacks back onto the main actor — matches
    /// the pattern used by `persistWizardBoard` and friends so the tap
    /// never blocks the UI on disk I/O.
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

        // Dismiss the sheet immediately on the main actor — the write
        // is fast on SSD but the user still gets a snappier-feeling
        // close while the background queue handles persistence.
        derivingFromTask = nil

        DispatchQueue.global(qos: .userInitiated).async {
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
                DispatchQueue.main.async {
                    onTaskCreated(newId, title, "counting")
                    onLibraryReloadRequested()
                }
            } catch {
                // Swallow on background; the user can retry. A toast
                // surface lives on the parent's wizard banner; threading
                // it through here would require extra plumbing for an
                // edge-case path.
            }
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
                Text("\(selectedCount) / \(tasksRequired)\(countSuffix)")
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

            if activeFilter != .fromBoard {
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
            }

            // Scrollable pill row instead of .segmented — matches the
            // composite wizard; avoids the "Composite" truncation on
            // narrow iPhones.
            //
            // Phase 6.1: append .fromParents only when the wizard's
            // current timeframe has parent timeframes. yearly + custom
            // hide the chip (it would always be empty).
            FilterTabsView(
                tabs: visibleFilterTabs.map { FilterTab(value: $0.rawValue, label: $0.rawValue) },
                activeTab: Binding(
                    get: { activeFilter.rawValue },
                    set: { newValue in
                        if let f = LibraryFilter(rawValue: newValue) {
                            activeFilter = f
                            expandedCompositeId = nil
                            // Re-entering the From-a-board flow resets the
                            // picker so the user always lands in "pick a
                            // board" mode.
                            if f == .fromBoard {
                                pickedSourceBoardId = nil
                            }
                        }
                    }
                ),
                onTabChange: { _ in }
            )

            // Issue #73 — Group subtasks chip. Only shown when the from-board
            // branch is not active (it has its own grid UI). Capsule pill
            // matching the style in `TasksFilterControlsView`.
            if activeFilter != .fromBoard {
                HStack(spacing: 0) {
                    Button {
                        groupByCompound.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Group subtasks")
                                .font(.system(size: 12, weight: .medium))
                            if groupByCompound {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                            }
                        }
                        .foregroundColor(groupByCompound ? .blue : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(groupByCompound ? Color.blue.opacity(0.12) : Color(.systemGray6))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(groupByCompound ? Color.blue : Color(.systemGray4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(groupByCompound
                        ? "Group subtasks, on. Tap to show flat list."
                        : "Group subtasks, off. Tap to group subtasks under parents.")
                    .accessibilityAddTraits(.isToggle)
                    Spacer()
                }
            }
        }
    }

    /// LibraryFilter cases visible in this wizard step. Excludes
    /// `.fromParents` for child timeframes that have no parents.
    /// `.fromBoard` is always shown (no timeframe gating).
    private var visibleFilterTabs: [LibraryFilter] {
        let hasParents = !(parentTimeframesByChild[currentTimeframe] ?? []).isEmpty
        return LibraryFilter.allCases.filter { $0 != .fromParents || hasParents }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if activeFilter == .fromBoard {
            fromBoardList
        } else if visibleTasks.isEmpty && visibleComposites.isEmpty {
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

    /// `From a board…` branch — picker when no source picked, grid
    /// when one is. Mirrors the web wizard's `from-board` routing.
    @ViewBuilder
    private var fromBoardList: some View {
        if let pickedId = pickedSourceBoardId,
           let sourceBoard = sourceBoardsVM.eligibleBoards.first(where: { $0.id == pickedId }) {
            FromBoardGridView(
                vm: sourceBoardsVM,
                sourceBoard: sourceBoard,
                userId: userId,
                selectedTaskIds: selectedTaskIds,
                copiedTaskIds: copiedTaskIds,
                onToggleSelection: { taskId in toggleSelection(taskId) },
                onCopyTask: { task in copyingTask = task },
                onAddAllSubtasks: { _, leafTaskIds in
                    // Grid passes its already-resolved leaf ids (from
                    // the SOURCE board's compound, which may not be in
                    // the wizard's library map). Don't fall back to a
                    // local lookup — it would silently no-op when the
                    // compound isn't present in `library`.
                    for leafId in leafTaskIds where !selectedTaskIds.contains(leafId) {
                        toggleSelection(leafId)
                    }
                },
                onOpenInLibrary: { taskId in
                    openedTaskInLibrary = TaskIdItem(id: taskId)
                },
                onChangeSource: { pickedSourceBoardId = nil },
                onTaskCreated: { task in
                    // Derived counter — auto-add to selection.
                    if !selectedTaskIds.contains(task.id) {
                        toggleSelection(task.id)
                    }
                }
            )
        } else {
            FromBoardPickerView(
                vm: sourceBoardsVM,
                userId: userId,
                onPickBoard: { boardId in pickedSourceBoardId = boardId }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            if !trimmedQuery.isEmpty {
                Text("No tasks match \"\(searchQuery)\".")
            } else if activeFilter == .fromParents {
                Text("No parent boards found.")
                    .fontWeight(.medium)
                Text("Create a longer-window board first (weekly/monthly/yearly) to surface its tasks here.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
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
                Button("Open in library", systemImage: "info.circle") {
                    openedTaskInLibrary = TaskIdItem(id: task.id)
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
            // Bug #85 — read from effective map so pending compounds show
            // a real count, not 0.
            let n = effectiveChildrenByCompound[task.id]?.count ?? 0
            if n == 0 { return "" }
            return "\(n) step\(n == 1 ? "" : "s")"
        default:
            return ""
        }
    }
}
