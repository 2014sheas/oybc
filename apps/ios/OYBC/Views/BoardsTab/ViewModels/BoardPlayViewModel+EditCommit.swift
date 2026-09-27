import Foundation
import GRDB

// MARK: - BoardPlayViewModel + Edit commit

/// Edit-mode draft mutators + the staged squares commit path (Board Edit
/// redesign slice 3, T4). Stored `edit*` state stays on the class (Swift
/// extensions can't hold stored properties).
///
/// Slice 3 (D7) retires the Edit-tasks ⇄ Rearrange sub-modes: every mutator
/// below writes directly into the position-keyed `editSquaresDraft`, which
/// `editSquaresEditCells` (in `+EditDraft.swift`) rebuilds fresh on every
/// read (D20) — there is no parallel "rearrange cells" array to keep in sync.
extension BoardPlayViewModel {

    /// Seeds the squares draft + center type from the live board record
    /// before entering edit mode. Called synchronously on the main actor
    /// immediately before the view flips `editMode = true`.
    ///
    /// - Parameter b: The current active `Board`.
    func seedEditDraft(from b: Board) {
        // D1 — the draft always reads the EFFECTIVE center (never `.chosen`):
        // a legacy CHOSEN board opens already looking like "task square +
        // locked center placement".
        editCenterType = CenterSquare.effectiveCenter(b.centerSquareType)
        editSquaresDraft = [:]
        editTaskOverrides = [:]
        editShuffled = false
        editBaselineBoardTaskIds = []
        editOriginalCenterBoardTaskId = nil

        let size = gridSize
        let mid = size / 2
        // Board-integrity PR-2 (Part 2): resolve through
        // `PlacementIntegrity.resolvePlacements` first — a raw duplicate row
        // at one cell would otherwise seed the draft from whichever row
        // happens to iterate last (arbitrary), instead of the deterministic
        // winner render/derivation agree on.
        for bt in PlacementIntegrity.resolvePlacements(boardTasks, boardSize: size) {
            // D1 — effective lock = the row's own flag OR the legacy-CHOSEN
            // implicit center lock.
            let effectiveLocked = bt.isLocked || CenterSquare.isLegacyChosenCenterLocked(
                centerType: b.centerSquareType, row: bt.row, col: bt.col, gridSize: size
            )
            let key = "\(bt.row)-\(bt.col)"
            editSquaresDraft[key] = SquaresDraftCell(
                id: bt.id, isNew: false, taskId: bt.taskId, pending: nil,
                isLocked: effectiveLocked,
                originalRow: bt.row, originalCol: bt.col,
                originalTaskId: bt.taskId, originalIsLocked: effectiveLocked
            )
            editBaselineBoardTaskIds.insert(bt.id)
            if size % 2 == 1 && bt.row == mid && bt.col == mid {
                editOriginalCenterBoardTaskId = bt.id
            }
        }
    }

    /// Stages a task placement at `cellKey` — either an EXISTING library task
    /// (`taskId` with `pending == nil`) or a not-yet-created one (`taskId`
    /// is the pre-minted id from the quick-add / special-type panel's
    /// deferred payload). Works uniformly for Replace (an occupied cellKey)
    /// and Add (an empty cellKey) — the Square picker sheet is the SAME
    /// sheet for both (D13).
    ///
    /// - Parameters:
    ///   - cellKey: The "row-col" key into `editSquaresDraft`.
    ///   - taskId: The task now occupying the square.
    ///   - pending: Non-nil when `taskId`'s task doesn't exist in the DB yet
    ///     (D14) — inserted at Save with `createdInWizard: false`.
    private func stagePlacement(cellKey: String, taskId: String, pending: PendingTaskPayload?) {
        if var existing = editSquaresDraft[cellKey] {
            existing.taskId = taskId
            existing.pending = pending
            editSquaresDraft[cellKey] = existing
        } else {
            editSquaresDraft[cellKey] = SquaresDraftCell(
                id: "new-\(AppDatabase.generateUUID())", isNew: true,
                taskId: taskId, pending: pending, isLocked: false,
                originalRow: nil, originalCol: nil,
                originalTaskId: nil, originalIsLocked: false
            )
        }
    }

    /// Stages a fresh placement on an EMPTY square (D13/D17 — the picker is
    /// the only path onto the board now; the play-mode "+" is retired).
    func handleEditAdd(cellKey: String, taskId: String, pending: PendingTaskPayload? = nil) {
        stagePlacement(cellKey: cellKey, taskId: taskId, pending: pending)
    }

