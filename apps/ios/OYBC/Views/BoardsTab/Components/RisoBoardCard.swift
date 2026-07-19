import SwiftUI

/// Riso-styled board card shown in the Boards home list.
///
/// Renders the board name (19px Bricolage 800), timeframe subtitle, status
/// badge, 5×5 mini-grid thumbnail, progress bar, and meta line. Wrapped by
/// `BoardListView` in a `NavigationLink` + swipe-to-delete — this view is
/// presentational only and takes all data as props.
///
/// Progress bar is red for active/expiring boards and green for completed ones.
/// Meta line shows "N/M squares" and, when `linesCompleted > 0`, "★ N bingo(s)".
struct RisoBoardCard: View {

    let board: Board
    /// Pre-computed timeframe label from `formatTimeframeLabel`.
    let timeframeLabel: String
    /// Whether this board is expiring soon (drives the badge color).
    let isExpiring: Bool
    /// Pre-computed TRUE preview cells (bugfix/board-preview-real-cells).
    /// `BoardListView` (a LIST of cards) batch-builds these once via
    /// `BoardPreviewCells.fetchWorkspaceData`/`buildMany` and always passes a
    /// non-nil value (an all-empty placeholder while its batch fetch is in
    /// flight) — it never relies on the `nil` fallback below, since that
    /// fallback mounting per-card is exactly the N-cards-N-reads perf bug the
    /// batch hoist fixes. `nil` (the default) is for genuinely single-card
    /// contexts only — `CoreBoardWindowCellView` (one board per pager
    /// screen) — where it self-loads via `RisoBoardPreviewGrid`. Snapshot
    /// tests inject a value directly so the DB is never touched.
    var previewCells: BoardPreviewCellsResult? = nil

    private var progressValue: Double {
        guard board.totalTasks > 0 else { return 0 }
        return Double(board.completedTasks) / Double(board.totalTasks)
    }

    private var progressColor: Color {
        board.status == .completed ? .risoGreen : .risoRed
    }

    private var badgeKind: RisoBoardStatusBadge.Kind {
        .init(status: board.status, isExpiring: isExpiring)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: name + timeframe on left, status badge + mini-grid on right
            HStack(alignment: .top, spacing: 12) {
                // Left column
                VStack(alignment: .leading, spacing: 5) {
                    Text(board.name)
                        .font(.risoHead(19, .extraBold))
                        .tracking(-0.38)
                        .foregroundStyle(Color.risoInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(timeframeLabel)
                        .font(.risoBody(11.5, .bold))
                        .foregroundStyle(Color.risoMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                // Right column: badge(s) stacked above mini-grid
                VStack(alignment: .trailing, spacing: 9) {
                    VStack(alignment: .trailing, spacing: 4) {
                        // Windowed Completion — a sealed board shows the
                        // "Sealed" pill in place of the live status badge
                        // (docs §Effects of sealed; OQ1 resolution: single
                        // badge, no distinct "ended-but-empty" treatment).
                        if board.sealedAt != nil {
                            RisoSealedBadge()
                        } else {
                            RisoBoardStatusBadge(kind: badgeKind)
                        }
                        // Issue #321 — provenance tag for recurring-spawned boards.
                        if RisoRecurringBadge.shouldShow(for: board) {
                            RisoRecurringBadge()
                        }
                    }
                    if let previewCells {
                        RisoMiniGrid(gridSize: previewCells.size, cells: previewCells.cells)
                    } else {
                        RisoBoardPreviewGrid(board: board)
                    }
                }
                .fixedSize()
            }

            // Progress bar
            RisoProgressBar(value: progressValue, color: progressColor)
                .padding(.top, 14)
                .padding(.bottom, 10)

            // Meta line
            metaLine
        }
        .padding(15)
        .risoCard()
        .risoHardShadow(Riso.Shadow.card)
    }

    @ViewBuilder
    private var metaLine: some View {
        HStack(spacing: 8) {
            Text("\(board.completedTasks)/\(board.totalTasks) squares")
                .font(.risoBody(11.5, .bold))
                .foregroundStyle(Color.risoMuted)

            if board.linesCompleted > 0 {
                Text("·")
                    .font(.risoBody(11.5, .bold))
                    .foregroundStyle(Color.risoMuted)

                HStack(spacing: 4) {
                    // Gold star shape
                    Image(systemName: "star.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 11, height: 11)
                        .foregroundStyle(Color.risoGold)
                        .overlay(
                            Image(systemName: "star")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 11, height: 11)
                                .foregroundStyle(Color.risoInk)
                                .fontWeight(.bold)
                        )
                    Text("\(board.linesCompleted) bingo\(board.linesCompleted == 1 ? "" : "s")")
                        .font(.risoBody(11.5, .bold))
                        .foregroundStyle(Color.risoInk)
                }
            }
        }
    }
}

#if DEBUG
/// Builds a Board fixture via JSON round-trip (same technique as SnapshotFixtures.makeBoard).
private func previewBoard(
    id: String, name: String, timeframe: Timeframe,
    status: BoardStatus, completed: Int = 12, total: Int = 25, lines: Int = 1
) -> Board {
    let dict: [String: Any] = [
        "id": id, "userId": "preview-user", "name": name,
        "status": status.rawValue, "boardSize": 5,
        "timeframe": timeframe.rawValue,
        "startDate": "2026-06-01T00:00:00.000",
        "endDate": "2026-06-30T23:59:59.999",
        "centerSquareType": "free", "isRandomized": false,
        "totalTasks": total, "completedTasks": completed,
        "linesCompleted": lines, "completedLineIds": "[]",
        "createdAt": "2026-06-01T00:00:00.000",
        "updatedAt": "2026-06-01T00:00:00.000",
        "version": 1, "isCore": false, "isDeleted": false,
    ]
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(Board.self, from: data)
}

#Preview("Board Cards") {
    ZStack {
        RisoPaperBackground()
        ScrollView {
            VStack(spacing: 12) {
                RisoBoardCard(
                    board: previewBoard(id: "b-a", name: "Weekly Wellness", timeframe: .weekly, status: .active),
                    timeframeLabel: "This week · 4 days left",
                    isExpiring: false
                )
                RisoBoardCard(
                    board: previewBoard(id: "b-c", name: "January Reading Sprint", timeframe: .monthly, status: .completed, completed: 25, total: 25, lines: 3),
                    timeframeLabel: "January 2026",
                    isExpiring: false
                )
                RisoBoardCard(
                    board: previewBoard(id: "b-d", name: "My New Board", timeframe: .weekly, status: .draft, completed: 0, lines: 0),
                    timeframeLabel: "This week",
                    isExpiring: false
                )
                RisoBoardCard(
                    board: previewBoard(id: "b-e", name: "Fitness February", timeframe: .monthly, status: .active, completed: 20),
                    timeframeLabel: "This month · expires soon",
                    isExpiring: true
                )
            }
            .padding(Riso.gutter)
        }
    }
}
#endif
