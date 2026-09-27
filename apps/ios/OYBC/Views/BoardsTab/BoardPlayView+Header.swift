import SwiftUI

// MARK: - BoardPlayView + Header

/// The play board's in-content title row + a couple of small stat-bar text
/// helpers, split out of `BoardPlayView.swift` (Board Edit redesign slice 2
/// — that file was already at its frozen file-size cap before slice 2's
/// "…" menu additions; this is a ROADMAP-B6-style extraction, not a cap
/// bump). Everything here reads view-owned `@State`/`@StateObject` that
/// stayed `internal` (not `private`) specifically so this file can see it —
/// see each property's "internal for the +Header extension split" comment
/// in `BoardPlayView.swift`.
extension BoardPlayView {

    /// Kicker text derived from the board's timeframe (e.g. "WEEKLY BOARD").
    var boardKicker: String {
        guard let b = board else { return "BOARD" }
        switch b.timeframe {
        case .daily:   return "DAILY BOARD"
        case .weekly:  return "WEEKLY BOARD"
        case .monthly: return "MONTHLY BOARD"
        case .yearly:  return "YEARLY BOARD"
        case .custom:  return "CUSTOM BOARD"
        case .indefinite: return "ONGOING BOARD"
        }
    }

    // MARK: - Riso Play Header

    /// In-content header (masthead layout): back button (non-embedded
    /// only) + the extracted `BoardPlayHeaderView` leaf (kicker · name +
    /// inline streak chip · badge row · a single `Edit` slot — Board Edit
    /// consolidation, D1/D2). The Edit gate is
    /// `BoardMenuItems.showsEditButton(board:) && !editMode` (any non-draft
    /// board, not already editing) on both platforms — the edit overlay
    /// (SQUARES + BOARD section) replaces this chrome while open, and
    /// decides internally whether its SQUARES section is itself editable
    /// (`BoardMenuItems.canEditSquares`, D3).
    @ViewBuilder
    var risoPlayHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            // Back button — hidden when embedded (host owns navigation chrome)
            if !embedded {
                // SwiftUI's NavigationStack owns the back gesture; this button
                // is a visual affordance only. Calling dismiss via the environment
                // is the idiomatic way to pop without a NavigationLink.
                risoBackButton
            }

            BoardPlayHeaderView(
                kicker: boardKicker,
                name: board?.name ?? "",
                nameSize: embedded ? 24 : 22,
                streakValue: greenlogStreakValue,
                status: board?.status,
                isSealed: isSealed,
                isEnded: isEnded,
                showRecurringBadge: board.map { RisoRecurringBadge.shouldShow(for: $0) } ?? false,
                canEdit: board.map(BoardMenuItems.showsEditButton) == true && !editMode,
                onEdit: {
                    guard let b = board else { return }
                    // Board Edit consolidation (D3) — frozen once, at entry;
                    // does not flip mid-session even if the board ends/seals
                    // while the user edits (the Save-time "Board closed"
                    // guard owns that race).
                    editSquaresEditable = BoardMenuItems.canEditSquares(
                        board: b, now: Date().timeIntervalSince1970 * 1000
                    )
                    viewModel.seedEditDraft(from: b)
                    // `seedEditDraft` used to reset `editSaving` inline;
                    // it stays view-side, so reset it here.
                    editSaving = false
                    withAnimation(.easeInOut(duration: 0.22)) { editMode = true }
                }
            )
        }
    }

    @ViewBuilder
    var risoBackButton: some View {
        // In-content back square. When !embedded, BoardPlayTitleChrome hides
        // the system nav-bar back button, so this IS the primary back
        // affordance (the swipe-back gesture still works); when embedded the
        // host owns the chrome. Uses the environment dismiss action.
        BackButton()
    }

    // NOTE: the status pill moved into `BoardPlayHeaderView` (core-board
    // surface rework header extraction).

    /// Short end-date string for the sealed ENDED stat card ("Aug 31").
    func risoEndedText(board: Board) -> String {
        guard let endStr = board.endDate, let end = parseISO8601Date(endStr) else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "MMM d"
        return f.string(from: end)
    }

    /// Compact expiry string for the stat bar — "4d", "Expired", "Today", etc.
    /// A custom board with an end date counts down like a timed board (it seals
    /// at that date too); only INDEFINITE / no-endDate boards read "No end".
    func risoExpiryText(board: Board) -> String {
        guard !board.isIndefinite else { return "No end" }
        guard let endStr = board.endDate, let end = parseISO8601Date(endStr) else { return "—" }
        let now = Date()
        guard now <= end else { return "Expired" }
        let secs = end.timeIntervalSince(now)
        if secs < 86_400 { return "Today" }
        let days = Int(ceil(secs / 86_400))
        return "\(days)d"
    }
}