    /// Stages a task-ID replacement on an OCCUPIED square (no DB write until
    /// Save). Same picker sheet as Add (D13); pass `pending` when the user
    /// created a brand-new task via the quick-add row.
    func handleEditReplace(cellKey: String, taskId: String, pending: PendingTaskPayload? = nil) {
        stagePlacement(cellKey: cellKey, taskId: taskId, pending: pending)
    }

    /// Stages a cell removal (no DB write). Drops the cell from the squares
    /// draft so it renders as a dashed empty square; the placement is only
    /// soft-deleted (tombstoned) on Save.
    func handleEditRemove(cellKey: String) {
        editSquaresDraft.removeValue(forKey: cellKey)
    }

    /// Stages a lock toggle on one square (no DB write).
    func handleEditToggleLock(cellKey: String) {
        guard var cell = editSquaresDraft[cellKey] else { return }
        cell.isLocked.toggle()
        editSquaresDraft[cellKey] = cell
    }

    /// Stages task-field overrides for a global Task (no DB write). The
    /// edit-mode draft task map picks this up immediately so the grid label
    /// updates.
    func handleEditTaskOverride(taskId: String, patch: SquareEditTaskSheet.Patch) {
        editTaskOverrides[taskId] = StagedTaskOverride(
            title: patch.title,
            type: patch.type,
            action: patch.action.isEmpty ? nil : patch.action,
            unit: patch.unit.isEmpty ? nil : patch.unit,
            maxCount: patch.maxCount
        )
    }

    /// D16 — Free center → task square. The center becomes an empty (dashed)
    /// square; the user taps it to add via the picker like any other empty
    /// square. No cell to remove (a FREE center never has a draft entry).
    func handleEditCenterTask() {
        editCenterType = .none
    }

    /// D16 — Task square center → free space. Stages the center placement's
    /// removal (tombstoned on Save, same as any Remove) AND flips the
    /// toggle — counted as ONE edit (`SquaresEditCount.centerChanged`), not
    /// two, per D11.
    func handleEditCenterFree() {
        editCenterType = .free
        if let key = editCenterCellKey {
            editSquaresDraft.removeValue(forKey: key)
        }
    }

