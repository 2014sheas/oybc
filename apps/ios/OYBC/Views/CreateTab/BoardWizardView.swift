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
    let startRecurring: Bool
    let onCancel: () -> Void
    let onComplete: (_ boardId: String, _ status: String) -> Void
    var onTemplateComplete: ((_ templateId: String) -> Void)? = nil
    var onDeleteDraft: ((_ boardId: String) -> Void)? = nil

    @State private var wizard: BoardWizardViewModel
    @State private var library = TaskLibraryViewModel()
    @State private var showCancelDialog: Bool = false
    @State private var cancelDialogError: String? = nil
    @State private var isSavingFromCancel: Bool = false

    init(
        userId: String,
        preferences: UserPreferences,
        draft: (board: Board, boardTasks: [BoardTask])? = nil,
        prefilledRecurringTimeframe: Timeframe? = nil,
        targetWindowDate: Date? = nil,
        editingTemplate: RecurringBoardTemplate? = nil,
        startRecurring: Bool = false,
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
        self.onCancel = onCancel
        self.onComplete = onComplete
        self.onTemplateComplete = onTemplateComplete
        self.onDeleteDraft = onDeleteDraft
        _wizard = State(initialValue: BoardWizardViewModel(
            preferences: preferences,
            draft: draft,
            prefilledRecurringTimeframe: prefilledRecurringTimeframe,
            targetWindowDate: targetWindowDate,
            editingTemplate: editingTemplate,
            startRecurring: startRecurring,
            userId: userId
        ))
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

    private func handleDialogSaveDraft() {
        cancelDialogError = nil
        guard canSaveDraft else { return }
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
    private var kickerText: String {
        if wizard.currentStep == 3 { return "LAST LOOK" }
        if draft != nil { return "RESUME DRAFT" }
        if wizard.isRecurring {
            return editingTemplate != nil ? "EDIT RECURRING BOARD" : "NEW RECURRING BOARD"
        }
        return "NEW BOARD"
    }

    /// H2 title — the name of the current step.
    private var stepTitle: String {
        switch wizard.currentStep {
        case 1: return "Setup"
        case 2: return "Tasks"
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
                                .risoKicker()
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
        }
        .sheet(isPresented: $showCancelDialog) {
            BoardWizardCancelDialogView(
                canSaveDraft: canSaveDraft,
                saveDraftBlockedReason: saveBlockedReason,
                saveDraftLabel: isSavingFromCancel
                    ? "Saving…"
                    : (wizard.draftBoardId != nil ? "Save Changes" : "Save Draft"),
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
                tasksRequired: wizard.tasksRequired,
                isRecurring: wizard.isRecurring,
                centerTaskMode: wizard.centerMode,
                centerTaskId: $wizard.centerTaskId,
                userId: userId,
                currentTimeframe: wizard.timeframe,
                currentStartDate: { if case .ok(let s, _) = currentDates { return s }; return nil }(),
                currentEndDate: { if case .ok(_, let e) = currentDates { return e }; return nil }(),
                onTaskCreated: { taskId, _, _ in
                    wizard.toggleTaskSelection(taskId)
                },
                onCompositeCreated: { _ in
                    // Composites can't be auto-selected (not boardable).
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
                onNext: { wizard.goNext() }
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
                onTemplateComplete: onTemplateComplete
            )
        }
    }
}
