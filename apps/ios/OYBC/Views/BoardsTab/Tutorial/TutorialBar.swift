import SwiftUI

/// The tutorial stage's ink bar (`TutorialBar.dc.html`): the lesson label, one
/// 6pt dot per step (gold up to the current step, paper at 35% after), `n/m`
/// and the ✕ — the only way out of a lesson. Ink fills from the top edge
/// through the status bar; 40pt of content sits under the safe area. Props-only.
struct TutorialBar: View {
    let label: String
    /// 0-based current step.
    let step: Int
    let stepCount: Int
    var onExit: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.risoHead(13, .extraBold))
                .tracking(-0.13)
                .foregroundStyle(Color.risoPaper)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                ForEach(0..<max(stepCount, 1), id: \.self) { index in
                    Circle()
                        .fill(index <= step ? Color.risoGold : Color.risoPaper.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
            Text("\(min(step + 1, stepCount))/\(stepCount)")
                .font(.risoHead(12, .extraBold))
                .monospacedDigit()
                .foregroundStyle(Color.risoPaper)
                .padding(.leading, 2)
            Button(action: onExit) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.risoPaper)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
            .accessibilityLabel("Leave lesson")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(Color.risoInk.ignoresSafeArea(edges: .top))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(label), step \(min(step + 1, stepCount)) of \(stepCount)")
    }
}