    /// Builds the center-only metadata patch (when changed) + staged
    /// square/override/position/lock commits from the current draft state
    /// and writes them in ONE transaction, in D15 order. On success it
    /// reloads the board and emits `editEvent(.saved)`; on failure it emits
    /// `editEvent(.saveFailed)` or, for a sealed/deleted board,
    /// `editEvent(.boardClosed)`.
    ///
    /// - Returns: `true` if the DB commit was dispatched (view should show the
    ///   saving state); `false` if a save is already in flight.
    @discardableResult
    func handleEditSave() -> Bool {
        guard !editSaveInFlight else { return false }
        guard let liveBoard = board else { return false }

        // D9 (9) — the center-only metadata patch, computed against the
        // EFFECTIVE stored value so an untouched legacy-CHOSEN board writes
        // nothing extra here (D1's baseline is already normalized).
        var metaPatch = AppDatabase.UpdateActiveBoardPatch()
        if editCenterType != CenterSquare.effectiveCenter(liveBoard.centerSquareType) {
            metaPatch.centerSquareType = editCenterType
        }
        let patch = metaPatch

        // Snapshot the staged square edits as value types before the detached
        // task (the `@Published` dictionaries are only safe on the MainActor).
        let draftSnapshot = editSquaresDraft

        // (1) Pending (not-yet-created) tasks staged via the picker. A staged
        // "Edit task…" override on a pending task is merged into its payload
        // here (it has no `taskMap` row for step 4 to patch) — web
        // `resolveTask` / `updateTaskAndCascade`-after-insert parity.
        let overridesSnapshot = editTaskOverrides
        let pendingPayloads: [PendingTaskPayload] = draftSnapshot.values.compactMap { cell in
            guard let payload = cell.pending else { return nil }
            guard let override = overridesSnapshot[payload.task.id] else { return payload }
            return PendingTaskPayload(
                task: Self.applyingOverride(override, to: payload.task),
                childTasks: payload.childTasks,
                childLinks: payload.childLinks
            )
        }

        // (3) Replacements — EXISTING cells whose task changed.
        let cellReplacements: [(boardTaskId: String, newTaskId: String)] = draftSnapshot.values
            .filter { !$0.isNew && $0.taskId != $0.originalTaskId }
            .map { (boardTaskId: $0.id, newTaskId: $0.taskId) }

        // (4) Task-field overrides — unchanged shape from slice 2.
        var taskOverridePairs: [(task: Task, override: StagedTaskOverride)] = []
        for (taskId, override) in editTaskOverrides {
            if let task = taskMap[taskId] {
                taskOverridePairs.append((task: task, override: override))
            }
        }

        // (5) Removals — baseline ids missing from the current draft. This
        // is the FULL set (unlike the UI's `editSquaresEditCount`, which
        // excludes the center's Free-toggle removal from the COUNT) — the
        // center's placement still gets a real tombstone here.
        let currentIds = Set(draftSnapshot.values.map { $0.id })
        let cellRemovals: [String] = editBaselineBoardTaskIds.filter { !currentIds.contains($0) }

        // (6) Moves — EXISTING cells whose CURRENT slot differs from seed.
        let positionMoves: [(boardTaskId: String, row: Int, col: Int)] = draftSnapshot
            .compactMap { key, cell -> (boardTaskId: String, row: Int, col: Int)? in
                guard !cell.isNew, let (row, col) = parseSquareCellKey(key) else { return nil }
                guard cell.originalRow != row || cell.originalCol != col else { return nil }
                return (boardTaskId: cell.id, row: row, col: col)
            }

        // (7) Adds — staged new placements, at their CURRENT slot.
        let cellAdds: [(row: Int, col: Int, taskId: String, isLocked: Bool)] = draftSnapshot
            .compactMap { key, cell -> (row: Int, col: Int, taskId: String, isLocked: Bool)? in
                guard cell.isNew, let (row, col) = parseSquareCellKey(key) else { return nil }
                return (row: row, col: col, taskId: cell.taskId, isLocked: cell.isLocked)
            }

        // (5b / 8) Lock changes — EXISTING cells only (a staged add's lock is
        // written by `addBoardTaskToBoard(isLocked:)` at insertion). Split by
        // direction: UNLOCKS land before the moves (step 5b) because
        // `updateBoardTaskPositions` rejects moving a row that is locked ON
        // DISK — "Unlock → hold-drag → Save" in one session would otherwise
        // fail; LOCKS land after the moves (step 8) so "move → Lock in place"
        // moves the row first.
        let unlocks: [String] = draftSnapshot.values
            .filter { !$0.isNew && $0.originalIsLocked && !$0.isLocked }
            .map { $0.id }
        let locks: [String] = draftSnapshot.values
            .filter { !$0.isNew && !$0.originalIsLocked && $0.isLocked }
            .map { $0.id }

        // (2) D2 — legacy-CHOSEN normalization's `keepLocked`: the draft's
        // CURRENT lock state for the (possibly moved) original center
        // placement. Defaults to `true` (the effective baseline) when the
        // center was removed this session — it's about to be tombstoned by
        // (5) regardless.
        let centerKeepLocked = draftSnapshot.values
            .first(where: { $0.id == editOriginalCenterBoardTaskId })?.isLocked ?? true

        editSaveInFlight = true
        let bid = boardId
        let database = self.database
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                try database.write { db in
                    // 0. A board sealed or deleted since edit mode opened
                    //    throws here, rolling back EVERYTHING below.
                    try AppDatabase.assertBoardEditable(db: db, boardId: bid)

                    let now = AppDatabase.currentTimestamp()

                    // 1. Insert pending (not-yet-created) tasks — D14:
                    //    `createdInWizard: false` (a deliberate library task,
                    //    unlike the wizard's hidden drafts).
                    for payload in pendingPayloads {
                        var task = payload.task
                        task.createdInWizard = false
                        try task.save(db)
                        try SyncQueueBuilder.makeItem(
                            entityType: "tasks", entityId: task.id,
                            operationType: .create, payload: task, now: now
                        ).enqueue(db)
                        for (childTask, link) in zip(payload.childTasks, payload.childLinks) {
                            var child = childTask
                            child.createdInWizard = false
                            try child.save(db)
                            try SyncQueueBuilder.makeItem(
                                entityType: "tasks", entityId: child.id,
                                operationType: .create, payload: child, now: now
                            ).enqueue(db)
                            try link.save(db)
                            try SyncQueueBuilder.makeItem(
                                entityType: "compoundChildren", entityId: link.id,
                                operationType: .create, payload: link, now: now
                            ).enqueue(db)
                        }
                    }

                    // 2. D2 — one-time legacy CHOSEN conversion (no-op unless
                    //    the on-disk row is still CHOSEN).
                    try AppDatabase.normalizeLegacyChosenCenter(
                        db: db, boardId: bid, keepLocked: centerKeepLocked
                    )

                    // 3. Staged cell replacements.
                    for replacement in cellReplacements {
                        try AppDatabase.updateBoardTaskAndCascade(
                            db: db,
                            boardTaskId: replacement.boardTaskId,
                            newTaskId: replacement.newTaskId
                        )
                    }

                    // 4. Staged task-field overrides.
                    for (task, override) in taskOverridePairs {
                        var updated = Self.applyingOverride(override, to: task)
                        updated.updatedAt = now
                        updated.version  += 1
                        try AppDatabase.saveTaskAndCascade(db: db, task: updated)
                    }

                    // 5. Staged removals — BEFORE moves/adds (D15) so a
                    //    freed position is never mistaken for occupied.
                    for removedId in cellRemovals {
                        try AppDatabase.removeBoardTaskFromBoard(db: db, boardTaskId: removedId)
                    }

                    // 5b. Staged UNLOCKS on existing placements — before the
                    //     moves (see the `unlocks` doc above).
                    for boardTaskId in unlocks {
                        try AppDatabase.setBoardTaskLocked(db: db, boardTaskId: boardTaskId, locked: false)
                    }

                    // 6. Staged position moves.
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

                    // 7. Staged adds, carrying any staged lock.
                    for add in cellAdds {
                        try AppDatabase.addBoardTaskToBoard(
                            db: db, boardId: bid, taskId: add.taskId,
                            position: (row: add.row, col: add.col),
                            isLocked: add.isLocked
                        )
                    }

                    // 8. Staged LOCKS on existing placements — after the moves.
                    for boardTaskId in locks {
                        try AppDatabase.setBoardTaskLocked(db: db, boardTaskId: boardTaskId, locked: true)
                    }

                    // 9. Center-only metadata patch — skipped when unchanged.
                    if patch.centerSquareType != nil {
                        try AppDatabase.updateBoardAndCascade(db: db, boardId: bid, patch: patch)
                    }
                }

                await MainActor.run {
                    self.editSaveInFlight = false
                    self.reload()
                    self.emitEdit(.saved)
                }
            } catch BoardEditError.boardNotEditable {
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

    /// Whether Board Edit may switch a task from `from` to `to`. Only
    /// Simple ⇄ Counting: a Compound carries `compound_children` + a rule and
    /// an Achievement carries its trigger + board/template target — neither
    /// can be entered or left from the "Edit task…" sheet (their structure is
    /// edited from Task Detail), so their type is immutable here.
    nonisolated static func boardEditAllowsTypeSwitch(from: TaskType, to: TaskType) -> Bool {
        let switchable: Set<TaskType> = [.normal, .counting]
        return switchable.contains(from) && switchable.contains(to)
    }

    /// Applies a staged "Edit task…" override to a task's fields (title,
    /// type — Simple ⇄ Counting only, see `boardEditAllowsTypeSwitch` — and
    /// the counting fields). Shared by the Save's step 4 (existing tasks),
    /// step 1 (pending tasks) and the staged grid (`editDraftTaskMap`).
    nonisolated static func applyingOverride(_ override: StagedTaskOverride, to task: Task) -> Task {
        var updated = task
        updated.title = override.title
        if boardEditAllowsTypeSwitch(from: task.type, to: override.type) {
            updated.type = override.type
        }
        switch updated.type {
        case .counting:
            updated.action = override.action
            if let u = override.unit   { updated.unit   = u }
            if let m = override.maxCount { updated.maxCount = m }
        case .normal:
            if task.type == .counting {
                updated.action   = nil
                updated.unit     = nil
                updated.maxCount = nil
            }
        default:
            break
        }
        return updated
    }

    /// Publishes a one-shot `editEvent` the view observes to run the residual
    /// edit-commit UI mutations it still owns.
    private func emitEdit(_ outcome: BoardPlayEditEvent.Outcome) {
        editEventCounter += 1
        editEvent = BoardPlayEditEvent(id: editEventCounter, outcome: outcome)
    }
}
