import SwiftUI

/// Which of the two board-creation entry points this card represents.
/// Board Creation Split (iOS PR A) — mode is fixed per card; there is no
/// shared "decide later" CTA anymore.
enum CreateHubBoardCTAKind {
    /// RED identity — a single board played once, timeframe picked in Setup.
    case oneOff
    /// BLUE identity — a fresh board spawned each cadence from a task pool.
    case recurring
}

/// CreateHubBoardCTAView — Riso-styled full-width card that launches ONE of
/// the two board-creation wizards, mode locked at the tap. iOS twin of
/// web's `CreateHubBoardCTA`.
///
/// Board Creation Split (iOS PR A) replaced the single "Start a new board"
/// CTA — whose Step-1 "Repeats" segmented silently morphed the rest of the
/// wizard (Timeframe hidden, "Choose" center suppressed, task counts flip
/// to "at least N") — with two entry points: a RED one-off card and a BLUE
/// recurring card, always shown together at full strength. The retired
/// `variant` (`.primary`/`.secondary` demotion when core boards need
/// attention) is gone with it — only the `CoreBoardsSectionView` above
/// these cards changes prominence, never the cards themselves.
struct CreateHubBoardCTAView: View {
    let kind: CreateHubBoardCTAKind
    let onTap: () -> Void

    // MARK: - Copy (README §Copy strings — byte-identical to web, parity-critical)

    private var title: String {
        switch kind {
        case .oneOff: return "Start a one-off board"
        case .recurring: return "Start a recurring board"
        }
    }

    private var subtitle: String {
        switch kind {
        case .oneOff: return "Pick a timeframe, fill the grid, play it once."
        case .recurring: return "A fresh board every day, week, month, or year."
        }
    }

    private var systemImageName: String {
        switch kind {
        case .oneOff: return "square.grid.3x3.fill"
        case .recurring: return "repeat"
        }
    }

    private var fill: Color {
        switch kind {
        case .oneOff: return .risoRed
        case .recurring: return .risoBlue
        }
    }

    // MARK: - Body

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Icon square — gold fill with ink symbol (non-inverting ink so
                // the glyph stays readable on gold in dark mode).
                Image(systemName: systemImageName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.risoInkStatic)
                    .frame(width: 44, height: 44)
                    .risoCard(fill: Color.risoGold)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.risoHead(16, .extraBold))
                        .foregroundStyle(Color.risoPaper)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.risoBody(12, .medium))
                        .foregroundStyle(Color.risoPaper.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.risoPaper.opacity(0.7))
            }
            .padding(Riso.cardPadding)
            .risoCard(fill: fill)
        }
        .buttonStyle(RisoButtonStyle())
        .accessibilityLabel(title)
    }
}
