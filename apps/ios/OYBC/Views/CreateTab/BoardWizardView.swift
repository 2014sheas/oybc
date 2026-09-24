import SwiftUI

/// BoardWizardView — Orchestrator for the 3-step board-creation
/// wizard. iOS twin of web's `BoardWizardPage`.
///
/// **Riso reskin (Phase 3a):** Riso header (kicker + H2 title, X-cancel as
/// a keyline icon button), `RisoBoardWizardStepperView`, and
/// `RisoPaperBackground`. The Create tab stays visible (it's a tab, not a
/// modal) — footer buttons in each step view sit above it.
///
/// All wiring is preserved unchanged:
///   - `BoardWizardViewModel` owns the full wizard state.
///   - `stepContent` routes to the three step views.
///   - `handleCancelRequested` / `BoardWizardCancelDialogView` logic unchanged.
///   - `persistWizardBoard` / `persistRecurringTemplate` call sites in the
///     Preview step are untouched.
///   - `onComplete(boardId, status)` + `onTemplateComplete(templateId)` callbacks.
struct BoardWizardView: View {
    let userId: String
    let preferences: UserPreferences
    let draft: (board: Board, boardTasks: [BoardTask])?
    let prefilledRecurringTimeframe: Timeframe?
    let targetWindowDate: Date?
    let editingTemplate: RecurringBoardTemplate?
    /// Board Creation Split (iOS PR A) — true when launched from the
    /// recurring hub card. Only takes effect for a truly fresh wizard
    /// (no draft/template/prefill) — see `BoardWizardViewModel.init`.
    var startRecurring: Bool = false
    /// Which step the wizard opens on (issue #321). Defaults to 1 (Setup)
    /// for every existing entry point; the Recurring-templates card's
    /// "Add tasks" affordance passes 2 (Tasks) so the user lands directly
    /// on the pool picker instead of re-walking Setup.
    var initialStep: WizardStep = 1
    let onCancel: () -> Void
    let onComplete: (_ boardId: String, _ status: String) -> Void
    var onTemplateComplete: ((_ templateId: String) -> Void)? = nil
    var onDeleteDraft: ((_ boardId: String) -> Void)? = nil

    @State private var wizard: BoardWizardViewModel
    @State private var library = TaskLibraryViewModel()
    @State private var showCancelDialog: Bool = false
    @State private var cancelDialogError: String? = nil
    @State private var isSavingFromCancel: Bool = false

    // The user's pools + active recurring templates, for the Tasks step's
    // Sources sheet ("Add from a pool or board"). Owned here (mirrors
    // `library`) rather than on the wizard VM, so `pullPool` stays a pure
    // function of caller-supplied lookups instead of a VM-cached copy that
    // could go stale relative to a fresh load.
    @State private var pools: [Pool] = []
    /// Board Sources P2 — the source sheet's BOARDS rows, loaded off-main
    /// in `loadSources()` (walks every active board).
    @State private var sheetBoardEntries: [RisoSourcePickerSheetView.BoardEntry] = []
    @State private var templates: [RecurringBoardTemplate] = []

    init(
        userId: String,
        preferences: UserPreferences,
        draft: (board: Board, boardTasks: [BoardTask])? = nil,
        prefilledRecurringTimeframe: Timeframe? = nil,
        targetWindowDate: Date? = nil,
        editingTemplate: RecurringBoardTemplate? = nil,
        startRecurring: Bool = false,
        initialStep: WizardStep = 1,
        onCancel: @escaping () -> Void,
        onComplete: @escaping (_ boardId: String, _ status: String) -> Void,
        onTemplateComplete: ((_ templateId: String) -> Void)? = nil,
        onDeleteDraft: ((_ boardId: String) -> Void)? = nil
    ) {
        self.userId = userId
        self.preferences = preferences
        self.draft = draft
        self.prefilledRecurringTimeframe = prefilledRecurringTimeframe
        self.targetWindowDate = targetWindowDate
        self.editingTemplate = editingTemplate
        self.startRecurring = startRecurring
        self.initialStep = initialStep
        self.onCancel = onCancel
        self.onComplete = onComplete
        self.onTemplateComplete = onTemplateComplete
        self.onDeleteDraft = onDeleteDraft
        _wizard = State(initialValue: BoardWizardViewModel(
            preferences: preferences,
            initialStep: initialStep,
            draft: draft,
            prefilledRecurringTimeframe: prefilledRecurringTimeframe,
            targetWindowDate: targetWindowDate,
            editingTemplate: editingTemplate,
            startRecurring: startRecurring,
            userId: userId
        ))
    }

