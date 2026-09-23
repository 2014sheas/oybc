import SwiftUI

/// RisoDiceButton — the 28×28 opt-in "variation" toggle that sits after a
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

    /// Pip centres per vary level, in the button's 24×24 inner box:
    /// `.off` = one centred pip, dimmed (B3.1 — an empty bordered square
    /// beside the row's ✕ reads as an unchecked checkbox, not a die);
    /// `.little` = two pips on the diagonal, `.lot` = the five-pip
    /// quincunx — a true quincunx now that the box is square. Same
    /// coordinates as the web SVG viewBox.
    ///
    /// The face grew 22×22 → 28×28 on 2026-09-22 (owner, device-testing
    /// #493: the member-row controls were too small to use comfortably),
    /// so it no longer sits visibly smaller than the 32pt stepper pill
    /// beside it and matches the row's 28pt ✕. The whole geometry scaled
    /// with it: the inner box 18 → 24 (the same 2pt inset inside the
    /// face), ``pipDiameter`` 3.2 → 4, and every coordinate by 24/18,
    /// rounded to integers — 9 → 12, 5 → 7, 13 → 17 — identically to the
    /// web SVG. The proportions of the B3.1 review that set the corners
    /// at 5/13 rather than 6/12 are therefore preserved.
    ///
    /// Clearance to the keyline is now **5.5pt**: the outermost pip edge
    /// sits at 17 + 2 (radius) = 19 in the 24-box, so 21 in face
    /// coordinates (the box is centred, inset 2), while the 1.5pt
    /// ``Riso/Keyline/dense`` has its inner edge at 26.5 — 26.5 − 21 =
    /// 5.5. The worst pip-EDGE gap, corner to centre, is
    /// √(5²+5²) = 7.071 − 4 = **3.07pt** (was 2.46pt at the old scale).
    /// The `Riso.cellRadius` corner does not bite — its arc centre sits
    /// inside the pip centre on both axes, so the straight edges govern.
    ///
    /// Internal rather than private so `RisoDiceButtonTests` can pin the
    /// coordinates against the web twin's `PIPS` table — cross-platform
    /// coordinate parity is the whole point of the square-dice face, and
    /// the iOS snapshot baselines that would otherwise be the only cover
    /// are advisory in CI (ROADMAP A8).
    static let pips: [VaryLevel: [CGPoint]] = [
        .off: [CGPoint(x: 12, y: 12)],
        .little: [CGPoint(x: 7, y: 7), CGPoint(x: 17, y: 17)],
        .lot: [
            CGPoint(x: 7, y: 7),
            CGPoint(x: 17, y: 7),
            CGPoint(x: 12, y: 12),
            CGPoint(x: 7, y: 17),
            CGPoint(x: 17, y: 17),
        ],
    ]

    static let pipDiameter: CGFloat = 4

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
                .frame(width: 28, height: 28)
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
        .frame(width: 24, height: 24)
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
