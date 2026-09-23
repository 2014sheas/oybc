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
/// All business logic (selection validation, pending-task merges,
/// compound expand, library feed) is preserved intact;
/// only the visual layer is rebuilt in the Riso design language.
///
/// Layout (top to bottom — Board Sources P2, docs/BOARD_SOURCES.md
/// §Surfaces item 1 / handoff frame 2a):
///   1. Pool header card — capacity/required, progress bar, model note.
///   2. "ADD TASKS" section — quick-add row + special-type panel button.
///   3. "Add from a pool or board" dashed row → the source sheet (2c/5c).
///   4. Library entry button (dashed) → bottom sheet at .fraction(0.76).
///   5. "On your board" — SOURCE rows (expandable range/filter/member
///      panels) + hand-added task rows.
///   6. Red "! Add N more" gate line (only when capacity is short).
///   7. Footer — Riso Back + Next (Next disabled when !canAdvance).
///
/// Sub-views (separate files):
///   - `RisoTasksPoolHeaderView`    — pool header card (capacity-based)
///   - `RisoSourceRowView`          — one pulled source row + expanded panel
///   - `RisoSourcePickerSheetView`  — "Add from a pool or board" sheet
///   - `RisoQuickAddRowView`        — text input + red Add button
///   - `RisoSpecialTaskPanel`       — collapsed/expanded type-specific panel
///   - `RisoLibrarySheetView`       — dashed entry button + bottom sheet (owns search,
///                                     filters, compound expand)
///   - `RisoMemberRuleRowView`      — one member row inside an expanded source
///                                     panel (§Member rules controls)
///   - `RisoPoolListView`           — source + hand-added rows + empty state
struct BoardWizardTasksStepView: View {

    /// Renders the "Add from your library" dashed entry row + bottom sheet.
    ///
    /// Set to false for UX testing (owner, 2026-09-17) — the row was mostly
    /// taking up space next to quick-add's search and the "Add a pool or
    /// board" sheet. Every code path behind it is intact; flip this to
    /// bring it back.
    ///
    /// Web twin: `LIBRARY_ENTRY_ENABLED` in `BoardWizardTasksStep.tsx`.
    static let libraryEntryEnabled = false


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
    ///
    /// Returns `false` when the VM REFUSED the toggle and nothing changed
    /// (the last included part of a Split-up compound); `true` otherwise.
    let onToggleSelection: (_ taskId: String) -> Bool

    /// Fired after a non-compound task is created from the sheet.
    let onTaskCreated: (_ taskId: String, _ title: String, _ type: String) -> Void

    /// Fired after a compound task is created from the sheet.
    let onCompoundCreated: (OYBC.Task) -> Void

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

    // MARK: - Sources (Board Sources P2, docs/BOARD_SOURCES.md)

    /// The user's non-deleted pools — the source sheet's POOLS section.
    /// Loaded and owned by the container (`BoardWizardView`), mirroring
    /// how `library` is threaded through.
    var pools: [Pool] = []
    /// Pulled sources in row order (`BoardWizardViewModel.sources`).
    var sources: [BoardSource] = []
    /// Per-source display/supply cache (`supplyInfoBySourceId`).
    var supplyInfoBySourceId: [String: WizardSourceSupply] = [:]
    /// Expanded row state (`expandedSourceIds` — UI-only, never persisted).
    var expandedSourceIds: Set<String> = []
    /// Post-exclude/post-filter available count per source — the range
    /// slider's N. Routes to `BoardWizardViewModel.availableCount(forSourceId:)`.
    var availableCountForSource: (_ sourceId: String) -> Int = { _ in 0 }
    /// The header/gate capacity (`BoardWizardViewModel.sourceCapacity`) —
    /// sum of source maxes + hand-added, deduped.
    var capacity: Int = 0
    /// The source sheet's BOARDS rows (active boards + counts) — loaded
    /// off-main by the container alongside `loadPools()` (review finding:
    /// the resolution walks every active board and must never run
    /// synchronously on appear).
    var sheetBoardEntries: [RisoSourcePickerSheetView.BoardEntry] = []
    var onToggleSourceExpanded: (_ sourceId: String) -> Void = { _ in }
    var onRemoveSource: (_ sourceId: String) -> Void = { _ in }
    var onSetSourceFilter: (_ sourceId: String, _ filter: BoardSource.Filter) -> Void = { _, _ in }
    var onSetSourceRange: (_ sourceId: String, _ min: Int, _ max: Int?) -> Void = { _, _, _ in }
    var onToggleSourceExclude: (_ sourceId: String, _ taskId: String) -> Void = { _, _ in }
    var onPullPoolSource: (_ pool: Pool) -> Void = { _ in }
    var onPullBoardSource: (_ boardId: String) -> Void = { _ in }
    /// The repeating board under edit (`BoardWizardViewModel.editingTemplateId`),
    /// or nil for every other session. Only used to append the
    /// `WizardEditModeNote` line to the remove-source confirm, so the dialog
    /// can't read as if it were changing the board already on the Boards tab.
    var editingTemplateId: String? = nil

