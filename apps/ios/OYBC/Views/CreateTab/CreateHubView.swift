import SwiftUI

/// CreateHubView — Landing surface for the Create tab. iOS twin of
/// web's `CreateHubPage`.
///
/// Composes:
/// - `CreateHubBoardCTAView`: primary "Start a new board" card that
///   swaps the view into the 3-step wizard.
/// - `CreateHubDraftsListView` (conditional): lists DRAFT boards
///   loaded via GRDB; tapping a row hydrates the wizard from that
///   draft.
/// - Library section: shows the user's task count.
/// - `CreateHubQuickAddView`: inline task-creation form that writes
///   to the library only.
///
/// Hub-mode state, drafts, library count, and the four GRDB loaders
/// live on `CreateHubViewModel`. The view is a thin switch over
/// `vm.mode` plus the `.onAppear` hook that triggers initial loads
/// and consumes the cross-tab deep-link bindings.
struct CreateHubView: View {
    let userId: String
    let preferences: UserPreferences
    /// Phase 6.1: when non-nil on appear, the hub immediately enters the
    /// wizard with this timeframe prefilled (and the field locked) and
    /// resets the binding to nil so a wizard cancel + manual re-entry
    /// doesn't re-arm the prefill. Set by `MainTabView` from the Boards-
    /// tab Recurring Boards banner. Optional binding keeps the
    /// playground / preview path simple.
    var pendingRecurringTimeframe: Binding<Timeframe?> = .constant(nil)
    /// Phase 6.2 UX rework: cross-tab edit deep-link. When non-nil on
    /// appear, the hub fetches the template and immediately enters the
    /// wizard in template-edit mode, then resets the binding to nil
    /// so a wizard cancel + manual re-entry doesn't re-arm the edit.
    /// Set by `MainTabView` from `RecurringTemplatesView`'s row Edit
    /// callback.
    var pendingEditTemplateId: Binding<String?> = .constant(nil)
    /// Called after a board is successfully activated or saved as a
    /// draft. Parent typically navigates to the created board; the
    /// hub itself always returns to its landing view.
    var onBoardCompleted: ((_ boardId: String, _ status: String) -> Void)? = nil
    /// Phase 6.2: called when a recurring template was saved with no
    /// spawnable board (skip OR edit). Parent should switch to the
    /// Profile tab so the user lands on the templates list (with
    /// attention badge if the spawn was skipped). Without this the
    /// wizard would have to overload `onBoardCompleted` with a
    /// templateId, navigating to a non-existent board.
    var onTemplateCompleted: ((_ templateId: String) -> Void)? = nil

    @State private var vm = CreateHubViewModel()

    /// Phase 6.1d: pending core boards (daily/weekly/monthly/yearly) that
    /// the user hasn't created yet for the current windows. When non-empty,
    /// the prominent `PendingCoreBoardsSectionView` becomes the headline
    /// action and the existing `CreateHubBoardCTAView` is demoted to a
    /// secondary "Custom timeframe board" affordance below it. Kept as
    /// its own observable on the view rather than embedding it in
    /// `CreateHubViewModel` — it's already an `@Observable` and nesting
    /// adds an indirection without removing state from the view.
    @State private var pendingRecurringVM = PendingRecurringBoardsViewModel()

