import SwiftUI

// MARK: - RisoBingoToast

/// Drops-in from the top of the screen on a new bingo. Blue keyline card
/// with a placeholder Blip art zone, "BINGO!" headline, subtitle, and the
/// gold bingo-count badge. Auto-dismiss is managed by the caller.
///
/// Animation: the view slides in from translateY −90 to 0 with a slight
/// spring overshoot (~500ms). Attach with `.transition(.move(edge: .top)
/// .combined(with: .opacity))` in the call site.
struct RisoBingoToast: View {

    /// Short contextual subtitle — e.g. "Row 2 complete!"
    let subtitle: String
    /// Current total number of bingos to display in the gold count badge.
    let bingoCount: Int

    var body: some View {
        HStack(spacing: 12) {
            // ── Blip placeholder (42×42) ──
            blipPlaceholder
                .frame(width: 42, height: 42)

            // ── Text column ──
            VStack(alignment: .leading, spacing: 4) {
                Text("BINGO!")
                    .font(.risoHead(19, .extraBold))
                    .tracking(-0.19)
                    .foregroundStyle(Color.risoPaper)

                Text(subtitle)
                    .font(.risoBody(11, .bold))
                    .foregroundStyle(Color.risoPaper.opacity(0.92))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // ── Gold count badge ──
            Text("×\(bingoCount)")
                .font(.risoHead(26, .extraBold))
                .foregroundStyle(Color.risoGold)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.risoBlue)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
        )
        .background(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .fill(Color.risoInk)
                .offset(x: Riso.Shadow.card, y: Riso.Shadow.card)
        )
    }

    // MARK: - Blip placeholder

    /// Overprint sticker character — red circle (multiply) behind a blue
    /// halftone body, ink eyes, gold grin. All shapes, no raster assets.
    private var blipPlaceholder: some View {
        ZStack {
            // Red backing circle (multiply overprint effect)
            Circle()
                .fill(Color.risoRed.opacity(0.85))
                .blendMode(.multiply)
                .frame(width: 38, height: 38)
                .offset(x: -3, y: 4)

            // Blue halftone body
            Circle()
                .fill(Color.risoBlue)
                .risoHalftone(tile: 5, layerOpacity: 0.4)
                .clipShape(Circle())
                .frame(width: 34, height: 34)

            // Eyes
            HStack(spacing: 8) {
                Circle().fill(Color.risoInk).frame(width: 5, height: 5)
                Circle().fill(Color.risoInk).frame(width: 5, height: 5)
            }
            .offset(y: -3)

            // Grin
            Path { path in
                path.move(to: CGPoint(x: 8, y: 12))
                path.addQuadCurve(
                    to: CGPoint(x: 26, y: 12),
                    control: CGPoint(x: 17, y: 20)
                )
            }
            .stroke(Color.risoGold, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 34, height: 24)
            .offset(y: 4)

            // Gold star spark
            StarShape()
                .fill(Color.risoGold)
                .frame(width: 8, height: 8)
                .offset(x: 14, y: -15)
        }
    }
}

// MARK: - Preview

#Preview("Bingo toast") {
    ZStack {
        RisoPaperBackground()
        VStack {
            RisoBingoToast(subtitle: "Row 2 complete!", bingoCount: 2)
                .padding(.horizontal, Riso.gutter)
            Spacer()
        }
        .padding(.top, 60)
    }
}
