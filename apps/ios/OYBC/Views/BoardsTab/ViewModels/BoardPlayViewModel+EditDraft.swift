import Foundation

// MARK: - BoardPlayViewModel + Edit draft (derived)

/// The edit draft's derived readers (moved out of `BoardPlayViewModel.swift`
/// for the Board Edit redesign slice 1 — the stored `@Published` draft
/// fields stay on the class; everything computed over them lives here) plus
/// the slice-1 per-square lock helpers (docs/BOARD_EDIT_REDESIGN.md).
extension BoardPlayViewModel {
    // MARK: - Draft readers (B2-I3)
    //
    // Moved from `BoardPlayView` as computed vars. The pre-move versions each
    // opened with `guard editMode, …` — but `editMode` stays view-side, and the
    // guard is redundant at the sole render site (the `if editMode` panel
    // overlay) because the draft-state guards below already return the base
    // value right after `seedEditDraft` (staged == original ⇒ no overlay,
    // empty overrides ⇒ base map, nil rearrange ⇒ zero moves). Dropping
    // `editMode` therefore leaves the *rendered* result byte-identical while
    // making these unit-testable (a test can seed a draft and read the count
    // without a live view). See the B2-I3 report for the full analysis.

    /// Live `BoardTask` rows with staged task-ID replacements applied. Used as
    /// `boardTasks:` in `BoardEditPanel` so the draft grid shows the staged
    /// tasks without touching the database.
    var editDraftBoardTasks: [BoardTask] {
        // Sole consumer is BoardEditPanel (edit mode only), and `seedEditDraft`
        // populates the draft synchronously before the view flips `editMode`, so
        // a MISSING key here always means the cell was removed via
        // `handleEditRemove` — drop it (compactMap → nil) so the grid renders the
        // hole. An all-removed session correctly yields []. (Mirrors the way
        // `editSquaresEditCount` treats an absent draft entry as a removal.)
        //
        // Board-integrity PR-2 (Part 2): resolve `boardTasks` first — a raw
        // duplicate row sharing a cell with `editSquaresDraft`'s winner
        // would otherwise ALSO match that draft key here (the draft is
        // keyed by "row-col", not boardTaskId) and get its taskId
        // overwritten to the staged value too, rendering two BoardTasks for
        // one cell in the edit grid.
        let lockedIds = editEffectiveLockedIds
        return PlacementIntegrity.resolvePlacements(boardTasks, boardSize: gridSize).compactMap { bt in
            let key = "\(bt.row)-\(bt.col)"
            guard let draft = editSquaresDraft[key] else { return nil }
            var copy = bt
            copy.taskId = draft.stagedTaskId
            // Slice 1: the draft row carries the staged lock so the edit grid
            // reads one flag (`isLocked`) for the chip.
            copy.isLocked = lockedIds.contains(bt.id)
            return copy
        }
    }

