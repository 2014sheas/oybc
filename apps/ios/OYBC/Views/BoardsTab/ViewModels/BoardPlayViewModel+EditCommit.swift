import Foundation
import GRDB

// MARK: - BoardPlayViewModel + Edit commit

/// Edit-mode draft mutators + the staged squares commit path (B2-I3), split
/// out of `BoardPlayViewModel.swift` when the staged REPEATS section pushed
/// the file past its frozen drift-guardrail cap (2026-09-15) — a true
/// ROADMAP-B6-style extraction, not a cap bump. Stored `edit*` state
/// stays on the class (Swift extensions can't hold stored properties).
///
/// Board Edit redesign slice 2 (T3): name / timeframe / dates / REPEATS /
/// Archive all moved OFF this file — the squares draft (replacements, task
/// overrides, position moves, lock changes) plus the center-only metadata
/// patch are all `handleEditSave` writes now.
extension BoardPlayViewModel {
    // MARK: - Edit-mode draft mutators + commit (B2-I3)
    //
    // Moved verbatim from `BoardPlayView`. The pure staged-draft mutators
    // (`seedRearrangeCells` / `handleRearrange` / `handleEditCellReplace` /
    // `handleEditTaskOverride`) only touch the `@Published` draft fields. The
    // DB-touching functions (`seedEditDraft` / `handleEditSave`) write
    // through the injected `database` (I2's precedent) and signal the
    // residual view-owned UI mutations back through the one-shot `editEvent`.
    //
    // NOT moved (they stay in the view because they touch view-owned state):
    //  - `handleEditCellTap` / `handleFreeCenterTap` mutate the edit-cell-menu
    //    routing `@State` (`editCellMenuRow/Col/Visible/IsCenter`), which stays.
    //  - the two `.onChange(of: editSubMode/editCenterType)` reactions stay as
    //    view `.onChange` observers (they call `seedRearrangeCells` / rebuild
    //    `editRearrangeCells`) to preserve SwiftUI's post-update onChange timing
    //    exactly — a `didSet` on the published var would fire synchronously
    //    before the re-render, a subtle behavior change. See the B2-I3 report.

    /// Seeds all edit-draft fields from the live board record before entering
    /// edit mode. Called synchronously on the main actor immediately before the
    /// view flips `editMode = true` so the form shows the current board values on
    /// first render.
    ///
    /// The pre-move version also reset the view's `editSaving = false`; that
    /// stays view-side (the Edit button resets it), since `editSaving` is a view
    /// `@State`.
    ///
    /// - Parameter b: The current active `Board`.
    func seedEditDraft(from b: Board) {
        editCenterType = b.centerSquareType
        editSubMode = .editTasks

        // Phase 2 — seed the squares draft from the current live placement rows.
        // `boardTasks` is already loaded by `reload()` on appear.
        //
        // Board-integrity PR-2 (Part 2): resolve through
        // `PlacementIntegrity.resolvePlacements` first — a raw duplicate row
        // at one cell would otherwise seed the draft from whichever row
        // happens to iterate last (arbitrary), instead of the deterministic
        // winner render/derivation agree on.
        editSquaresDraft = [:]
        for bt in PlacementIntegrity.resolvePlacements(boardTasks, boardSize: gridSize) {
            let key = "\(bt.row)-\(bt.col)"
            editSquaresDraft[key] = SquaresDraftCell(
                boardTaskId: bt.id,
                row: bt.row,
                col: bt.col,
                isCenter: bt.isCenter,
                originalTaskId: bt.taskId,
                stagedTaskId: bt.taskId
            )
        }
        editTaskOverrides = [:]
        // Slice 1 — staged lock changes are per-session too.
        editLockOverrides = [:]
        // Phase 3 — reset rearrange cells so they're rebuilt fresh on next entry.
        editRearrangeCells = nil
    }

    /// Lazily builds `editRearrangeCells` the first time the user switches to
    /// Rearrange sub-mode. Subsequent sub-mode switches preserve the staged order.
    func seedRearrangeCells(for b: Board) {
        guard editRearrangeCells == nil else { return }
        editRearrangeCells = buildRearrangeCells(
            squaresDraft: editSquaresDraft,
            gridSize: b.boardSize,
            centerSquareType: editCenterType,
            lockedBoardTaskIds: editEffectiveLockedIds
        )
    }

    /// Called by `RearrangeGrid.onReorder` when a drag-to-insert or tap-to-swap
    /// is committed. Updates the staged rearrange cells — no DB write until Save.
    func handleRearrange(newCells: [RearrangeCellData]) {
        editRearrangeCells = newCells
    }

