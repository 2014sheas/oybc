import SwiftUI

/// PoolsBrowseView — the Tasks-tab "Pools" segment content (Task Pools +
/// Recurring Boards Rework, P2). Lists the user's pools as cards + a dashed
/// "+ New pool" entry; tapping a card (or "+ New pool") opens
/// `PoolEditSheetView`. See docs/POOLS_RECURRING.md §Surfaces item 1 + the
/// handoff screenshot `01-pools.png`.
///
/// **NO board-related actions anywhere on this surface** (locked decision)
/// — pools are populated here; boards pull them in from the wizard side.
///
/// DB-free and props-only (mirrors `RisoTaskRowView` / `RisoTasksControlsView`'s
/// leaf-component pattern) so it's directly snapshot-testable without a
/// database — the caller (`TasksTabView`) batches `pools` /
/// `poolTasksById` / `healthByPoolId` ONCE per render from its own loaded
/// state; this view does no I/O and no per-card health computation (see
/// `PoolHealth.computePoolHealth`'s "batched once per screen" contract).
///
/// Mirrors web's `PoolsBrowse.tsx` + `PoolCard.tsx` (kept as one file here,
/// following this screen's existing single-file convention — see
/// `DefaultPoolsListView.swift`, which combines its list + card in one
/// file too). Card visual language mirrors `DefaultPoolsListView.poolCard`
/// minus the "FEEDS" tag (pools are no longer timeframe-keyed).
struct PoolsBrowseView: View {

    /// The user's non-deleted pools, in display order.
    let pools: [Pool]
    /// `pool.id` → its resolvable, non-deleted tasks (in `taskIds` order) —
    /// resolved once by the caller for the chip row + count.
    let poolTasksById: [String: [Task]]
    /// `pool.id` → this pool's derived health (`PoolHealth.computePoolHealth`),
    /// computed once by the caller — never per-card.
    let healthByPoolId: [String: PoolHealth.Result]
    let onSelectPool: (Pool) -> Void
    let onNewPool: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keep like tasks together. Any board can draw from a pool.")
                .font(.risoBody(14, .semibold))
                .foregroundStyle(Color.risoMuted)

            if !pools.isEmpty {
                VStack(spacing: 14) {
                    ForEach(pools, id: \.id) { pool in
                        poolCard(pool)
                    }
                }
            }

            RisoDashedButton(label: "+ New pool", action: onNewPool)
        }
    }

    // MARK: - Pool card

    private func poolCard(_ pool: Pool) -> some View {
        let tasks = poolTasksById[pool.id] ?? []
        let health = healthByPoolId[pool.id] ?? PoolHealth.Result(taskCount: tasks.count, consumers: [])

        return Button { onSelectPool(pool) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(pool.name)
                    .font(.risoHead(17, .extraBold)).foregroundStyle(Color.risoInk)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)

                taskChips(tasks)

                HStack(spacing: 4) {
                    Text("\(health.taskCount)").font(.risoBody(12, .bold)).foregroundStyle(Color.risoInk)
                    Text(health.taskCount == 1 ? "task" : "tasks")
                        .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                    Text("·").foregroundStyle(Color.risoMuted)
                    Text("tap to edit").font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                }

                let shortSummary = PoolHealth.formatPoolShortSummary(health.consumers)
                if !shortSummary.isEmpty {
                    Text(shortSummary)
                        .font(.risoBody(12, .bold)).foregroundStyle(Color.risoRed)
                }
            }
            .padding(Riso.cardPadding)
            .risoCard()
            .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func taskChips(_ tasks: [Task]) -> some View {
        let visible = Array(tasks.prefix(4))
        let overflow = tasks.count - visible.count

        if !visible.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(visible, id: \.id) { task in
                    Text(task.title.isEmpty ? "(untitled task)" : task.title)
                        .font(.risoBody(12, .semibold)).foregroundStyle(Color.risoInk)
                        .padding(.vertical, 4).padding(.horizontal, 9)
                        .background(Capsule().fill(Color.risoPaper))
                        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                        .lineLimit(1)
                }
                if overflow > 0 {
                    Text("+\(overflow) more")
                        .font(.risoBody(12, .semibold)).foregroundStyle(Color.risoBlue)
                }
            }
        }
    }
}
