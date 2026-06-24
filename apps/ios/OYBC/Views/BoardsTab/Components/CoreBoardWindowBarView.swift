import SwiftUI

/// Prev / label / next navigation bar for the core-board window pager,
/// with a trailing list button that opens the full browser.
///
/// Prev and next paging is always enabled (unbounded — the user can
/// page as far into the past or future as they like). The label
/// reflects the current window (e.g. "Today", "Week of May 18 – 24").
///
/// Rendered in the Riso design language: Bricolage/Archivo typography,
/// paper background, ink keyline chevrons, `RisoIconButton` for
/// navigation actions.
///
/// Mirrors the web `CoreBoardWindowBar` component.
struct CoreBoardWindowBarView: View {
    let label: String
    /// Current greenlog streak for this timeframe. 0 (or a non-recurring
    /// timeframe) hides the flame chip. The chip's display ("3w") and its
    /// VoiceOver label ("3 weekly greenlog streak") are both derived from
    /// `streakCount` + `streakTimeframe`.
    var streakCount: Int = 0
    var streakTimeframe: Timeframe = .weekly
    let onPrev: () -> Void
    let onNext: () -> Void
    let onOpenList: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Previous chevron
            Button(action: onPrev) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 44, height: 44)
                    .risoCard(fill: .risoPaper2)
            }
            .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small, radius: Riso.cardRadius))
            .accessibilityLabel("Previous window")

            Spacer()

            // Window label + optional greenlog-streak flame chip
            VStack(spacing: 3) {
                Text(label)
                    .font(.risoHead(15, .bold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if streakCount >= 1 {
                    streakChip
                }
            }

            Spacer()

            // List (browser) button
            Button(action: onOpenList) {
                HStack(spacing: 5) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 12, weight: .bold))
                    Text("List")
                        .font(.risoHead(13, .bold))
                }
                .foregroundStyle(Color.risoInk)
                .padding(.vertical, 11)
                .padding(.horizontal, 13)
                .risoCard(fill: .risoPaper2)
            }
            .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small, radius: Riso.cardRadius))
            .accessibilityLabel("Show all windows")

            // Next chevron
            Button(action: onNext) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 44, height: 44)
                    .risoCard(fill: .risoPaper2)
            }
            .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small, radius: Riso.cardRadius))
            .accessibilityLabel("Next window")
        }
        .padding(.horizontal, Riso.gutter)
        .padding(.vertical, 10)
        .background(Color.risoPaper)
        .overlay(
            Rectangle()
                .fill(Color.risoInk.opacity(0.15))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    /// Gold flame capsule (🔥 3d) showing the current greenlog streak for this
    /// timeframe. `risoInkStatic` keeps it readable on gold in dark mode.
    private var streakChip: some View {
        HStack(spacing: 2) {
            Image(systemName: "flame.fill")
                .font(.system(size: 8, weight: .bold))
            Text(compactStreakLabel(streakCount, timeframe: streakTimeframe))
                .font(.risoHead(10, .bold))
        }
        .foregroundStyle(Color.risoInkStatic)
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(Capsule().fill(Color.risoGold))
        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
        .accessibilityElement()
        .accessibilityLabel("\(streakCount) \(streakA11yWord) greenlog streak")
    }

    /// Human timeframe word for VoiceOver (e.g. "weekly"), so the chip reads
    /// "3 weekly greenlog streak" rather than the letter-by-letter "3w".
    private var streakA11yWord: String {
        switch streakTimeframe {
        case .daily:   return "daily"
        case .weekly:  return "weekly"
        case .monthly: return "monthly"
        case .yearly:  return "yearly"
        case .custom:  return "custom"
        case .indefinite: return "ongoing"
        }
    }
}