    var body: some View {
        switch vm.mode {
        case .hub:
            hubContent
                .onAppear {
                    vm.reloadDrafts(userId: userId)
                    vm.reloadLibraryCount(userId: userId)
                    pendingRecurringVM.reloadAsync(userId: userId)
                    // Consume the recurring-banner deep link, if any.
                    // Same behavior as web's URL-param consumption +
                    // immediate clear in `useRecurringTimeframeParam`.
                    if let timeframe = pendingRecurringTimeframe.wrappedValue {
                        pendingRecurringTimeframe.wrappedValue = nil
                        vm.enterRecurringWizard(timeframe: timeframe)
                        return
                    }
                    // Consume the edit-template deep link, if any.
                    // Fetch the template first; mount the wizard only
                    // after hydration so its view-model sees real data.
                    if let templateId = pendingEditTemplateId.wrappedValue {
                        pendingEditTemplateId.wrappedValue = nil
                        vm.loadTemplateAndEnterWizard(templateId: templateId)
                    }
                }
        case .wizardFresh:
            wizard(draft: nil, prefilledRecurringTimeframe: nil, editingTemplate: nil)
        case .wizardResume:
            wizard(draft: vm.resumeDraft, prefilledRecurringTimeframe: nil, editingTemplate: nil)
        case .wizardRecurring(let timeframe):
            wizard(draft: nil, prefilledRecurringTimeframe: timeframe, editingTemplate: nil)
        case .wizardEditTemplate:
            // The mode is set BEFORE `editingTemplate` is set (when
            // hydration is in flight) and AFTER (once loaded). Render
            // a thin loading state in the in-flight window so the
            // wizard doesn't mount with stale state.
            if let template = vm.editingTemplate {
                wizard(draft: nil, prefilledRecurringTimeframe: nil, editingTemplate: template)
            } else {
                ProgressView("Loading template…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            }
        }
    }

    /// Single source of truth for how the wizard is wired into the hub.
    /// Cancellation + completion always route through the view-model so
    /// the hub-side cleanup (mode reset, drafts reload, pending-recurring
    /// refresh) lives in exactly one place.
    @ViewBuilder
    private func wizard(
        draft: (board: Board, boardTasks: [BoardTask])?,
        prefilledRecurringTimeframe: Timeframe?,
        editingTemplate: RecurringBoardTemplate?
    ) -> some View {
        BoardWizardView(
            userId: userId,
            preferences: preferences,
            draft: draft,
            prefilledRecurringTimeframe: prefilledRecurringTimeframe,
            editingTemplate: editingTemplate,
            onCancel: { handleHubReturn() },
            onComplete: { boardId, status in
                onBoardCompleted?(boardId, status)
                handleHubReturn()
            },
            onTemplateComplete: { templateId in
                onTemplateCompleted?(templateId)
                handleHubReturn()
            }
        )
    }

    /// Hub-return shim: resets the view-model and also refreshes the
    /// pending-recurring section so a board the user just created
    /// disappears from the banner without a tab switch.
    private func handleHubReturn() {
        vm.returnToHub(userId: userId)
        pendingRecurringVM.reloadAsync(userId: userId)
    }

    @ViewBuilder
    private var hubContent: some View {
        let hasPendingCoreBoards = !pendingRecurringVM.pending.isEmpty
        VStack(alignment: .leading, spacing: 20) {
            Text("Create")
                .font(.largeTitle)
                .fontWeight(.bold)

            // Phase 6.1d: when there are pending core boards (daily /
            // weekly / monthly / yearly windows the user hasn't created
            // yet), they become the headline action. The
            // `CreateHubBoardCTAView` demotes to its secondary "custom
            // timeframe" variant below. When `hasPendingCoreBoards` is
            // false (everything created, or all 4 prefs disabled), the
            // section short-circuits to nil and the existing primary CTA
            // takes the headline slot — matching pre-6.1d behavior for
            // back-compat.
            PendingCoreBoardsSectionView(
                pending: pendingRecurringVM.pending,
                variant: .createTab,
                onCreate: { entry in
                    // Already on the Create tab — flip mode directly
                    // rather than bouncing through MainTabView's
                    // pendingRecurringTimeframe binding.
                    vm.enterRecurringWizard(timeframe: entry.timeframe)
                }
            )

            CreateHubBoardCTAView(
                onTap: { vm.enterFreshWizard() },
                variant: hasPendingCoreBoards ? .secondary : .primary
            )

            if !vm.drafts.isEmpty {
                CreateHubDraftsListView(
                    drafts: vm.drafts,
                    onResume: { board in
                        vm.loadDraftAndEnterWizard(board: board)
                    }
                )
            }

            librarySection

            CreateHubQuickAddView(
                userId: userId,
                onTaskCreated: {
                    vm.reloadLibraryCount(userId: userId)
                }
            )
        }
        // Hub mode pads itself; wizard mode pads inside each step view.
        // Padding moved off the parent ScrollView so the wizard's tasks
        // step doesn't get double-padded (16pt outer + 16pt step + 12pt
        // row chrome shrunk row content to ~78% of screen width).
        .padding(16)
    }

    @ViewBuilder
    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("YOUR TASK LIBRARY")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            Text(
                vm.libraryCount == 0
                    ? "No tasks yet — quick-add below or pick some when you build a board."
                    : "\(vm.libraryCount) task\(vm.libraryCount == 1 ? "" : "s") ready to place on a board."
            )
            .font(.subheadline)
            .foregroundColor(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
}
