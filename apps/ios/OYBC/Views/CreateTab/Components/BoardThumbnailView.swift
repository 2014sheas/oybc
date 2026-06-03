import SwiftUI

/// Per-cell state shown by a {@link BoardThumbnailView}. Conceptually:
/// `done` = completed task, `pending` = placed task not completed,
/// `center` = the source board's center square (accented regardless
/// of completion), `empty` = no placement here.
enum ThumbnailCellState {
    case done
    case pending
    case center
    case empty
}

/// Tiny visual thumbnail of a board's grid — used by the wizard's
/// `From a board…` source picker to give the user a glanceable preview
/// of each candidate source. iOS twin of web's `BoardThumbnail` component.
///
/// Cells render as colored squares only — no titles. Recognition is
/// about "which board is the busy weekly one" / "the empty one I never
/// filled in", not about reading task names at thumbnail scale.
///
/// Designed for future extraction: the same renderer could surface in
/// the Boards tab, the create hub, etc. without changes.
struct BoardThumbnailView: View {
    /// 3, 4, or 5 — board geometry.
    let gridSize: Int

    /// Cell states in row-major order. Length should equal `gridSize²`;
    /// extra entries are ignored, missing entries render as `empty`.
    let cellStates: [ThumbnailCellState]

    /// Pixel size of the entire square thumbnail (default 48).
    var pixelSize: CGFloat = 48

    var body: some View {
        let total = gridSize * gridSize
        let cells: [ThumbnailCellState] = (0..<total).map { i in
            i < cellStates.count ? cellStates[i] : .empty
        }

        let columns: [GridItem] = Array(
            repeating: GridItem(.flexible(), spacing: 1),
            count: gridSize
        )

        LazyVGrid(columns: columns, spacing: 1) {
            ForEach(0..<cells.count, id: \.self) { i in
                Rectangle()
                    .fill(color(for: cells[i]))
                    .cornerRadius(1)
            }
        }
        .padding(2)
        .frame(width: pixelSize, height: pixelSize)
        .background(Color.white.opacity(0.04))
        .cornerRadius(4)
        .accessibilityHidden(true)
    }

    private func color(for state: ThumbnailCellState) -> Color {
        switch state {
        case .done:
            return .accentColor
        case .pending:
            return Color.white.opacity(0.22)
        case .center:
            return .orange
        case .empty:
            return .clear
        }
    }
}
