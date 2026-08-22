import SwiftUI

/// PoolPickerSheetView — Task Pools + Recurring Boards Rework (P7),
/// docs/POOLS_RECURRING.md §Surfaces item 10 ("Pool picker sheet
/// (shared)"). A toggleable list of the user's pools, each row showing a
/// derived health note (`PoolHealth.formatPoolShortSummary`), plus a
/// dashed "+ Build a new pool…" affordance that opens `PoolEditSheetView`
/// in create mode and hands the new pool back to the caller SELECTED.
///
/// Deliberately callback-based (never a raw `Binding<Set<String>>`) rather
/// than owning toggle semantics itself — different callers need different
/// bookkeeping on a toggle:
/// - `CoreDefaultsEditSheetView` (current consumer): toggling is a flat set
///   membership flip (`CoreBoardDefault.corePoolIds` has no manual/removed
///   layer).
/// - A `manualTaskIds`/`removedTaskIds`-bearing record (e.g. the recurring
///   wizard's own pool-mix state, `BoardWizardViewModel.pullPool`/
///   `untogglePool`) instead needs `PoolMix.resolvePoolPullAdditions` /
///   `resolvePoolUntoggleRemovals` / `clearRemovalsForUntoggle` against
///   that union-rule bookkeeping — never just a membership flip. (P7's
///   `RepeatingBoardEditSheetView` was this shape; Board Creation Split
///   PR B retired it in favor of editing via the wizard directly, which
///   uses its own pool-pull card rather than this sheet.)
/// Only the CALLER knows which bookkeeping applies, so `onToggle` stays a
/// plain "the user tapped this pool's row" signal.
///
/// Props-only, DB-free (mirrors `RisoPoolPullCardView`'s leaf pattern)
/// EXCEPT for presenting `PoolEditSheetView` itself, which owns its own
/// persistence — this view never writes to `pools` directly.
struct PoolPickerSheetView: View {

    /// The caller's current pool list (non-deleted), in display order.
    /// The caller is responsible for appending a freshly-created pool
    /// (via `onPoolCreated`) to whatever it passes here on a re-render —
    /// this view holds no DB-backed state of its own.
    let pools: [Pool]
    /// Pools currently toggled ON, for chip/row highlight state.
    let selectedPoolIds: Set<String>
    /// Batched ONCE per screen by the caller (never per-row) —
    /// `PoolHealth.computePoolHealth`'s "batched once" contract.
    let healthByPoolId: [String: PoolHealth.Result]
    /// Needed only to construct `PoolEditSheetView`'s deck-preview floor
    /// when creating a new pool.
    let templates: [RecurringBoardTemplate]
    /// Read reactively so a quick-added task's title resolves immediately.
    let library: TaskLibraryViewModel
    let userId: String
    var title: String = "Pools"
    /// Fired when the user taps a pool row — the caller decides what
    /// "toggle" means for its own bookkeeping (see type doc above).
    let onToggle: (_ poolId: String) -> Void
    /// Fired when "+ Build a new pool…" successfully creates a pool. The
    /// caller should both append it to its own pool list AND select it
    /// (this view calls `onToggle` for you is NOT assumed — the new pool
    /// starts unselected in `selectedPoolIds` until the caller reacts).
    let onPoolCreated: (Pool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showCreateSheet = false

    var body: some View {
        ZStack {
            Color.risoPaper.ignoresSafeArea()
            VStack(spacing: 0) {
                grabber
                header
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        if pools.isEmpty {
                            Text("You don't have any pools yet.")
                                .font(.risoBody(13, .semibold))
                                .foregroundStyle(Color.risoMuted)
                                .padding(.top, 8)
                        } else {
                            ForEach(pools, id: \.id) { pool in
                                poolRow(pool)
                            }
                        }
                        RisoDashedButton(label: "+ Build a new pool…") {
                            showCreateSheet = true
                        }
                        .padding(.top, pools.isEmpty ? 0 : 6)
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 20)
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            PoolEditSheetView(
                pool: nil,
                templates: templates,
                library: library,
                userId: userId,
                onSaved: { showCreateSheet = false },
                onDeleted: {},
                onCreated: { newPool in onPoolCreated(newPool) }
            )
        }
    }

    // MARK: - Header

    private var grabber: some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.risoInk.opacity(0.2))
            .frame(width: 36, height: 4).padding(.top, 10).padding(.bottom, 14)
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.risoHead(19, .extraBold)).foregroundStyle(Color.risoInk)
            Spacer()
            RisoButton(title: "Done", kind: .primary) { dismiss() }
        }
        .padding(.horizontal, Riso.gutter).padding(.bottom, 18)
    }

    // MARK: - Row

    private func poolRow(_ pool: Pool) -> some View {
        let isOn = selectedPoolIds.contains(pool.id)
        let health = healthByPoolId[pool.id] ?? PoolHealth.Result(taskCount: pool.taskIds.count, consumers: [])
        let shortSummary = PoolHealth.formatPoolShortSummary(health.consumers)

        return Button { onToggle(pool.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundStyle(isOn ? Color.risoBlue : Color.risoMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pool.name)
                        .font(.risoHead(15, .bold)).foregroundStyle(Color.risoInk)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text("\(health.taskCount)").font(.risoBody(12, .bold)).foregroundStyle(Color.risoInk)
                        Text(health.taskCount == 1 ? "task" : "tasks")
                            .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                        if !shortSummary.isEmpty {
                            Text("·").foregroundStyle(Color.risoMuted)
                            Text(shortSummary)
                                .font(.risoBody(12, .bold)).foregroundStyle(Color.risoRed)
                        }
                    }
                }
                Spacer()
            }
            .padding(12)
            .risoCard(fill: isOn ? .risoPaper2 : .risoPaper)
            .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        }
        .buttonStyle(.plain)
    }
}
