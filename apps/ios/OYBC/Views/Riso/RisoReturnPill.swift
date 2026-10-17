import SwiftUI

/// The sheet's return pill: after an in-sheet task swap it takes the back-chevron slot
/// and returns to the task you came from — paper2, 2pt keyline, 2pt hard shadow, a ‹, the
/// previous task's 18pt type-letter square and its name (max 200pt, ellipsis). Web twin:
/// `components/riso/RisoReturnPill.tsx`.
struct RisoReturnPill: View {

    let title: String
    let kind: RisoTaskKind
    /// The keyline + shadow colour: `inkStatic` on a coloured hero, `ink` on paper.
    var border: Color = .risoInkStatic
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.risoInk)
                RisoTypeBadge(kind: kind, style: .letterSquare, size: 18)
                Text(title)
                    .font(.risoHead(13, .bold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.vertical, 6)
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(maxWidth: 200, alignment: .leading)
            .background(Capsule().fill(Color.risoPaper2))
            .overlay(Capsule().strokeBorder(border, lineWidth: Riso.Keyline.container))
            .contentShape(Capsule())
        }
        .buttonStyle(ReturnPillStyle(shadow: border))
        .accessibilityLabel("Back to \(title)")
    }
}

/// Press = translate 2pt and the 2pt hard shadow to 0.
private struct ReturnPillStyle: ButtonStyle {
    let shadow: Color

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let offset = Riso.Shadow.small
        return configuration.label
            .background(Capsule().fill(shadow).offset(x: pressed ? 0 : offset, y: pressed ? 0 : offset))
            .offset(x: pressed ? offset : 0, y: pressed ? offset : 0)
            .animation(.easeOut(duration: Riso.pressDuration), value: pressed)
    }
}

#if DEBUG
#Preview("Return pill") {
    VStack(spacing: 12) {
        RisoReturnPill(title: "Daily wellness", kind: .compound, action: {})
        RisoReturnPill(title: "A very long previous task name that must truncate with an ellipsis", kind: .counting, action: {})
    }
    .padding()
    .background(Color.risoTeal)
}
#endif
