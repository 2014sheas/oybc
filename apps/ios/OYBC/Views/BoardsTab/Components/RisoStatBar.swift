import SwiftUI

// MARK: - RisoStatBar

/// The three-card stat bar at the top of the play board:
///   - "SQUARES  14/25" + mini progress bar
///   - "LEFT  4d  to fill it"
///   - "BINGOS  ★ 1" (solid gold card)
///
/// Pure presentation — no database access.
struct RisoStatBar: View {

    let completedTasks: Int
    let totalTasks: Int
    let linesCompleted: Int
    /// "4d" or "Expired" etc — produced by `getExpiryLabel` in the caller.
    let expiryText: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // ── Squares card ──
            squaresCard

            // ── Left card ──
            leftCard

            // ── Bingos card (gold) ──
            bingosCard
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Cards

    private var squaresCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SQUARES")
                .risoSectionLabel()

            // "14/25" — large value with muted denominator
            (Text("\(completedTasks)")
                .font(.risoHead(19, .extraBold))
                .foregroundStyle(Color.risoInk)
            + Text("/\(totalTasks)")
                .font(.risoHead(13, .extraBold))
                .foregroundStyle(Color.risoMuted)
            )
            .monospacedDigit()

            RisoProgressBar(
                value: totalTasks > 0 ? Double(completedTasks) / Double(totalTasks) : 0,
                color: completedTasks == totalTasks && totalTasks > 0 ? .risoGreen : .risoRed,
                height: 9
            )
            .padding(.top, 3)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.risoPaper2)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
        )
    }

    private var leftCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LEFT")
                .risoSectionLabel()

            Text(expiryText)
                .font(.risoHead(19, .extraBold))
                .foregroundStyle(Color.risoInk)
                .monospacedDigit()

            Text("to fill it")
                .font(.risoBody(10, .bold))
                .foregroundStyle(Color.risoMuted)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.risoPaper2)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
        )
    }

    private var bingosCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Content sits on the gold card — non-inverting ink for dark mode.
            Text("BINGOS")
                .font(.risoBody(9, .bold))
                .tracking(1.0)
                .textCase(.uppercase)
                .foregroundStyle(Color.risoInkStatic)

            HStack(alignment: .center, spacing: 5) {
                StarShape()
                    .fill(Color.risoInkStatic)
                    .frame(width: 15, height: 15)
                Text("\(linesCompleted)")
                    .font(.risoHead(19, .extraBold))
                    .foregroundStyle(Color.risoInkStatic)
                    .monospacedDigit()
            }
        }
        .padding(11)
        .frame(minWidth: 72, alignment: .leading)
        .background(Color.risoGold)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
        )
    }
}

// MARK: - Preview

#Preview("Stat bar — light") {
    ZStack {
        RisoPaperBackground()
        RisoStatBar(
            completedTasks: 12,
            totalTasks: 25,
            linesCompleted: 1,
            expiryText: "4d"
        )
        .padding(Riso.gutter)
    }
}

#Preview("Stat bar — dark") {
    ZStack {
        RisoPaperBackground()
        RisoStatBar(
            completedTasks: 25,
            totalTasks: 25,
            linesCompleted: 5,
            expiryText: "Expired"
        )
        .padding(Riso.gutter)
    }
    .environment(\.colorScheme, .dark)
}
