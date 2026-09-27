import SwiftUI

/// The board title row's "…" menu trigger (Board Edit redesign slice 2, D1 —
/// docs/BOARD_EDIT_REDESIGN.md, handoff frame i1). A 34pt Riso square (card
/// fill, 2pt ink keyline, small hard shadow) wrapping a native SwiftUI `Menu`
/// over the pure `BoardMenuItems.items(board:sourceTemplate:)` list.
///
/// `Delete` renders with `role: .destructive` (red, per D7). Hidden entirely
/// by the caller when `items` is empty (draft boards — the header shows the
/// draft-resume prompt instead of this chrome).
struct BoardActionsMenuButton: View {
    let items: [BoardMenuItem]
    let onSelect: (BoardMenuItem) -> Void

    var body: some View {
        Menu {
            ForEach(items) { item in
                Button(role: item.isDestructive ? .destructive : nil) {
                    onSelect(item)
                } label: {
                    Label(item.label, systemImage: item.systemImage)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.risoInk)
                .frame(width: 34, height: 34)
                .background(Color.risoPaper2)
                .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                )
                .risoHardShadow(Riso.Shadow.small)
        }
        .accessibilityLabel("Board menu")
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: 12) {
        BoardActionsMenuButton(items: [.details, .repeatBoard, .archive, .delete], onSelect: { _ in })
        BoardActionsMenuButton(items: [.coreDefaults, .delete], onSelect: { _ in })
    }
    .padding()
    .background(Color.risoPaper)
}
