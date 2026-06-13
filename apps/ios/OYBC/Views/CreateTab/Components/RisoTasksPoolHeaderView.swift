import SwiftUI

/// Pool-header card for the Riso wizard Tasks step.
///
/// Displays "YOUR TASK POOL" kicker, the big N/required count (green when
/// satisfied), a blue progress bar, and pool-model copy.  When
/// `centerTaskMode` is on it adds a center-task indicator line.
///
/// All derived values are passed in as simple scalars — no VM dependency —
/// so the view is trivially snapshot-testable and reusable.
struct RisoTasksPoolHeaderView: View {

    let selectedCount: Int
    let tasksRequired: Int
    let isRecurring: Bool
    let centerTaskMode: Bool
    let centerSatisfied: Bool

    // MARK: - Derived

    private var remaining: Int { max(0, tasksRequired - selectedCount) }
    private var extra: Int { max(0, selectedCount - tasksRequired) }
    private var isSatisfied: Bool { selectedCount >= tasksRequired }
    private var progress: Double { tasksRequired > 0 ? min(1.0, Double(selectedCount) / Double(tasksRequired)) : 0 }

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
            Text("\(selectedCount)")
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
                    + Text("\(extra) extra")
                        .font(.risoBody(11, .extraBold))
                        .foregroundStyle(Color.risoGreen)
                    + Text(isRecurring ? " shuffle in each spawn" : " shuffle into the mix")
                        .font(.risoBody(11, .semibold))
                        .foregroundStyle(Color.risoGreen)
                } else {
                    Text("Fills your board exactly")
                        .font(.risoBody(11, .extraBold))
                        .foregroundStyle(Color.risoGreen)
                }
            }
        } else {
            // Short: "Add N more — extras later just shuffle into the mix"
            Text("Add ") +
            Text("\(remaining)")
                .fontWeight(.heavy) +
            Text(" more — extras later just shuffle into the mix")
        }
    }

    @ViewBuilder
    private var centerTaskLine: some View {
        HStack(spacing: 6) {
            Image(systemName: centerSatisfied ? "star.fill" : "star")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(centerSatisfied ? Color.risoGold : Color.risoMuted)
            Text(centerSatisfied ? "Center task chosen" : "Center task required")
                .font(.risoBody(11, .bold))
                .foregroundStyle(centerSatisfied ? Color.risoGold : Color.risoMuted)
        }
    }
}
