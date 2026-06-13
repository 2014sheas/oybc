import SwiftUI

/// BoardWizardTasksStepView — Step 2 of the board-creation wizard (Riso redesign).
///
/// This is a PRESENTATION RESTRUCTURE of the pre-Phase 3b implementation.
/// All business logic (selection validation, pending-task merges, derive,
/// from-a-board, copy, compound expand, library feed) is preserved intact;
/// only the visual layer is rebuilt in the Riso design language.
///
/// Layout (top to bottom, per README §3 + screenshot 04):
///   1. Pool header card  — "YOUR TASK POOL" kicker, N/required, progress bar, model note.
///   2. "ADD TASKS" section — quick-add row + special-type panel button.
///   3. Library entry button (dashed) → bottom sheet at .fraction(0.76).
///   4. Pool list — Riso rows for each selected task.
///   5. Footer — Riso Back + Next (Next disabled when !canAdvance).
///
/// Sub-views (separate files):
///   - `RisoTasksPoolHeaderView`   — pool header card
///   - `RisoQuickAddRowView`       — text input + red Add button
///   - `RisoSpecialTaskPanel`      — collapsed/expanded type-specific panel
///   - `RisoLibrarySheetView`      — dashed entry button + bottom sheet
///   - `RisoPoolListView`          — selected task rows + empty state
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
    let isRecurring: Bool

    /// When true, every selected row shows a star radio for picking the center task.
    let centerTaskMode: Bool

    /// The currently-marked center task id, or `nil` if none picked.
    @Binding var centerTaskId: String?

    /// Authenticated user id used by the inline new-task sheet.
    let userId: String

    /// Phase 6.1: current wizard timeframe. Drives the "From parent boards" chip.
    let currentTimeframe: Timeframe

    /// Phase 6.Y — resolved start/end dates the wizard will write on the board.
    var currentStartDate: String? = nil
    var currentEndDate: String? = nil

    /// Fired after a non-composite task is created from the sheet.
    let onTaskCreated: (_ taskId: String, _ title: String, _ type: String) -> Void

    /// Fired after a composite task is created from the sheet.
    let onCompositeCreated: (OYBC.Task) -> Void

    /// Called after either creation callback so the parent's library VM can refresh.
    let onLibraryReloadRequested: () -> Void

    /// Bug #85 — Called alongside `onTaskCreated` when a task is created in
    /// deferred-persist mode. Nil disables deferred mode (immediate persist).
    var onPendingCreated: ((_ payload: PendingTaskPayload) -> Void)? = nil

    /// Bug #85 — In-memory pending tasks owned by the wizard. Keyed by task.id.
    var pendingTasks: [String: PendingTaskPayload]? = nil

    /// Navigates to the previous wizard step.
    let onBack: () -> Void

    /// Navigates to the next wizard step. Disabled when validation fails.
    let onNext: () -> Void

    // MARK: - Internal state (PRESERVED from pre-3b — all logic kept intact)

    @State private var searchQuery: String = ""
    @State private var activeFilter: LibraryFilter = .all
    @State private var expandedCompositeId: String? = nil
    @State private var isSheetPresented: Bool = false
    @State private var groupByCompound: Bool = true

    /// Phase 6.1: parent-board tasks for the "From parent boards" filter.
    @State private var parentTasksVM = ParentBoardTasksViewModel()

    /// Derive-smaller state (PRESERVED — existing saveDerivedCounter logic).
    @State private var derivingFromTask: OYBC.Task? = nil
    @State private var deriveMaxCountInput: String = ""

    @State private var openedTaskInLibrary: TaskIdItem? = nil

    // From-a-board state (PRESERVED)
    @State private var sourceBoardsVM = SourceBoardsViewModel()
    @State private var pickedSourceBoardId: String? = nil
    @State private var copiedTaskIds: Set<String> = []
    @State private var copyingTask: OYBC.Task? = nil

    // MARK: - Derived (ALL PRESERVED — no changes)

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matches(_ title: String) -> Bool {
        trimmedQuery.isEmpty || title.lowercased().contains(trimmedQuery)
    }

    private func notExpired(_ t: Task) -> Bool {
        !TasksTabViewModel.isTaskExpired(t)
    }

    private func notGroupedChild(_ t: Task) -> Bool {
        guard groupByCompound else { return true }
        return !library.childTaskIds.contains(t.id)
    }

    /// Bug #85 — Effective task pool: live library tasks merged with any in-memory pending tasks.
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
        case .all:      pool = effectiveAllTasks.filter { notExpired($0) && notGroupedChild($0) && $0.type != .compound }
        case .normal:   pool = effectiveAllTasks.filter { notExpired($0) && notGroupedChild($0) && $0.type == .normal }
        case .counting: pool = effectiveAllTasks.filter { notExpired($0) && notGroupedChild($0) && $0.type == .counting }
        case .compound: pool = []
        case .fromParents: pool = parentTasksVM.tasks.filter { notExpired($0) }
        case .fromBoard: pool = []
        }
        return pool.filter { matches($0.title) }
    }

    private var visibleComposites: [OYBC.Task] {
        switch activeFilter {
        case .all, .compound:
            return effectiveAllTasks
                .filter { notExpired($0) && $0.type == .compound }
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

    private var countSuffix: String { isRecurring ? " min" : "" }

    // MARK: - Usage / leaf data (PRESERVED)

    private var taskBoardCounts: [String: Int] {
        var buckets: [String: Set<String>] = [:]
        for bt in library.allLibraryBoardTasks {
            buckets[bt.taskId, default: []].insert(bt.boardId)
        }
        return buckets.mapValues { $0.count }
    }

    /// Bug #85 — Effective compound-children map merging live + pending.
    private var effectiveChildrenByCompound: [String: [CompoundChild]] {
        guard let pending = pendingTasks, !pending.isEmpty else {
            return library.compoundChildrenByCompound
        }
        var merged = library.compoundChildrenByCompound
        for payload in pending.values where !payload.childLinks.isEmpty {
            merged[payload.task.id] = payload.childLinks
        }
        return merged
    }

    /// Bug #85 — Per-id task lookup including pending parent + child tasks.
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

    private var compositeLeafPreviews: [String: LeafPreview] {
        let taskById = effectiveTaskById
        var out: [String: LeafPreview] = [:]
        for (compoundId, children) in effectiveChildrenByCompound {
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

    private func leafTasks(for compoundId: String) -> [OYBC.Task] {
        let children = effectiveChildrenByCompound[compoundId] ?? []
        let taskById = effectiveTaskById
        return children.compactMap { child -> OYBC.Task? in
            guard let task = taskById[child.childTaskId] else { return nil }
            if task.type == .compound { return nil }
            return task
        }
    }

    private var visibleFilterTabs: [LibraryFilter] {
        let hasParents = !(parentTimeframesByChild[currentTimeframe] ?? []).isEmpty
        return LibraryFilter.allCases.filter { $0 != .fromParents || hasParents }
    }

    private var hasParentBoards: Bool {
        !(parentTimeframesByChild[currentTimeframe] ?? []).isEmpty
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 1. Pool header card
                RisoTasksPoolHeaderView(
                    selectedCount: selectedCount,
                    tasksRequired: tasksRequired,
                    isRecurring: isRecurring,
                    centerTaskMode: centerTaskMode,
                    centerSatisfied: isCenterSatisfied
                )

                // 2. ADD TASKS section
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add tasks")
                        .risoSectionLabel()

                    // Quick-add card (wraps input + button)
                    VStack(spacing: 0) {
                        RisoQuickAddRowView(
                            userId: userId,
                            defaultTimeframe: currentTimeframe,
                            defaultStartDate: currentStartDate,
                            defaultEndDate: currentEndDate,
                            onTaskCreated: { taskId, title, type in
                                onTaskCreated(taskId, title, type)
                            },
                            onPendingCreated: onPendingCreated,
                            onLibraryReloadRequested: onLibraryReloadRequested
                        )
                    }
                    .padding(12)
                    .risoCard(fill: .risoPaper2)
                    .risoHardShadow(Riso.Shadow.small)

                    // Special-type panel
                    RisoSpecialTaskPanel(
                        userId: userId,
                        defaultTimeframe: currentTimeframe,
                        defaultStartDate: currentStartDate,
                        defaultEndDate: currentEndDate,
                        onTaskCreated: { taskId, title, type in
                            onTaskCreated(taskId, title, type)
                        },
                        onCompositeCreated: { ct in
                            onCompositeCreated(ct)
                        },
                        onPendingCreated: onPendingCreated,
                        onLibraryReloadRequested: onLibraryReloadRequested
                    )
                }

                // 3. Library entry button (dashed) → bottom sheet
                RisoLibrarySheetView(
                    library: library,
                    selectedTaskIds: selectedTaskIds,
                    taskBoardCounts: taskBoardCounts,
                    effectiveAllTasks: effectiveAllTasks,
                    effectiveChildrenByCompound: effectiveChildrenByCompound,
                    effectiveTaskById: effectiveTaskById,
                    hasParentBoards: hasParentBoards,
                    currentTimeframe: currentTimeframe,
                    userId: userId,
                    defaultStartDate: currentStartDate,
                    defaultEndDate: currentEndDate,
                    onPendingCreated: onPendingCreated,
                    onLibraryReloadRequested: onLibraryReloadRequested,
                    onToggle: { taskId in toggleSelection(taskId) },
                    onTaskCreated: { taskId, title, type in
                        onTaskCreated(taskId, title, type)
                    },
                    sourceBoardsVM: sourceBoardsVM,
                    pickedSourceBoardId: $pickedSourceBoardId,
                    copiedTaskIds: copiedTaskIds,
                    onCopyTask: { task in copyingTask = task },
                    onOpenInLibrary: { taskId in openedTaskInLibrary = TaskIdItem(id: taskId) }
                )

                // 4. Pool list
                RisoPoolListView(
                    selectedTaskIds: selectedTaskIds,
                    effectiveTaskById: effectiveTaskById,
                    effectiveChildrenByCompound: effectiveChildrenByCompound,
                    isRecurring: isRecurring,
                    onRemove: { taskId in toggleSelection(taskId) }
                )
            }
            .padding(Riso.gutter)
        }
        .background(RisoPaperBackground())
        .safeAreaInset(edge: .bottom) {
            footer
        }
        .onAppear {
            parentTasksVM.reloadAsync(userId: userId, childTimeframe: currentTimeframe)
        }
        .onChange(of: currentTimeframe) { _, newTimeframe in
            parentTasksVM.reloadAsync(userId: userId, childTimeframe: newTimeframe)
            let newHasParents = !(parentTimeframesByChild[newTimeframe] ?? []).isEmpty
            if !newHasParents && activeFilter == .fromParents {
                activeFilter = .all
            }
        }
        // New task sheet (old sheet access path — kept for legacy callers)
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
        // Derive-smaller sheet (PRESERVED — same logic as pre-3b)
        .sheet(item: derivePickerItemBinding) { _ in
            deriveCounterSheet
        }
        // Task detail sheet (PRESERVED)
        .sheet(item: $openedTaskInLibrary) { item in
            TaskDetailSheetView(
                taskId: item.id,
                onClose: { openedTaskInLibrary = nil },
                onOpenBoard: { _ in openedTaskInLibrary = nil }
            )
        }
        // Copy sheet for From-a-board (PRESERVED)
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

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            RisoButton(title: "Back", kind: .neutral, fullWidth: true) {
                onBack()
            }
            RisoButton(title: "Next ›", kind: .primary, fullWidth: true) {
                onNext()
            }
            .opacity(canAdvance ? 1 : 0.45)
            .allowsHitTesting(canAdvance)
        }
        .padding(.horizontal, Riso.gutter)
        .padding(.vertical, 16)
        .background(
            Color.risoPaper
                .overlay(
                    Rectangle()
                        .fill(Color.risoInk)
                        .frame(height: Riso.Keyline.container),
                    alignment: .top
                )
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Derive sheet (PRESERVED verbatim from pre-3b)

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

    // TODO(riso 3b-follow-up): Shared-counter-linked derive — currently creates a
    // standalone derived counter. The full linked path (↔ source, shared counters
    // Phase 4) is deferred. Keep current standalone behavior.
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
                // Swallow on background; user can retry.
            }
        }
    }

    // MARK: - Selection helper (PRESERVED verbatim)

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
}
