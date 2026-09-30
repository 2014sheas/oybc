import Foundation

/// Delete the repeating board a wizard session is EDITING (Profile reorg
/// PR3 — Delete moved from the Board-settings roster row into the editor's
/// Setup step). iOS twin of web `deleteEditedRecurringTemplate`
/// (`wizardPersist.ts`).
///
/// Routes through the SAME `softDeleteRecurringBoardTemplateAndEnqueue`
/// op the old roster button called: a soft-delete tombstone with a version
/// bump + a DELETE sync-queue item, atomically. Boards already created from
/// the template are deliberately untouched (as before). Nothing else in the
/// session is persisted — pending tasks / staged edits are simply dropped
/// with the wizard.
///
/// Runs on a background queue; dispatches callbacks on the main queue.
/// `onError` fires (with nothing written) when the controller is not
/// editing a repeating board — a fresh session has nothing to delete, and
/// reaching this from one is a wiring bug, not a user-facing state.
///
/// - Parameters:
///   - controller: The wizard ViewModel; must be in edit mode.
///   - database: The database to write through (callers pass
///     `controller.database`; defaults to `.shared`).
///   - onSuccess: Receives the deleted template's id (for `onTemplateComplete`).
///   - onError: Receives a human-readable failure message.
func deleteEditedRecurringTemplate(
    controller: BoardWizardViewModel,
    database: AppDatabase = .shared,
    onSuccess: @escaping (_ templateId: String) -> Void,
    onError: @escaping (_ message: String) -> Void
) {
    guard let templateId = controller.editingTemplateId else {
        onError("The wizard is not editing a repeating board.")
        return
    }
    let now = AppDatabase.currentTimestamp()
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            try database.softDeleteRecurringBoardTemplateAndEnqueue(id: templateId, now: now)
            DispatchQueue.main.async { onSuccess(templateId) }
        } catch {
            DispatchQueue.main.async { onError(error.localizedDescription) }
        }
    }
}
