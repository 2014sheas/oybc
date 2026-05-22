import SwiftUI

/// One row in the core-board browser. Two visually consistent variants:
///
///   - **Filled** (cell.board != nil): renders `BoardListItemView` so
///     the row matches the standard Boards-tab list. Tap navigates to
///     `BoardPlayView`.
///   - **Empty**: a Create CTA (calendar icon + "Create [window label]")
///     that opens the wizard pre-filled for that window. Past empty
///     cells are tagged "Past window" so the user knows they're
///     backfilling.
///
/// Current-window cell gets a subtle accent border to orient the user.
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
        VStack(alignment: .leading, spacing: 6) {
            metaRow
            if let board = cell.board {
                filledContent(board: board)
            } else {
                emptyContent
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    cell.isCurrentWindow ? Color.accentColor : Color(.separator),
                    lineWidth: cell.isCurrentWindow ? 2 : 1
                )
        )
    }

    // MARK: - Header

    private var metaRow: some View {
        HStack(spacing: 8) {
            Text(cell.windowLabel.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if cell.isCurrentWindow {
                badge(text: "CURRENT", filled: true)
            } else if cell.isPastWindow && cell.board == nil {
                badge(text: "PAST WINDOW", filled: false)
            }
            Spacer(minLength: 0)
        }
    }

    private func badge(text: String, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(filled ? .white : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(filled ? Color.accentColor : Color(.tertiarySystemBackground))
            )
            .overlay(
                Capsule().strokeBorder(
                    filled ? Color.clear : Color(.separator),
                    lineWidth: 1
                )
            )
    }

    // MARK: - Filled

    @ViewBuilder
    private func filledContent(board: Board) -> some View {
        Button {
            onOpenBoard(board.id)
        } label: {
            BoardListItemView(board: board)
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
                    .font(.system(size: 16, weight: .semibold))
                Text(cell.isPastWindow ? "Backfill \(cell.windowLabel)" : "Create \(cell.windowLabel)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundColor(.accentColor)
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1, dash: [4])
                    )
            )
        }
        .buttonStyle(.plain)
        .opacity(cell.isPastWindow ? 0.75 : 1.0)
        .accessibilityLabel(
            cell.isPastWindow
                ? "Backfill \(cell.windowLabel)"
                : "Create board for \(cell.windowLabel)"
        )
    }
}
