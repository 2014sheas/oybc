import SwiftUI

/// Riso-styled "Your streaks" card for the Profile tab — a per-timeframe matrix
/// of the user's current **bingo** and **greenlog** streaks.
///
/// Pure presentational: takes a `[Timeframe: StreakPair]` map (from
/// `computeAllStreaks`) and renders the four recurring timeframes in order.
/// No environment / DB / Firebase dependency, so it's snapshot-testable in
/// isolation (same convention as `RisoProfileAccountCard` /
/// `NotificationPreferencesContent`).
///
/// A streak of 0 renders a muted "–" cell; ≥ 1 renders a colored flame chip
/// (gold for bingo, green for greenlog). On-gold text uses `risoInkStatic`
/// (non-inverting) so it stays readable in dark mode; on green it uses
/// `risoPaper`, matching the completed-cell convention.
struct RisoYourStreaksCard: View {

    let streaks: [Timeframe: StreakPair]

    private let order: [Timeframe] = [.daily, .weekly, .monthly, .yearly]
    /// Shared width for the two stat columns so headers + cells stay aligned.
    /// Wide enough for the "Greenlog" header (with a scale fallback) and "12mo".
    private let cellWidth: CGFloat = 76

    private func label(_ tf: Timeframe) -> String {
        switch tf {
        case .daily:   return "Daily"
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        case .yearly:  return "Yearly"
        case .custom:  return "Custom"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                columnHeader("Bingo")
                columnHeader("Greenlog")
            }
            .padding(.bottom, 8)

            ForEach(Array(order.enumerated()), id: \.element) { index, tf in
                if index > 0 { rowDivider }
                let pair = streaks[tf] ?? StreakPair(bingo: 0, greenlog: 0)
                HStack(spacing: 8) {
                    Text(label(tf))
                        .font(.risoBody(14, .bold))
                        .foregroundStyle(Color.risoInk)
                    Spacer(minLength: 0)
                    streakCell(count: pair.bingo, timeframe: tf, fill: .risoGold, onFill: .risoInkStatic)
                    streakCell(count: pair.greenlog, timeframe: tf, fill: .risoGreen, onFill: .risoPaper)
                }
                .padding(.vertical, 9)
            }
        }
        .padding(Riso.cardPadding)
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    // MARK: - Pieces

    private func columnHeader(_ text: String) -> some View {
        Text(text)
            .risoSectionLabel()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: cellWidth, alignment: .center)
    }

    /// One streak cell: a colored flame chip for ≥ 1, a muted "–" otherwise.
    @ViewBuilder
    private func streakCell(count: Int, timeframe: Timeframe, fill: Color, onFill: Color) -> some View {
        if count >= 1 {
            HStack(spacing: 2) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(compactStreakLabel(count, timeframe: timeframe))
                    .font(.risoHead(12, .bold))
            }
            .foregroundStyle(onFill)
            .frame(width: cellWidth, height: 26)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
            .accessibilityLabel("\(count) \(label(timeframe).lowercased()) streak")
        } else {
            Text("–")
                .font(.risoHead(12, .bold))
                .foregroundStyle(Color.risoMuted)
                .frame(width: cellWidth, height: 26)
                .background(Capsule().fill(Color.risoPaper2))
                .overlay(Capsule().strokeBorder(Color.risoInk.opacity(0.25), lineWidth: Riso.Keyline.dense))
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.risoInk.opacity(0.12))
            .frame(height: 1)
    }
}

#if DEBUG
#Preview("Your streaks — mixed") {
    ZStack {
        RisoPaperBackground()
        RisoYourStreaksCard(streaks: [
            .daily: StreakPair(bingo: 12, greenlog: 5),
            .weekly: StreakPair(bingo: 3, greenlog: 0),
            .monthly: StreakPair(bingo: 0, greenlog: 0),
            .yearly: StreakPair(bingo: 1, greenlog: 1),
        ])
        .padding(20)
    }
}
#endif