    /// `taskMap` with staged task-field overrides applied. Used as `taskMap:` in
    /// `BoardEditPanel` so cell labels show the staged title/type without a
    /// database write.
    var editDraftTaskMap: [String: Task] {
        guard !editTaskOverrides.isEmpty else { return taskMap }
        var map = taskMap
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

    /// Number of staged square edits: cell replacements + task-field overrides +
    /// lock changes + position moves (from Rearrange sub-mode). Forwarded to
    /// `BoardEditPanel.squareEditCount` so the counter + Save pill react to
    /// square-level changes, not just metadata changes.
    ///
    /// Position moves are DERIVED: a drag that returns a cell to its original
    /// slot is net-zero and does not inflate the counter.
    var editSquaresEditCount: Int {
        let replacements = editSquaresDraft.values
            .filter { $0.stagedTaskId != $0.originalTaskId }.count
        let overrides = editTaskOverrides.count
        // Slice 1: each staged lock change is one edit (overrides are only
        // stored when they differ from the row).
        let lockChanges = editLockOverrides.count
        let positionMoves = countPositionMoves(in: editRearrangeCells, gridSize: gridSize)
        // Staged removals — boardTaskIds seeded from the pre-edit placements but
        // no longer present in the draft (removed via `handleEditRemove`).
        // Diff against the RESOLVED set (matches `seedEditDraft`'s seed
        // source + web's centralized resolution): a pre-repair collision
        // loser is invisible to the edit UI and must not inflate the count
        // as a change the user didn't make (PR-2 review).
        let draftIds = Set(editSquaresDraft.values.map { $0.boardTaskId })
        let removals = PlacementIntegrity.resolvePlacements(boardTasks, boardSize: gridSize)
            .filter { !draftIds.contains($0.id) }.count
        return replacements + overrides + lockChanges + positionMoves + removals
    }

    /// Returns the number of task cells that are in a different grid slot from
    /// their `originalRow`/`originalCol`. Center and empty slots are excluded.
    func countPositionMoves(in cells: [RearrangeCellData]?, gridSize: Int) -> Int {
        guard let cells, gridSize > 0 else { return 0 }
        var count = 0
        for (slotIdx, cell) in cells.enumerated() {
            guard !cell.isCenter, !cell.isEmpty else { continue }
            let stagedRow = slotIdx / gridSize
            let stagedCol = slotIdx % gridSize
            if stagedRow != cell.originalRow || stagedCol != cell.originalCol {
                count += 1
            }
        }
        return count
    }


    // MARK: - Slice 1 — per-square locks

    /// The row's stored lock for a draft cell (the value a staged override
    /// is compared against).
    private func storedLock(forBoardTaskId id: String) -> Bool {
        boardTasks.first { $0.id == id }?.isLocked ?? false
    }

    /// boardTaskIds locked once the staged overrides are applied — the set
    /// the Rearrange grid pins and the edit grid chips.
    var editEffectiveLockedIds: Set<String> {
        var ids = Set(boardTasks.filter { $0.isLocked && !$0.isDeleted }.map { $0.id })
        for (key, locked) in editLockOverrides {
            guard let draft = editSquaresDraft[key] else { continue }
            if locked { ids.insert(draft.boardTaskId) } else { ids.remove(draft.boardTaskId) }
        }
        return ids
    }

    /// Whether the square at `cellKey` is locked in the draft (stored value
    /// with any staged override applied). False for an empty cell.
    func isEditCellLocked(cellKey: String) -> Bool {
        guard let draft = editSquaresDraft[cellKey] else { return false }
        return editEffectiveLockedIds.contains(draft.boardTaskId)
    }

    /// Stages a lock toggle on one square (no DB write). Toggling back to the
    /// stored value drops the override so the counter stays derived. Keeps an
    /// already-seeded Rearrange grid in sync (pinning follows immediately).
    func handleEditToggleLock(cellKey: String) {
        guard let draft = editSquaresDraft[cellKey] else { return }
        let next = !isEditCellLocked(cellKey: cellKey)
        if next == storedLock(forBoardTaskId: draft.boardTaskId) {
            editLockOverrides.removeValue(forKey: cellKey)
        } else {
            editLockOverrides[cellKey] = next
        }
        if let idx = editRearrangeCells?.firstIndex(where: { $0.id == draft.boardTaskId }) {
            editRearrangeCells![idx].isLocked = next
        }
    }

    /// Staged lock changes as value pairs for the commit (only real changes —
    /// `handleEditToggleLock` never stores a no-op override).
    var editLockChanges: [(boardTaskId: String, locked: Bool)] {
        editLockOverrides.compactMap { key, locked in
            guard let draft = editSquaresDraft[key] else { return nil }
            return (boardTaskId: draft.boardTaskId, locked: locked)
        }
    }

    /// "row-col" keys of squares carrying a staged, unsaved edit other than a
    /// move (replace / task-field override / lock change) — the edit grid's
    /// gold pencil chip. Moves are derived by the Rearrange grid itself.
    var editDirtyCellKeys: Set<String> {
        var keys = Set<String>()
        for (key, draft) in editSquaresDraft {
            if draft.stagedTaskId != draft.originalTaskId
                || editTaskOverrides[draft.stagedTaskId] != nil
                || editLockOverrides[key] != nil {
                keys.insert(key)
            }
        }
        return keys
    }

    /// Rebuilds the staged rearrange cells for a new center type while
    /// preserving any in-progress reorder (each movable cell keeps its
    /// CURRENT slot). No-op until the grid has been seeded. Moved here from
    /// the view's `.onChange(of: editCenterType)` (slice 1) — the view keeps
    /// only the observer.
    func rebuildRearrangeCells(centerType: CenterSquareType) {
        guard let current = editRearrangeCells else { return }
        let size = gridSize
        var positions: [String: (row: Int, col: Int)] = [:]
        for (i, cell) in current.enumerated() where !cell.isCenter && !cell.isEmpty {
            positions[cell.id] = (row: i / size, col: i % size)
        }
        editRearrangeCells = buildRearrangeCells(
            squaresDraft: editSquaresDraft,
            gridSize: size,
            centerSquareType: centerType,
            positionDraft: positions,
            lockedBoardTaskIds: editEffectiveLockedIds
        )
    }
}
