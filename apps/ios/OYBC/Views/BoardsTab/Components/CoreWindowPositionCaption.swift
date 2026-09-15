import SwiftUI

/// The centred `‹ August · dots · October ›` row under the board grid.
/// Tapping a side steps one window (same as the swipe). Archivo 11 bold,
/// muted; the dots reuse the chip's neighborhood palette (6pt base,
/// 8pt displayed, gold ring on today).
///
/// Mirrors the web `CoreWindowPositionCaption`.
struct CoreWindowPositionCaption: View {
    /// Previous window's label ("August").
    let prevLabel: String
    /// Next window's label ("October").
    let nextLabel: String
    /// ±2-window position dots (from `CoreWindowPicker.buildNeighborhood`).
    let dots: [CoreWindowPicker.NeighborhoodDot]
    /// Stepping is disabled (edit mode).
    var isDisabled: Bool = false
    let onPrev: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPrev) {
                Text("‹ \(prevLabel)")
                    .font(.risoBody(11, .bold))
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel("Previous window")

            HStack(spacing: 6) {
                ForEach(dots) { dot in
                    dotView(dot)
                }
            }
            .accessibilityHidden(true)

            Button(action: onNext) {
                Text("\(nextLabel) ›")
                    .font(.risoBody(11, .bold))
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel("Next window")
        }
        .foregroundStyle(Color.risoMuted)
        .opacity(isDisabled ? 0.45 : 1)
        .frame(maxWidth: .infinity)
    }

    /// One position dot: 6pt muted filled (has board), 8pt ink
    /// (displayed), 6pt hollow 1.5pt muted (empty); gold ring on today.
    @ViewBuilder
    private func dotView(_ dot: CoreWindowPicker.NeighborhoodDot) -> some View {
        let size: CGFloat = dot.isDisplayed ? 8 : 6
        let baseColor: Color = dot.isDisplayed ? .risoInk : .risoMuted

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
                        lineWidth: 1.5
                    )
                    .padding(-1.5)
            )
            .frame(width: size, height: size)
    }
}
