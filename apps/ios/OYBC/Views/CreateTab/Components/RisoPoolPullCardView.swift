import SwiftUI

/// "PULL IN A POOL" card — Task Pools + Recurring Boards Rework (P3),
/// docs/POOLS_RECURRING.md §Surfaces item 5 (Wizard step 2).
///
/// Lists the user's pools as toggle chips. Toggling one ON unions its
/// resolvable supply into the wizard's selection (`BoardWizardViewModel.
/// pullPool`); toggling it OFF removes only that pool's non-manual,
/// no-longer-otherwise-supplied tasks (`untogglePool`) — the manual layer
/// is never reset, and the saved `Pool` itself is never mutated by either
/// action (locked decision).
///
/// Props-only, DB-free — mirrors `RisoTasksPoolHeaderView`/
/// `RisoPoolListView`'s leaf-component pattern, so it's directly
/// snapshot-testable without a database.
struct RisoPoolPullCardView: View {

    /// The user's non-deleted pools, in display order.
    let pools: [Pool]
    /// Pools currently pulled into the selection
    /// (`BoardWizardViewModel.pulledPoolIds`) — drives each chip's on/off state.
    let pulledPoolIds: [String]
    /// Section header. Defaults to the standard wizard-step-2 copy;
    /// core-board setup (Task Pools + Recurring Boards Rework, P5,
    /// docs/POOLS_RECURRING.md §Surfaces item 6) overrides this to
    /// "Start with a pool — optional" — same card, different context copy.
    var title: String = "Pull in a pool"
    /// Fired when the user taps a pool's chip (either direction — the
    /// caller decides pull vs. untoggle based on current membership).
    let onToggle: (_ poolId: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .risoSectionLabel()

            if pools.isEmpty {
                Text("You don't have any pools yet.")
                    .font(.risoBody(12.5, .semibold))
                    .foregroundStyle(Color.risoMuted)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(pools, id: \.id) { pool in
                        RisoChip(
                            title: pool.name,
                            isOn: pulledPoolIds.contains(pool.id),
                            action: { onToggle(pool.id) }
                        )
                    }
                }
            }
        }
        .padding(12)
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.small)
    }
}
