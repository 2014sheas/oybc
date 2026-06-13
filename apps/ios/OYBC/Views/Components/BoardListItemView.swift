import SwiftUI

/// BoardListItemView — A single board row in the board list.
///
/// Mirrors the web `BoardListItem` component in `BoardListItem.tsx`.
///
/// Displays:
/// - Board name and timeframe label
/// - Progress bar with task completion count
/// - Bingo count (when > 0)
/// - Expiry indicator
/// - Status badge (trailing)
///
/// - Parameter board: The `Board` record to render.
struct BoardListItemView: View {

    // MARK: - Parameters

    let board: Board

    // MARK: - Derived Properties

    private var progressFraction: Double {
        guard board.totalTasks > 0 else { return 0 }
        return Double(board.completedTasks) / Double(board.totalTasks)
    }

    private var progressText: String {
        "\(board.completedTasks)/\(board.totalTasks) tasks"
    }

    private var timeframeLabel: String? {
        guard board.timeframe != .custom,
              let startDate = parseISO8601Date(board.startDate)
        else { return nil }
        return formatTimeframeLabel(timeframe: board.timeframe, startDate: startDate)
    }

    private var expired: Bool {
        isBoardExpired(board)
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                // Board name
                Text(board.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // Timeframe label (hidden for custom timeframe)
                if let label = timeframeLabel {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Progress bar
                ProgressView(value: progressFraction)
                    .tint(board.status == .completed ? .green : .accentColor)
                    .accessibilityLabel("\(Int(progressFraction * 100))% complete")

                // Meta row: task count, bingo count, expiry
                HStack(spacing: 6) {
                    Text(progressText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if board.linesCompleted > 0 {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(board.linesCompleted == 1
                             ? "1 bingo"
                             : "\(board.linesCompleted) bingos")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fontWeight(.medium)
                    }

                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(getExpiryLabel(board))
                        .font(.caption2)
                        .foregroundStyle(expired ? .red : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            BoardStatusBadgeView(status: board.status)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preview Helpers

/// Decodes a Board from a dictionary literal for use in SwiftUI previews.
/// Board has a custom Codable decoder so the memberwise init is unavailable.
private func previewBoard(_ dict: [String: Any]) -> Board {
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(Board.self, from: data)
}

#Preview {
    let now = ISO8601DateFormatter().string(from: Date())
    let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(7 * 86_400))

    let activeBoard = previewBoard([
        "id": "1", "userId": "u1", "name": "Weekly Wellness",
        "status": "active", "boardSize": 5, "timeframe": "weekly",
        "startDate": now, "endDate": future,
        "centerSquareType": "free", "isRandomized": false,
        "totalTasks": 10, "completedTasks": 4, "linesCompleted": 1,
        "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false
    ])

    let draftBoard = previewBoard([
        "id": "2", "userId": "u1", "name": "Draft Board",
        "status": "draft", "boardSize": 5, "timeframe": "custom",
        "startDate": now, "endDate": future,
        "centerSquareType": "free", "isRandomized": false,
        "totalTasks": 0, "completedTasks": 0, "linesCompleted": 0,
        "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false
    ])

    let completedBoard = previewBoard([
        "id": "3", "userId": "u1", "name": "Monthly Goals",
        "status": "completed", "boardSize": 5, "timeframe": "monthly",
        "startDate": now, "endDate": future,
        "centerSquareType": "free", "isRandomized": false,
        "totalTasks": 25, "completedTasks": 25, "linesCompleted": 3,
        "createdAt": now, "updatedAt": now, "version": 1, "isDeleted": false
    ])

    List {
        BoardListItemView(board: activeBoard)
        BoardListItemView(board: draftBoard)
        BoardListItemView(board: completedBoard)
    }
}
