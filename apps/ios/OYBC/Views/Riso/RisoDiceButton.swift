import SwiftUI

/// RisoDiceButton — the 26×22 opt-in "variation" toggle that sits after a
/// counting target (docs/BOARD_SOURCES.md §Member rules; handoff
/// §Interactions "Variation (dice)").
///
/// Off renders a muted 1.5pt outline with one faint centred pip (a die
/// face, not an empty checkbox); on renders a blue fill with
/// `risoInkStatic` pips — adaptive `risoInk` on a coloured fill is the
/// dark-mode trap (see memory `reference_riso_adaptive_ink_fill_darkmode`).
///
/// Stateless: the caller owns the level and decides what one tap means, so
/// the same button serves a member, a compound part and a hand-added row.
///
/// Web twin: `apps/web/src/components/riso/DiceButton.tsx`.
struct RisoDiceButton: View {

    /// Current vary level — `.off`, `.little` (±20 %), `.lot` (±50 %).
    let level: VaryLevel
    /// Advance one step around the off → a little → a lot → off cycle.
    let onCycle: () -> Void

    /// Pip centres per vary level, in the button's 20×16 inner box:
    /// `.off` = one centred pip, dimmed (B3.1 — an empty bordered square
    /// beside the row's ✕ reads as an unchecked checkbox, not a die);
    /// `.little` = two pips on the diagonal, `.lot` = the five-pip
    /// quincunx. Same coordinates as the web SVG viewBox.
    private static let pips: [VaryLevel: [CGPoint]] = [
        .off: [CGPoint(x: 10, y: 8)],
        .little: [CGPoint(x: 6, y: 5), CGPoint(x: 14, y: 11)],
        .lot: [
            CGPoint(x: 6, y: 5),
            CGPoint(x: 14, y: 5),
            CGPoint(x: 10, y: 8),
            CGPoint(x: 6, y: 11),
            CGPoint(x: 14, y: 11),
        ],
    ]

    private static let pipDiameter: CGFloat = 3.2

    /// Accessible name = the CURRENT state (B3 RC1), not the action. The
    /// button cycles through THREE states, so it deliberately carries no
    /// toggle trait: a pressed/not-pressed announcement would read "a
    /// little" and "a lot" identically, and a stateful name already tells a
    /// screen-reader user exactly where the control sits.
    private var label: String {
        switch level {
        case .off: return "Vary: off"
        case .little: return "Vary: a little"
        case .lot: return "Vary: a lot"
        }
    }

    var body: some View {
        Button(action: onCycle) {
            RoundedRectangle(cornerRadius: Riso.cellRadius)
                .fill(level == .off ? Color.clear : Color.risoBlue)
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cellRadius)
                        .strokeBorder(
                            level == .off ? Color.risoMuted : Color.risoInk,
                            lineWidth: Riso.Keyline.dense
                        )
                )
                .overlay { pipsView }
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var pipsView: some View {
        let points = Self.pips[level] ?? []
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(points.indices, id: \.self) { index in
                Circle()
                    // The off face's pip sits on PAPER, so it takes the
                    // adaptive muted ink; the lit faces' pips sit on the
                    // blue fill and must stay risoInkStatic (the
                    // dark-mode trap).
                    .fill(level == .off ? Color.risoMuted : Color.risoInkStatic)
                    .opacity(level == .off ? 0.45 : 1)
                    .frame(width: Self.pipDiameter, height: Self.pipDiameter)
                    .offset(
                        x: points[index].x - Self.pipDiameter / 2,
                        y: points[index].y - Self.pipDiameter / 2
                    )
            }
        }
        .frame(width: 20, height: 16)
    }
}

extension VaryLevel {
    /// The dice cycle: off → a little → a lot → off (handoff
    /// §Interactions "Variation (dice)"). Scoped to the type rather than
    /// left as a top-level function, but still ONE definition so the
    /// three dice surfaces (member, part, hand-added row) can't drift
    /// apart. Web twin: the module-private `nextVary` in
    /// `MemberRuleRow.tsx` / `PoolList.tsx`.
    var next: VaryLevel {
        switch self {
        case .off: return .little
        case .little: return .lot
        case .lot: return .off
        }
    }
}