    // MARK: - Pool mix lookups (Task Pools + Recurring Boards Rework, P3)

    private var poolsById: [String: Pool] {
        Dictionary(pools.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var tasksById: [String: OYBC.Task] {
        Dictionary(library.libraryTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Counter-family exclusivity — a cheap Equatable signature over the
    /// library's counting tasks, for the `.onChange` that refreshes the
    /// wizard VM's family map.
    private var counterFamilySignature: [String] {
        library.libraryTasks.compactMap { task in
            task.type == .counting ? "\(task.id)|\(task.sharedCounterId ?? "")" : nil
        }
    }

    /// Loads the user's pools + recurring templates + the Sources sheet's
    /// BOARDS rows (through `wizard.loadSourceCatalog`, i.e. the wizard's
    /// injected database). Runs from `.task`, so leaving the wizard cancels
    /// it and a late result never lands. Logged, otherwise silent on error —
    /// the pickers render with whatever they already had.
    private func loadSources() async {
        do {
            let catalog = try await wizard.loadSourceCatalog(userId: userId)
            pools = catalog.pools
            templates = catalog.templates
            sheetBoardEntries = catalog.boardEntries
            // Board Sources P2 — re-resolve pulled sources' supplies
            // against the fresh pools/library so ranges/counts track
            // live edits.
            wizard.refreshSourceSupplies(poolsById: poolsById, tasksById: tasksById)
        } catch is CancellationError {
            // The wizard went away mid-load — nothing to apply.
        } catch {
            dlog("board wizard: failed to load sources catalog: \(error)")
        }
    }

    // MARK: - Cancel / save-draft helpers

    private var currentDates: ResolvedWizardDates {
        resolveWizardDates(controller: wizard)
    }

    private var hasName: Bool {
        !wizard.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasResolvableDates: Bool {
        if case .ok = currentDates { return true }
        return false
    }

    private var canSaveDraft: Bool {
        hasName && hasResolvableDates && !isSavingFromCancel
    }

    private var saveBlockedReason: String? {
        if !hasName { return "Add a board name before saving as a draft." }
        if case .error(let msg) = currentDates { return msg }
        return nil
    }

    private func handleCancelRequested() {
        if wizard.isPristine {
            onCancel()
            return
        }
        cancelDialogError = nil
        showCancelDialog = true
    }

    /// Board Creation Split (PR B) — the cancel dialog is now
    /// byte-identical for both modes (README §4 "Cancel dialog"): a
    /// recurring wizard's "Save Draft" saves a real DRAFT `Board` via the
    /// SAME `persistWizardBoard` path a one-off wizard uses — nothing runs
    /// until "Create Board". The one exception is editing an EXISTING
    /// repeating board (`wizard.editingTemplateId != nil`): there's no
    /// "draft" concept for an edit, so that branch still calls
    /// `persistRecurringTemplate` to persist the edit directly, mirroring
    /// the Preview step's "Save Changes" verbatim (same outcome handling).
    private func handleDialogSaveDraft() {
        cancelDialogError = nil
        guard canSaveDraft else { return }

        if wizard.isRecurring && wizard.editingTemplateId != nil {
            isSavingFromCancel = true
            persistRecurringTemplate(
                controller: wizard,
                userId: userId,
                database: wizard.database,
                onSuccess: { outcome in
                    isSavingFromCancel = false
                    showCancelDialog = false
                    switch outcome {
                    case .createdAndSpawned(_, let boardId):
                        onComplete(boardId, WizardStatus.active.rawValue)
                    case .createdSpawnSkipped(let templateId, _):
                        onTemplateComplete?(templateId)
                    case .updated(let templateId):
                        onTemplateComplete?(templateId)
                    }
                },
                onError: { message in
                    isSavingFromCancel = false
                    cancelDialogError = "Failed to save recurring board: \(message)"
                }
            )
            return
        }

        guard case .ok(let start, let end) = currentDates else {
            if case .error(let msg) = currentDates { cancelDialogError = msg }
            return
        }
        isSavingFromCancel = true
        let placement = buildWizardPlacement(controller: wizard, library: library)
        persistWizardBoard(
            controller: wizard,
            userId: userId,
            placement: placement,
            dates: (start, end),
            status: .draft,
            database: wizard.database,
            onSuccess: { boardId in
                isSavingFromCancel = false
                showCancelDialog = false
                onComplete(boardId, WizardStatus.draft.rawValue)
            },
            onError: { message in
                isSavingFromCancel = false
                cancelDialogError = "Failed to save draft: \(message)"
            }
        )
    }

    /// Save-Draft button label for the cancel dialog. Board Creation Split
    /// (PR B) — the same rule now applies to BOTH modes (no more
    /// recurring-only special case): "Save Changes" when editing an
    /// existing repeating board OR resuming any draft (one-off or
    /// recurring); "Save Draft" for a truly fresh wizard. This is what
    /// makes the cancel dialog byte-identical across modes (README §4).
    private var saveDraftLabel: String {
        if isSavingFromCancel { return "Saving…" }
        if wizard.editingTemplateId != nil { return "Save Changes" }
        return wizard.draftBoardId != nil ? "Save Changes" : "Save Draft"
    }

    private func handleDialogDiscard() {
        showCancelDialog = false
        onCancel()
    }

    private func handleDialogKeepEditing() {
        showCancelDialog = false
        cancelDialogError = nil
    }

    // MARK: - Kicker text

    /// Header kicker: uppercase short label reflecting the launch mode.
    /// Mirrors the `step === 2 ? "Last look" : "New board"` pattern in
    /// `wizard.jsx`, extended to cover all OYBC launch modes.
    ///
    /// Board Creation Split (iOS PR A) — a fresh one-off wizard now reads
    /// "NEW ONE-OFF BOARD" (was "NEW BOARD") to match the recurring side's
    /// "NEW RECURRING BOARD" naming; the kicker's COLOR (see `kickerColor`)
    /// carries the red/blue identity through every step, including "LAST
    /// LOOK" / "RESUME DRAFT".
    private var kickerText: String {
        if wizard.currentStep == 3 { return "LAST LOOK" }
        if draft != nil { return "RESUME DRAFT" }
        if wizard.isRecurring {
            return editingTemplate != nil ? "EDIT RECURRING BOARD" : "NEW RECURRING BOARD"
        }
        return "NEW ONE-OFF BOARD"
    }

    /// Board Creation Split (iOS PR A) — the kicker's red/blue identity
    /// tracks the wizard's fixed mode through every step (Setup/Tasks-or-
    /// Pool/"Last look"), not just the fresh-launch label.
    private var kickerColor: Color {
        wizard.isRecurring ? .risoBlue : .risoRed
    }

    /// H2 title — the name of the current step. Board Creation Split
    /// (iOS PR A) — step 2 reads "Pool" for a recurring board (matches the
    /// stepper's per-mode label), "Tasks" for one-off.
    private var stepTitle: String {
        switch wizard.currentStep {
        case 1: return "Setup"
        case 2: return wizard.isRecurring ? "Pool" : "Tasks"
        default: return "Preview"
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            RisoPaperBackground()

            VStack(spacing: 0) {
                // ── Riso header ──────────────────────────────────────────
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kickerText)
                                .risoKicker(kickerColor)
                            Text(stepTitle)
                                .risoH2()
                        }

                        Spacer()

                        // X-cancel: 46pt keyline square (matches RisoIconButton's
                        // canonical size + the 44pt minimum tap target).
                        Button {
                            handleCancelRequested()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Color.risoInk)
                                .frame(width: 46, height: 46)
                                .risoCard(fill: .risoPaper2)
                        }
                        .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small))
                        .accessibilityLabel("Close wizard")
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.top, 16)
                    .padding(.bottom, 2)

                    // ── Riso stepper ──────────────────────────────────
                    RisoBoardWizardStepperView(
                        currentStep: wizard.currentStep,
                        isRecurring: wizard.isRecurring,
                        onStepClick: { wizard.goToStep($0) }
                    )
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 8)

                    // Board Sources P2 (locked decision) — editing an
                    // existing repeating board IS the "Sources" surface;
                    // the design's frame-5a note renders here.
                    if wizard.editingTemplateId != nil {
                        Text("Changes apply from the next board.")
                            .font(.risoBody(11, .semibold))
                            .foregroundStyle(Color.risoMuted)
                            .padding(.horizontal, Riso.gutter)
                            .padding(.bottom, 6)
                    }
                }