    // MARK: - Member rules (B3, docs/BOARD_SOURCES.md §Member rules)

    /// Dice level per HAND-ADDED counting task
    /// (`BoardWizardViewModel.manualTaskVary`). Absent ids are `.off`.
    var manualTaskVary: [String: VaryLevel] = [:]
    /// Sets a hand-added counting task's dice level. nil ⇒ no dice on the
    /// hand-added rows (a read-only mount).
    var onSetManualVary: ((_ taskId: String, _ level: VaryLevel) -> Void)? = nil
    var onSetMemberTarget: (_ sourceId: String, _ taskId: String, _ target: Int?) -> Void = { _, _, _ in }
    var onSetMemberVary: (_ sourceId: String, _ taskId: String, _ level: VaryLevel) -> Void = { _, _, _ in }
    var onSetMemberSplit: (_ sourceId: String, _ taskId: String, _ split: Bool) -> Void = { _, _, _ in }
    var onSetPartExcluded: (_ sourceId: String, _ taskId: String, _ childId: String, _ excluded: Bool) -> Void = { _, _, _, _ in }
    var onSetPartTarget: (_ sourceId: String, _ taskId: String, _ childId: String, _ target: Int?) -> Void = { _, _, _, _ in }
    var onSetPartVary: (_ sourceId: String, _ taskId: String, _ childId: String, _ level: VaryLevel) -> Void = { _, _, _, _ in }

    // MARK: - Internal state

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

    // Board Sources P2 — "Add from a pool or board" sheet.
    @State private var showSourceSheet = false

    /// The pulled source a ✕ (or a sheet un-toggle) asked to remove while it
    /// still carried configuration — the remove-confirm's subject (owner
    /// ruling 2026-09-19). nil whenever no confirm is up; an UNTOUCHED source
    /// never lands here, it removes on the spot.
    @State private var pendingSourceRemoval: BoardSource? = nil

    /// A removal requested from INSIDE the source sheet, parked until that
    /// sheet has finished dismissing (see `requestRemoveSource(_:fromSheet:)`).
    @State private var sourceRemovalAfterSheetDismiss: BoardSource? = nil

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

    private var isCountSatisfied: Bool { capacity >= tasksRequired }

    /// Counter-family exclusivity (2026-09-08) — collisions visible in
    /// the wizard pool, for the "shares a counter with 'X' · one per
    /// board" row hints. Computed over the staged-overlaid task map so
    /// renames show. Web twin: `computeCounterClashes`.
    /// §Member rules (B3) — the window a pulled counting target
    /// pro-rates AGAINST, and which planning mode applies. Both are built
    /// from props the step already takes; nothing new is threaded from
    /// the container for them. Web twin: `wizardWindow` / `planMode` in
    /// `BoardWizardTasksStep.tsx`.
    private var wizardWindow: BoardSources.BoardWindow {
        BoardSources.BoardWindow(
            timeframe: currentTimeframe,
            startDate: currentStartDate,
            endDate: currentEndDate
        )
    }

