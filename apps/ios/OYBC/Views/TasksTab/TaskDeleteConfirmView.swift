import SwiftUI

/// TaskDeleteConfirmView — destructive confirmation sheet for the
/// Tasks-tab swipe-to-delete affordance.
///
/// Mirrors web's `TaskConfirmDeleteDialog` (`apps/web/src/pages/tasks/
/// TaskConfirmDeleteDialog.tsx`): lists each affected board by name +
/// a status pill (Active / Completed / Draft / Expired) so the user
/// can decide whether the cascade is acceptable before confirming.
/// Expired boards are flagged in red — they're technically still
/// ACTIVE status but past their endDate, which weakens the "these
/// placements still matter" reasoning behind the cascade.
///
/// Presented via `.sheet(item:)` rather than `.alert(...)`: alert can't
/// host the affected-boards list. `.presentationDetents([.medium])`
/// keeps it from taking the full screen.
struct TaskDeleteConfirmView: View {
    let task: Task
    let impact: AppDatabase.TaskDeletionImpact
    /// Called when the user taps Delete. The caller runs
    /// `AppDatabase.shared.deleteTaskWithCascade(taskId:)` off-main and
    /// dismisses the sheet on success.
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var isDeleting = false

    private var titleForDisplay: String {
        task.title.isEmpty ? "(untitled task)" : task.title
    }

    private var hasBoards: Bool {
        !impact.affectedBoards.isEmpty
    }

    private var otherCountsTotal: Int {
        impact.childLinkCount + impact.parentLinkCount
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\"\(titleForDisplay)\" will be removed from your library. This can't be undone.")
                        .font(.system(size: 15))
                        .foregroundColor(.primary)

                    if hasBoards {
                        affectedBoardsSection
                    }

                    if otherCountsTotal > 0 {
                        otherImpactSection
                    }

                    if !hasBoards && otherCountsTotal == 0 {
                        Text("No other rows affected.")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Delete task?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .disabled(isDeleting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .destructive) {
                        isDeleting = true
                        onConfirm()
                    } label: {
                        Text(isDeleting ? "Deleting…" : "Delete")
                            .fontWeight(.semibold)
                    }
                    .disabled(isDeleting)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Sections

    @ViewBuilder
    private var affectedBoardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Removes from \(impact.boardTaskCount) board square\(impact.boardTaskCount == 1 ? "" : "s") on \(impact.affectedBoards.count) board\(impact.affectedBoards.count == 1 ? "" : "s"):")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)

            VStack(spacing: 6) {
                ForEach(impact.affectedBoards, id: \.id) { board in
                    affectedBoardRow(board)
                }
            }
        }
    }

    @ViewBuilder
    private func affectedBoardRow(_ board: Board) -> some View {
        HStack(spacing: 8) {
            Text(board.name)
                .font(.system(size: 14))
                .foregroundColor(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if isBoardExpired(board) {
                expiredPill
            } else {
                BoardStatusBadgeView(status: board.status)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var expiredPill: some View {
        Text("EXPIRED")
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundStyle(Color(red: 0.725, green: 0.110, blue: 0.110))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(red: 0.863, green: 0.208, blue: 0.271).opacity(0.12))
            .clipShape(Capsule())
            .accessibilityLabel("Expired board")
    }

    @ViewBuilder
    private var otherImpactSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if impact.childLinkCount > 0 {
                Text("• Detaches from \(impact.childLinkCount) compound parent\(impact.childLinkCount == 1 ? "" : "s") (the parent\(impact.childLinkCount == 1 ? "" : "s") loses this child).")
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
            }
            if impact.parentLinkCount > 0 {
                Text("• Releases \(impact.parentLinkCount) subtask\(impact.parentLinkCount == 1 ? "" : "s") (\(impact.parentLinkCount == 1 ? "it stays" : "they stay") in your library).")
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
            }
        }
    }
}
