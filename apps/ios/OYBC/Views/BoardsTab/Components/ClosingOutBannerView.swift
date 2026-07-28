import SwiftUI

/// ClosingOutBannerView — Boards-tab prompt for boards whose window has
/// closed (docs/WINDOWED_COMPLETION.md §Sealing → Lifecycle → Prompt). iOS
/// twin of web's `ClosingOutBanner.tsx`.
///
/// Deliberately the same lazy-detection banner vocabulary as the recurring
/// Core Boards grid (OQ3 resolution: one row per closing board — mirrors the
/// 6.1 recurring-window prompt, which already renders one tappable row per
/// pending window). Each row: the board name + the window that ended, a
/// **Log** action (opens the still-live board — the closing window keeps
/// evaluating events until sealed) and a **Seal** action (freezes the
/// snapshot via the seal transaction). The row disappears once the board is
/// sealed (the caller's VM reload drops it).
///
/// Pure leaf view — takes data + closures as props, holds no persistence, so
/// it renders deterministically for snapshot coverage.
struct ClosingOutBannerView: View {
    /// Boards whose window has ended but which aren't sealed yet.
    let boards: [Board]
    /// The board id currently mid-seal (disables that row's buttons + shows
    /// "Sealing…"). `nil` when no seal is in flight.
    var sealingBoardId: String? = nil
    /// Open the (still fully live) board to log any last activity.
    let onLog: (String) -> Void
    /// Seal the board — freeze its window into a permanent record.
    let onSeal: (String) -> Void

    var body: some View {
        if !boards.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 12, weight: .bold))
                    Text("WINDOWS CLOSED")
                        .font(.risoHead(11, .bold))
                        .tracking(0.8)
                }
                .foregroundStyle(Color.risoInk)

                VStack(spacing: 8) {
                    ForEach(boards, id: \.id) { board in
                        ClosingOutBoardRow(
                            board: board,
                            isSealing: sealingBoardId == board.id,
                            onLog: { onLog(board.id) },
                            onSeal: { onSeal(board.id) }
                        )
                    }
                }
            }
            .padding(14)
            .risoCard(fill: .risoPaper2)
            .risoHardShadow(Riso.Shadow.card)
        }
    }
}

/// One closing-out board row: name + "Ended <window> — anything left to log?"
/// + Log/Seal actions.
private struct ClosingOutBoardRow: View {
    let board: Board
    let isSealing: Bool
    let onLog: () -> Void
    let onSeal: () -> Void

    private var windowLabel: String {
        guard let start = parseISO8601Date(board.startDate) else {
            return board.timeframe.rawValue.capitalized
        }
        return formatTimeframeLabel(timeframe: board.timeframe, startDate: start)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(board.name)
                    .font(.risoHead(14, .extraBold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                Text("Ended \(windowLabel) — anything left to log?")
                    .font(.risoBody(11.5, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                RisoButton(title: "Log", kind: .neutral, small: true) { onLog() }
                    .disabled(isSealing)
                RisoButton(title: isSealing ? "Closing…" : "Close out", kind: .gold, small: true) { onSeal() }
                    .disabled(isSealing)
                    .accessibilityLabel("Close out \(board.name)")
            }
        }
        .padding(10)
        .risoCard(fill: .risoPaper)
        .risoHardShadow(Riso.Shadow.small)
    }
}

#if DEBUG
private func previewClosingBoard(id: String, name: String, timeframe: Timeframe) -> Board {
    let dict: [String: Any] = [
        "id": id, "userId": "preview-user", "name": name,
        "status": "active", "boardSize": 5,
        "timeframe": timeframe.rawValue,
        "startDate": "2026-06-01T00:00:00.000",
        "endDate": "2026-06-01T23:59:59.999",
        "centerSquareType": "free", "isRandomized": false,
        "totalTasks": 25, "completedTasks": 12,
        "linesCompleted": 0, "completedLineIds": "[]",
        "createdAt": "2026-06-01T00:00:00.000",
        "updatedAt": "2026-06-01T00:00:00.000",
        "version": 1, "isCore": false, "isDeleted": false,
    ]
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(Board.self, from: data)
}

#Preview("Closing Out Banner") {
    ZStack {
        RisoPaperBackground()
        ScrollView {
            ClosingOutBannerView(
                boards: [
                    previewClosingBoard(id: "b-1", name: "Daily Reset", timeframe: .daily),
                    previewClosingBoard(id: "b-2", name: "Weekly Wellness", timeframe: .weekly),
                ],
                sealingBoardId: "b-2",
                onLog: { _ in },
                onSeal: { _ in }
            )
            .padding(Riso.gutter)
        }
    }
}
#endif
