import SwiftUI

/// The Profile-home "day one" hero card (design handoff §1.3, frame `#4e`) —
/// shown ABOVE the two tiles only while `completedCount == 0`. Copy is
/// verbatim: kicker "GETTING STARTED", title "Make your first board", body
/// "Eight short steps. This card leaves once you've done them.", a 6pt
/// progress track, "{done}/{total}", and a pill button "Start".
///
/// Distinct from `TutorialCard` (the Boards-tab pinned card): different
/// copy, no dismiss ✕ (this card only ever shows at `completedCount == 0`
/// and disappears on its own once a lesson is learned), and the "Start"
/// pill sits inline with the progress row rather than as a top-row chip.
/// The whole card is one tap target — "Start" is a styled `Text`, not a
/// nested `Button` (this card has only one destination).
struct RisoGettingStartedHero: View {
    let done: Int
    let total: Int
    let onStart: () -> Void

    private var fraction: Double {
        total > 0 ? Double(done) / Double(total) : 0
    }

    var body: some View {
        Button(action: onStart) {
            VStack(alignment: .leading, spacing: 8) {
                Text("GETTING STARTED")
                    .font(.risoBody(11, .bold))
                    .tracking(2.2)
                    .foregroundStyle(Color.risoInkStatic.opacity(0.7))

                Text("Make your first board")
                    .font(.risoHead(22, .extraBold))
                    .tracking(-0.44)
                    .foregroundStyle(Color.risoInkStatic)

                Text("Eight short steps. This card leaves once you've done them.")
                    .font(.risoBody(13, .semibold))
                    .foregroundStyle(Color.risoInkStatic.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.risoInkStatic.opacity(0.2))
                            Capsule().fill(Color.risoInkStatic)
                                .frame(width: max(0, min(1, fraction)) * geo.size.width)
                        }
                    }
                    .frame(height: 6)

                    Text("\(done)/\(total)")
                        .font(.risoHead(12, .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.risoInkStatic)
                        .fixedSize()

                    Text("Start")
                        .font(.risoHead(13, .extraBold))
                        .foregroundStyle(Color.risoOnColor)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(Capsule().fill(Color.risoInkStatic))
                        .fixedSize()
                }
                .padding(.top, 4)
            }
            .padding(Riso.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .risoCard(fill: .risoGold)
        .risoHardShadow(Riso.Shadow.card, radius: Riso.cardRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Getting started, make your first board, \(done) of \(total) done")
    }
}

#if DEBUG
#Preview("Day one hero") {
    ZStack {
        RisoPaperBackground()
        RisoGettingStartedHero(done: 0, total: 8, onStart: {})
            .padding(20)
    }
}
#endif
