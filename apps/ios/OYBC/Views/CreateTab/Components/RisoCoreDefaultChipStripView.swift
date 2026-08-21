import SwiftUI

/// Provenance chip strip for core-board setup — Task Pools + Recurring
/// Boards Rework (P5), docs/POOLS_RECURRING.md §Surfaces item 6:
/// "pre-filled chips plain, hand-added chips blue-tinted w/ ✕".
///
/// Renders every currently-selected task (in `orderedTaskIds`) as a chip:
/// - Pre-filled (pool- or default-sourced, i.e. NOT in `manualTaskIds`):
///   a plain paper2 chip, no dismiss — it came from a saved default;
///   removing it here would be surprising mid-setup.
/// - Hand-added (in `manualTaskIds`): a blue-tinted chip with a ✕ that
///   removes it outright. A manually-added task was never pool-supplied
///   at add time in the common case, so `onRemove` can route straight to
///   the wizard's plain `toggleTaskSelection` — no `removedTaskIds`
///   bookkeeping concern here (the caller's `onToggleSelection` closure
///   already threads the real `poolsById`/`tasksById` lookups for the
///   rarer case where a hand-added task later also became pool-supplied).
///
/// Props-only, DB-free — mirrors `RisoPoolPullCardView`'s leaf-component
/// pattern for direct snapshot-testability.
struct RisoCoreDefaultChipStripView: View {
    /// Insertion order of the selection (`BoardWizardViewModel.poolOrder`).
    let orderedTaskIds: [String]
    /// Hand-added task ids (`BoardWizardViewModel.manualTaskIds`) — drives
    /// each chip's plain vs. blue-tinted-with-✕ variant.
    let manualTaskIds: Set<String>
    /// Task lookup for resolving each id's title.
    let taskById: [String: OYBC.Task]
    /// Fired when the user taps a hand-added chip's ✕.
    let onRemove: (_ taskId: String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(orderedTaskIds, id: \.self) { taskId in
                if let task = taskById[taskId] {
                    if manualTaskIds.contains(taskId) {
                        manualChip(task)
                    } else {
                        plainChip(task)
                    }
                }
            }
        }
    }

    private func plainChip(_ task: OYBC.Task) -> some View {
        Text(task.title.isEmpty ? "(untitled task)" : task.title)
            .font(.risoBody(12, .semibold))
            .foregroundStyle(Color.risoInk)
            .lineLimit(1)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Capsule().fill(Color.risoPaper2))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }

    private func manualChip(_ task: OYBC.Task) -> some View {
        HStack(spacing: 5) {
            Text(task.title.isEmpty ? "(untitled task)" : task.title)
                .font(.risoBody(12, .semibold))
                .foregroundStyle(Color.risoPaper)
                .lineLimit(1)
            Button {
                onRemove(task.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.risoPaper)
            }
            .accessibilityLabel("Remove \(task.title)")
        }
        .padding(.vertical, 6)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .background(Capsule().fill(Color.risoBlue))
        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }
}
