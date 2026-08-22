import SwiftUI

/// CreateHubView — Landing surface for the Create tab. iOS twin of
/// web's `CreateHubPage`.
///
/// Composes:
/// - `CreateHubBoardCTAView` × 2 (Board Creation Split, iOS PR A): a RED
///   one-off card and a BLUE recurring card, each swapping the view into
///   its own mode-locked wizard instance.
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
    /// the user hasn't created yet for the current windows, surfaced via
    /// `CoreBoardsSectionView` above the two hub CTAs. Board Creation Split
    /// (iOS PR A) retired the CTA-demotion behavior this once drove — the
    /// CTAs are always shown at full strength now; only this section's own
    /// presence/emptiness changes. Kept as its own observable on the view
    /// rather than embedding it in `CreateHubViewModel` — it's already an
    /// `@Observable` and nesting adds an indirection without removing state
    /// from the view.
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
                    // Consume the draft-resume deep link, if any. Fetch the
                    // draft board + its placements, then enter wizardResume —
                    // same hydration path as tapping a row in the drafts list.
                    if let draftId = pendingDraftId.wrappedValue {
                        pendingDraftId.wrappedValue = nil
                        vm.loadDraftAndEnterWizard(boardId: draftId, userId: userId)
                    }
                }
        case .wizardFresh(let startRecurring):
            wizard(draft: nil, prefilledRecurringTimeframe: nil, targetWindowDate: nil, startRecurring: startRecurring)
        case .wizardResume:
            wizard(
                draft: vm.resumeDraft,
                prefilledRecurringTimeframe: nil,
                targetWindowDate: nil,
                initialStep: vm.resumeInitialStep
            )
        case .wizardCoreBoard(let timeframe, let targetWindowDate):
            wizard(draft: nil, prefilledRecurringTimeframe: timeframe, targetWindowDate: targetWindowDate)
        }
    }

    /// Single source of truth for how the wizard is wired into the hub.
    /// Cancellation + completion always route through `handleHubReturn`
    /// so the hub-side cleanup lives in exactly one place: view-model
    /// reset (mode + drafts + library count) plus the
    /// pending-recurring refresh that's intentionally view-owned.
    ///
    /// P7 (Task Pools + Recurring Boards Rework): dropped the
    /// `editingTemplate` parameter — its only feeder was the
    /// `.wizardEditTemplate` hub mode, which was itself only reachable
    /// from the now-retired Profile → Recurring templates page's cross-tab
    /// Edit/"Add tasks" callbacks. `BoardWizardView`/`BoardWizardViewModel`
    /// still support `editingTemplate:` as a general capability (exercised
    /// directly by `BoardWizardViewModel` unit tests) — only this one dead
    /// UI trigger path is gone.
    @ViewBuilder
    private func wizard(
        draft: (board: Board, boardTasks: [BoardTask])?,
        prefilledRecurringTimeframe: Timeframe?,
        targetWindowDate: Date?,
        startRecurring: Bool = false,
        initialStep: WizardStep = 1
    ) -> some View {
        BoardWizardView(
            userId: userId,
            preferences: preferences,
            draft: draft,
            prefilledRecurringTimeframe: prefilledRecurringTimeframe,
            targetWindowDate: targetWindowDate,
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

                    // Board Creation Split (iOS PR A) — two stacked
                    // full-width CTAs under a "NEW BOARD" section label,
                    // mode locked at the tap. Always shown at full
                    // strength; the retired primary/secondary demotion
                    // logic lived here before the split.
                    VStack(alignment: .leading, spacing: 10) {
                        Text("New board")
                            .risoSectionLabel()

                        CreateHubBoardCTAView(kind: .oneOff) {
                            vm.enterFreshWizard(startRecurring: false)
                        }

                        CreateHubBoardCTAView(kind: .recurring) {
                            vm.enterFreshWizard(startRecurring: true)
                        }
                    }

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
