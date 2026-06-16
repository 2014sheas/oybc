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

/// CreateHubDraftsListView — Riso-styled list of the user's DRAFT boards
/// so they can be resumed. iOS twin of web's `CreateHubDraftsList`. Only
/// rendered when `drafts.count > 0`.
///
/// Each row is a Riso keyline card with a tappable resume area and a
/// trailing per-row delete affordance (ink × button). The destructive
/// button opens a confirmation `Alert` before invoking the caller-supplied
/// `onDelete` callback; parent runs `AppDatabase.deleteDraftWithCascade(id:)`
/// and triggers a reload. Logic is unchanged from the pre-Riso version.
struct CreateHubDraftsListView: View {
    let drafts: [DraftRowData]
    let onResume: (Board) -> Void
    let onDelete: (Board) -> Void

    @State private var deleteTarget: DraftRowData?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section label + count pill — Riso section label style
            HStack(spacing: 8) {
                Text("Drafts")
                    .risoSectionLabel()
                Text("\(drafts.count)")
                    .font(.risoHead(10, .bold))
                    .foregroundStyle(Color.risoPaper)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.risoInk))
                    .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
            }

            VStack(spacing: 8) {
                ForEach(drafts) { row in
                    RisoDraftRow(row: row, onResume: onResume) {
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

// MARK: - RisoDraftRow

/// Individual draft row — Riso keyline card. Tapping the main area
/// resumes the draft; the trailing × dismisses with a confirm alert.
private struct RisoDraftRow: View {
    let row: DraftRowData
    let onResume: (Board) -> Void
    let onDeleteTap: () -> Void

    var body: some View {
        let displayName = row.board.name.isEmpty ? "(untitled draft)" : row.board.name
        let plural = row.taskCount == 1 ? "" : "s"

        HStack(spacing: 0) {
            // Resume area
            Button {
                onResume(row.board)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName)
                            .font(.risoBody(14, .semibold))
                            .foregroundStyle(Color.risoInk)
                            .lineLimit(1)
                        Text("\(row.board.boardSize)×\(row.board.boardSize) · \(row.taskCount) task\(plural)")
                            .font(.risoBody(11, .regular))
                            .foregroundStyle(Color.risoMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.risoMuted)
                }
                .padding(.horizontal, Riso.cardPadding)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Resume \"\(displayName)\", \(row.board.boardSize) by \(row.board.boardSize) board with \(row.taskCount) task\(plural)")

            // Vertical ink divider
            Rectangle()
                .fill(Color.risoInk)
                .frame(width: Riso.Keyline.dense)
                .padding(.vertical, 0)

            // Delete button
            Button(role: .destructive, action: onDeleteTap) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete draft \"\(displayName)\"")
        }
        .risoCard(fill: .risoPaper2)
    }
}
