import Foundation

/// One entry in the board title row's "…" menu (Board Edit redesign slice 2,
/// D3 — docs/BOARD_EDIT_REDESIGN.md). Twin of web `BoardMenuItem` in
/// `apps/web/src/components/boardActions/boardMenu.ts`; the raw values are the
/// web `kind` strings so the two case tables read line-for-line.
enum BoardMenuItem: String, Identifiable, Equatable {
    case details
    case coreDefaults
    case repeatBoard = "repeat"
    case archive
    case delete

    var id: String { rawValue }

    /// Menu row label — copy verbatim from the design handoff.
    var label: String {
        switch self {
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
        case .details, .coreDefaults: return "slider.horizontal.3"
        case .repeatBoard: return "repeat"
        case .archive: return "archivebox"
        case .delete: return "trash"
        }
    }

    /// Destructive rows render red (`role: .destructive`).
    var isDestructive: Bool { self == .delete }
}

/// Pure builder for the board "…" menu (slice 2, D3 + D6). No DB, no view
/// state — the caller passes the board and its resolved source record.
enum BoardMenuItems {

    /// The menu rows for `board`, in display order.
    ///
    /// - Draft boards: no menu (the draft-resume prompt replaces the header).
    /// - Core boards: `Core defaults… · Delete` — name, timeframe, repeats and
    ///   archive are not fields on a core board.
    /// - Ad-hoc, editable (`active` + not sealed): `Board details… ·
    ///   Repeat this board… (if eligible) · Archive · Delete`.
    /// - Ad-hoc, not editable (sealed / ended / archived): `Delete` only —
    ///   Repeat back-stamps and Archive rewrites the row, both writes to a
    ///   closed record, so they wait for slice 4's closed-board rules.
    ///
    /// - Parameters:
    ///   - board: The board the menu is for.
    ///   - sourceTemplate: The board's resolved repeat record, or nil when it
    ///     has none or it hasn't resolved (yet).
    /// - Returns: The ordered menu items; empty means "show no menu".
    static func items(board: Board, sourceTemplate: RecurringBoardTemplate?) -> [BoardMenuItem] {
        if board.status == .draft { return [] }
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
