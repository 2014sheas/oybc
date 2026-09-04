import SwiftUI

/// Pool-header card for the Riso wizard Tasks step.
///
/// Displays "YOUR TASK POOL" kicker, the big N/required count (green when
/// satisfied), a blue progress bar, and pool-model copy.  When
/// `centerTaskMode` is on it adds a center-task indicator line.
///
/// Board Sources P2 (docs/BOARD_SOURCES.md §Surfaces item 1): the count is
/// the CAPACITY — sum of every source's effective max + hand-added,
/// deduped (`BoardWizardViewModel.sourceCapacity`) — and the copy is the
/// design's: short → "N more to fill the board. Widen a pool's range or
/// add tasks."; filled → "✓ Fills your board · N extras rotate in". No
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

    // MARK: - Derived

    private var remaining: Int { max(0, tasksRequired - capacity) }
    private var extra: Int { max(0, capacity - tasksRequired) }
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
            .padding(.bottom, 8)

            // Pool model note
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

    @ViewBuilder
    private var poolModelNote: some View {
        // Board Creation Split (README §Copy strings) — this note's copy is
        // now byte-identical across one-off and recurring: "✓ Fills your
        // board · {X} extra rotate in" / "Add {X} more — extras shuffle
        // into the mix". `isRecurring` no longer branches the text (it's
        // kept as a parameter for any future per-mode divergence).
        if isSatisfied {
            // Satisfied: green "✓ Fills your board …" copy
            HStack(spacing: 4) {
                Text("✓")
                    .font(.risoBody(11, .extraBold))
                    .foregroundStyle(Color.risoGreen)
                if extra > 0 {
                    Text("Fills your board · ")
                        .font(.risoBody(11, .semibold))
                        .foregroundStyle(Color.risoGreen)
                    + Text("\(extra) extra\(extra == 1 ? "" : "s")")
                        .font(.risoBody(11, .extraBold))
                        .foregroundStyle(Color.risoGreen)
                    + Text(" rotate in")
                        .font(.risoBody(11, .semibold))
                        .foregroundStyle(Color.risoGreen)
                } else {
                    Text("Fills your board exactly")
                        .font(.risoBody(11, .extraBold))
                        .foregroundStyle(Color.risoGreen)
                }
            }
        } else {
            // Short — red, per the design (frame 2a item 1).
            (Text("\(remaining) more")
                .font(.risoBody(11, .extraBold))
             + Text(" to fill the board. Widen a pool's range or add tasks.")
                .font(.risoBody(11, .semibold)))
                .foregroundStyle(Color.risoRed)
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
