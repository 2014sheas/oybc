import SwiftUI

/// RisoDiceButton — the 26×22 opt-in "variation" toggle that sits after a
/// counting target (docs/BOARD_SOURCES.md §Member rules; handoff
/// §Interactions "Variation (dice)").
///
/// Off renders a muted 1.5pt outline with no pips; on renders a blue fill
/// with `risoInkStatic` pips — adaptive `risoInk` on a coloured fill is the
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
    /// `.little` = two pips on the diagonal, `.lot` = the five-pip
    /// quincunx. `.off` draws nothing (handoff: "Off state: muted 1.5pt
    /// outline, no pips"). Same coordinates as the web SVG viewBox.
    private static let pips: [VaryLevel: [CGPoint]] = [
        .off: [],
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
                    .fill(Color.risoInkStatic)
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

/// The dice cycle: off → a little → a lot → off (handoff §Interactions
/// "Variation (dice)"). Shared by every dice call site so the three
/// surfaces (member, part, hand-added row) can't drift apart. Web twin:
/// the local `nextVary` in `MemberRuleRow.tsx` / `PoolList.tsx`.
///
/// - Parameter level: The current level.
/// - Returns: The next level in the cycle.
func nextVaryLevel(_ level: VaryLevel) -> VaryLevel {
    switch level {
    case .off: return .little
    case .little: return .lot
    case .lot: return .off
    }
}
