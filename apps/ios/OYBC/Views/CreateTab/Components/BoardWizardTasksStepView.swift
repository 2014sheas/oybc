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
///   - `RisoLibrarySheetView`      — dashed entry button + bottom sheet (owns search,
///                                    filters, derive, from-a-board, compound expand)
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

    // MARK: - Internal state

    /// Drives the task-detail sheet opened from a library row's "Open in library".
    @State private var openedTaskInLibrary: TaskIdItem? = nil

    /// From-a-board picker/copy state (the picker + grid live in the library sheet;
    /// the source VM and copy sheet are owned here so they survive sheet dismissal).
    @State private var sourceBoardsVM = SourceBoardsViewModel()
    @State private var pickedSourceBoardId: String? = nil
    @State private var copiedTaskIds: Set<String> = []
    @State private var copyingTask: OYBC.Task? = nil

    // MARK: - Derived

    /// Bug #85 — Effective task pool for BROWSE surfaces (the "add from
    /// library" sheet + compound autocomplete): the draft-filtered
    /// `browsableTasks` merged with this session's in-memory pending tasks.
    /// Uses `browsableTasks` (not `libraryTasks`) so wizard-born tasks saved
    /// onto OTHER drafts don't reappear in the picker; the current session's
    /// pending tasks are still merged in so a task you just added is findable.
    /// Placement RESOLUTION (`effectiveTaskById`, `buildWizardPlacement`)
    /// keeps using the full `libraryTasks` so a resumed draft still renders
    /// its own (draft-hidden) tasks.
    private var effectiveAllTasks: [Task] {
        guard let pending = pendingTasks, !pending.isEmpty else {
            return library.browsableTasks
        }
        var seen = Set(library.browsableTasks.map { $0.id })
        var combined = library.browsableTasks
        for payload in pending.values {
            if !seen.contains(payload.task.id) {
                combined.append(payload.task)
                seen.insert(payload.task.id)
            }
        }
        return combined
    }

    private var selectedCount: Int { selectedTaskIds.count }
    private var isCountSatisfied: Bool { selectedCount >= tasksRequired }
    private var isCenterSatisfied: Bool {
        if !centerTaskMode { return true }
        guard let id = centerTaskId else { return false }
        return selectedTaskIds.contains(id)
    }
    private var canAdvance: Bool { isCountSatisfied && isCenterSatisfied }

    /// taskId → count of distinct boards it's placed on (library usage hint).
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

    /// Whether the current timeframe has parent timeframes (drives the
    /// "From parent boards" filter chip's visibility in the library sheet).
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

                    // Special-type panel — pass effectiveAllTasks so the
                    // inline compound builder can autocomplete against live
                    // + pending tasks without a separate GRDB fetch.
                    RisoSpecialTaskPanel(
                        userId: userId,
                        defaultTimeframe: currentTimeframe,
                        defaultStartDate: currentStartDate,
                        defaultEndDate: currentEndDate,
                        taskLibrary: effectiveAllTasks,
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
                    onRemove: { taskId in toggleSelection(taskId) },
                    centerTaskMode: centerTaskMode,
                    centerTaskId: centerTaskId,
                    onSetCenter: { taskId in
                        // Toggle: tapping the marked task again clears it.
                        centerTaskId = (centerTaskId == taskId) ? nil : taskId
                    }
                )
            }
            .padding(Riso.gutter)
        }
        .background(RisoPaperBackground())
        .safeAreaInset(edge: .bottom) {
            footer
        }
        // Task detail sheet (opened from a library row's "Open in library").
        .sheet(item: $openedTaskInLibrary) { item in
            TaskDetailSheetView(
                taskId: item.id,
                onClose: { openedTaskInLibrary = nil },
                onOpenBoard: { _ in openedTaskInLibrary = nil }
            )
        }
        // Copy sheet for From-a-board.
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
            // Real disabled state (not just .allowsHitTesting) so VoiceOver
            // reports + blocks it; dim cue retained.
            .opacity(canAdvance ? 1 : 0.45)
            .disabled(!canAdvance)
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

    // MARK: - Selection helper

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
