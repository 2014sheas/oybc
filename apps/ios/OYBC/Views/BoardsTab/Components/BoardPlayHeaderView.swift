import SwiftUI

/// The play board's in-content title block (masthead layout — core-board
/// surface rework): kicker · name (+ inline gold streak chip) · badge
/// row, with "Edit squares" — or the sealed "Read-only" lock — plus the
/// "…" board menu (Board Edit redesign slice 2, D1) in the trailing slot.
///
/// Pure presentation: all state arrives as props so the view is
/// directly snapshot-testable. The Edit gate is decided by the CALLER
/// (`BoardPlayView`) with the one shared rule
/// `status == .active && sealedAt == nil && !editMode`; this leaf just
/// renders whatever slot state it is handed.
///
/// Mirrors the web `BoardPlaySurface` rail top/title rows.
struct BoardPlayHeaderView: View {
    /// Kicker text ("MONTHLY BOARD").
    let kicker: String
    /// Board name.
    let name: String
    /// Name point size (24 embedded in the pager, 22 standalone).
    var nameSize: CGFloat = 22
    /// Compact greenlog-streak value ("2mo") — nil hides the chip.
    var streakValue: String? = nil
    /// Live status badge value; nil hides the badge row entirely
    /// (board not loaded yet).
    var status: BoardStatus? = nil
    /// Sealed boards show CLOSED in place of the status badge; the trailing
    /// slot drops Edit squares (no "Read-only" label anywhere — D14).
    var isSealed: Bool = false
    /// Board Edit redesign slice 4 (D14): a board whose window ended but
    /// isn't sealed yet shows ENDED in place of the status badge. Ignored
    /// when `isSealed` (CLOSED wins).
    var isEnded: Bool = false
    /// Whether to show the RECURRING provenance badge.
    var showRecurringBadge: Bool = false
    /// Whether the trailing slot shows the Edit button (the caller's
    /// one-rule gate). Ignored when `isSealed`.
    var canEdit: Bool = false
    var onEdit: () -> Void = {}
    /// Board Edit redesign slice 2 (D1/D3) — the "…" menu's items, in
    /// display order. Empty hides the menu entirely (draft boards). The
    /// menu still shows for a sealed board when non-empty (D3: sealed menu
    /// = Delete, + Core defaults… on core) — unlike `canEdit`, its
    /// visibility does NOT depend on `isSealed`.
    var menuItems: [BoardMenuItem] = []
    /// Called with the tapped menu item. No-op default so existing call
    /// sites (and snapshot fixtures) that don't pass `menuItems` compile
    /// unchanged.
    var onMenuSelect: (BoardMenuItem) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Title block: kicker · name (+ streak chip) · badge row.
            VStack(alignment: .leading, spacing: 4) {
                Text(kicker)
                    .risoKicker()
                HStack(alignment: .center, spacing: 8) {
                    Text(name)
                        .font(.risoHead(nameSize, .extraBold))
                        .tracking(-0.44)
                        .foregroundStyle(Color.risoInk)
                        .lineLimit(2)
                    if let streakValue {
                        streakChip(streakValue)
                    }
                }
                if let status {
                    HStack(spacing: 6) {
                        if isSealed {
                            RisoSealedBadge()
                        } else if isEnded {
                            RisoEndedBadge()
                        } else {
                            statusBadge(status)
                        }
                        if showRecurringBadge {
                            RisoRecurringBadge()
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Trailing slot: Edit squares + "…" menu, or just the menu.
            // Board Edit redesign slice 2 (D1): the "…" menu is a SEPARATE
            // affordance from Edit squares — it is hidden only while
            // `editMode` (the caller passes `canEdit` false and an empty
            // `menuItems` together in that case) or for a draft (empty
            // `menuItems`). Board Edit redesign slice 4 (D14): no
            // "Read-only" label anywhere — a sealed/ended board's trailing
            // slot is just the menu.
            let showEdit = canEdit && !isSealed && !isEnded
            HStack(spacing: 8) {
                if showEdit {
                    RisoButton(
                        title: "Edit squares",
                        kind: .neutral,
                        systemImage: "pencil",
                        small: true,
                        action: onEdit
                    )
                    .accessibilityLabel("Edit squares")
                }
                if !menuItems.isEmpty {
                    BoardActionsMenuButton(items: menuItems, onSelect: onMenuSelect)
                }
            }
            .padding(.top, showEdit ? 22 : 24)
        }
    }

    /// Gold flame streak capsule inline after the board name.
    /// Ink-static content — it sits on gold.
    private func streakChip(_ value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.system(size: 10, weight: .bold))
            Text(value)
                .font(.risoHead(11, .bold))
        }
        .foregroundStyle(Color.risoInkStatic)
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Capsule().fill(Color.risoGold))
        .overlay(Capsule().strokeBorder(Color.risoInkStatic, lineWidth: Riso.Keyline.dense))
        .accessibilityElement()
        .accessibilityLabel("\(value) greenlog streak")
    }

    /// Live status pill (ACTIVE / COMPLETE / DRAFT / ARCHIVED).
    @ViewBuilder
    private func statusBadge(_ status: BoardStatus) -> some View {
        let (label, fill, fore): (String, Color, Color) = {
            switch status {
            case .active:    return ("ACTIVE",    Color.risoBlue,  Color.risoPaper)
            case .completed: return ("COMPLETE",  Color.risoGreen, Color.risoPaper)
            case .draft:     return ("DRAFT",     Color.risoPaper2, Color.risoMuted)
            case .archived:  return ("ARCHIVED",  Color.risoPaper2, Color.risoMuted)
            }
        }()
        Text(label)
            .font(.risoHead(10, .bold))
            .foregroundStyle(fore)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
    }
}
