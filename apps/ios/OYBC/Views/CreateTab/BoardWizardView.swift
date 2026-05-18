import SwiftUI

/// BoardWizardView — Orchestrator for the 3-step board-creation
/// wizard. iOS twin of web's `BoardWizardPage`.
///
/// Owns the wizard view-model and a `TaskLibraryViewModel`, then
/// routes them into the active step view. When the user dismisses
/// the wizard mid-edit, `BoardWizardCancelDialogView` is presented
/// with the smart 3-option prompt; pristine states dismiss silently.
///
/// Supports resuming an existing draft via the optional `draft`
/// argument — every wizard field hydrates from the Board record and
/// the selection set rebuilds from its `BoardTask` rows.
struct BoardWizardView: View {
    let userId: String
    let preferences: UserPreferences
    let draft: (board: Board, boardTasks: [BoardTask])?
    /// Phase 6.1: when set, the wizard was launched from the Boards-
    /// tab Recurring Boards banner. The setup step locks the timeframe
    /// field to this value (see BoardWizardViewModel + BoardSetupForm).
    /// Mutually exclusive with `draft` — drafts already lock semantics
    /// by hydrating the full record.
    let prefilledRecurringTimeframe: Timeframe?
    /// Phase 6.2 UX rework: when set, the wizard was launched from
    /// Profile → Recurring templates → Edit. All fields hydrate from
    /// the template, `isRecurring` is forced ON, and Save updates the
    /// template instead of creating a new board.
    let editingTemplate: RecurringBoardTemplate?
    let onCancel: () -> Void
    let onComplete: (_ boardId: String, _ status: String) -> Void
    /// Phase 6.2: called when a recurring template was saved with no
    /// spawnable board (skip OR edit). Optional — one-off call sites
    /// don't need to wire it.
    var onTemplateComplete: ((_ templateId: String) -> Void)? = nil

    @State private var wizard: BoardWizardViewModel
    @State private var library = TaskLibraryViewModel()
    @State private var showCancelDialog: Bool = false
    @State private var cancelDialogError: String? = nil
    @State private var isSavingFromCancel: Bool = false

    /// True when the timeframe field should render as a read-only chip.
    /// Mirrors web's `lockTimeframe = prefilledRecurringTimeframe !== undefined && draft === undefined`.
    private var lockTimeframe: Bool {
        prefilledRecurringTimeframe != nil && draft == nil
    }

    init(
        userId: String,
        preferences: UserPreferences,
        draft: (board: Board, boardTasks: [BoardTask])? = nil,
        prefilledRecurringTimeframe: Timeframe? = nil,
        editingTemplate: RecurringBoardTemplate? = nil,
        onCancel: @escaping () -> Void,
        onComplete: @escaping (_ boardId: String, _ status: String) -> Void,
        onTemplateComplete: ((_ templateId: String) -> Void)? = nil
    ) {
        self.userId = userId
        self.preferences = preferences
        self.draft = draft
        self.prefilledRecurringTimeframe = prefilledRecurringTimeframe
        self.editingTemplate = editingTemplate
        self.onCancel = onCancel
        self.onComplete = onComplete
        self.onTemplateComplete = onTemplateComplete
        _wizard = State(initialValue: BoardWizardViewModel(
            preferences: preferences,
            draft: draft,
            prefilledRecurringTimeframe: prefilledRecurringTimeframe,
            editingTemplate: editingTemplate,
            userId: userId
        ))
    }

    // MARK: - Cancel / save-draft helpers

    /// Resolved dates for the current wizard state (re-evaluates each
    /// render — inexpensive computed property).
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

    /// Entry-point called by every "close wizard" affordance (header
    /// X + Step 1's Cancel footer button). Dismisses silently when
    /// the wizard is pristine; otherwise shows the smart dialog.
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

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(draft != nil ? "Resume draft" : "New board")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button {
                    handleCancelRequested()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close wizard")
            }

            BoardWizardStepperView(
                currentStep: wizard.currentStep,
                onStepClick: { wizard.goToStep($0) }
            )

            stepContent

            if let err = cancelDialogError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
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
                onKeepEditing: handleDialogKeepEditing
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
                lockTimeframe: lockTimeframe,
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
                onTaskCreated: { taskId, _, _ in
                    wizard.toggleTaskSelection(taskId)
                },
                onCompositeCreated: { _ in
                    // Composites can't be auto-selected (not boardable).
                },
                onLibraryReloadRequested: {
                    library.loadLibrary(userId: userId)
                },
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
