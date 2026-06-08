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
///
/// Each row pairs the tappable resume area with a trailing `xmark`
/// button. The destructive button opens a confirmation `Alert` before
/// invoking the caller-supplied `onDelete` callback; parent runs
/// `AppDatabase.deleteDraftWithCascade(id:)` and triggers a reload.
struct CreateHubDraftsListView: View {
    let drafts: [DraftRowData]
    let onResume: (Board) -> Void
    let onDelete: (Board) -> Void

    @State private var deleteTarget: DraftRowData?

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
                    DraftRow(row: row, onResume: onResume) {
                        deleteTarget = row
                    }
                }
            }
        }
        .alert("Delete draft?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        ), presenting: deleteTarget) { row in
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
            Button("Delete", role: .destructive) {
                onDelete(row.board)
                deleteTarget = nil
            }
        } message: { row in
            let name = row.board.name.isEmpty ? "(untitled draft)" : row.board.name
            let plural = row.taskCount == 1 ? "" : "s"
            Text("Delete \"\(name)\"? Its \(row.taskCount) placed task\(plural) will be removed from the board. The underlying tasks stay in your library.")
        }
    }
}

private struct DraftRow: View {
    let row: DraftRowData
    let onResume: (Board) -> Void
    let onDeleteTap: () -> Void

    var body: some View {
        let displayName = row.board.name.isEmpty ? "(untitled draft)" : row.board.name
        let plural = row.taskCount == 1 ? "" : "s"

        HStack(spacing: 8) {
            Button {
                onResume(row.board)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text("\(row.board.boardSize)×\(row.board.boardSize) · \(row.taskCount) task\(plural)")
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Resume \"\(displayName)\", \(row.board.boardSize) by \(row.board.boardSize) board with \(row.taskCount) task\(plural)")

            Button(role: .destructive, action: onDeleteTap) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete draft \"\(displayName)\"")
        }
        .background(Color(.systemBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(.systemGray4), lineWidth: 1)
        )
        .cornerRadius(10)
    }
}
