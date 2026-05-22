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
        /// Wizard launched from the Recurring Boards banner with a
        /// pre-selected timeframe. The setup step locks the timeframe
        /// field; everything else behaves like `wizardFresh`. When
        /// `targetWindowDate` is non-nil (Phase B — core-board
        /// browser pre-spawn), the wizard's `computedBoundaries`
        /// resolve against that date instead of "now", so the
        /// persisted window matches the picked one.
        case wizardRecurring(timeframe: Timeframe, targetWindowDate: Date?)
        /// Wizard launched in template-edit mode (Profile → Recurring
        /// templates → Edit). The wizard hydrates from the template
        /// and Save updates the template instead of creating a board.
        case wizardEditTemplate(templateId: String)
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

    func enterRecurringWizard(timeframe: Timeframe, targetWindowDate: Date? = nil) {
        resumeDraft = nil
        mode = .wizardRecurring(timeframe: timeframe, targetWindowDate: targetWindowDate)
    }

    // MARK: - Async loaders

    func reloadDrafts(userId: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
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
                let boardTasks = try AppDatabase.shared.fetchBoardTasks(boardId: board.id)
                DispatchQueue.main.async {
                    self.resumeDraft = (board, boardTasks)
                    self.mode = .wizardResume(boardId: board.id)
                }
            } catch {
                DispatchQueue.main.async {
                    self.resumeDraft = nil
                    self.mode = .wizardFresh
                    print("⚠️ Failed to load draft \(board.id): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Cross-tab edit hydration. Sets `wizardEditTemplate` mode
    /// immediately (so the view can show a loading state) and then
    /// fetches the template. A concurrently-deleted template falls
    /// back to fresh-create with a log.
    func loadTemplateAndEnterWizard(templateId: String) {
        mode = .wizardEditTemplate(templateId: templateId)
        editingTemplate = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let template = try AppDatabase.shared.fetchRecurringBoardTemplate(id: templateId)
                DispatchQueue.main.async {
                    if let template = template {
                        self.editingTemplate = template
                    } else {
                        print("⚠️ Recurring template \(templateId) no longer exists")
                        self.mode = .wizardFresh
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    print("⚠️ Failed to load recurring template \(templateId): \(error.localizedDescription)")
                    self.mode = .wizardFresh
                }
            }
        }
    }
}
