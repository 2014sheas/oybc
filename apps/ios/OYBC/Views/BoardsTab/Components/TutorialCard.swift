import SwiftUI

/// Pinned gold "Getting started" card on the Boards home (handoff 01). The pill
/// reads START HERE, then KEEP GOING once a lesson is done, then BINGO once the
/// free middle row is. The ✕ appears only when the middle row is done; the
/// dismissal is stored with the account. Tapping opens the tutorial board.
/// Props-only / snapshot-testable.
struct TutorialCard: View {
    let done: Int
    let total: Int
    /// The three free lessons are done: the pill reads BINGO and the ✕ shows.
    var middleRowDone: Bool = false
    let onOpen: () -> Void
    let onDismiss: () -> Void

    private var fraction: Double {
        total > 0 ? Double(done) / Double(total) : 0
    }

    /// START HERE → KEEP GOING → BINGO.
    private var pill: String {
        if middleRowDone { return "BINGO" }
        return done >= 1 ? "KEEP GOING" : "START HERE"
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(pill)
                        .font(.risoBody(10, .bold))
                        .tracking(0.6)
                        .foregroundStyle(Color.risoPaper)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(Capsule().fill(Color.risoInk))

                    Text("Getting started")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInkStatic)

                    Spacer(minLength: 4)

                    if middleRowDone {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.risoInkStatic)
                                .frame(width: 26, height: 26)
                                .background(Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Hide tutorial")
                    }
                }

                HStack(spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.risoInkStatic.opacity(0.18))
                            Capsule().fill(Color.risoGreen)
                                .frame(width: max(0, min(1, fraction)) * geo.size.width)
                        }
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                    }
                    .frame(height: 10)

                    Text("\(done)/\(total)")
                        .font(.risoHead(12, .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.risoInkStatic)
                }
            }
            .padding(Riso.cardPadding)
            .risoCard(fill: .risoGold)
            .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview("Tutorial card") {
    ZStack {
        RisoPaperBackground()
        VStack(spacing: 16) {
            TutorialCard(done: 0, total: 9, onOpen: {}, onDismiss: {})
            TutorialCard(done: 1, total: 9, onOpen: {}, onDismiss: {})
            TutorialCard(done: 3, total: 9, middleRowDone: true, onOpen: {}, onDismiss: {})
        }
        .padding(20)
    }
}
#endif
