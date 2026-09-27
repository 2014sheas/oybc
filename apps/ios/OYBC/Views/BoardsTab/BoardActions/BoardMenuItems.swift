import Foundation

/// One entry in the Edit screen's BOARD section (Board Edit redesign slice 2,
/// D3, superseded by the Edit consolidation D6 — docs/BOARD_EDIT_REDESIGN.md).
/// Twin of web `BoardMenuItem` in
/// `apps/web/src/components/boardActions/boardMenu.ts`; the raw values are the
/// web `kind` strings so the two case tables read line-for-line.
enum BoardMenuItem: String, Identifiable, Equatable {
    case close
    case reopen
    case details
    case coreDefaults
    case repeatBoard = "repeat"
    case archive
    case delete

    var id: String { rawValue }

    /// Menu row label — copy verbatim from the design handoff.
    var label: String {
        switch self {
        case .close: return "Close board"
        case .reopen: return "Reopen board"
        case .details: return "Board details…"
        case .coreDefaults: return "Core defaults…"
        case .repeatBoard: return "Repeat this board…"
        case .archive: return "Archive"
        case .delete: return "Delete"
        }
    }

    /// SF Symbol for the menu row.
    var systemImage: String {
        switch self {
        case .close: return "lock"
        case .reopen: return "lock.open"
        case .details, .coreDefaults: return "slider.horizontal.3"
        case .repeatBoard: return "repeat"
        case .archive: return "archivebox"
        case .delete: return "trash"
        }
    }

    /// Destructive rows render red (`role: .destructive`).
    var isDestructive: Bool { self == .delete }
}

/// Board Edit consolidation — dirty-squares-draft handling per BOARD-section
/// row kind (D8). Decided once per row kind, not per board instance.
enum BoardItemDraftPolicy: Equatable {
    /// The sheet opens over the Edit screen; the squares draft is untouched
    /// (both platforms' squares commits are field-level and never re-seed
    /// the draft on reload) — `.details`, `.repeatBoard`, `.coreDefaults`.
    case keep
    /// The action leaves the screen, so the draft dies with it; when dirty
    /// the confirm body gets `BoardMenuItems.discardSquaresSuffix` appended
    /// — `.archive`, `.delete`.
    case discardInConfirm
    /// Only reachable with a dirty draft via the D3 race (squares were
    /// editable at Edit entry, then the board ended/sealed mid-session):
    /// show a "Discard changes?" confirm first — `.close`, `.reopen`.
    case discardFirst
}

/// Pure builder for the Edit screen's BOARD section (slice 2, D3 + D6). No
/// DB, no view state — the caller passes the board and its resolved source
/// record.
enum BoardMenuItems {

    /// Board Edit consolidation (D2) — the Edit gate: any non-draft board.
    /// Drafts never reach the play surface (the draft-resume prompt replaces
    /// the header), so this only ever reads `false` for a draft in practice.
    ///
    /// - Parameter board: The board to test.
    /// - Returns: `true` unless `board.status == .draft`.
    static func showsEditButton(board: Board) -> Bool {
        board.status != .draft
    }

    /// Board Edit consolidation (D3) — the SQUARES section gate, captured
    /// once at Edit entry (it does not flip mid-session; a board that ends
    /// or seals while the user edits keeps its squares section, and the
    /// existing Save-time "Board closed" guard handles that race). Exactly
    /// slice 4's D13 rule, named and shared instead of copied three times.
    ///
    /// - Parameters:
    ///   - board: The board to test.
    ///   - now: Current time (epoch ms).
    /// - Returns: `true` iff the SQUARES grid should be editable.
    static func canEditSquares(board: Board, now: Double) -> Bool {
        board.status == .active && board.sealedAt == nil && !isBoardEnded(board, nowMs: now)
    }

    /// Board Edit consolidation (D4) — the muted explanation line shown in
    /// place of the SQUARES grid when `canEditSquares` is false. Copy
    /// verbatim from the design decision; `nil` when squares ARE editable.
    ///
    /// - Parameters:
    ///   - board: The board to test.
    ///   - now: Current time (epoch ms).
    /// - Returns: The reason line, or `nil` when squares are editable.
    static func squaresLockedReason(board: Board, now: Double) -> String? {
        if canEditSquares(board: board, now: now) { return nil }
        if board.status == .archived {
            return "This board is archived, so its squares can't change."
        }
        if isBoardEnded(board, nowMs: now) || isBoardClosed(board) {
            return "This board has ended, so its squares can't change."
        }
        return "This board is complete, so its squares can't change."
    }

