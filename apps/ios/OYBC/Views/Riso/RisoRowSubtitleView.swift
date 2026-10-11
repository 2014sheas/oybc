import SwiftUI

/// A task row's subtitle slot (unit-tasks PR 2, Decision 10): the dense
/// `UnitTagView` is ALWAYS its first item, then the row's existing subtitle
/// text. Linked copies and unit tasks carry the same tag (Decision 5 — no new
/// mark; the text tells them apart). Renders nothing when both are absent.
/// Web twin: the `UnitTag` + `.rowSubtitle` / `.rowMeta` slots.
struct RisoRowSubtitleView: View {
    /// `rowCounterTagName` of the row's task; nil = no tag.
    let counterTagName: String?
    /// The row's existing subtitle text; nil = none.
    let text: String?
    var fontSize: CGFloat = 12
    var weight: RisoBodyWeight = .regular

    var body: some View {
        if counterTagName != nil || text != nil {
            HStack(spacing: 6) {
                if let counterTagName {
                    UnitTagView(name: counterTagName, dense: true)
                        .layoutPriority(1)
                }
                if let text {
                    Text(text)
                        .font(.risoBody(fontSize, weight))
                        .foregroundStyle(Color.risoMuted)
                        .lineLimit(1)
                }
            }
        }
    }
}
