import SwiftUI

// MARK: - BoardPlayView + BoardActions

/// The Edit screen's BOARD-section routing + the `BoardActionsPresenter`
/// wiring, split out of `BoardPlayView.swift` (Board Edit consolidation —
/// file-size guardrail, D11; same ROADMAP-B6-style extraction as
/// `+Header.swift`). Reads view-owned `@State`/`@StateObject` that stayed
/// `internal` (not `private`) specifically so this file can see it —
/// `editMode`, `boardAction`, `viewModel`, `board`, `dismiss`.
extension BoardPlayView {

    /// Board Edit consolidation (D9) — routes a tapped BOARD-section row to
    /// the matching `BoardAction`. Close/Reopen apply `draftPolicy`'s
    /// `discardFirst`: those rows only exist when `!canEditSquares` (D3), so
    /// a dirty squares draft here is only reachable via the D3 race — the
    /// board was still editable at Edit entry and ended/sealed mid-session.
    /// When dirty, route through the "Discard changes?" confirm first;
    /// otherwise behave exactly as before consolidation.
    func handleBoardItem(_ item: BoardMenuItem) {
        if BoardMenuItems.draftPolicy(for: item) == .discardFirst, viewModel.editSquaresEditCount > 0 {
            boardAction = .confirmDiscard(then: item)
            return
        }
        switch item {
        case .close: boardAction = .close
        case .reopen: boardAction = .confirmReopen
        case .details: boardAction = .details
        case .repeatBoard: boardAction = .repeatBoard
        case .coreDefaults: boardAction = .coreDefaults
        case .archive: boardAction = .confirmArchive
        case .delete: boardAction = .confirmDelete
        }
    }

    /// The BOARD-section sheets/confirms + Close/Reopen/Archive/Delete
    /// wiring, keyed off `boardAction`. A computed property (rather than an
    /// inline `.modifier(...)` construction) purely for the file-size split.
    var boardActionsPresenter: BoardActionsPresenter {
        BoardActionsPresenter(
            activeAction: $boardAction,
            board: board,
            sourceTemplate: viewModel.editSourceTemplate,
            weekStartDay: authService.currentUser?.decodedPreferences.weekStartDay.rawValue ?? "monday",
            userId: authService.currentUser?.id ?? "",
            viewModel: viewModel,
            squaresDirty: viewModel.editSquaresEditCount > 0,
            onDetailsSaved: { triggerBoardSavedToast() },
            // D9 — Close/Reopen success returns to the play surface; its
            // CLOSED/ENDED pill flip IS the feedback (no toast).
            onExitEdit: { withAnimation(.easeInOut(duration: 0.22)) { editMode = false } },
            onRemoved: {
                // D9 — Delete used to be unreachable while editing; now the
                // core-window pager could lose its board out from under an
                // open Edit screen, and this view unmounts before its
                // `editMode` `.onChange` observer would fire. Notify the
                // host explicitly so the chip/paging never stay locked.
                editMode = false
                onEditModeChange?(false)
                if board?.isCore == true {
                    onBoardRemoved?()
                } else {
                    dismiss()
                }
            }
        )
    }
}
