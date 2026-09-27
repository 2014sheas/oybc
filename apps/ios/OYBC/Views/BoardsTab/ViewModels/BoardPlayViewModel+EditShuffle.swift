import Foundation

// MARK: - SquaresEditDirection

/// A single-step keyboard/VoiceOver move direction (D9).
enum SquaresEditDirection {
    case up, down, left, right

    var delta: (row: Int, col: Int) {
        switch self {
        case .up:    return (-1, 0)
        case .down:  return (1, 0)
        case .left:  return (0, -1)
        case .right: return (0, 1)
        }
    }
}

// MARK: - BoardPlayViewModel + Shuffle / move

/// Position-move handlers (Board Edit redesign slice 3, T4) — split out of
/// `+EditCommit.swift` to keep both files under their frozen size caps.
/// Every mutator here REBUILDS `editSquaresDraft` from scratch (D20) rather
/// than patching it in place.
extension BoardPlayViewModel {

    /// Called by `SquaresEditGrid.onReorder` when a hold-drag commits (or by
    /// `handleEditKeyboardMove` after a single swap). `newCells` is the
    /// grid's full ordered array in its NEW slot order; this rebuilds the
    /// position-keyed draft from it by matching each cell's stable `id` back
    /// to its `SquaresDraftCell` value.
    func handleEditMove(newCells: [SquareEditCellData]) {
        let size = gridSize
        guard size > 0 else { return }
        let cellsById = Dictionary(uniqueKeysWithValues: editSquaresDraft.values.map { ($0.id, $0) })
        var rebuilt: [String: SquaresDraftCell] = [:]
        for (idx, cellData) in newCells.enumerated() where !cellData.isCenter && !cellData.isEmpty {
            guard let original = cellsById[cellData.id] else { continue }
            let row = idx / size, col = idx % size
            rebuilt["\(row)-\(col)"] = original
        }
        editSquaresDraft = rebuilt
    }

    /// VoiceOver / keyboard fallback (D9): swaps the named cell with its
    /// neighbor one step in `direction`. A no-op off the grid edge or into a
    /// pinned (locked / FREE center) slot.
    func handleEditKeyboardMove(cellId: String, direction: SquaresEditDirection) {
        let size = gridSize
        guard size > 0 else { return }
        var cells = editSquaresEditCells
        guard let fromIdx = cells.firstIndex(where: { $0.id == cellId }) else { return }
        let row = fromIdx / size, col = fromIdx % size
        let d = direction.delta
        let newRow = row + d.row, newCol = col + d.col
        guard newRow >= 0, newRow < size, newCol >= 0, newCol < size else { return }
        let toIdx = newRow * size + newCol
        guard !cells[toIdx].isPinned else { return }
        cells.swapAt(fromIdx, toIdx)
        handleEditMove(newCells: cells)
    }

    /// Shuffles every non-fixed slot (D10). Fixed = an effectively-locked
    /// placement, or the FREE center. No-op when `canShuffle` is false.
    func handleEditShuffle(rng: () -> Double = { Double.random(in: 0..<1) }) {
        guard canShuffle else { return }
        let size = gridSize
        guard size > 0 else { return }
        let mid = size / 2

        var slots: [String?] = []
        var fixed: [Bool] = []
        for row in 0..<size {
            for col in 0..<size {
                let isPositionalCenter = size % 2 == 1 && row == mid && col == mid
                if isPositionalCenter && editCenterType == .free {
                    slots.append(nil)
                    fixed.append(true)
                    continue
                }
                if let cell = editSquaresDraft["\(row)-\(col)"] {
                    slots.append(cell.id)
                    fixed.append(cell.isLocked)
                } else {
                    slots.append(nil)
                    fixed.append(false)
                }
            }
        }

        let shuffled = Shuffle.shuffleUnlockedSlots(slots, fixed: fixed, rng: rng)
        let cellsById = Dictionary(uniqueKeysWithValues: editSquaresDraft.values.map { ($0.id, $0) })
        var rebuilt: [String: SquaresDraftCell] = [:]
        for row in 0..<size {
            for col in 0..<size {
                let idx = row * size + col
                guard let id = shuffled[idx], let cell = cellsById[id] else { continue }
                rebuilt["\(row)-\(col)"] = cell
            }
        }
        editSquaresDraft = rebuilt
        editShuffled = true
    }
}
