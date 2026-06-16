import SwiftUI

/// One row in the core-board browser. Two visually consistent variants:
///
///   - **Filled** (cell.board != nil): renders `RisoBoardCard` so the
///     row matches the standard Riso board-list style. Tap navigates to
///     `BoardPlayView`.
///   - **Empty**: a Riso-styled Create CTA (dashed keyline button) that
///     opens the wizard pre-filled for that window. Past empty cells are
///     tagged "Past window" so the user knows they're backfilling.
///
/// Current-window cell gets a gold accent stripe so the user can
/// quickly orient around "now" while browsing the list.
///
/// Mirrors the web `CoreBoardWindowCell` component
/// (`apps/web/src/pages/core-board-browser/CoreBoardWindowCell.tsx`).
struct CoreBoardWindowCellView: View {
    let cell: CoreBoardWindowCell
    let timeframe: Timeframe
    /// Tap target for a filled cell. Receives the matched board's id.
    let onOpenBoard: (String) -> Void
    /// Tap target for an empty cell. Receives the window's start Date
    /// (already a local-time date the wizard can use as-is) and the
    /// timeframe.
    let onCreate: (Date, Timeframe) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            metaRow
            if let board = cell.board {
                filledContent(board: board)
            } else {
                emptyContent
            }
        }
        .padding(Riso.cardPadding)
        .background(Color.risoPaper2)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(
                    cell.isCurrentWindow ? Color.risoGold : Color.risoInk,
                    lineWidth: cell.isCurrentWindow ? Riso.Keyline.container : Riso.Keyline.dense
                )
        )
        .risoHardShadow(
            cell.isCurrentWindow ? Riso.Shadow.card : Riso.Shadow.small,
            radius: Riso.cardRadius
        )
    }

    // MARK: - Header

    private var metaRow: some View {
        HStack(spacing: 8) {
            Text(cell.windowLabel.uppercased())
                .risoSectionLabel()
                .lineLimit(1)
                .truncationMode(.tail)

            if cell.isCurrentWindow {
                currentBadge
            } else if cell.isPastWindow && cell.board == nil {
                pastBadge
            }

            Spacer(minLength: 0)
        }
    }

    /// Gold-filled "CURRENT" badge — matches the CoreTimeframeCard "Active" dot language.
    private var currentBadge: some View {
        Text("CURRENT")
            .font(.risoHead(10, .bold))
            .tracking(0.5)
            .foregroundStyle(Color.risoInk)
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .background(Capsule().fill(Color.risoGold))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }

    /// Quiet muted "PAST WINDOW" badge for empty backfill slots.
    private var pastBadge: some View {
        Text("PAST WINDOW")
            .font(.risoHead(10, .bold))
            .tracking(0.5)
            .foregroundStyle(Color.risoMuted)
            .padding(.vertical, 3)
            .padding(.horizontal, 9)
            .background(Capsule().fill(Color.risoPaper))
            .overlay(Capsule().strokeBorder(Color.risoMuted, lineWidth: Riso.Keyline.dense))
    }

    // MARK: - Filled

    /// Renders the board using `RisoBoardCard` so the browser cell matches
    /// the Boards-home list aesthetics exactly. The card is wrapped in a
    /// plain button so the whole surface taps through to BoardPlayView.
    @ViewBuilder
    private func filledContent(board: Board) -> some View {
        Button {
            onOpenBoard(board.id)
        } label: {
            RisoBoardCard(
                board: board,
                timeframeLabel: windowTimeframeLabel(board),
                isExpiring: false
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty

    private var emptyContent: some View {
        Button {
            // Convert the local-ISO startDate string into a Date the
            // wizard can use as its target window reference. Using the
            // start-of-day is correct: `computeTimeframeBoundaries`
            // re-snaps to the full window's boundaries regardless.
            if let date = parseISO8601Date(cell.windowStart) {
                onCreate(date, timeframe)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 15, weight: .bold))
                Text(cell.isPastWindow
                     ? "Backfill \(cell.windowLabel)"
                     : "Create \(cell.windowLabel)")
                    .font(.risoHead(14, .bold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(cell.isPastWindow ? Color.risoMuted : Color.risoInk)
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .fill(Color.risoPaper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(
                        cell.isPastWindow ? Color.risoMuted : Color.risoInk,
                        style: StrokeStyle(
                            lineWidth: Riso.Keyline.dense,
                            dash: [5, 3]
                        )
                    )
            )
        }
        .buttonStyle(.plain)
        .opacity(cell.isPastWindow ? 0.7 : 1.0)
        .accessibilityLabel(
            cell.isPastWindow
                ? "Backfill \(cell.windowLabel)"
                : "Create board for \(cell.windowLabel)"
        )
    }

    // MARK: - Helpers

    /// Produces a minimal timeframe label for the inner `RisoBoardCard`
    /// (e.g. "Weekly window" or just the board's raw timeframe string).
    /// A full `formatTimeframeLabel` call would be ideal but requires a
    /// parsed startDate — use the windowLabel since it is already human-readable.
    private func windowTimeframeLabel(_ board: Board) -> String {
        cell.windowLabel
    }
}
