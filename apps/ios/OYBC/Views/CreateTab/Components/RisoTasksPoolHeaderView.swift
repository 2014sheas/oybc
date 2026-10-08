import SwiftUI

/// Pool-header card for the Riso wizard Tasks step.
///
/// Displays "YOUR TASK POOL" kicker, the big N/required count (green when
/// satisfied), a blue progress bar, and an optional caller note.  When
/// `centerTaskMode` is on it adds a center-task indicator line.
///
/// Board Sources P2 (docs/BOARD_SOURCES.md §Surfaces item 1): the count is
/// the CAPACITY — sum of every source's effective max + hand-added,
/// deduped (`BoardWizardViewModel.sourceCapacity`) — shown as
/// `n/required` (green once satisfied). The advice sentences ("N more to
/// fill the board…", "✓ Fills your board…") were removed under #548. No
/// "min" suffix anymore.
///
/// All derived values are passed in as simple scalars — no VM dependency —
/// so the view is trivially snapshot-testable and reusable.
struct RisoTasksPoolHeaderView: View {

    /// The sources capacity (see type doc). Named `selectedCount` before P2.
    let capacity: Int
    let tasksRequired: Int
    let isRecurring: Bool
    let centerTaskMode: Bool
    let centerSatisfied: Bool
    /// When set, replaces the pool-model note (green when satisfied, red when
    /// short). The pool editor passes its deck-preview line.
    var noteOverride: String? = nil

    // MARK: - Derived

    private var isSatisfied: Bool { capacity >= tasksRequired }
    private var progress: Double { tasksRequired > 0 ? min(1.0, Double(capacity) / Double(tasksRequired)) : 0 }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Kicker + count row
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Your task pool")
                    .risoKicker(.risoInk)
                Spacer()
                countBadge
            }

            // Progress bar
            RisoProgressBar(
                value: progress,
                color: isSatisfied ? .risoGreen : .risoBlue
            )
            .padding(.top, 9)
            .padding(.bottom, noteOverride == nil ? 0 : 8)

            // Optional caller note
            poolModelNote

            // Center-task indicator (only when active)
            if centerTaskMode {
                Divider()
                    .background(Color.risoInk.opacity(0.15))
                    .padding(.top, 8)
                centerTaskLine
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.small)
    }

    // MARK: - Sub-views

    private var countBadge: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(capacity)")
                .font(.risoHead(22, .extraBold))
                .tracking(-0.44)
                .foregroundStyle(isSatisfied ? Color.risoGreen : Color.risoInk)
            Text("/\(tasksRequired)")
                .font(.risoHead(14, .bold))
                .foregroundStyle(Color.risoMuted)
        }
    }

    /// Only a caller-supplied note renders (the pool editor's deck-preview
    /// line); the default "N more to fill…" / "✓ Fills your board…" advice
    /// sentences were removed under #548 — the count + bar carry the state.
    @ViewBuilder
    private var poolModelNote: some View {
        if let noteOverride {
            Text(noteOverride)
                .font(.risoBody(11, .semibold))
                .foregroundStyle(isSatisfied ? Color.risoGreen : Color.risoRed)
        }
    }

    @ViewBuilder
    private var centerTaskLine: some View {
        HStack(spacing: 6) {
            Image(systemName: centerSatisfied ? "star.fill" : "star")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(centerSatisfied ? Color.risoGold : Color.risoMuted)
            Text(centerSatisfied ? "Center task chosen" : "Tap ☆ on a pool task to set the center")
                .font(.risoBody(11, .bold))
                .foregroundStyle(centerSatisfied ? Color.risoGold : Color.risoMuted)
        }
    }
}
