import SwiftUI

/// A transient toast shown above the wizard footer (staged-save / discard /
/// remove), with an optional Undo affordance. Auto-dismisses after 6s.
private struct PoolEditToast: Identifiable {
    let id = UUID()
    let text: String
    let undo: (() -> Void)?
}

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
    /// Insertion order of the pool (from `BoardWizardViewModel.poolOrder`).
    /// Passed down so the list renders in order rather than sorting.
    let poolOrder: [String]
    /// Staged inline edits (from `BoardWizardViewModel.stagedEdits`), overlaid
    /// onto `effectiveTaskById` so rows + preview reflect unsaved edits.
    var stagedEdits: [String: TaskEditPatch] = [:]

    /// Stage an inline edit; returns the previous patch (or nil) for the Save
    /// toast's Undo. Routes to `BoardWizardViewModel.stageEdit`.
    var onStageEdit: (_ patch: TaskEditPatch, _ taskId: String) -> TaskEditPatch? = { _, _ in nil }
    /// Undo a staged edit. Routes to `BoardWizardViewModel.revertEdit`.
    var onRevertEdit: (_ taskId: String, _ previous: TaskEditPatch?) -> Void = { _, _ in }
    /// Restore a removed task to the pool at its original index (re-adding its
    /// pending payload when non-nil). Routes to
    /// `BoardWizardViewModel.restoreToPool`.
    var onRestoreToPool: (_ taskId: String, _ index: Int, _ payload: PendingTaskPayload?) -> Void = { _, _, _ in }

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

    /// Toggles a task's board selection. MUST route through the wizard's
    /// `toggleTaskSelection` so deselecting a newly-created task also purges
    /// its deferred (Bug #85) `pendingTasks` payload — otherwise the removed
    /// task is still written to the DB on save and leaks into the library.
    let onToggleSelection: (_ taskId: String) -> Void

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

    // Inline task editor (PR 1) — at most one row open at a time.
    @State private var editingTaskId: String? = nil
    @State private var editDraft = TaskEditPatch(title: "")
    /// The draft as it was when the editor opened — used to tell whether the
    /// user actually changed anything on Discard (a fresh `TaskEditPatch(from:)`
    /// never carries compound children, so comparing against it falsely reports
    /// "changed" for every compound).
    @State private var editBaseline = TaskEditPatch(title: "")
    @State private var toast: PoolEditToast? = nil
    @State private var toastDismiss: _Concurrency.Task<Void, Never>? = nil

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

    /// Unfiltered (non-browsable-filtered) task pool + this session's pending
    /// tasks, used ONLY as the counter-link suggestion pool passed to
    /// `RisoSpecialTaskPanel`. Unlike `effectiveAllTasks` (which is built
    /// from `browsableTasks` for pickers/autocomplete), this uses
    /// `library.libraryTasks` so goal-less hub-born counters — which
    /// `computeBrowsableTasks` excludes — still surface a link suggestion
    /// in the wizard. Compound-child pickers must keep using
    /// `effectiveAllTasks`; only the suggestion pool changes here.
    private var effectiveSuggestionPool: [Task] {
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
        // Overlay staged inline edits so rows + preview reflect unsaved changes
        // (the DB is untouched until board create).
        for (id, patch) in stagedEdits {
            if let base = by[id] { by[id] = patch.applied(to: base) }
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
        ScrollViewReader { proxy in
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
                            onLibraryReloadRequested: onLibraryReloadRequested,
                            // Library-poll (owner decision 2026-07-21): the
                            // same browsable+pending pool the compound
                            // autocomplete + library sheet already use.
                            // Matches are guaranteed unselected, so reusing
                            // `toggleSelection` (add-only in this context)
                            // is safe and keeps the Bug #85 pending-purge
                            // semantics on any future deselect.
                            libraryTasks: effectiveAllTasks,
                            selectedIds: selectedTaskIds,
                            onExistingTaskPicked: { task in
                                toggleSelection(task.id)
                            }
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
                        suggestionPool: effectiveSuggestionPool,
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
                    orderedTaskIds: poolOrder,
                    effectiveTaskById: effectiveTaskById,
                    effectiveChildrenByCompound: effectiveChildrenByCompound,
                    isRecurring: isRecurring,
                    onRemove: { taskId in removeWithUndo(taskId) },
                    centerTaskMode: centerTaskMode,
                    centerTaskId: centerTaskId,
                    onSetCenter: { taskId in
                        // Toggle: tapping the marked task again clears it.
                        centerTaskId = (centerTaskId == taskId) ? nil : taskId
                    },
                    onEdit: { taskId in openEditor(taskId) },
                    sharedCountByTaskId: taskBoardCounts,
                    editingTaskId: editingTaskId,
                    editor: { task in
                        AnyView(
                            RisoPoolRowEditorView(
                                taskType: task.type,
                                draft: $editDraft,
                                onSave: { saveEdit(task) },
                                onDiscard: { discardEdit(task) }
                            )
                        )
                    }
                )
            }
            .padding(Riso.gutter)
            }
            .onChange(of: editingTaskId) { _, newValue in
                guard let id = newValue else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
        }
        .background(RisoPaperBackground())
        .safeAreaInset(edge: .bottom) {
            footer
        }
        .overlay(alignment: .bottom) {
            if let toast { toastOverlay(toast) }
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

    // MARK: - Inline editor (PR 1)

    /// Open the inline editor for a row. Closes any other open editor (only one
    /// at a time). Seeds the draft from the effective (staged-overlaid) task.
    private func openEditor(_ taskId: String) {
        guard let task = effectiveTaskById[taskId] else { return }
        let draft: TaskEditPatch
        if let staged = stagedEdits[taskId] {
            // Reopen: reuse the staged patch verbatim. The effectiveTaskById
            // overlay carries scalar edits (title/counting) but NOT compound
            // child edits, so reconstructing children here would silently revert
            // a prior step rename/add/delete.
            draft = staged
        } else {
            var d = TaskEditPatch(from: task)
            if task.type == .compound {
                // First open: seed step rows from the compound's links (in
                // childIndex order), resolving each child Task.
                let links = (effectiveChildrenByCompound[taskId] ?? [])
                    .sorted { $0.childIndex < $1.childIndex }
                d.children = links.compactMap { link in
                    effectiveTaskById[link.childTaskId].map { ChildPatch(from: $0) }
                }
            }
            draft = d
        }
        editDraft = draft
        editBaseline = draft
        editingTaskId = taskId
    }

    /// Save the edit into the wizard's staged map (no DB write) and toast with
    /// undo to the previous snapshot.
    private func saveEdit(_ task: OYBC.Task) {
        let previous = onStageEdit(editDraft, task.id)
        editingTaskId = nil
        // "edited" (not "updated") — the change is captured for this board's
        // creation, not yet written to the DB; don't overclaim persistence.
        showToast("Task edited") { onRevertEdit(task.id, previous) }
    }

    /// Discard the edit. If the draft differs from the task, toast "Edit
    /// discarded" with undo that reopens the row with the typing intact.
    private func discardEdit(_ task: OYBC.Task) {
        // Compare against the draft as it opened — not a fresh TaskEditPatch(from:),
        // which never carries compound children and so always reads as "changed".
        let changed = editDraft != editBaseline
        let keptDraft = editDraft
        editingTaskId = nil
        if changed {
            showToast("Edit discarded") {
                editDraft = keptDraft
                editingTaskId = task.id
            }
        }
    }

    /// Remove a row immediately, closing its editor if open, and toast with
    /// undo that restores it at its original index.
    private func removeWithUndo(_ taskId: String) {
        let index = poolOrder.firstIndex(of: taskId) ?? poolOrder.count
        let name = effectiveTaskById[taskId]?.title ?? "task"
        // Capture the deferred (Bug #85) pending payload BEFORE removal purges
        // it, so Undo can restore it — otherwise the restored id can't resolve
        // and the board under-fills. nil for library tasks.
        let payload = pendingTasks?[taskId]
        if editingTaskId == taskId { editingTaskId = nil }
        toggleSelection(taskId)
        showToast("Removed \"\(name)\"") { onRestoreToPool(taskId, index, payload) }
    }

    private func showToast(_ text: String, undo: (() -> Void)?) {
        toastDismiss?.cancel()
        toast = PoolEditToast(text: text, undo: undo)
        toastDismiss = _Concurrency.Task {
            try? await _Concurrency.Task.sleep(nanoseconds: 6_000_000_000)
            if !_Concurrency.Task.isCancelled { toast = nil }
        }
    }

    private func toastOverlay(_ toast: PoolEditToast) -> some View {
        HStack(spacing: 10) {
            Text(toast.text)
                .font(.risoHead(13, .extraBold))
                .foregroundStyle(Color.risoPaper)
                .fixedSize(horizontal: false, vertical: true)
            if let undo = toast.undo {
                Spacer(minLength: 8)
                Button {
                    toastDismiss?.cancel()
                    self.toast = nil
                    undo()
                } label: {
                    Text("UNDO")
                        .font(.risoBody(11.5, .extraBold))
                        .tracking(0.6)
                        .foregroundStyle(Color.risoInk)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.risoPaper))
                        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoGreen))
        .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
        .risoHardShadow(Riso.Shadow.card)
        .padding(.horizontal, 18)
        .padding(.bottom, 112)
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
        // Delegate to the wizard VM: it updates selection, clears the center
        // mark, AND purges the deferred `pendingTasks` payload on deselect.
        // The old local-only version skipped the pending purge, so removed
        // tasks were persisted as orphans and leaked into the library.
        onToggleSelection(taskId)
    }
}
