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

    // Task Pools + Recurring Boards Rework (P3) — the user's pools + active
    // recurring templates, for the Tasks step's "PULL IN A POOL" card and
    // "Save as pool" sheet. Owned here (mirrors `library`) rather than on
    // the wizard VM, so `pullPool`/`untogglePool`/`provenanceByTaskId` stay
    // pure functions of caller-supplied lookups instead of a VM-cached copy
    // that could go stale relative to a fresh load.
    @State private var pools: [Pool] = []
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

    /// Loads the user's pools + active recurring templates for the Tasks
    /// step. Fire-and-forget, mirroring `library.loadLibrary`'s shim —
    /// silent on error (the pull card just renders empty/stale, same
    /// resilience posture as the DefaultPool prefill in the wizard VM's init).
    private func loadPools() {
        let uid = userId
        _Concurrency.Task {
            do {
                let loadedPools = try await _Concurrency.Task.detached(priority: .userInitiated) {
                    try AppDatabase.shared.fetchPools(userId: uid)
                }.value
                let loadedTemplates = try await _Concurrency.Task.detached(priority: .userInitiated) {
                    try AppDatabase.shared.fetchRecurringBoardTemplates(userId: uid)
                }.value
                await MainActor.run {
                    pools = loadedPools
                    templates = loadedTemplates
                }
            } catch {
                // Non-fatal: the pull card renders with whatever it already had.
            }
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

    /// Task Pools + Recurring Boards Rework (P4) — the cancel dialog's
    /// "Save Draft" action must branch on `wizard.isRecurring`: pre-P4 this
    /// unconditionally called `persistWizardBoard` (the one-off path),
    /// which for a recurring wizard silently saved a one-off DRAFT `Board`
    /// instead of the `RecurringBoardTemplate` the user actually configured
    /// (Repeats set to a cadence). Mirrors the Preview step's
    /// `performCreation(status:)` branch verbatim — same
    /// `persistRecurringTemplate` outcome handling — so both save-exit
    /// points behave identically.
    private func handleDialogSaveDraft() {
        cancelDialogError = nil
        guard canSaveDraft else { return }

        if wizard.isRecurring {
            isSavingFromCancel = true
            persistRecurringTemplate(
                controller: wizard,
                userId: userId,
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

    /// Save-Draft button label for the cancel dialog. Recurring boards can't
    /// yet save a draft (PR B), so from the cancel dialog a fresh recurring
    /// board's action is to create it — "Create Board", matching
    /// `BoardWizardPreviewStepView.recurringPrimaryLabel` verbatim (minus its
    /// "Saving…" busy state, surfaced here via `isSavingFromCancel`) so the
    /// same action reads identically from either exit point. No "template"/
    /// "spawn" mechanics words in UI copy.
    private var saveDraftLabel: String {
        if isSavingFromCancel { return "Saving…" }
        if wizard.isRecurring {
            return wizard.editingTemplateId != nil ? "Save Changes" : "Create Board"
        }
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
            loadPools()
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
                    // P3 — pass the real pools/tasks lookups so a row-remove
                    // that's still supplied by a pulled pool gets recorded
                    // in `removedTaskIds` bookkeeping.
                    wizard.toggleTaskSelection(taskId, poolsById: poolsById, tasksById: tasksById)
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
                pulledPoolIds: wizard.pulledPoolIds,
                provenanceByTaskId: wizard.provenanceByTaskId(poolsById: poolsById, tasksById: tasksById),
                onPullPool: { poolId in
                    wizard.pullPool(poolId, poolsById: poolsById, tasksById: tasksById)
                },
                onUntogglePool: { poolId in
                    wizard.untogglePool(poolId, poolsById: poolsById, tasksById: tasksById)
                },
                templates: templates,
                onPoolsReloadRequested: { loadPools() },
                isCore: wizard.isCore,
                manualTaskIds: wizard.manualTaskIds,
                savedCorePoolIds: wizard.savedCorePoolIds,
                onSetCorePoolDefaultSaved: { saved in
                    wizard.setCorePoolDefaultSaved(saved, userId: userId)
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