    private var planMode: BoardSources.PlanMode { isRecurring ? .recurring : .oneOff }

    private var counterClashByTaskId: [String: String] {
        let byId = effectiveTaskById
        let familyMap = BoardSources.buildCounterFamilyMap(byId.values)
        var membersByFamily: [String: [String]] = [:]
        for id in selectedTaskIds {
            guard let fam = familyMap[id] else { continue }
            membersByFamily[fam, default: []].append(id)
        }
        var out: [String: String] = [:]
        for members in membersByFamily.values where members.count >= 2 {
            // Sorted so the "other" title is stable across launches (Set
            // iteration order isn't) — cosmetic determinism for 3+-member
            // families, matching web's insertion-order stability.
            let ordered = members.sorted()
            for id in ordered {
                guard let other = ordered.first(where: { $0 != id }) else { continue }
                out[id] = byId[other]?.title ?? "another task"
            }
        }
        return out
    }
    private var isCenterSatisfied: Bool {
        if !centerTaskMode { return true }
        guard let id = centerTaskId else { return false }
        return selectedTaskIds.contains(id)
    }
    private var canAdvance: Bool { isCountSatisfied && isCenterSatisfied }

    // Board Sources P2 — the core-setup chip strip / floor gate / "Start
    // every…" checkbox were REMOVED from this step (docs/BOARD_SOURCES.md
    // §Removed): core defaults now pre-pull as source rows, and the
    // Board-settings defaults sheet is the sole author surface.

    /// taskId → count of distinct boards it's placed on (library usage hint).
    private var taskBoardCounts: [String: Int] {
        var buckets: [String: Set<String>] = [:]
        for bt in library.allLibraryBoardTasks {
            buckets[bt.taskId, default: []].insert(bt.boardId)
        }
        return buckets.mapValues { $0.count }
    }

    /// Bug #85 / Inline Task Editing — effective compound-children map
    /// merging live + pending + staged child edits. Delegates to the shared
    /// `effectiveCompoundChildrenByCompound` (BoardWizardPersist.swift) so
    /// this view and the Step-3 preview (`BoardWizardPreviewStepView`) can
    /// never disagree about "how many sub-tasks does this compound have
    /// right now" — a staged add/remove/rename now shows up immediately in
    /// the pool-row subtitle instead of staying stale until Save.
    private var effectiveChildrenByCompound: [String: [CompoundChild]] {
        effectiveCompoundChildrenByCompound(
            library: library,
            pendingTasks: pendingTasks ?? [:],
            stagedEdits: stagedEdits
        )
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
        // Inline Task Editing — synthesize placeholder Task entries for
        // brand-new staged compound sub-tasks (no real Task row yet) so the
        // pool subtitle's "N with a goal" subcount can resolve their type via
        // the matching synthetic childTaskId `effectiveChildrenByCompound`
        // produces above.
        for (id, task) in stagedNewChildPlaceholders(userId: userId, stagedEdits: stagedEdits) {
            by[id] = task
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
                    capacity: capacity,
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
                        onCompoundCreated: { ct in
                            onCompoundCreated(ct)
                        },
                        onPendingCreated: onPendingCreated,
                        onLibraryReloadRequested: onLibraryReloadRequested
                    )
                }

                // 3. Add from a pool or board (Board Sources P2, frame 2a) —
                // dashed row styled like the library row; opens the sheet.
                sourceSheetEntry