    /// Stages a task-ID replacement on one cell (no DB write). Increments the
    /// squares draft so the panel counter + Save pill reflect this staged change.
    ///
    /// - Parameters:
    ///   - cellKey: The "row-col" key into `editSquaresDraft`.
    ///   - newTaskId: The task the user selected from `CellSwapSheet`.
    func handleEditCellReplace(cellKey: String, newTaskId: String) {
        guard let draft = editSquaresDraft[cellKey] else { return }
        editSquaresDraft[cellKey]?.stagedTaskId = newTaskId
        // Keep an already-seeded rearrange grid in sync so a Replace made after
        // switching to Rearrange (which doesn't re-seed) shows the new task label.
        if let idx = editRearrangeCells?.firstIndex(where: { $0.id == draft.boardTaskId }) {
            let old = editRearrangeCells![idx]
            editRearrangeCells![idx] = RearrangeCellData(
                id: old.id,
                taskId: newTaskId,
                isCenter: old.isCenter,
                isEmpty: old.isEmpty,
                originalRow: old.originalRow,
                originalCol: old.originalCol
            )
        }
    }

    /// Stages a cell removal (no DB write). Drops the cell from the squares
    /// draft so it renders empty; the placement is only soft-deleted
    /// (tombstoned) from the board on Save (`handleEditSave`, which diffs
    /// `boardTasks` against the remaining draft). Increments
    /// `editSquaresEditCount` so the panel counter + Save pill reflect the
    /// staged removal.
    ///
    /// A pinned free center has no `editSquaresDraft` entry, so the edit tap-menu
    /// never surfaces Remove for it — pinned centers stay non-removable.
    ///
    /// - Parameter cellKey: The "row-col" key into `editSquaresDraft`.
    func handleEditRemove(cellKey: String) {
        guard let draft = editSquaresDraft[cellKey] else { return }
        let removedBoardTaskId = draft.boardTaskId
        editSquaresDraft.removeValue(forKey: cellKey)
        // Keep an already-seeded rearrange grid in sync so a removal made after
        // switching to Rearrange (which doesn't re-seed) shows the hole. Replace
        // the removed cell in-place with an empty slot at its current position,
        // mirroring `buildRearrangeCells`'s empty representation.
        if let idx = editRearrangeCells?.firstIndex(where: { $0.id == removedBoardTaskId }) {
            let size = gridSize
            let stagedRow = size > 0 ? idx / size : 0
            let stagedCol = size > 0 ? idx % size : 0
            editRearrangeCells![idx] = RearrangeCellData(
                id: "empty-\(stagedRow)-\(stagedCol)",
                taskId: nil,
                isCenter: false,
                isEmpty: true,
                originalRow: stagedRow,
                originalCol: stagedCol
            )
        }
    }

    /// Stages task-field overrides for a global Task (no DB write). The
    /// edit-mode draft task map picks this up immediately so the grid label
    /// updates.
    ///
    /// - Parameters:
    ///   - taskId: The global Task being edited.
    ///   - patch: Name / type / counting fields from `SquareEditTaskSheet`.
    func handleEditTaskOverride(taskId: String, patch: SquareEditTaskSheet.Patch) {
        editTaskOverrides[taskId] = StagedTaskOverride(
            title: patch.title,
            type: patch.type,
            action: patch.action.isEmpty ? nil : patch.action,
            unit: patch.unit.isEmpty ? nil : patch.unit,
            maxCount: patch.maxCount
        )
    }

