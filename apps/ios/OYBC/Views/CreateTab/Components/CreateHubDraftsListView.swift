import SwiftUI

/// Minimal payload passed to the hub's drafts list — one row per
/// draft Board with a precomputed task count. Supplied by
/// `CreateHubView` which loads the rows on appear and after the
/// wizard dismisses.
///
/// Board Creation Split (PR B) — `taskCount` means different things per
/// `kind`: for a one-off draft it's the placed `BoardTask` row count
/// (unchanged); for a recurring draft it's the FULL resolved pool size
/// (`recurringDraftMix`, via `BoardWizardViewModel.resolvePoolMixHydration`)
/// — never the placed-row count, which silently truncates an intentionally
/// overfilled pool to the grid size. See `CreateHubViewModel.reloadDrafts`.
struct DraftRowData: Identifiable {
    /// One-off (red) vs recurring (blue) — drives the row's typed pill,
    /// meta-line format, and which wizard mode `onResume` reopens
    /// (resolved automatically by `BoardWizardViewModel.init` from
    /// `board.isRecurringDraft`, so no separate routing is needed here).
    enum Kind {
        case oneOff
        case recurring
    }

    let board: Board
    let taskCount: Int
    var id: String { board.id }
    var kind: Kind { board.isRecurringDraft ? .recurring : .oneOff }
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

    /// Board Creation Split (PR B) — "4×4 · 9 tasks" for a one-off draft;
    /// "Every week · 5×5 · 12 tasks" for a recurring one (README §Screens
    /// "1. Create hub"). `formatRecurringCadence` supplies the canonical
    /// "Every {day|week|month|year}" prefix.
    private var metaText: String {
        let plural = row.taskCount == 1 ? "" : "s"
        let sizeAndCount = "\(row.board.boardSize)×\(row.board.boardSize) · \(row.taskCount) task\(plural)"
        guard row.kind == .recurring else { return sizeAndCount }
        return "\(formatRecurringCadence(timeframe: row.board.timeframe)) · \(sizeAndCount)"
    }

    private var pillLabel: String {
        row.kind == .recurring ? "RECURRING" : "ONE-OFF"
    }

    private var pillColor: Color {
        row.kind == .recurring ? .risoBlue : .risoRed
    }

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
                        HStack(spacing: 6) {
                            Text(displayName)
                                .font(.risoBody(14, .semibold))
                                .foregroundStyle(Color.risoInk)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            typePill
                        }
                        Text(metaText)
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
            .accessibilityLabel("Resume \"\(displayName)\", \(pillLabel.capitalized) draft, \(row.board.boardSize) by \(row.board.boardSize) board with \(row.taskCount) task\(plural)")

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

    /// Typed pill (README §Screens "1. Create hub") — ONE-OFF (red) /
    /// RECURRING (blue) fill + on-color text (`.risoPaper`, matching
    /// `RecurringTemplateCard.timeframeTag`'s identical colored-capsule
    /// pattern) — never adaptive ink on a colored fill.
    private var typePill: some View {
        Text(pillLabel)
            .font(.risoHead(8.5, .bold))
            .tracking(0.3)
            .foregroundStyle(Color.risoPaper)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(pillColor))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }
}
