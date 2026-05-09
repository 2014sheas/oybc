import SwiftUI
import GRDB

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
/// The hub owns the wizard-mount state so the two surfaces
/// transition in-place. Dismissing the wizard (Cancel / Activate /
/// Save Draft) returns to the hub and triggers a drafts reload.
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

    private enum HubMode: Equatable {
        case hub
        case wizardFresh
        case wizardResume(boardId: String)
        /// Wizard launched from the Recurring Boards banner with a
        /// pre-selected timeframe. The setup step locks the timeframe
        /// field; everything else behaves like `wizardFresh`.
        case wizardRecurring(timeframe: Timeframe)
        /// Wizard launched in template-edit mode (Profile → Recurring
        /// templates → Edit). The wizard hydrates from the template
        /// and Save updates the template instead of creating a board.
        case wizardEditTemplate(templateId: String)
    }

    @State private var mode: HubMode = .hub
    @State private var resumeDraft: (board: Board, boardTasks: [BoardTask])? = nil

    @State private var drafts: [DraftRowData] = []
    @State private var libraryCount: Int = 0

    /// Phase 6.1d: pending core boards (daily/weekly/monthly/yearly) that
    /// the user hasn't created yet for the current windows. When non-empty,
    /// the prominent `PendingCoreBoardsSectionView` becomes the headline
    /// action and the existing `CreateHubBoardCTAView` is demoted to a
    /// secondary "Custom timeframe board" affordance below it.
    @State private var pendingRecurringVM = PendingRecurringBoardsViewModel()

    /// Phase 6.2 UX rework: hydrated template for `wizardEditTemplate`
    /// mode. Loaded asynchronously when `pendingEditTemplateId` is
    /// consumed; the wizard mounts only after this resolves so the
    /// view-model's hydration runs against real data.
    @State private var editingTemplate: RecurringBoardTemplate? = nil

    var body: some View {
        switch mode {
        case .hub:
            hubContent
                .onAppear {
                    reloadDrafts()
                    reloadLibraryCount()
                    pendingRecurringVM.reloadAsync(userId: userId)
                    // Consume the recurring-banner deep link, if any.
                    // Same behavior as web's URL-param consumption +
                    // immediate clear in CreateHubPage.
                    if let timeframe = pendingRecurringTimeframe.wrappedValue {
                        pendingRecurringTimeframe.wrappedValue = nil
                        mode = .wizardRecurring(timeframe: timeframe)
                        return
                    }
                    // Consume the edit-template deep link, if any.
                    // Fetch the template first; mount the wizard only
                    // after hydration so its view-model sees real data.
                    if let templateId = pendingEditTemplateId.wrappedValue {
                        pendingEditTemplateId.wrappedValue = nil
                        loadTemplateAndEnterWizard(templateId: templateId)
                    }
                }
        case .wizardFresh:
            BoardWizardView(
                userId: userId,
                preferences: preferences,
                draft: nil,
                prefilledRecurringTimeframe: nil,
                editingTemplate: nil,
                onCancel: { returnToHub() },
                onComplete: { boardId, status in
                    onBoardCompleted?(boardId, status)
                    returnToHub()
                },
                onTemplateComplete: { templateId in
                    onTemplateCompleted?(templateId)
                    returnToHub()
                }
            )
        case .wizardResume:
            BoardWizardView(
                userId: userId,
                preferences: preferences,
                draft: resumeDraft,
                prefilledRecurringTimeframe: nil,
                editingTemplate: nil,
                onCancel: { returnToHub() },
                onComplete: { boardId, status in
                    onBoardCompleted?(boardId, status)
                    returnToHub()
                },
                onTemplateComplete: { templateId in
                    onTemplateCompleted?(templateId)
                    returnToHub()
                }
            )
        case .wizardRecurring(let timeframe):
            BoardWizardView(
                userId: userId,
                preferences: preferences,
                draft: nil,
                prefilledRecurringTimeframe: timeframe,
                editingTemplate: nil,
                onCancel: { returnToHub() },
                onComplete: { boardId, status in
                    onBoardCompleted?(boardId, status)
                    returnToHub()
                },
                onTemplateComplete: { templateId in
                    onTemplateCompleted?(templateId)
                    returnToHub()
                }
            )
        case .wizardEditTemplate:
            // The mode is set BEFORE `editingTemplate` is set (when
            // hydration is in flight) and AFTER (once loaded). Render
            // a thin loading state in the in-flight window so the
            // wizard doesn't mount with stale state.
            if let template = editingTemplate {
                BoardWizardView(
                    userId: userId,
                    preferences: preferences,
                    draft: nil,
                    prefilledRecurringTimeframe: nil,
                    editingTemplate: template,
                    onCancel: { returnToHub() },
                    onComplete: { boardId, status in
                        onBoardCompleted?(boardId, status)
                        returnToHub()
                    },
                    onTemplateComplete: { templateId in
                        onTemplateCompleted?(templateId)
                        returnToHub()
                    }
                )
            } else {
                ProgressView("Loading template…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            }
        }
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
                    resumeDraft = nil
                    mode = .wizardRecurring(timeframe: entry.timeframe)
                }
            )

            CreateHubBoardCTAView(
                onTap: {
                    resumeDraft = nil
                    mode = .wizardFresh
                },
                variant: hasPendingCoreBoards ? .secondary : .primary
            )

            if !drafts.isEmpty {
                CreateHubDraftsListView(
                    drafts: drafts,
                    onResume: { board in
                        loadDraftAndEnterWizard(board: board)
                    }
                )
            }

            librarySection

            CreateHubQuickAddView(
                userId: userId,
                onTaskCreated: {
                    reloadLibraryCount()
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
                libraryCount == 0
                    ? "No tasks yet — quick-add below or pick some when you build a board."
                    : "\(libraryCount) task\(libraryCount == 1 ? "" : "s") ready to place on a board."
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

    // MARK: - State transitions

    private func returnToHub() {
        mode = .hub
        resumeDraft = nil
        reloadDrafts()
        reloadLibraryCount()
        // Refresh pending core boards so a board the user just created
        // disappears from the section without needing a tab-switch.
        pendingRecurringVM.reloadAsync(userId: userId)
    }

    private func loadDraftAndEnterWizard(board: Board) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let boardTasks = try AppDatabase.shared.fetchBoardTasks(boardId: board.id)
                DispatchQueue.main.async {
                    resumeDraft = (board, boardTasks)
                    mode = .wizardResume(boardId: board.id)
                }
            } catch {
                // Fallback: just open the wizard fresh and surface the
                // error via a log — draft hydration failed but the
                // user can still create a new board.
                DispatchQueue.main.async {
                    resumeDraft = nil
                    mode = .wizardFresh
                    print("⚠️ Failed to load draft \(board.id): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Phase 6.2 UX rework: cross-tab edit hydration. The Profile-tab
    /// `RecurringTemplatesView` writes a `pendingEditTemplateId` and
    /// switches to Create; we fetch the template here and mount the
    /// wizard in `wizardEditTemplate` mode. If the template can't be
    /// found (deleted concurrently), surface a log and fall back to
    /// the fresh-create wizard so the user can recover.
    private func loadTemplateAndEnterWizard(templateId: String) {
        // Set the mode immediately so the user gets a "loading" view;
        // the wizard mounts after editingTemplate hydrates.
        mode = .wizardEditTemplate(templateId: templateId)
        editingTemplate = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let template = try AppDatabase.shared.fetchRecurringBoardTemplate(id: templateId)
                DispatchQueue.main.async {
                    if let template = template {
                        editingTemplate = template
                    } else {
                        print("⚠️ Recurring template \(templateId) no longer exists")
                        mode = .wizardFresh
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    print("⚠️ Failed to load recurring template \(templateId): \(error.localizedDescription)")
                    mode = .wizardFresh
                }
            }
        }
    }

    // MARK: - Data loaders

    private func reloadDrafts() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let draftBoards: [Board] = try AppDatabase.shared.read { db in
                    try Board
                        .filter(
                            Column("userId") == userId
                            && Column("status") == "draft"
                            && Column("isDeleted") == false
                        )
                        .order(Column("updatedAt").desc)
                        .fetchAll(db)
                }
                var rows: [DraftRowData] = []
                for board in draftBoards {
                    let count = try AppDatabase.shared.fetchBoardTasks(boardId: board.id).count
                    rows.append(DraftRowData(board: board, taskCount: count))
                }
                DispatchQueue.main.async { drafts = rows }
            } catch {
                DispatchQueue.main.async { drafts = [] }
            }
        }
    }

    private func reloadLibraryCount() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Post-unification, compounds (formerly composite_tasks)
                // live in the `tasks` table with type='compound', so
                // `fetchTasks` already returns them. The previous
                // implementation also queried the legacy `composite_tasks`
                // table and added its row count, which double-counted
                // every compound for any user that had one.
                let tasks = try AppDatabase.shared.fetchTasks(userId: userId)
                let total = tasks.count
                DispatchQueue.main.async { libraryCount = total }
            } catch {
                DispatchQueue.main.async { libraryCount = 0 }
            }
        }
    }

}
