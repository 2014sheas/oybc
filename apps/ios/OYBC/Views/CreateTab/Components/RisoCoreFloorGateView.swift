import SwiftUI

/// Red "Add N more" fillable-floor note for core-board setup — Task
/// Pools + Recurring Boards Rework (P5), docs/POOLS_RECURRING.md
/// §Behavior invariants "Fillable floor everywhere".
///
/// Distinct from `RisoTasksPoolHeaderView`'s general (non-red) "Add N
/// more — extras later just shuffle into the mix" note, which every
/// board type already shows. This is an ADDITIONAL, core-setup-only,
/// visually louder call to action shown alongside it when the selection
/// is short of `tasksNeededForBoard(size:centerType:)` — never a
/// hardcoded 8.
struct RisoCoreFloorGateView: View {
    /// Tasks still needed to reach the floor. Callers should only render
    /// this view when `remaining > 0`.
    let remaining: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
            Text("Add \(remaining) more")
                .font(.risoHead(12.5, .bold))
        }
        .foregroundStyle(Color.risoRed)
    }
}
