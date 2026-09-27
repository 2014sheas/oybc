import SwiftUI

/// The Edit screen's BOARD section (Board Edit consolidation, D6) — one row
/// per `BoardMenuItems.items(...)`, below the SQUARES section (or its
/// locked-reason line). Replaces the retired title-row "…" popover
/// (`BoardActionsMenuButton`, deleted) with the same builder rendered as
/// inline rows, reusing `RisoProfileRow` inside a `.risoCard()` — the same
/// composition `ProfileView`'s cards use.
///
/// Pure presentation: props only, no DB access, so it is directly
/// snapshot-testable and reusable from both the live and the
/// squares-locked variants of `BoardEditPanel`.
struct BoardOptionsSectionView: View {
    /// The section's rows, in display order. Empty renders nothing (a draft
    /// board never reaches Edit in practice, so this is mostly defensive).
    let items: [BoardMenuItem]
    /// Called with the tapped row's kind.
    let onSelect: (BoardMenuItem) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("BOARD")
                    .risoSectionLabel()

                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            onSelect(item)
                        } label: {
                            RisoProfileRow(
                                icon: item.systemImage,
                                label: item.label,
                                chevron: item.label.hasSuffix("…"),
                                danger: item.isDestructive
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.label)

                        if index < items.count - 1 {
                            Divider()
                                .background(Color.risoInk.opacity(0.12))
                                .padding(.horizontal, Riso.cardPadding)
                        }
                    }
                }
                .risoCard()
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    ZStack {
        RisoPaperBackground()
        VStack {
            BoardOptionsSectionView(
                items: [.details, .repeatBoard, .archive, .delete],
                onSelect: { _ in }
            )
        }
        .padding(Riso.gutter)
    }
}
#endif
