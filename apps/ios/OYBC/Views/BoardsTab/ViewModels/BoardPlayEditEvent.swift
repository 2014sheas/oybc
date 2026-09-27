import Foundation

// MARK: - BoardPlayEditEvent

/// One-shot edit-commit signal published by `BoardPlayViewModel` after a
/// `handleEditSave` / `handleEditArchive` DB commit completes. The commit +
/// domain refresh (`reload()`) happen in the view model; this carries ONLY the
/// residual view-owned UI mutations the view still runs — `editSaving` /
/// `editMode` / `editSaveError` / the "Board saved" toast / `dismiss()` — which
/// depend on view `@State` and the `dismiss` environment and can't move.
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
        /// view shows it through the same alert as `.saveFailed`.
        case boardClosed(String)
        /// Archive committed → view flips `editMode` off (animated) and
        /// `dismiss()`es back to the Boards list.
        case archived
    }
}
