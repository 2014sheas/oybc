import Foundation
import GRDB
import Observation

/// CreateHubViewModel — Owns the Create tab's hub-mode state and the
/// GRDB loaders that feed the drafts list, library count, and the two
/// wizard hydration paths (resume-draft and edit-recurring-template).
///
/// iOS twin of `CreateHubPage`'s inline `useState` + the dedicated
/// hooks under `apps/web/src/pages/createHub/`. The web side splits
/// this into per-concern hooks because hooks are the React idiom; on
/// iOS the established pattern (see `BoardWizardViewModel`,
/// `CreateFormViewModel`, `TaskLibraryViewModel`) is one `@Observable`
/// view-model per surface, with persistence inside.
///
/// `pendingRecurringVM` is intentionally *not* embedded here — it is
/// already its own `@Observable` instance and the view binds it
/// directly. Nesting view-models adds an indirection without removing
/// any state from the view.
@Observable
final class CreateHubViewModel {

    enum HubMode: Equatable {
        case hub
        case wizardFresh
        case wizardResume(boardId: String)
        /// Wizard launched for a specific timeframe *window* — a one-off
        /// **core** board (Boards-tab banner / core-board browser /
        /// Create-hub Core Boards row). The timeframe is fixed to the
        /// window and the title auto-set; the setup step collapses to
        /// size + center (#70). `isCore` is true, `isRecurring` false —
        /// core boards are NOT recurring templates (#71 decoupled them).
        /// When `targetWindowDate` is non-nil (Phase B — core-board
        /// browser pre-spawn), the wizard's `computedBoundaries` resolve
        /// against that date instead of "now".
        case wizardCoreBoard(timeframe: Timeframe, targetWindowDate: Date?)
        /// Wizard launched in template-edit mode (Profile → Recurring
        /// templates → Edit). The wizard hydrates from the template
        /// and Save updates the template instead of creating a board.
        /// `initialStep` (issue #321) lets the "Add tasks" card
        /// affordance land the user on the Tasks step (2) directly
        /// instead of Setup (1); the whole-card tap keeps the default of
        /// step 1.
        case wizardEditTemplate(templateId: String, initialStep: WizardStep)
    }

    // MARK: - State

    var mode: HubMode = .hub
    var resumeDraft: (board: Board, boardTasks: [BoardTask])? = nil
    var drafts: [DraftRowData] = []

    /// Hydrated template for `wizardEditTemplate` mode. Loaded
    /// asynchronously when the edit-template deep link is consumed;
    /// the wizard mounts only after this resolves so its view-model's
    /// hydration runs against real data.
    var editingTemplate: RecurringBoardTemplate? = nil

    // MARK: - DB injection

    /// Injected for tests; defaults to the production singleton.
    @ObservationIgnored private let database: AppDatabase

    init(database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Mode transitions

    /// Reset the hub to its landing state. Clears any resume-draft
    /// hydration and reloads the on-screen data so newly-saved drafts
    /// appear without a tab-switch.
    func returnToHub(userId: String) {
        mode = .hub
        resumeDraft = nil
        editingTemplate = nil
        reloadDrafts(userId: userId)
    }

    func enterFreshWizard() {
        resumeDraft = nil
        mode = .wizardFresh
    }

    /// Enter the wizard for a one-off core board scoped to a timeframe
    /// window (banner / core-board browser / Create-hub Core Boards row).
    func enterCoreBoardWizard(timeframe: Timeframe, targetWindowDate: Date? = nil) {
        resumeDraft = nil
        mode = .wizardCoreBoard(timeframe: timeframe, targetWindowDate: targetWindowDate)
    }

    // MARK: - Async loaders

    func reloadDrafts(userId: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let draftBoards: [Board] = try self.database.read { db in
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
                    let count = try self.database.fetchBoardTasks(boardId: board.id).count
                    rows.append(DraftRowData(board: board, taskCount: count))
                }
                DispatchQueue.main.async { self.drafts = rows }
            } catch {
                DispatchQueue.main.async { self.drafts = [] }
            }
        }
    }

    /// Tap-a-draft hydration: fetch the draft's placements and enter
    /// `wizardResume` mode. Falls back to fresh-create on error so the
    /// user can still recover.
    func loadDraftAndEnterWizard(board: Board) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let boardTasks = try self.database.fetchBoardTasks(boardId: board.id)
                DispatchQueue.main.async {
                    self.resumeDraft = (board, boardTasks)
                    self.mode = .wizardResume(boardId: board.id)
                }
            } catch {
                DispatchQueue.main.async {
                    self.resumeDraft = nil
                    self.mode = .wizardFresh
                    dlog("⚠️ Failed to load draft \(board.id): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Cross-tab draft-resume by id: fetch the draft board (then defer to
    /// `loadDraftAndEnterWizard(board:)` for placement hydration). Used by the
    /// Boards-tab draft tap, which only has the board id. Falls back to
    /// fresh-create if the board can't be loaded (e.g. deleted meanwhile).
    func loadDraftAndEnterWizard(boardId: String, userId: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let board = try? self.database.fetchBoard(id: boardId)
            DispatchQueue.main.async {
                if let board {
                    self.loadDraftAndEnterWizard(board: board)
                } else {
                    self.resumeDraft = nil
                    self.mode = .wizardFresh
                    dlog("⚠️ Failed to load draft board \(boardId) for resume")
                }
            }
        }
    }

    /// Delete a draft + its attached BoardTask placements atomically.
    /// Caller (the drafts list × button OR the wizard's cancel-dialog
    /// "Delete draft" button) has already shown a confirm before
    /// invoking this, so we go straight to the DB call. The
    /// `reloadDrafts` follow-up keeps the list in sync with GRDB.
    /// Errors are logged and the draft stays visible — the user can
    /// retry.
    func deleteDraft(boardId: String, userId: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.database.deleteDraftWithCascade(id: boardId)
                DispatchQueue.main.async {
                    self.reloadDrafts(userId: userId)
                }
            } catch {
                dlog("⚠️ Failed to delete draft \(boardId): \(error.localizedDescription)")
            }
        }
    }

    /// Cross-tab edit hydration. Sets `wizardEditTemplate` mode
    /// immediately (so the view can show a loading state) and then
    /// fetches the template. A concurrently-deleted template falls
    /// back to fresh-create with a log.
    ///
    /// - Parameter initialStep: which wizard step to land on once
    ///   hydrated. Defaults to 1 (Setup) for the whole-card tap; the
    ///   card's "Add tasks" affordance (issue #321) passes 2 (Tasks) so
    ///   the user lands directly on the pool picker.
    func loadTemplateAndEnterWizard(templateId: String, initialStep: WizardStep = 1) {
        mode = .wizardEditTemplate(templateId: templateId, initialStep: initialStep)
        editingTemplate = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let template = try self.database.fetchRecurringBoardTemplate(id: templateId)
                DispatchQueue.main.async {
                    if let template = template {
                        self.editingTemplate = template
                    } else {
                        dlog("⚠️ Recurring template \(templateId) no longer exists")
                        self.mode = .wizardFresh
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    dlog("⚠️ Failed to load recurring template \(templateId): \(error.localizedDescription)")
                    self.mode = .wizardFresh
                }
            }
        }
    }
}
