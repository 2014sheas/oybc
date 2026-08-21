import SwiftUI

/// Board-screen "manage row" for a repeating board (Task Pools + Recurring
/// Boards Rework, P6 — docs/POOLS_RECURRING.md §Surfaces item 7). Shown
/// when `board.spawnedFromTemplateId != nil` AND the backing template
/// resolves (a soft-deleted template hides the row entirely — the caller's
/// job, not this view's).
///
/// Renders `↻ Repeats {cadence} · from "{template name}"` plus an inline
/// Pause/Resume pill. Leaf view (no DB access, no `@EnvironmentObject`) so
/// it's independently snapshot-testable — `BoardPlayView` queries
/// `AppDatabase.shared` and isn't itself covered by snapshot tests (see
/// `docs/RISO_UI_CHECKLIST.md` / `SnapshotFixtures`'s existing note on
/// `RisoRecurringBadgeSnapshotTests`).
struct RisoRecurringManageRow: View {
    /// e.g. "daily" — from `formatCadenceAdverb(template.timeframe)`.
    let cadenceAdverb: String
    let templateName: String
    let isActive: Bool
    let onToggleActive: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("↻")
                    .font(.risoHead(13, .bold))
                Text("Repeats \(cadenceAdverb) · from \"\(templateName)\"")
                    .font(.risoBody(12.5, .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isActive ? Color.risoInk : Color.risoMuted)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onToggleActive) {
                Text(isActive ? "Pause" : "Resume")
                    .font(.risoHead(11, .bold))
                    .foregroundStyle(Color.risoInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.risoPaper2))
                    .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .risoCard()
        .opacity(isActive ? 1.0 : 0.7)
    }
}

#if DEBUG
#Preview("Recurring Manage Row") {
    ZStack {
        RisoPaperBackground()
        VStack(spacing: 14) {
            RisoRecurringManageRow(
                cadenceAdverb: "daily",
                templateName: "Morning Kickstart",
                isActive: true,
                onToggleActive: {}
            )
            RisoRecurringManageRow(
                cadenceAdverb: "weekly",
                templateName: "Morning Kickstart",
                isActive: false,
                onToggleActive: {}
            )
        }
        .padding()
    }
}
#endif