                // ── Step content ────────────────────────────────────────
                stepContent

                // ── Cancel-dialog error (shown beneath content) ─────────
                if let err = cancelDialogError {
                    Text(err)
                        .font(.risoBody(12, .semibold))
                        .foregroundStyle(Color.risoRed)
                        .padding(.horizontal, Riso.gutter)
                        .padding(.vertical, 8)
                }
            }
        }
        .onAppear {
            library.loadLibrary(userId: userId)
            wizard.refreshCounterFamilies(libraryTasks: library.libraryTasks)
        }
        // Structured, so disappearing cancels the load (see `loadSources`).
        .task { await loadSources() }
        // Counter-family exclusivity (2026-09-08) — keep the wizard VM's
        // library-half family map in lockstep with the live library. The
        // signature is only the counting tasks' id|sharedCounterId pairs,
        // so unrelated library churn doesn't re-derive anything.
        .onChange(of: counterFamilySignature) { _, _ in
            wizard.refreshCounterFamilies(libraryTasks: library.libraryTasks)
        }
        .sheet(isPresented: $showCancelDialog) {
            BoardWizardCancelDialogView(
                canSaveDraft: canSaveDraft,
                saveDraftBlockedReason: saveBlockedReason,
                saveDraftLabel: saveDraftLabel,
                onSaveDraft: handleDialogSaveDraft,
                onDiscard: handleDialogDiscard,
                onKeepEditing: handleDialogKeepEditing,
                onDeleteDraft: (wizard.draftBoardId != nil && onDeleteDraft != nil)
                    ? { if let id = wizard.draftBoardId { onDeleteDraft?(id) } }
                    : nil
            )
            .presentationDetents([.medium])
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch wizard.currentStep {
        case 1:
            BoardWizardSetupStepView(
                controller: wizard,
                onCancel: handleCancelRequested,
                onNext: { wizard.goNext() }
            )
        case 2:
            BoardWizardTasksStepView(
                library: library,
                selectedTaskIds: $wizard.selectedTaskIds,
                poolOrder: wizard.poolOrder,
                stagedEdits: wizard.stagedEdits,
                onStageEdit: { patch, taskId in wizard.stageEdit(patch, for: taskId) },
                onRevertEdit: { taskId, previous in wizard.revertEdit(for: taskId, to: previous) },
                onRestoreToPool: { taskId, index, payload in wizard.restoreToPool(taskId, at: index, payload: payload) },
                tasksRequired: wizard.tasksRequired,
                isRecurring: wizard.isRecurring,
                centerTaskMode: wizard.centerMode,
                centerTaskId: $wizard.centerTaskId,
                userId: userId,
                currentTimeframe: wizard.timeframe,
                currentStartDate: { if case .ok(let s, _) = currentDates { return s }; return nil }(),
                currentEndDate: { if case .ok(_, let e) = currentDates { return e }; return nil }(),
                onToggleSelection: { taskId in
                    // Board Sources P2 — a row-remove of a source-supplied
                    // task now records per-source excludes internally (the
                    // VM's supply caches replace the caller lookups).
                    wizard.toggleTaskSelection(taskId)
                },
                onTaskCreated: { taskId, _, _ in
                    wizard.toggleTaskSelection(taskId)
                },
                onCompoundCreated: { _ in
                    // Compounds can't be auto-selected (not boardable).
                },
                onLibraryReloadRequested: {
                    library.loadLibrary(userId: userId)
                },
                onPendingCreated: { payload in
                    // Bug #85 — store the deferred payload so persistWizardBoard
                    // can write it atomically inside the board-save transaction.
                    wizard.addPendingTask(payload)
                },
                pendingTasks: wizard.pendingTasks,
                onBack: { wizard.goBack() },
                onNext: { wizard.goNext() },
                pools: pools,
                sources: wizard.sources,
                supplyInfoBySourceId: wizard.supplyInfoBySourceId,
                expandedSourceIds: wizard.expandedSourceIds,
                availableCountForSource: { wizard.availableCount(forSourceId: $0) },
                capacity: wizard.sourceCapacity,
                sheetBoardEntries: sheetBoardEntries,
                onToggleSourceExpanded: { sourceId in
                    if wizard.expandedSourceIds.contains(sourceId) {
                        wizard.expandedSourceIds.remove(sourceId)
                    } else {
                        wizard.expandedSourceIds.insert(sourceId)
                    }
                },
                onRemoveSource: { wizard.removeSource(sourceId: $0) },
                onSetSourceFilter: { wizard.setSourceFilter(sourceId: $0, filter: $1) },
                onSetSourceRange: { wizard.setSourceRange(sourceId: $0, min: $1, max: $2) },
                onToggleSourceExclude: { wizard.toggleSourceExclude(sourceId: $0, taskId: $1) },
                onPullPoolSource: { pool in
                    wizard.pullPool(pool, tasksById: tasksById)
                },
                onPullBoardSource: { wizard.pullBoard(boardId: $0) },
                editingTemplateId: wizard.editingTemplateId,
                // §Member rules (B3) — the seven rule actions + the
                // hand-added dice map (`BoardWizardViewModel+MemberRules`).
                manualTaskVary: wizard.manualTaskVary,
                onSetManualVary: { wizard.setManualVary(taskId: $0, level: $1) },
                onSetMemberTarget: { wizard.setMemberTarget(sourceId: $0, taskId: $1, target: $2) },
                onSetMemberVary: { wizard.setMemberVary(sourceId: $0, taskId: $1, level: $2) },
                onSetMemberSplit: { wizard.setMemberSplit(sourceId: $0, taskId: $1, split: $2) },
                onSetPartExcluded: {
                    wizard.setPartExcluded(sourceId: $0, taskId: $1, childId: $2, excluded: $3)
                },
                onSetPartTarget: {
                    wizard.setPartTarget(sourceId: $0, taskId: $1, childId: $2, target: $3)
                },
                onSetPartVary: {
                    wizard.setPartVary(sourceId: $0, taskId: $1, childId: $2, level: $3)
                }
            )
        default:
            BoardWizardPreviewStepView(
                controller: wizard,
                library: library,
                userId: userId,
                onBack: { wizard.goBack() },
                onComplete: { boardId, status in
                    onComplete(boardId, status.rawValue)
                },
                onTemplateComplete: onTemplateComplete,
                pools: pools
            )
        }
    }
}
