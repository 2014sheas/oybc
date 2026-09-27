import Foundation

// MARK: - BoardPlayViewModel + Edit draft (derived)

/// The edit draft's derived readers (Board Edit redesign slice 3, T4) —
/// everything computed over the stored `@Published` draft fields on
/// `BoardPlayViewModel` lives here. D20: `editSquaresEditCells` is a plain
/// computed property (never seeded/patched) — SwiftUI re-evaluates it on
/// every `editSquaresDraft` / `editCenterType` publish, which is exactly
/// the reactivity a stored `@Published` array used to need manual upkeep for.
extension BoardPlayViewModel {

    /// `taskMap` with staged task-field overrides applied. Used to resolve a
    /// cell's rendered title/type without a database write.
    var editDraftTaskMap: [String: Task] {
        // Staged NEW (pending) tasks resolve too, so the square menu's
        // title and "Edit task…" work on them (web `resolveTask` parity).
        var map = taskMap
        for cell in editSquaresDraft.values {
            if let pending = cell.pending { map[pending.task.id] = pending.task }
        }
        guard !editTaskOverrides.isEmpty else { return map }
        for (taskId, override) in editTaskOverrides {
            guard var t = map[taskId] else { continue }
            t.title = override.title
            if override.type != .compound && t.type != .compound { t.type = override.type } // never into/out of Compound (as the commit)
            if t.type == .counting {
                t.action   = override.action
                t.unit     = override.unit
                t.maxCount = override.maxCount
            }
            map[taskId] = t
        }
        return map
    }

    /// The unified squares-edit grid (D7) — rebuilt fresh from
    /// `editSquaresDraft` on every read (D20). `BoardEditPanel` /
    /// `SquaresEditGrid` render this directly; there is no separate
    /// "Edit tasks" static grid anymore.
    var editSquaresEditCells: [SquareEditCellData] {
        buildSquaresEditCells(
            draft: editSquaresDraft,
            gridSize: gridSize,
            centerType: editCenterType,
            hasTaskOverride: { [editTaskOverrides] taskId in editTaskOverrides[taskId] != nil }
        )
    }

    /// Number of staged square edits — see `SquaresEditCount` for the D11
    /// formula. Forwarded to `BoardEditPanel`'s Save pill / edit counter.
    var editSquaresEditCount: Int {
        SquaresEditCount.count(editCountInput)
    }

    /// True when Shuffle is available (D10/OQ8): at least 2 non-fixed slots
    /// hold a task. Fixed = an effectively-locked placement, or the FREE
    /// center.
    var canShuffle: Bool {
        let size = gridSize
        guard size > 0 else { return false }
        let mid = size / 2
        var occupiedUnfixed = 0
        for row in 0..<size {
            for col in 0..<size {
                let isPositionalCenter = size % 2 == 1 && row == mid && col == mid
                if isPositionalCenter && editCenterType == .free { continue }
                if let cell = editSquaresDraft["\(row)-\(col)"], !cell.isLocked {
                    occupiedUnfixed += 1
                }
            }
        }
        return occupiedUnfixed >= 2
    }

    /// The draft cell keyed at the board's positional center, if any (`nil`
    /// on an even-sized board or when the center is empty/FREE).
    var editCenterCellKey: String? {
        let size = gridSize
        guard size % 2 == 1 else { return nil }
        let mid = size / 2
        return "\(mid)-\(mid)"
    }

    /// Whether the square at `cellKey` is locked in the draft.
    func isEditCellLocked(cellKey: String) -> Bool {
        editSquaresDraft[cellKey]?.isLocked ?? false
    }

    /// Assembles the `SquaresEditCount.Input` from current draft state.
    private var editCountInput: SquaresEditCount.Input {
        var replacements = 0, adds = 0, lockChanges = 0, moved = 0
        for (key, cell) in editSquaresDraft {
            if cell.isNew { adds += 1; continue }
            if cell.taskId != cell.originalTaskId { replacements += 1 }
            // A staged add's lock is written at insertion (D15 step 7), so
            // lock changes are only meaningful for an EXISTING placement.
            if cell.isLocked != cell.originalIsLocked { lockChanges += 1 }
            guard let (row, col) = parseSquareCellKey(key) else { continue }
            if cell.originalRow != row || cell.originalCol != col { moved += 1 }
        }

        let currentIds = Set(editSquaresDraft.values.map { $0.id })
        var removedIds = editBaselineBoardTaskIds.filter { !currentIds.contains($0) }
        // D11 — the center Free-toggle's implied removal is ONE edit
        // (`centerChanged`), not two. Still tombstoned on Save
        // (`handleEditSave` diffs the same baseline set unfiltered).
        if editCenterType == .free, let centerId = editOriginalCenterBoardTaskId {
            removedIds.remove(centerId)
        }

        let centerChanged = board.map { editCenterType != CenterSquare.effectiveCenter($0.centerSquareType) } ?? false

        return SquaresEditCount.Input(
            replacements: replacements,
            adds: adds,
            removals: removedIds.count,
            taskOverrides: editTaskOverrides.count,
            lockChanges: lockChanges,
            centerChanged: centerChanged,
            movedPlacements: moved,
            shuffled: editShuffled
        )
    }
}
