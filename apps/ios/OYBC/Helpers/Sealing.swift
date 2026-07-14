import Foundation

// MARK: - Board sealing detection (Swift port of algorithms/sealing.ts)
//
// Swift port of `packages/shared/src/algorithms/sealing.ts` (Windowed
// Completion, docs/WINDOWED_COMPLETION.md §Sealing → Lifecycle + Backstop,
// §Migration step 3, §Edge cases). Pure predicates that own the "which boards
// can/should seal" decision so both platforms + the migration agree
// byte-for-byte. The TS file is the source of truth.

/// Whether a board is eligible to seal at all (docs §Lifecycle → Detection): a
/// real, closeable window that isn't already sealed. Excludes soft-deleted,
/// already-sealed, DRAFT, and indefinite boards. Archived boards ARE sealable
/// (archived is a status, orthogonal to sealing). Mirrors `isBoardSealable`.
func isBoardSealable(_ board: Board) -> Bool {
    if board.isDeleted { return false }
    if board.sealedAt != nil { return false }
    if board.status == .draft { return false }
    if board.isIndefinite { return false }
    return true
}

/// Whether a board's window has closed and it awaits close-out (docs §Lifecycle
/// → Detection: the "closing-out set"). Sealable AND its `endDate` is strictly
/// before `now`. The prompt set (banner UX is slice 2). Mirrors
/// `isBoardClosingOut`.
///
/// - Parameters:
///   - board: The board to test.
///   - nowMs: Current time as epoch ms.
func isBoardClosingOut(_ board: Board, nowMs: Double) -> Bool {
    guard isBoardSealable(board) else { return false }
    guard let endDate = board.endDate, let end = DateFormatting.parseISO(endDate) else { return false }
    return end.timeIntervalSince1970 * 1000 < nowMs
}

/// Whether a board is past its auto-seal backstop deadline (docs §Lifecycle →
/// Backstop). Sealable AND `now` is beyond the timeframe-scaled deadline, which
/// keys off `max(endDate, activatedAt)` — so a DRAFT activated after its window
/// already expired still gets one full prompt cycle before any silent seal.
/// Both the lazy app-open backstop check and the migration's expired-board
/// sealing gate on this. Mirrors `isBoardPastBackstop`.
///
/// - Parameters:
///   - board: The board to test.
///   - nowMs: Current time as epoch ms.
func isBoardPastBackstop(_ board: Board, nowMs: Double) -> Bool {
    guard isBoardSealable(board) else { return false }
    guard let deadline = computeBackstopDeadlineMs(
        startDate: board.startDate,
        endDate: board.endDate,
        activatedAt: board.activatedAt
    ) else { return false }
    return nowMs > deadline
}

/// Whether board-PLAY interactions are locked (docs §Effects of sealed —
/// "Not editable": tap-to-complete, counter stepper, context-menu actions,
/// the empty-cell "+" add affordance, and the toolbar Edit entry point).
/// `BoardPlayView.isBoardLocked` composes this predicate.
///
/// A board locks when — and only when — it is SEALED. Sealing REPLACES the
/// old expiry-based interaction lock: per docs §Sealing → Lifecycle, an
/// expired-but-unsealed board is "still fully live" (the closing-out
/// banner's **Log** action depends on this — the 11:58pm workout logged at
/// 12:04am counts for the closing daily), and the timeframe-scaled backstop
/// bounds the overtime, after which the board auto-seals and locks. A sealed
/// board can never be interacted with again (no unseal gesture in v1).
///
/// Extracted as a standalone pure function (rather than left inline in the
/// view) so the gating rule is unit-testable without instantiating SwiftUI.
///
/// - Parameter board: The board to test.
/// - Returns: `true` iff every play interaction should be disabled.
func isBoardPlayLocked(_ board: Board) -> Bool {
    board.sealedAt != nil
}
