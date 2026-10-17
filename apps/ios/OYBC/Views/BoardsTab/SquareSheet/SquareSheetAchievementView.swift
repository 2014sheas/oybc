import SwiftUI

/// The achievement body of the square sheet: the watched-board card and the
/// gold "Open ‹board›" button. Reading is allowed on a closed board — opening
/// a board is navigation, not a write.
struct SquareSheetAchievementView: View {
    let achievement: SquareSheetContent.Achievement
    let actions: SquareSheetActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if achievement.isMet {
                    RisoStatusPill(status: .done)
                } else {
                    SquareSheetBadge(text: "Watching")
                }
            }
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("WATCHED BOARD")
                        .font(.risoHead(11, .bold))
                        .tracking(1.1)
                        .foregroundStyle(Color.risoMuted)
                    if let badge = achievement.timeframeBadge {
                        Text(badge.uppercased())
                            .font(.risoHead(9, .bold))
                            .tracking(0.45)
                            .foregroundStyle(Color.risoMuted)
                            .padding(.vertical, 1)
                            .padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.risoPaper))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                    }
                    Spacer(minLength: 4)
                    if let days = achievement.daysLeft {
                        Text(days)
                            .font(.risoBody(11, .semibold))
                            .foregroundStyle(Color.risoMuted)
                    }
                }
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(achievement.watchedName ?? "Board unavailable")
                        .font(.risoHead(22, .extraBold))
                        .tracking(-0.4)
                        .foregroundStyle(Color.risoInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text(achievement.progress)
                        .font(.risoHead(14, .extraBold))
                        .monospacedDigit()
                        .foregroundStyle(Color.risoInk)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .risoCard(fill: .risoPaper2)
            .padding(.top, 12)

            if let boardId = achievement.openBoardId, let name = achievement.watchedName {
                RisoButton(title: "Open \(name)", kind: .gold, fullWidth: true) { actions.onOpenBoard(boardId) }
                    .padding(.top, 12)
            }
        }
    }
}