    /// Board Edit consolidation (D8) — the dirty-squares-draft policy for a
    /// given BOARD-section row kind. Pure lookup, not board-instance-aware.
    ///
    /// - Parameter kind: The row's `BoardMenuItem`.
    /// - Returns: How that row should treat a dirty squares draft.
    static func draftPolicy(for kind: BoardMenuItem) -> BoardItemDraftPolicy {
        switch kind {
        case .details, .repeatBoard, .coreDefaults: return .keep
        case .archive, .delete: return .discardInConfirm
        case .close, .reopen: return .discardFirst
        }
    }

    /// Board Edit consolidation (D8) — appended verbatim to the Archive /
    /// Delete confirm body when the squares draft is dirty.
    static let discardSquaresSuffix = " Your unsaved square changes will be discarded."

    /// The menu rows for `board`, in display order (Board Edit redesign
    /// slice 4, D12 — extends slice 2's table with Ended/Closed rows).
    ///
    /// - Draft boards: no menu (the draft-resume prompt replaces the header).
    /// - Archived boards: unchanged from slice 2 (`Core defaults…, Delete` /
    ///   `Delete`) — no Close/Reopen on an archived board (OQ5).
    /// - **Ended** (window over, not sealed yet): ad-hoc → `Close board ·
    ///   Board details… · Repeat this board… (if eligible) · Archive ·
    ///   Delete`; core → `Close board · Core defaults… · Delete`.
    /// - **Closed** (sealed): ad-hoc → `Reopen board · Repeat this board…
    ///   (if eligible) · Archive · Delete` (no Board details); core →
    ///   `Reopen board · Core defaults… · Delete`.
    /// - Core, live: `Core defaults… · Delete`.
    /// - Ad-hoc, live (`active` + not sealed + not ended): `Board details… ·
    ///   Repeat this board… (if eligible) · Archive · Delete`.
    ///
    /// - Parameters:
    ///   - board: The board the menu is for.
    ///   - sourceTemplate: The board's resolved repeat record, or nil when it
    ///     has none or it hasn't resolved (yet).
    ///   - now: Current time (epoch ms) — decides Ended vs Closed vs live.
    /// - Returns: The ordered menu items; empty means "show no menu".
    static func items(board: Board, sourceTemplate: RecurringBoardTemplate?, now: Double) -> [BoardMenuItem] {
        if board.status == .draft { return [] }

        if isBoardClosed(board) {
            if board.isCore { return [.reopen, .coreDefaults, .delete] }
            var items: [BoardMenuItem] = [.reopen]
            if isRepeatEligible(board: board, sourceTemplate: sourceTemplate) { items.append(.repeatBoard) }
            items.append(contentsOf: [.archive, .delete])
            return items
        }

        if isBoardEnded(board, nowMs: now) {
            if board.isCore { return [.close, .coreDefaults, .delete] }
            var items: [BoardMenuItem] = [.close, .details]
            if isRepeatEligible(board: board, sourceTemplate: sourceTemplate) { items.append(.repeatBoard) }
            items.append(contentsOf: [.archive, .delete])
            return items
        }

        if board.isCore { return [.coreDefaults, .delete] }
        let editable = board.status == .active && board.sealedAt == nil
        guard editable else { return [.delete] }
        var items: [BoardMenuItem] = [.details]
        if isRepeatEligible(board: board, sourceTemplate: sourceTemplate) {
            items.append(.repeatBoard)
        }
        items.append(contentsOf: [.archive, .delete])
        return items
    }

    /// Whether "Repeat this board…" is offered — the same hide rule the old
    /// in-panel REPEATS section used (`BoardEditPanel.showsOneOffRepeat` +
    /// `repeatInfo != nil`).
    ///
    /// - A one-off board (no `spawnedFromTemplateId`) is eligible when its
    ///   EFFECTIVE center is FREE or NONE — always, since slice 3 (D5): a
    ///   legacy CHOSEN board reads as NONE + a locked center and repeats with
    ///   a NONE-center template (locks don't carry into templates).
    /// - A repeating board is eligible only once its source record resolved —
    ///   an unresolved record has nothing to pause or resume.
    ///
    /// - Parameters:
    ///   - board: The board.
    ///   - sourceTemplate: Its resolved repeat record, if any.
    /// - Returns: `true` if the Repeat item should show.
    static func isRepeatEligible(board: Board, sourceTemplate: RecurringBoardTemplate?) -> Bool {
        if board.spawnedFromTemplateId == nil {
            // Effective center is always FREE or NONE — both repeatable.
            return true
        }
        return sourceTemplate != nil
    }
}
