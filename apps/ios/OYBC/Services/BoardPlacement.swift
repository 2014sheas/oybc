import Foundation

/// Swift mirror of `@oybc/bingo-core` `placeBoard` — see packages/bingo-core/MIRRORS.md.
///
/// Superset board-placement core shared by the wizard-preview and
/// template-spawn paths. Keep byte-identical to the TS `placeBoard`
/// (packages/bingo-core/src/placement.ts): same center rules, same fill
/// walk, same shuffle. The golden-parity tests (BoardPlacementTests.swift
/// ↔ placement.test.ts / recurringBoardTemplates.test.ts) assert the SAME
/// expected arrays under the SAME seeded LCG — that lockstep is the proof.
enum BoardPlacement {

    /// Places `items` onto a `gridSize²` board, honouring the center rules.
    ///
    /// Semantics (superset of the four historical sites):
    ///   1. Even grids have no center (every cell ordinary).
    ///   2. Odd grid + `.chosen` + a `chosenCenterId` that resolves → pin
    ///      that item at the center and exclude it from the fill pool.
    ///      Unresolvable id → ordinary center.
    ///   3. Odd grid + `.free` / `.customFree` → center stays `nil` (reserved).
    ///   4. `.none` (or even grid) → center is filled like any other cell.
    ///   5. Fill pool = `items` minus any pinned center;
    ///      `randomize ? Shuffle.fisherYatesShuffle(pool, rng:) : pool`.
    ///   6. Walk cells row-major, skipping the pinned/reserved center;
    ///      extra items are ignored, an exhausted pool leaves `nil`s.
    ///
    /// - Parameters:
    ///   - items: candidates in the caller's preferred order (used verbatim
    ///     when `randomize == false`).
    ///   - gridSize: board edge length.
    ///   - centerType: center-square behaviour; ignored on even grids.
    ///   - chosenCenterId: CHOSEN center pin; ignored for other center types
    ///     / even grids.
    ///   - randomize: shuffle the fill pool when true.
    ///   - rng: uniform `[0, 1)` generator, injectable for deterministic tests.
    /// - Returns: `gridSize²` array; `nil` = empty cell (reserved
    ///   FREE/CUSTOM_FREE center, or pool underfill).
    static func placeBoard(
        items: [Task],
        gridSize: Int,
        centerType: CenterSquareType,
        chosenCenterId: String? = nil,
        randomize: Bool,
        rng: () -> Double = { Double.random(in: 0..<1) }
    ) -> [Task?] {
        let total = gridSize * gridSize
        let isOdd = gridSize % 2 != 0
        let centerIdx = isOdd ? (gridSize / 2) * gridSize + (gridSize / 2) : -1

        let chosenCenter: Task? = {
            guard isOdd, centerType == .chosen, let id = chosenCenterId else { return nil }
            return items.first(where: { $0.id == id })
        }()
        let pool = chosenCenter != nil ? items.filter { $0.id != chosenCenter!.id } : items
        let ordered = randomize ? Shuffle.fisherYatesShuffle(pool, rng: rng) : pool

        var grid: [Task?] = Array(repeating: nil, count: total)
        var next = 0
        for cell in 0..<total {
            if cell == centerIdx {
                if let center = chosenCenter { grid[cell] = center; continue }
                if centerType == .free || centerType == .customFree { continue }
            }
            if next < ordered.count { grid[cell] = ordered[next]; next += 1 }
        }
        return grid
    }
}
