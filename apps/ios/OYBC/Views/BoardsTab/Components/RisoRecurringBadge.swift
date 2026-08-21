import SwiftUI

/// Small provenance pill marking a board that was spawned by a recurring
/// template (`board.spawnedFromTemplateId != nil` — Phase 6.2). Issue #321.
///
/// Deliberately an OUTLINE look — `Color.risoPaper2` fill, `Color.risoInk`
/// text + a 1.5pt ink keyline — distinct from the *filled* status pills
/// (`RisoBoardStatusBadge` / `BoardPlayView.risoStatusBadge`), so it reads
/// as a provenance tag and never collides with status-color semantics.
///
/// Dark-mode note: `Color.risoInk` is used here only as TEXT/BORDER, never
/// as a FILL behind cream content — see `docs/RISO_UI_CHECKLIST.md`.
///
/// **Paused variant** (Task Pools + Recurring Boards Rework, P6 —
/// docs/POOLS_RECURRING.md §Surfaces item 8): pass `paused: true` for a
/// board whose source template is currently paused (`!template.isActive`).
/// Same shell (fill/capsule/keyline weight), swapped to `Color.risoMuted`
/// for both text and border so it reads as de-emphasized rather than a
/// second "recurring" tag. Default `false` — every existing call site
/// keeps the unchanged "RECURRING" rendering with no changes needed.
struct RisoRecurringBadge: View {
    var paused: Bool = false

    var body: some View {
        Text(paused ? "↻ PAUSED" : "RECURRING")
            .font(.risoHead(9, .bold))
            .tracking(0.5)
            .foregroundStyle(paused ? Color.risoMuted : Color.risoInk)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(Capsule().fill(Color.risoPaper2))
            .overlay(Capsule().strokeBorder(paused ? Color.risoMuted : Color.risoInk, lineWidth: Riso.Keyline.dense))
    }

    /// Pure derivation predicate — no schema change needed, badge visibility
    /// is entirely a function of the existing `spawnedFromTemplateId` field.
    /// Extracted so it's independently unit-testable (see
    /// `RecurringBoardsUXPassTests`).
    static func shouldShow(for board: Board) -> Bool {
        board.spawnedFromTemplateId != nil
    }
}

#if DEBUG
#Preview("Recurring Badge") {
    ZStack {
        RisoPaperBackground()
        VStack(spacing: 14) {
            RisoRecurringBadge()
            RisoRecurringBadge(paused: true)
            HStack(spacing: 8) {
                RisoBoardStatusBadge(kind: .active)
                RisoRecurringBadge()
            }
        }
        .padding()
    }
}
#endif
