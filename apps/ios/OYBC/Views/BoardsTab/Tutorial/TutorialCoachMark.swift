import SwiftUI

/// The walkthrough's coach mark (handoff 03 / `CoachMark.dc.html`): a paper-2
/// card with the lesson title, an optional RESUMED tag, the ✕ exit, the one-line
/// instruction, step dots and (on read-only steps) a gold Next button, with a
/// 12pt notch on the edge facing the lit control. Props-only so it snapshots.
struct TutorialCoachMark: View {
    /// Which card edge carries the notch (the edge facing the target).
    enum Notch: Equatable {
        case up      // card sits below the target
        case down    // card sits above the target
        case none    // no target (fallback placement)
    }

    let lessonTitle: String
    let text: String
    /// 0-based index of the current step.
    let step: Int
    let stepCount: Int
    var resumed: Bool = false
    var showsNext: Bool = false
    /// The step's action happened: a green check leads the line, Next moves on.
    var done: Bool = false
    var notch: Notch = .up
    /// Distance from the card's leading edge to the notch's centre.
    var notchOffset: CGFloat = 28
    var onExit: () -> Void = {}
    var onNext: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(lessonTitle)
                    .risoSectionLabel()
                    .lineLimit(1)
                    .truncationMode(.tail)
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
                Spacer(minLength: 0)
                Button(action: onExit) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.risoMuted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -2)
                .accessibilityLabel("Exit lesson")
            }
            .frame(minHeight: 24)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color.risoPaper)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.risoGreen))
                        .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                        .accessibilityHidden(true)
                }
                Text(text)
                    .font(.risoHead(15, .bold))
                    .tracking(-0.15)
                    .lineSpacing(15 * 0.3 - 15 * 0.2) // line-height 1.3 over the ~1.2 font default
                    .foregroundStyle(Color.risoInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(0..<max(stepCount, 1), id: \.self) { index in
                        Circle()
                            .fill(index <= step ? Color.risoGold : Color.risoPaper)
                            .frame(width: 6, height: 6)
                            .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense).padding(-Riso.Keyline.dense))
                    }
                }
                .padding(.horizontal, Riso.Keyline.dense)
                Text("\(step + 1) of \(stepCount)")
                    .font(.risoHead(11, .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.risoMuted)
                Spacer(minLength: 0)
                if showsNext {
                    RisoButton(title: "Next", kind: .gold, small: true, action: onNext)
                }
            }
            .frame(minHeight: 24)
            .padding(.top, 4)
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 12, trailing: 10))
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.button)
        .overlay(alignment: notch == .down ? .bottomLeading : .topLeading) {
            if notch != .none { notchView }
        }
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
