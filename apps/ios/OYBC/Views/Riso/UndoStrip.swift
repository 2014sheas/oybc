import SwiftUI

/// The inline result of a one-gesture log: a green check, one line ("Logged +5
/// pages · Week 42") and an Undo pill. Replaces a confirmation step. Web twin:
/// `components/riso/UndoStrip.tsx`.
struct UndoStrip: View {

    let text: String
    /// The compound child's inline strip is a size down (12pt, 1.5pt keyline).
    var compact: Bool = false
    /// A write in flight — Undo stays visible but inert.
    var disabled: Bool = false
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            Image(systemName: "checkmark")
                .font(.system(size: compact ? 11 : 13, weight: .heavy))
                .foregroundStyle(Color.risoGreen)
            Text(text)
                .font(.risoHead(compact ? 12 : 13, .bold))
                .foregroundStyle(Color.risoInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            RisoUndoPill(scale: compact ? .part : .member, accessibilityLabel: "Undo", action: onUndo)
                .disabled(disabled)
                .opacity(disabled ? 0.45 : 1)
        }
        .padding(.leading, compact ? 10 : 12)
        .padding(.trailing, compact ? 6 : 8)
        .padding(.vertical, compact ? 4 : 6)
        .risoCard(keyline: compact ? Riso.Keyline.dense : Riso.Keyline.container, fill: .risoPaper2)
        .accessibilityElement(children: .contain)
    }
}

#if DEBUG
#Preview("Undo strip") {
    VStack(spacing: 12) {
        UndoStrip(text: "Logged +5 pages · Week 42", onUndo: {})
        UndoStrip(text: "Logged +5 pages · Week 42", compact: true, onUndo: {})
    }
    .padding(Riso.gutter)
    .background(Color.risoPaper)
}
#endif
