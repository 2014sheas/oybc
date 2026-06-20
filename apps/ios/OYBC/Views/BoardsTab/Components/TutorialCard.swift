import SwiftUI

/// Pinned gold "Getting Started" card on the Boards home (handoff §0a,
/// screenshot 20). Tapping it opens the tutorial board; the ✕ dismisses it
/// (the tutorial stays reachable from Profile). Props-only / snapshot-testable.
struct TutorialCard: View {
    let done: Int
    let total: Int
    let onOpen: () -> Void
    let onDismiss: () -> Void

    private var complete: Bool { done >= total }
    private var fraction: Double {
        total > 0 ? Double(done) / Double(total) : 0
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                // Top row: "START HERE" pill + title + dismiss ✕
                HStack(spacing: 8) {
                    Text(complete ? "DONE" : "START HERE")
                        .font(.risoBody(10, .bold))
                        .tracking(0.6)
                        .foregroundStyle(Color.risoPaper)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(Capsule().fill(Color.risoInk))

                    Text(complete ? "You know OYBC" : "Getting started")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInkStatic)

                    Spacer(minLength: 4)

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

                Text(complete
                     ? "Every square cleared. Replay it any time from settings."
                     : "Learn OYBC by playing it — eight squares, eight key moves.")
                    .font(.risoBody(13, .semibold))
                    .foregroundStyle(Color.risoInkStatic.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Progress bar + count
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
            TutorialCard(done: 3, total: 8, onOpen: {}, onDismiss: {})
            TutorialCard(done: 8, total: 8, onOpen: {}, onDismiss: {})
        }
        .padding(20)
    }
}
#endif
