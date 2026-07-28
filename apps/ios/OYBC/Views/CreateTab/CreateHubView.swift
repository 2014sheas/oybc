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
/// (Task quick-add lives on the Tasks tab now; the Create hub is
/// board-creation only.)
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
    /// Phase B — Optional target-window date that pairs with
    /// `pendingRecurringTimeframe`. Set by the core-board browser
    /// when the user picks a non-current window via a Create-cell tap;
    /// `nil` keeps the legacy "today's window" behaviour when the
    /// banner is the entry point. Read + cleared on the same `.onAppear`
    /// that consumes the timeframe binding.
    var pendingTargetWindowDate: Binding<Date?> = .constant(nil)
    /// Phase 6.2 UX rework: cross-tab edit deep-link. When non-nil on
    /// appear, the hub fetches the template and immediately enters the
    /// wizard in template-edit mode, then resets the binding to nil
    /// so a wizard cancel + manual re-entry doesn't re-arm the edit.
    /// Set by `MainTabView` from `RecurringTemplatesView`'s row Edit
    /// callback.
    var pendingEditTemplateId: Binding<String?> = .constant(nil)
    /// "Add tasks" cross-tab deep-link (issue #321) — mirrors
    /// `pendingEditTemplateId` exactly, except the hub lands the wizard
    /// on the Tasks step (2) instead of Setup (1). Set by `MainTabView`
    /// from `RecurringTemplatesView`'s per-card "Add tasks" button.
    var pendingAddTasksTemplateId: Binding<String?> = .constant(nil)
    /// New-template cross-tab deep-link. When true on appear, the hub
    /// opens the wizard's fresh recurring-template flow (same as the
    /// hub's own "Create a recurring board" CTA) and clears the flag.
    /// Set by `MainTabView` from `RecurringTemplatesView`'s
    /// "+ New template" button — mirrors `pendingEditTemplateId`.
    var pendingNewRecurringTemplate: Binding<Bool> = .constant(false)
    /// Draft-resume cross-tab deep-link. When non-nil on appear, the hub
    /// hydrates the wizard from that draft board id (via the same resume
    /// path as the drafts list) and clears the binding. Set by
    /// `MainTabView` when a DRAFT board is tapped on the Boards tab — drafts
    /// are never opened as a playable board, so this is the resume entry.
    var pendingDraftId: Binding<String?> = .constant(nil)
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
                    pendingRecurringVM.reloadAsync(userId: userId)
                    // Consume the recurring-banner deep link, if any.
                    // Same behavior as web's URL-param consumption +
                    // immediate clear in `useRecurringTimeframeParam`.
                    if let timeframe = pendingRecurringTimeframe.wrappedValue {
                        let date = pendingTargetWindowDate.wrappedValue
                        pendingRecurringTimeframe.wrappedValue = nil
                        pendingTargetWindowDate.wrappedValue = nil
                        vm.enterCoreBoardWizard(timeframe: timeframe, targetWindowDate: date)
                        return
                    }
                    // Consume the edit-template deep link, if any.
                    // Fetch the template first; mount the wizard only
                    // after hydration so its view-model sees real data.
                    if let templateId = pendingEditTemplateId.wrappedValue {
                        pendingEditTemplateId.wrappedValue = nil
                        vm.loadTemplateAndEnterWizard(templateId: templateId)
                        return
                    }
                    // Consume the "Add tasks" deep link, if any (issue #321)
                    // — same hydration as edit, but lands on the Tasks step.
                    if let templateId = pendingAddTasksTemplateId.wrappedValue {
                        pendingAddTasksTemplateId.wrappedValue = nil
                        vm.loadTemplateAndEnterWizard(templateId: templateId, initialStep: 2)
                        return
                    }
                    // Consume the new-recurring-template deep link, if any.
                    // Same wizard flow as the hub's own recurring CTA.
                    if pendingNewRecurringTemplate.wrappedValue {
                        pendingNewRecurringTemplate.wrappedValue = false
                        vm.enterRecurringTemplateWizard()
                        return
                    }
                    // Consume the draft-resume deep link, if any. Fetch the
                    // draft board + its placements, then enter wizardResume —
                    // same hydration path as tapping a row in the drafts list.
                    if let draftId = pendingDraftId.wrappedValue {
                        pendingDraftId.wrappedValue = nil
                        vm.loadDraftAndEnterWizard(boardId: draftId, userId: userId)
                    }
                }
        case .wizardFresh:
            wizard(draft: nil, prefilledRecurringTimeframe: nil, targetWindowDate: nil, editingTemplate: nil)
        case .wizardResume:
            wizard(draft: vm.resumeDraft, prefilledRecurringTimeframe: nil, targetWindowDate: nil, editingTemplate: nil)
        case .wizardCoreBoard(let timeframe, let targetWindowDate):
            wizard(draft: nil, prefilledRecurringTimeframe: timeframe, targetWindowDate: targetWindowDate, editingTemplate: nil)
        case .wizardRecurringTemplate:
            wizard(draft: nil, prefilledRecurringTimeframe: nil, targetWindowDate: nil, editingTemplate: nil, startRecurring: true)
        case .wizardEditTemplate(_, let initialStep):
            // The mode is set BEFORE `editingTemplate` is set (when
            // hydration is in flight) and AFTER (once loaded). Render
            // a thin loading state in the in-flight window so the
            // wizard doesn't mount with stale state.
            if let template = vm.editingTemplate {
                wizard(draft: nil, prefilledRecurringTimeframe: nil, targetWindowDate: nil, editingTemplate: template, initialStep: initialStep)
            } else {
                ProgressView("Loading template…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            }
        }
    }

    /// Single source of truth for how the wizard is wired into the hub.
    /// Cancellation + completion always route through `handleHubReturn`
    /// so the hub-side cleanup lives in exactly one place: view-model
    /// reset (mode + drafts + library count) plus the
    /// pending-recurring refresh that's intentionally view-owned.
    @ViewBuilder
    private func wizard(
        draft: (board: Board, boardTasks: [BoardTask])?,
        prefilledRecurringTimeframe: Timeframe?,
        targetWindowDate: Date?,
        editingTemplate: RecurringBoardTemplate?,
        startRecurring: Bool = false,
        initialStep: WizardStep = 1
    ) -> some View {
        BoardWizardView(
            userId: userId,
            preferences: preferences,
            draft: draft,
            prefilledRecurringTimeframe: prefilledRecurringTimeframe,
            targetWindowDate: targetWindowDate,
            editingTemplate: editingTemplate,
            startRecurring: startRecurring,
            initialStep: initialStep,
            onCancel: { handleHubReturn() },
            onComplete: { boardId, status in
                onBoardCompleted?(boardId, status)
                handleHubReturn()
            },
            onTemplateComplete: { templateId in
                onTemplateCompleted?(templateId)
                handleHubReturn()
            },
            onDeleteDraft: { boardId in
                // Cancel-dialog "Delete draft" path: drop the draft + its
                // placements, then close the wizard back to the hub. The
                // drafts list refreshes via the standard reloadDrafts path.
                vm.deleteDraft(boardId: boardId, userId: userId)
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

    // MARK: - Hub content (Riso)

    /// Riso-styled hub landing: `RisoPaperBackground` behind a scrolling
    /// VStack with kicker + H1, core-boards section, CTA cards, and drafts.
    ///
    /// Layout mirrors the Boards home (`BoardListView`) pattern:
    ///   kicker → H1 → content cards, all scrolling (no sticky header).
    @ViewBuilder
    private var hubContent: some View {
        // Demote the custom-board CTA only when at least one core-board
        // slot needs creation today — the persistent Core Boards section
        // is the headline action in that case. When every enabled slot
        // is already done (or no recurring timeframes are enabled at
        // all), the CTA stays primary so the user has an obvious next
        // action.
        let hasUncreatedCoreBoards = pendingRecurringVM.slots.contains { $0.currentBoard == nil }

        ZStack {
            RisoPaperBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    // Kicker + H1 header
                    hubHeader

                    CoreBoardsSectionView(
                        slots: pendingRecurringVM.slots,
                        onSelect: { slot in
                            // Already on the Create tab — whole-row tap flips
                            // mode directly into the wizard for that
                            // timeframe's current window, no cross-tab hop.
                            // To browse past/future windows the user goes to
                            // the Boards tab.
                            vm.enterCoreBoardWizard(timeframe: slot.timeframe)
                        },
                        subtitle: "Your standard board for each time period."
                    )

                    CreateHubBoardCTAView(
                        kind: .oneOff,
                        onTap: { vm.enterFreshWizard() },
                        variant: hasUncreatedCoreBoards ? .secondary : .primary
                    )

                    // Issue #71 — recurring-board creation is its own deliberate
                    // entry point, always the lighter secondary card below the
                    // one-off CTA.
                    CreateHubBoardCTAView(
                        kind: .recurring,
                        onTap: { vm.enterRecurringTemplateWizard() },
                        variant: .secondary
                    )

                    if !vm.drafts.isEmpty {
                        CreateHubDraftsListView(
                            drafts: vm.drafts,
                            onResume: { board in
                                vm.loadDraftAndEnterWizard(board: board)
                            },
                            onDelete: { board in
                                vm.deleteDraft(boardId: board.id, userId: userId)
                            }
                        )
                    }
                }
                // Hub mode pads itself; wizard mode pads inside each step view.
                .padding(.horizontal, Riso.gutter)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
    }

    /// Kicker + H1 matching the Boards home header convention.
    private var hubHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Build something")
                .risoKicker()
            Text("Create")
                .risoH1()
                .padding(.top, 4)
        }
    }
}
