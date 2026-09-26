import SwiftUI

// MARK: - RisoBoardGrid

/// The one board-grid layout (Board Edit redesign slice 1,
/// docs/BOARD_EDIT_REDESIGN.md): a square `LazyVGrid` of `gridSize` columns
/// with the kit's cell gap, iterating every slot row-major and handing
/// `(row, col, index)` to the caller's cell builder. Used by the board
/// itself (`BoardPlayView`), the edit panel (`BoardEditPanel`) and — for its
/// geometry — the rearrange grid, so every surface draws the same square in
/// the same place. The cell face is always `RisoBoardPlayCell`; this view
/// owns only the layout.
struct RisoBoardGrid<Cell: View>: View {
    let gridSize: Int
    var gap: CGFloat = Riso.cellGap
    @ViewBuilder let cell: (_ row: Int, _ col: Int, _ index: Int) -> Cell

    var body: some View {
        let size = max(gridSize, 1)
        let columns = Array(repeating: GridItem(.flexible(), spacing: gap), count: size)
        LazyVGrid(columns: columns, spacing: gap) {
            ForEach(0..<(size * size), id: \.self) { index in
                cell(index / size, index % size, index)
            }
        }
    }

    /// Edge length of one cell when the grid is laid out at `sideLength`
    /// points — the same arithmetic `LazyVGrid` resolves to, exposed for
    /// the rearrange grid's hand-positioned `ZStack` so its cells match the
    /// laid-out grid to the point.
    static func cellSide(forSideLength sideLength: CGFloat, gridSize: Int, gap: CGFloat = Riso.cellGap) -> CGFloat {
        let size = max(gridSize, 1)
        return (sideLength - CGFloat(size - 1) * gap) / CGFloat(size)
    }
}