    /// Builds the center-only metadata patch (when changed) + staged
    /// square/override/position commits from the current draft state and
    /// writes them via the injected `database`. On success it reloads the
    /// board and emits `editEvent(.saved)`; on failure it emits
    /// `editEvent(.saveFailed)` or, for a sealed/deleted board,
    /// `editEvent(.boardClosed)`.
    ///
    /// Board Edit redesign slice 2 (T3): name / timeframe / dates / REPEATS
    /// moved to `BoardDetailsSheetView` / `BoardRepeatSheetView` (their own
    /// independent saves), so this only ever writes `centerSquareType` from
    /// the metadata patch — the calendar-timeframe re-window branch and the
    /// two-phase repeat save are both gone.
    ///
    /// The pre-move version set the view's `editSaving = true` synchronously
    /// after validation passed. To preserve that exact timing while keeping
    /// `editSaving` view-side, this returns `true` iff the commit was actually
    /// dispatched (not re-entrant) so the view flips `editSaving = true` in
    /// the same synchronous tick; `editEvent` drives the reset. The
    /// authoritative double-save guard is `editSaveInFlight` here.
    ///
    /// - Returns: `true` if the DB commit was dispatched (view should show the
    ///   saving state); `false` if a save is already in flight (view leaves
    ///   `editSaving` untouched).
    @discardableResult
    func handleEditSave() -> Bool {
        guard !editSaveInFlight else { return false }
        guard let liveBoard = board else { return false }

        var metaPatch = AppDatabase.UpdateActiveBoardPatch()
        if editCenterType != liveBoard.centerSquareType {
            metaPatch.centerSquareType = editCenterType
        }
        let patch = metaPatch

        // Snapshot the staged square edits as value types before the detached
        // task (the `@Published` dictionaries are only safe on the MainActor).
        let cellReplacements: [(boardTaskId: String, newTaskId: String)] =
            editSquaresDraft.values
                .filter { $0.stagedTaskId != $0.originalTaskId }
                .map { (boardTaskId: $0.boardTaskId, newTaskId: $0.stagedTaskId) }

        // Build (task, override) pairs from the live taskMap + staged overrides.
        var taskOverridePairs: [(task: Task, override: StagedTaskOverride)] = []
        for (taskId, override) in editTaskOverrides {
            if let task = taskMap[taskId] {
                taskOverridePairs.append((task: task, override: override))
            }
        }

        // Phase 3 — snapshot staged position moves. Compare each cell's slot in
        // `editRearrangeCells` to its originalRow/Col. Center and empty slots are
        // excluded (they don't correspond to BoardTask rows).
        let size = gridSize
        let positionMoves: [(boardTaskId: String, row: Int, col: Int)] = {
            guard let rearranged = editRearrangeCells, size > 0 else { return [] }
            var moves: [(boardTaskId: String, row: Int, col: Int)] = []
            for (slotIdx, cell) in rearranged.enumerated() {
                guard !cell.isCenter, !cell.isEmpty else { continue }
                let stagedRow = slotIdx / size
                let stagedCol = slotIdx % size
                if stagedRow != cell.originalRow || stagedCol != cell.originalCol {
                    moves.append((boardTaskId: cell.id, row: stagedRow, col: stagedCol))
                }
            }
            return moves
        }()

        // Staged removals — boardTaskIds present in the pre-edit placements
        // (the RESOLVED seed source, matching `seedEditDraft` + web) but
        // absent from the draft after one or more `handleEditRemove` actions.
        // Deleted from the board on Save. Diffing the resolved set means a
        // pre-repair collision loser is never folded in as a user-staged
        // removal — the repair pass owns tombstoning losers (PR-2 review).
        let cellRemovals: [String] = {
            let draftIds = Set(editSquaresDraft.values.map { $0.boardTaskId })
            return PlacementIntegrity.resolvePlacements(boardTasks, boardSize: gridSize)
                .filter { !draftIds.contains($0.id) }.map { $0.id }
        }()

        // Slice 1 — staged lock changes (value pairs; see `editLockChanges`).
        let lockChanges = editLockChanges

        editSaveInFlight = true
        let bid = boardId
        let database = self.database
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                // Board-integrity PR-4 (Item 3, docs/BOARD_INTEGRITY.md): the five
                // sub-ops below used to run as five SEPARATE `database.write {}`
                // transactions — a failure partway through left a half-applied
                // board (e.g. metadata renamed but a cell replacement never
                // landed) with only a generic "save failed" surfaced, and no way
                // to roll back the pieces that DID commit. Composing them into
                // ONE `database.write {}` makes the whole Save all-or-nothing.
                //
                // Each sub-op below calls the `db:`-scoped core of its normal
                // instance-method entry point (`updateBoardAndCascade`,
                // `updateBoardTaskAndCascade`, `saveTaskAndCascade`,
                // `updateBoardTaskPositions`, `removeBoardTaskFromBoard`) instead
                // of the instance method itself — GRDB's `DatabaseQueue.write` (and
                // `.read`) are not reentrant, so calling the instance methods
                // (which each open their own `write {}`) from inside this
                // already-open transaction would trap. The op order and cascade
                // semantics are otherwise unchanged.
                try database.write { db in
                    // 0. Slice 2 (D11): a board sealed or deleted since edit
                    //    mode opened throws here, rolling back EVERYTHING
                    //    below (task overrides included) — never "Board saved".
                    try AppDatabase.assertBoardEditable(db: db, boardId: bid)

                    // 1. Metadata patch (name / timeframe / center).
                    try AppDatabase.updateBoardAndCascade(db: db, boardId: bid, patch: patch)

                    // 2. Staged cell replacements — each repoints one BoardTask row
                    //    and re-derives board stats for the old + new task contexts.
                    for replacement in cellReplacements {
                        try AppDatabase.updateBoardTaskAndCascade(
                            db: db,
                            boardTaskId: replacement.boardTaskId,
                            newTaskId: replacement.newTaskId
                        )
                    }

                    // 3. Staged task-field overrides — each writes the global Task
                    //    and re-derives board stats for all boards the task is on.
                    let now = AppDatabase.currentTimestamp()
                    for (task, override) in taskOverridePairs {
                        var updated = task
                        updated.title = override.title
                        // Board Edit never switches a task into or out of
                        // Compound: out would orphan its compound_children,
                        // in would mint a zero-child, rule-less compound. The
                        // sheet no longer offers it; this guards stale drafts.
                        if override.type != .compound && task.type != .compound {
                            updated.type = override.type
                        }
                        switch updated.type {
                        case .counting:
                            // action can be cleared (nil) — assign unconditionally so the
                            // commit matches the draft grid (which clears it on blank).
                            updated.action = override.action
                            if let u = override.unit   { updated.unit   = u }
                            if let m = override.maxCount { updated.maxCount = m }
                        case .normal:
                            // Switching from Counting → Simple: clear counting fields.
                            if task.type == .counting {
                                updated.action   = nil
                                updated.unit     = nil
                                updated.maxCount = nil
                            }
                        default:
                            break
                        }
                        updated.updatedAt = now
                        updated.version  += 1
                        try AppDatabase.saveTaskAndCascade(db: db, task: updated)
                    }

                    // 4. Phase 3 — Staged position moves: rewrite row/col on moved
                    //    BoardTask rows, then re-derive bingo lines for this board.
                    if !positionMoves.isEmpty {
                        try AppDatabase.updateBoardTaskPositions(
                            db: db,
                            boardId: bid,
                            moves: positionMoves.map {
                                AppDatabase.BoardTaskPositionMove(
                                    boardTaskId: $0.boardTaskId,
                                    row: $0.row,
                                    col: $0.col
                                )
                            }
                        )
                    }

                    // 5. Staged removals — soft-delete (tombstone) each removed
                    //    BoardTask row. `removeBoardTaskFromBoard` is idempotent
                    //    (no-op if the row is already tombstoned) and re-derives
                    //    stats for every affected board, in the SAME transaction
                    //    as everything above.
                    for removedId in cellRemovals {
                        try AppDatabase.removeBoardTaskFromBoard(db: db, boardTaskId: removedId)
                    }

                    // 6. Slice 1 — staged lock changes, in the SAME transaction.
                    //    Runs after the moves so a square locked in this
                    //    session can still have been moved in it (the lock
                    //    applies from Save on).
                    for change in lockChanges {
                        try AppDatabase.setBoardTaskLocked(
                            db: db,
                            boardTaskId: change.boardTaskId,
                            locked: change.locked
                        )
                    }
                }

                await MainActor.run {
                    self.editSaveInFlight = false
                    // Domain refresh moves here; the view-owned UI mutations
                    // (editSaving off, editMode off, "Board saved" toast) run in
                    // the view's `.onChange(of: editEvent)` on `.saved`.
                    self.reload()
                    self.emitEdit(.saved)
                }
            } catch BoardEditError.boardNotEditable {
                // Sealed / deleted mid-session — the transaction rolled back.
                await MainActor.run {
                    self.editSaveInFlight = false
                    self.reload()
                    self.emitEdit(.boardClosed(BoardEditError.boardClosedMessage))
                }
            } catch {
                dlog("⚠️ BoardPlayViewModel.handleEditSave: \(error)")
                await MainActor.run {
                    self.editSaveInFlight = false
                    self.emitEdit(.saveFailed("Couldn’t save your changes — please try again."))
                }
            }
        }
        return true
    }

    // `handleEditArchive` moved to `BoardPlayViewModel+BoardActions.swift`
    // (Board Edit redesign slice 2, T2) as the plain `async throws`
    // `archiveBoard()` — Archive is no longer part of the squares-editor
    // commit path; it's a "…" menu action.

    /// Publishes a one-shot `editEvent` the view observes to run the residual
    /// edit-commit UI mutations it still owns.
    private func emitEdit(_ outcome: BoardPlayEditEvent.Outcome) {
        editEventCounter += 1
        editEvent = BoardPlayEditEvent(id: editEventCounter, outcome: outcome)
    }

}
