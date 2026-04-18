import SwiftUI

/// Minimal payload passed to the hub's drafts list — one row per
/// draft Board with a precomputed task count. Supplied by
/// `CreateHubView` which loads the rows on appear and after the
/// wizard dismisses.
struct DraftRowData: Identifiable {
    let board: Board
    let taskCount: Int
    var id: String { board.id }
}

/// CreateHubDraftsListView — Lists the user's DRAFT boards so they
/// can be resumed. iOS twin of web's `CreateHubDraftsList`. Only
/// rendered when `drafts.count > 0`.
struct CreateHubDraftsListView: View {
    let drafts: [DraftRowData]
    let onResume: (Board) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("DRAFTS")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                Text("\(drafts.count)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }

            VStack(spacing: 6) {
                ForEach(drafts) { row in
                    DraftRow(row: row, onResume: onResume)
                }
            }
        }
    }
}

private struct DraftRow: View {
    let row: DraftRowData
    let onResume: (Board) -> Void

    var body: some View {
        Button {
            onResume(row.board)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.board.name.isEmpty ? "(untitled draft)" : row.board.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text("\(row.board.boardSize)×\(row.board.boardSize) · \(row.taskCount) task\(row.taskCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(.systemGray4), lineWidth: 1)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume \"\(row.board.name)\", \(row.board.boardSize) by \(row.board.boardSize) board with \(row.taskCount) tasks")
    }
}
