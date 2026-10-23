import SwiftUI

/// The walkthrough's compact coach mark (`CoachMark.dc.html`): a paper-2 card
/// with one line of Bricolage 15/700, a gold RESUMED tag on the first mark
/// after a resume, Next (gold, small) on read-only steps only, and a 12pt notch
/// on the edge facing the lit control. Step and exit live in the tutorial bar.
/// Props-only so it snapshots.
struct TutorialCoachMark: View {
    /// Which card edge carries the notch (the edge facing the target).
    enum Notch: Equatable {
        case up      // card sits below the target
        case down    // card sits above the target
        case none    // several targets, or no target
    }

    let text: String
    var resumed: Bool = false
    var showsNext: Bool = false
    var notch: Notch = .up
    /// Distance from the card's leading edge to the notch's centre.
    var notchOffset: CGFloat = 28
    var onNext: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(text)
                .font(.risoHead(15, .bold))
                .tracking(-0.15)
                .lineSpacing(15 * 0.3 - 15 * 0.2) // line-height 1.3 over the ~1.2 font default
                .foregroundStyle(Color.risoInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if resumed {
                Text("RESUMED")
                    .font(.risoHead(9, .bold))
                    .tracking(0.45)
                    .foregroundStyle(Color.risoInkStatic)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 7)
                    .background(Capsule().fill(Color.risoGold))
                    .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                    .fixedSize()
            }
            if showsNext {
                RisoButton(title: "Next", kind: .gold, small: true, action: onNext)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 12))
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.button)
        .overlay(alignment: notch == .down ? .bottomLeading : .topLeading) {
            if notch != .none { notchView }
        }
        .accessibilityElement(children: .contain)
    }

    /// The 12pt rotated square on the edge facing the target; its two outer
    /// edges carry the card's keyline.
    private var notchView: some View {
        Rectangle()
            .fill(Color.risoPaper2)
            .frame(width: 12, height: 12)
            .overlay(alignment: notch == .up ? .topLeading : .bottomTrailing) {
                NotchEdges(up: notch == .up)
                    .stroke(Color.risoInk, lineWidth: Riso.Keyline.container)
            }
            .rotationEffect(.degrees(45))
            .offset(x: notchOffset - 6, y: notch == .up ? -7 : 7)
            .allowsHitTesting(false)
    }
}

/// The two edges of the notch square that show outside the card (top+left for
/// an up notch, bottom+right for a down notch).
private struct NotchEdges: Shape {
    let up: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if up {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        return path
    }
}