                // 4. Library entry button (dashed) → bottom sheet.
                // HIDDEN for UX testing (owner, 2026-09-17): quick-add's
                // search and the "Add from a pool or board" sheet cover most of
                // what this did, and the dashed row was mostly taking up
                // space. All logic is kept — flip `libraryEntryEnabled` to
                // restore.
                if Self.libraryEntryEnabled {
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
                    onToggle: { taskId in toggleSelection(taskId) }
                )
                }

                // 5. Pool list
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
                    },
                    countOverride: capacity,
                    leadingRows: sourceRowsList,
                    counterClashByTaskId: counterClashByTaskId,
                    manualTaskVary: manualTaskVary,
                    onSetManualVary: onSetManualVary
                )

                // 6. Red gate line (frame 2a item 6) — only when short.
                if !isCountSatisfied {
                    Text("! Add \(tasksRequired - capacity) more")
                        .font(.risoBody(12, .extraBold))
                        .foregroundStyle(Color.risoRed)
                }
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
        // Board Sources P2 — the "Add from a pool or board" sheet (frames 2c/5c).
        //
        // `onDismiss` is where a sheet-originated remove-confirm is finally
        // presented: SwiftUI will not reliably present a confirmation dialog
        // from a host that is already presenting a sheet, and parking the
        // request here means the dialog goes up only once the sheet is
        // genuinely gone — no timer, no animation race.
        .sheet(isPresented: $showSourceSheet, onDismiss: {
            if let queued = sourceRemovalAfterSheetDismiss {
                sourceRemovalAfterSheetDismiss = nil
                pendingSourceRemoval = queued
            }
        }) {
            RisoSourcePickerSheetView(
                pools: pools,
                boards: sheetBoardEntries,
                pulledSourceIds: Set(sources.map { $0.sourceId }),
                onTogglePool: { pool in
                    // Un-toggling an already-pulled row is the same
                    // destructive act as the row's ✕ — same gate.
                    if let pulled = sources.first(where: { $0.sourceId == pool.id }) {
                        requestRemoveSource(pulled, fromSheet: true)
                    } else {
                        onPullPoolSource(pool)
                    }
                },
                onToggleBoard: { boardId in
                    if let pulled = sources.first(where: { $0.sourceId == boardId }) {
                        requestRemoveSource(pulled, fromSheet: true)
                    } else {
                        onPullBoardSource(boardId)
                    }
                }
            )
        }
        // The remove-source confirm (owner ruling 2026-09-19). A native
        // `.confirmationDialog` — the app's idiom for a two-choice
        // destructive confirm (`RecurringTemplateCardView`); the Riso kit's
        // own sheet exists for the counter-delete case because that one
        // LISTS members, which this doesn't.
        .confirmationDialog(
            pendingSourceRemoval.map { "Remove \"\(displayName(for: $0))\"?" } ?? "",
            isPresented: Binding(
                get: { pendingSourceRemoval != nil },
                set: { if !$0 { pendingSourceRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingSourceRemoval
        ) { source in
            Button("Remove", role: .destructive) {
                onRemoveSource(source.sourceId)
                pendingSourceRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingSourceRemoval = nil }
        } message: { source in
            Text(removeSourceMessage(for: source))
        }
    }

    // MARK: - Sources UI (Board Sources P2)

    /// The gate EVERY source-removal path goes through (the row's ✕ AND the
    /// source sheet's un-toggle): a source carrying configuration opens the
    /// confirm, an untouched one is removed on the spot.
    ///
    /// The default filter is KIND-SCOPED (`newSourceFilter(for:)`) — comparing
    /// against `BoardSource.init`'s `.all` (the legacy-decode default) would
    /// make every freshly pulled board look configured. Web twin:
    /// `sourceRemovalNeedsConfirm` in `wizardSourcesLogic.ts`.
    /// - Parameters:
    ///   - source: The row the ✕ (or a sheet un-toggle) named.
    ///   - fromSheet: True when the request came from inside the "Add from a
    ///     pool or board" sheet. A confirmation dialog cannot be reliably
    ///     presented from a host that is already presenting that sheet — the
    ///     usual result is that nothing appears and the dialog pops later,
    ///     orphaned — so the request is parked in
    ///     `sourceRemovalAfterSheetDismiss` and the sheet is closed; the
    ///     sheet's `onDismiss` then raises the dialog. The person also ends
    ///     up looking at the row they are about to lose, which is the better
    ///     read anyway. The UNCONFIGURED path is untouched: it removes on the
    ///     spot and leaves the sheet open, so un-toggling several untouched
    ///     sources in one visit still works.
    private func requestRemoveSource(_ source: BoardSource, fromSheet: Bool = false) {
        guard BoardSources.sourceHasConfiguration(
            source,
            defaultFilter: BoardWizardViewModel.newSourceFilter(for: source.kind),
            seededTargetByTaskId: seededTargets(for: source)
        ) else {
            onRemoveSource(source.sourceId)
            return
        }
        if fromSheet {
            sourceRemovalAfterSheetDismiss = source
            showSourceSheet = false
        } else {
            pendingSourceRemoval = source
        }
    }

    /// What the one-off prefill would seed for this source RIGHT NOW — the
    /// input that keeps the remove gate from mistaking a machine-written
    /// target for configuration (amended ruling 2026-09-23).
    ///
    /// Empty unless the prefill itself would run: a `.board` source on a
    /// ONE-OFF wizard (`prefillRemainingTargets` guards on
    /// `editingTemplateId == nil, !isRecurring` and is called from
    /// `pullBoard` alone). A pool source and every repeating session seed
    /// nothing, so every stored target there is hand-set by definition.
    ///
    /// Recomputed per call rather than remembered from the pull, so an input
    /// that has moved since makes the recomputed seed differ and the rule
    /// read as configured. Known cases, all erring the same safe way (ask
    /// rather than discard silently):
    ///
    /// - the wizard's TIMEFRAME changed after the pull — the person did
    ///   change something, so asking is right;
    /// - a RESUMED one-off draft, whose hydrated sources are never
    ///   re-seeded, or a supply re-fetch after a sync pull: both can move
    ///   `windowCountByTaskId` (it is live progress) while the stored target
    ///   stays, so an otherwise untouched source asks. A report of that is
    ///   this, not a bug.
    ///
    /// Reads the LIBRARY-backed task map, never `effectiveTaskById`: the
    /// prefill read persisted tasks (`database.fetchTasks(ids:)`), so an
    /// inline staged goal edit must not shift the recomputed seed — the
    /// staged edit lives on the task and survives the removal, so claiming
    /// "1 member rule" would be false.
    ///
    /// Web twin: `seededTargetsForRemoval` in `wizardSourcesLogic.ts`.
    private func seededTargets(for source: BoardSource) -> [String: Int] {
        guard !isRecurring, editingTemplateId == nil, source.kind == .board,
              let supply = supplyInfoBySourceId[source.sourceId] else { return [:] }
        var byId: [String: OYBC.Task] = [:]
        for task in library.libraryTasks { byId[task.id] = task }
        var tasksById: [String: BoardSources.SeededTargetTask] = [:]
        for id in supply.rawSupplyTaskIds {
            if let task = byId[id] { tasksById[id] = BoardSources.SeededTargetTask(task) }
        }
        return BoardSources.seededTargetsForSource(
            supplyTaskIds: supply.rawSupplyTaskIds,
            tasksById: tasksById,
            windowCountByTaskId: supply.windowCountByTaskId,
            sourceWindow: supply.sourceWindow,
            targetWindow: wizardWindow
        )
    }

    /// The pulled source's display name, for the confirm's title.
    private func displayName(for source: BoardSource) -> String {
        supplyInfoBySourceId[source.sourceId]?.displayName ?? "this source"
    }

    /// The confirm's body: what the removal costs, worded by the SHARED
    /// sentence builder so web and iOS can't drift, plus the edit-mode line
    /// while a repeating board is under edit (the same sentence
    /// `WizardEditModeNote` uses).
    private func removeSourceMessage(for source: BoardSource) -> String {
        let loss = BoardSources.removeSourceLossSentence(
            BoardSources.sourceConfiguration(
                source,
                defaultFilter: BoardWizardViewModel.newSourceFilter(for: source.kind),
                seededTargetByTaskId: seededTargets(for: source)
            )
        ) ?? ""
        guard editingTemplateId != nil else { return loss }
        return loss.isEmpty
            ? "Changes apply from the next board."
            : loss + " Changes apply from the next board."
    }

    /// Dashed "Add from a pool or board" entry row — styled like the library
    /// entry row (2pt dashed keyline, grid icon, trailing count badge =
    /// pools + active boards).
    private var sourceSheetEntry: some View {
        Button {
            showSourceSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
                Text("Add from a pool or board")
                    .font(.risoHead(13, .bold))
                    .foregroundStyle(Color.risoInk)
                Spacer()
                Text("\(pools.count + sheetBoardEntries.count)")
                    .font(.risoBody(11, .extraBold))
                    .foregroundStyle(Color.risoPaper)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.risoInk))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(
                        Color.risoInk.opacity(0.5),
                        style: StrokeStyle(lineWidth: Riso.Keyline.container, dash: [5, 4])
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add from a pool or board")
    }

    /// The source rows rendered at the top of the "On your board" list.
    private var sourceRowsList: AnyView? {
        guard !sources.isEmpty else { return nil }
        return AnyView(
            ForEach(sources, id: \.sourceId) { source in
                RisoSourceRowView(
                    source: source,
                    supply: supplyInfoBySourceId[source.sourceId]
                        ?? WizardSourceSupply(displayName: "", rawSupplyTaskIds: [], doneTaskIds: []),
                    availableCount: availableCountForSource(source.sourceId),
                    isExpanded: expandedSourceIds.contains(source.sourceId),
                    taskById: effectiveTaskById,
                    onToggleExpanded: { onToggleSourceExpanded(source.sourceId) },
                    onRemove: { requestRemoveSource(source) },
                    onSetFilter: { onSetSourceFilter(source.sourceId, $0) },
                    onSetRange: { onSetSourceRange(source.sourceId, $0, $1) },
                    onToggleExclude: { onToggleSourceExclude(source.sourceId, $0) },
                    counterClashByTaskId: counterClashByTaskId,
                    compoundChildrenByCompound: effectiveChildrenByCompound,
                    mode: planMode,
                    wizardWindow: wizardWindow,
                    onSetMemberTarget: { onSetMemberTarget(source.sourceId, $0, $1) },
                    onSetMemberVary: { onSetMemberVary(source.sourceId, $0, $1) },
                    onSetMemberSplit: { onSetMemberSplit(source.sourceId, $0, $1) },
                    onSetPartExcluded: { onSetPartExcluded(source.sourceId, $0, $1, $2) },
                    onSetPartTarget: { onSetPartTarget(source.sourceId, $0, $1, $2) },
                    onSetPartVary: { onSetPartVary(source.sourceId, $0, $1, $2) }
                )
            }
        )
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
            // First open: `seededForEditor` blanks a Counting task's Title
            // field when it still matches its auto-generated form, so the
            // title keeps re-deriving as Action/Goal/Unit change in the
            // editor (bug: a non-blank seeded title never re-derived).
            var d = TaskEditPatch.seededForEditor(from: task)
            if task.type == .compound {
                // First open: seed sub-task rows from the compound's links
                // (in childIndex order), resolving each child Task.
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
        // §Member rules (B3, final review I1) — the VM REFUSES a deselect
        // that would empty a Split-up compound, and the row correctly stays
        // on the board. Announcing "Removed …" anyway would contradict the
        // screen, and its Undo calls `restoreToPool` — which writes the id
        // into `manualTaskIds` and re-provenances a source-supplied part as
        // hand-added. So: no removal, no toast, no editor close.
        guard toggleSelection(taskId) else { return }
        if editingTaskId == taskId { editingTaskId = nil }
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
            // Board Creation Split (iOS PR A) — accent tracks the wizard's
            // fixed mode: red one-off / blue recurring.
            RisoButton(title: "Next ›", kind: isRecurring ? .blue : .primary, fullWidth: true) {
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

    /// - Parameter taskId: The row to add to, or remove from, the pool.
    /// - Returns: `false` when the VM REFUSED the toggle and nothing changed
    ///   (the last included part of a Split-up compound).
    @discardableResult
    private func toggleSelection(_ taskId: String) -> Bool {
        // Delegate to the wizard VM: it updates selection, clears the center
        // mark, AND purges the deferred `pendingTasks` payload on deselect.
        // The old local-only version skipped the pending purge, so removed
        // tasks were persisted as orphans and leaked into the library.
        onToggleSelection(taskId)
    }
}
