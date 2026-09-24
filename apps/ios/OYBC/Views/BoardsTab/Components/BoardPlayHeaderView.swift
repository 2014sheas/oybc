import SwiftUI

/// The play board's in-content title block (masthead layout — core-board
/// surface rework): kicker · name (+ inline gold streak chip) · badge
/// row, with the Edit button — or the sealed "Read-only" lock — in the
/// trailing slot.
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
    /// Sealed boards show CLOSED in place of the status badge and the
    /// Read-only lock in the trailing slot.
    var isSealed: Bool = false
    /// Whether to show the RECURRING provenance badge.
    var showRecurringBadge: Bool = false
    /// Whether the trailing slot shows the Edit button (the caller's
    /// one-rule gate). Ignored when `isSealed`.
    var canEdit: Bool = false
    var onEdit: () -> Void = {}

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

            // Trailing slot: Edit / Read-only / nothing.
            if canEdit && !isSealed {
                RisoButton(
                    title: "Edit",
                    kind: .neutral,
                    systemImage: "pencil",
                    small: true,
                    action: onEdit
                )
                .padding(.top, 22)
                .accessibilityLabel("Edit board")
            } else if isSealed {
                HStack(spacing: 5) {
                    Image(systemName: "lock")
                        .font(.system(size: 12, weight: .bold))
                    Text("Read-only")
                        .font(.risoBody(11, .bold))
                }
                .foregroundStyle(Color.risoMuted)
                .padding(.top, 24)
            }
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
            case .active:    return ("ACTIVE",    Color.risoBlue,  Color.risoOnColor)
            case .completed: return ("COMPLETE",  Color.risoGreen, Color.risoOnColor)
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
