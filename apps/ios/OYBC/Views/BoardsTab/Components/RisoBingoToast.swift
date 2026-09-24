import SwiftUI

// MARK: - RisoBingoToast

/// Drops-in from the top of the screen on a new bingo. Blue keyline card
/// with a mini-board art slot showing the board's completed line(s),
/// "BINGO!" headline, subtitle, and the gold bingo-count badge.
/// Auto-dismiss is managed by the caller.
///
/// Animation: the view slides in from translateY −90 to 0 with a slight
/// spring overshoot (~500ms). Attach with `.transition(.move(edge: .top)
/// .combined(with: .opacity))` in the call site.
struct RisoBingoToast: View {

    /// Short contextual subtitle — e.g. "Row 2 complete!"
    let subtitle: String
    /// Current total number of bingos to display in the gold count badge.
    let bingoCount: Int
    /// The board's grid size — the art mirrors the real geometry.
    var boardSize: Int = 5
    /// Completed-line cell indices (reading order) to light in the art —
    /// the caller already derives these from `completedLineIds` via
    /// `BingoDetection.getHighlightedSquares`.
    var lineCells: Set<Int> = []

    var body: some View {
        HStack(spacing: 12) {
            // ── Mini-board art (42×42, unframed, on-blue) ──
            RisoMiniBoardArt(
                size: 42,
                grid: boardSize,
                state: .bingo(lineCells),
                framed: false,
                onBlue: true
            )

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
}

// MARK: - Preview

#Preview("Bingo toast") {
    ZStack {
        RisoPaperBackground()
        VStack {
            RisoBingoToast(
                subtitle: "Row 2 complete!",
                bingoCount: 2,
                boardSize: 5,
                lineCells: [10, 11, 12, 13, 14]
            )
                .padding(.horizontal, Riso.gutter)
            Spacer()
        }
        .padding(.top, 60)
    }
}
