import SwiftUI

/// 5×5 thumbnail grid shown in each `RisoBoardCard`.
///
/// Renders `completedCount` out of `totalCount` cells as filled (red) using
/// a deterministic scatter seeded by `boardId`. This is a **count-based
/// approximation** — the actual completed squares are not fetched per-card
/// to avoid per-board DB reads on the list. The scatter is stable across
/// renders (same id → same pattern) so snapshot tests are deterministic.
///
/// `size` controls the rendered width/height of the whole grid; each cell
/// scales to fill the grid with 1px gaps.
struct RisoMiniGrid: View {

    let boardId: String
    let completedCount: Int
    let totalCount: Int
    var size: CGFloat = 46

    // Always renders as 5-column grid regardless of board size, matching
    // the prototype's `.r-mini` class (`grid-template-columns: repeat(5,1fr)`).
    private let cols = 5
    private let rows = 5
    private let totalCells = 25

    /// Deterministically scatter `completedCount` fills across 25 cells.
    /// Seeds a simple LCG from the board id hash so the pattern is stable
    /// without depending on `boardId` having any particular format.
    private var filledIndices: Set<Int> {
        let clamp = min(max(0, completedCount), totalCells)
        guard clamp > 0 else { return [] }

        // Build a pseudo-random ordering of 0..<25 seeded by the board id.
        // UInt64 is always non-negative, so no abs() needed.
        var seed: UInt64 = boardId.unicodeScalars.reduce(UInt64(5381)) { acc, c in
            acc &* 31 &+ UInt64(c.value)
        }
        var order = Array(0..<totalCells)
        // Fisher-Yates shuffle with LCG
        for i in stride(from: totalCells - 1, through: 1, by: -1) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let j = Int(seed >> 33) % (i + 1)
            order.swapAt(i, j)
        }
        return Set(order.prefix(clamp))
    }

    var body: some View {
        let gap: CGFloat = 1
        let cellSize = (size - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let filled = filledIndices

        VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<cols, id: \.self) { col in
                        let index = row * cols + col
                        RoundedRectangle(cornerRadius: 1)
                            .fill(filled.contains(index) ? Color.risoRed : Color.risoPaper)
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
    HStack(spacing: 12) {
        RisoMiniGrid(boardId: "board-abc", completedCount: 12, totalCount: 25)
        RisoMiniGrid(boardId: "board-xyz", completedCount: 0, totalCount: 25)
        RisoMiniGrid(boardId: "board-123", completedCount: 25, totalCount: 25)
    }
    .padding()
}
#endif
