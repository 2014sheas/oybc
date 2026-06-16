import SwiftUI

/// TaskDeleteConfirmView — destructive confirmation sheet (Riso) for the
/// Tasks-tab delete affordance.
///
/// Mirrors web's `TaskConfirmDeleteDialog`: lists each affected board by name
/// + a status pill (Active / Completed / Draft / Expiring) so the user can
/// decide whether the cascade is acceptable before confirming. Expired boards
/// (past `endDate`, still ACTIVE status) are flagged with a red EXPIRED pill —
/// their placements matter less, which weakens the cascade reasoning.
///
/// Presented via `.sheet(item:)` (alert can't host the affected-boards list);
/// `.presentationDetents([.medium])` keeps it from taking the full screen.
///
/// Presentation-only Riso reskin — the `task` / `impact` inputs, the
/// `onConfirm` / `onCancel` callbacks, and the `isDeleting` flow are unchanged.
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
                VStack(alignment: .leading, spacing: 14) {

                    // Destructive lede
                    VStack(alignment: .leading, spacing: 6) {
                        (Text("\"\(titleForDisplay)\"")
                            .font(.risoBody(14, .extraBold))
                            .foregroundStyle(Color.risoInk)
                        + Text(" will be removed from your library.")
                            .font(.risoBody(14, .semibold))
                            .foregroundStyle(Color.risoInk))
                        Text("This can't be undone.")
                            .font(.risoBody(12, .bold))
                            .foregroundStyle(Color.risoRed)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
                    .risoCard(fill: .risoPaper2)
                    .risoHardShadow(Riso.Shadow.small)

                    if hasBoards {
                        affectedBoardsSection
                    }

                    if otherCountsTotal > 0 {
                        otherImpactSection
                    }

                    if !hasBoards && otherCountsTotal == 0 {
                        Text("No other rows affected.")
                            .font(.risoBody(13, .semibold))
                            .foregroundStyle(Color.risoMuted)
                    }
                }
                .padding(Riso.gutter)
            }
            .background(Color.risoPaper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Delete task?")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .font(.risoBody(15, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .disabled(isDeleting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isDeleting = true
                        onConfirm()
                    } label: {
                        Text(isDeleting ? "Deleting…" : "Delete")
                            .font(.risoHead(13, .extraBold))
                            .foregroundStyle(Color.risoPaper)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.risoRed))
                            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                    }
                    .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small, radius: 999))
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
            Text("Removes from \(impact.boardTaskCount) board square\(impact.boardTaskCount == 1 ? "" : "s") on \(impact.affectedBoards.count) board\(impact.affectedBoards.count == 1 ? "" : "s")")
                .risoSectionLabel()

            VStack(spacing: 7) {
                ForEach(impact.affectedBoards, id: \.id) { board in
                    affectedBoardRow(board)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.small)
    }

    @ViewBuilder
    private func affectedBoardRow(_ board: Board) -> some View {
        HStack(spacing: 8) {
            Text(board.name)
                .font(.risoHead(13, .bold))
                .foregroundStyle(Color.risoInk)
                .lineLimit(1)
            Spacer(minLength: 8)
            if isBoardExpired(board) {
                expiredPill
            } else {
                RisoBoardStatusBadge(kind: .init(status: board.status, isExpiring: false))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Riso.cellRadius)
                .fill(Color.risoPaper)
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cellRadius)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                )
        )
    }

    /// Red "EXPIRED" pill for boards past their `endDate` (still ACTIVE
    /// status, but the placement matters less). Kept inline rather than as a
    /// `RisoBoardStatusBadge` kind because "expired" is a delete-time concern,
    /// distinct from the card's "expiring" (gold) state.
    private var expiredPill: some View {
        Text("EXPIRED")
            .font(.risoHead(10, .bold))
            .tracking(0.6)
            .foregroundStyle(Color.risoPaper)
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(Capsule().fill(Color.risoRed))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
            .accessibilityLabel("Expired board")
    }

    @ViewBuilder
    private var otherImpactSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            if impact.childLinkCount > 0 {
                impactBullet("Detaches from \(impact.childLinkCount) compound parent\(impact.childLinkCount == 1 ? "" : "s") (the parent\(impact.childLinkCount == 1 ? " loses" : "s lose") this child).")
            }
            if impact.parentLinkCount > 0 {
                impactBullet("Releases \(impact.parentLinkCount) subtask\(impact.parentLinkCount == 1 ? "" : "s") (\(impact.parentLinkCount == 1 ? "it stays" : "they stay") in your library).")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.small)
    }

    private func impactBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .font(.risoBody(13, .bold))
                .foregroundStyle(Color.risoInk)
            Text(text)
                .font(.risoBody(13, .semibold))
                .foregroundStyle(Color.risoInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
