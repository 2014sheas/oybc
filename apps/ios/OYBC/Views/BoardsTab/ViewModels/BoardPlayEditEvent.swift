import Foundation

// MARK: - BoardPlayEditEvent

/// One-shot edit-commit signal published by `BoardPlayViewModel` after a
/// `handleEditSave` DB commit completes. The commit + domain refresh
/// (`reload()`) happen in the view model; this carries ONLY the residual
/// view-owned UI mutations the view still runs — `editSaving` / `editMode` /
/// `editSaveError` / the "Board saved" toast — which depend on view `@State`
/// and can't move. Archive moved off this event entirely in Board Edit
/// redesign slice 2 (T2) — it's a plain `async throws` call from the "…"
/// menu now (`BoardPlayViewModel.archiveBoard()` /
/// `BoardActionsPresenter`), not a squares-editor Save outcome.
///
/// Mirrors `BoardPlayFlashEvent`'s one-shot pattern (monotonic `id` so
/// consecutive emissions stay distinct for the view's `.onChange`).
struct BoardPlayEditEvent: Identifiable, Equatable {
    let id: Int
    let outcome: Outcome

    enum Outcome: Equatable {
        /// Save committed → view resets `editSaving`, flips `editMode` off
        /// (animated), and flashes the "Board saved" toast.
        case saved
        /// Save threw → view resets `editSaving` and shows the alert via
        /// `editSaveError`. Carries the user-facing error copy.
        case saveFailed(String)
        /// Slice 2 (D11) — the board was sealed or deleted since edit mode
        /// opened; the save transaction rolled back. Never `.saved`. Carries
        /// the user-facing copy (`BoardEditError.boardClosedMessage`); the
        /// view shows it through its OWN "Board closed" alert (T3) and
        /// exits edit mode on OK.
        case boardClosed(String)
    }
}
