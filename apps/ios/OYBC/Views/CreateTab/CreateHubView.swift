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
    /// Called after a board is successfully activated or saved as a
    /// draft. Parent typically navigates to the created board; the
    /// hub itself always returns to its landing view.
    var onBoardCompleted: ((_ boardId: String, _ status: String) -> Void)? = nil

    private enum HubMode: Equatable {
        case hub
        case wizardFresh
        case wizardResume(boardId: String)
        /// Wizard launched from the Recurring Boards banner with a
        /// pre-selected timeframe. The setup step locks the timeframe
        /// field; everything else behaves like `wizardFresh`.
        case wizardRecurring(timeframe: Timeframe)
    }

    @State private var mode: HubMode = .hub
    @State private var resumeDraft: (board: Board, boardTasks: [BoardTask])? = nil

    @State private var drafts: [DraftRowData] = []
    @State private var libraryCount: Int = 0

    var body: some View {
        switch mode {
        case .hub:
            hubContent
                .onAppear {
                    reloadDrafts()
                    reloadLibraryCount()
                    // Consume the recurring-banner deep link, if any.
                    // Same behavior as web's URL-param consumption +
                    // immediate clear in CreateHubPage.
                    if let timeframe = pendingRecurringTimeframe.wrappedValue {
                        pendingRecurringTimeframe.wrappedValue = nil
                        mode = .wizardRecurring(timeframe: timeframe)
                    }
                }
        case .wizardFresh:
            BoardWizardView(
                userId: userId,
                preferences: preferences,
                draft: nil,
                prefilledRecurringTimeframe: nil,
                onCancel: { returnToHub() },
                onComplete: { boardId, status in
                    onBoardCompleted?(boardId, status)
                    returnToHub()
                }
            )
        case .wizardResume:
            BoardWizardView(
                userId: userId,
                preferences: preferences,
                draft: resumeDraft,
                prefilledRecurringTimeframe: nil,
                onCancel: { returnToHub() },
                onComplete: { boardId, status in
                    onBoardCompleted?(boardId, status)
                    returnToHub()
                }
            )
        case .wizardRecurring(let timeframe):
            BoardWizardView(
                userId: userId,
                preferences: preferences,
                draft: nil,
                prefilledRecurringTimeframe: timeframe,
                onCancel: { returnToHub() },
                onComplete: { boardId, status in
                    onBoardCompleted?(boardId, status)
                    returnToHub()
                }
            )
        }
    }

    @ViewBuilder
    private var hubContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Create")
                .font(.largeTitle)
                .fontWeight(.bold)

            CreateHubBoardCTAView {
                resumeDraft = nil
                mode = .wizardFresh
            }

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
