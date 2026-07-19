import SwiftUI

/// Pure presentational thumbnail grid shown in each `RisoBoardCard` (and the
/// wizard's "From a board" picker rows). Renders the TRUE board: `gridSize`
/// columns/rows and one `BoardPreviewCell` per position, row-major — no DB
/// access, no randomness, snapshot-safe. Callers that need to load a board's
/// real cells go through `RisoBoardPreviewGrid`, which wraps this view with a
/// `.task`-based DB fetch; this view itself just renders whatever cells it's
/// given (bugfix/board-preview-real-cells — this used to be a fixed 5×5 with a
/// count-scaled pseudo-random scatter; see git history for the old approach).
///
/// `size` controls the rendered width/height of the whole grid; each cell
/// scales to fill the grid with 1px gaps.
struct RisoMiniGrid: View {

    /// Grid edge length (columns == rows). Real `board.boardSize`.
    let gridSize: Int
    /// Row-major, length `gridSize * gridSize`.
    let cells: [BoardPreviewCell]
    var size: CGFloat = 46

    private func fill(for cell: BoardPreviewCell) -> Color {
        switch cell {
        case .task(let completed): return completed ? Color.risoRed : Color.risoPaper
        case .freeCenter: return Color.risoInk
        case .empty: return Color.risoPaper
        }
    }

    var body: some View {
        let gap: CGFloat = 1
        let cols = max(1, gridSize)
        let cellSize = (size - gap * CGFloat(cols - 1)) / CGFloat(cols)

        VStack(spacing: gap) {
            ForEach(0..<cols, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<cols, id: \.self) { col in
                        let index = row * cols + col
                        let cell = index < cells.count ? cells[index] : .empty
                        RoundedRectangle(cornerRadius: 1)
                            .fill(fill(for: cell))
                            .overlay(
                                RoundedRectangle(cornerRadius: 1)
                                    .strokeBorder(Color.risoInk, lineWidth: 1)
                            )
                            .frame(width: cellSize, height: cellSize)
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

#if DEBUG
#Preview("Mini Grid — partial") {
    let partial: [BoardPreviewCell] = (0..<25).map { $0 < 12 ? .task(completed: true) : .task(completed: false) }
    let empty: [BoardPreviewCell] = Array(repeating: .task(completed: false), count: 25)
    let full: [BoardPreviewCell] = Array(repeating: .task(completed: true), count: 25)
    return HStack(spacing: 12) {
        RisoMiniGrid(gridSize: 5, cells: partial)
        RisoMiniGrid(gridSize: 5, cells: empty)
        RisoMiniGrid(gridSize: 5, cells: full)
    }
    .padding()
}
#endif
