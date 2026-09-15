import SwiftUI

/// The pager's window chip: position dots + window label + a chevron.
/// Tapping opens the window picker sheet.
///
/// States (design spec §Window chip):
///   - resting: `risoPaper2` fill, 2pt ink keyline, 2pt hard shadow.
///   - open (picker up): ink fill, paper text, chevron flips up.
///   - empty window: dashed keyline, no shadow.
///   - edit mode: 45% opacity, non-interactive.
///
/// Position dots are the ±2-window neighborhood: 6pt muted filled = has
/// board; 6pt hollow (1.5pt muted) = empty; the displayed window = 9pt
/// ink filled; today's window carries a 2pt gold ring.
///
/// Mirrors the web `CoreWindowChip`.
struct CoreWindowChipView: View {
    /// Window label + suffix, e.g. "September 2026" / "October · next".
    let label: String
    /// ±2-window position dots (from `CoreWindowPicker.buildNeighborhood`).
    let dots: [CoreWindowPicker.NeighborhoodDot]
    /// Picker is open — chip inverts to ink fill, chevron flips up.
    var isOpen: Bool = false
    /// Displayed window has no board — dashed keyline, no shadow.
    var isEmpty: Bool = false
    /// Edit mode — dimmed to 45%, non-interactive.
    var isDisabled: Bool = false
    /// Accessibility label ("September, current window. Opens window picker.").
    let accessibilityText: String
    let action: () -> Void

    private var foreground: Color { isOpen ? .risoPaper : .risoInk }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(dots) { dot in
                        dotView(dot)
                    }
                }
                Text(label)
                    .font(.risoHead(14, .bold))
                    .lineLimit(1)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(foreground)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(Capsule().fill(isOpen ? Color.risoInk : Color.risoPaper2))
            .overlay(
                Capsule().strokeBorder(
                    Color.risoInk,
                    style: StrokeStyle(
                        lineWidth: Riso.Keyline.container,
                        dash: isEmpty && !isOpen ? [5, 4] : []
                    )
                )
            )
            .background(
                // Hard shadow — omitted while open, empty, or disabled.
                Capsule()
                    .fill(isOpen || isEmpty || isDisabled ? Color.clear : Color.risoInk)
                    .offset(x: Riso.Shadow.small, y: Riso.Shadow.small)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .accessibilityLabel(accessibilityText)
    }

    /// One position dot. Filled when the window has a board; hollow when
    /// empty. The displayed window's dot is larger; today's dot carries a
    /// gold ring. The open (inverted) chip renders paper dots — neighbors
    /// at 50%.
    @ViewBuilder
    private func dotView(_ dot: CoreWindowPicker.NeighborhoodDot) -> some View {
        let size: CGFloat = dot.isDisplayed ? 9 : 6
        let baseColor: Color = isOpen
            ? .risoPaper
            : (dot.isDisplayed ? .risoInk : .risoMuted)

        Circle()
            .fill(dot.hasBoard ? baseColor : Color.clear)
            .overlay(
                Circle().strokeBorder(
                    dot.hasBoard ? Color.clear : baseColor,
                    lineWidth: dot.isDisplayed ? 2 : 1.5
                )
            )
            .overlay(
                Circle()
                    .strokeBorder(
                        dot.isToday ? Color.risoGold : Color.clear,
                        lineWidth: 2
                    )
                    .padding(-2)
            )
            .frame(width: size, height: size)
            .opacity(isOpen && !dot.isDisplayed ? 0.5 : 1)
    }
}
