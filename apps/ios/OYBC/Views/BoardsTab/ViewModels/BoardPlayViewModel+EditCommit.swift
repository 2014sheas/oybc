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
        editForkConfirmed = false
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
    private func stagePlacement(
        cellKey: String, taskId: String, pending: PendingTaskPayload?, placement: PlacementParamsDraft? = nil
    ) {
        if var existing = editSquaresDraft[cellKey] {
            existing.taskId = taskId
            existing.pending = pending
            existing.placement = placement
            editSquaresDraft[cellKey] = existing
        } else {
            editSquaresDraft[cellKey] = SquaresDraftCell(
                id: "new-\(AppDatabase.generateUUID())", isNew: true,
                taskId: taskId, pending: pending, placement: placement, isLocked: false,
                originalRow: nil, originalCol: nil,
                originalTaskId: nil, originalIsLocked: false
            )
        }
    }

    /// Stages a fresh placement on an EMPTY square (D13/D17 — the picker is
    /// the only path onto the board now; the play-mode "+" is retired).
    func handleEditAdd(
        cellKey: String, taskId: String, pending: PendingTaskPayload? = nil, placement: PlacementParamsDraft? = nil
    ) {
        stagePlacement(cellKey: cellKey, taskId: taskId, pending: pending, placement: placement)
    }

    /// Stages a task-ID replacement on an OCCUPIED square (no DB write until
    /// Save). Same picker sheet as Add (D13); pass `pending` when the user
    /// created a brand-new task via the quick-add row.
    func handleEditReplace(
        cellKey: String, taskId: String, pending: PendingTaskPayload? = nil, placement: PlacementParamsDraft? = nil
    ) {
        stagePlacement(cellKey: cellKey, taskId: taskId, pending: pending, placement: placement)
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
        editTaskOverrides[taskId] = StagedTaskOverride(patch: patch)
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
            // A pending row carries no counts-toward flag — no Board Edit path stages one.
            return PendingTaskPayload(
                task: Self.applyingOverride(override, to: payload.task, writesKind: true),
                childTasks: payload.childTasks,
                childLinks: payload.childLinks
            )
        }

        // (3) Replacements — EXISTING cells whose task changed.
        let cellReplacements: [(boardTaskId: String, newTaskId: String, placement: PlacementParamsDraft?)] = draftSnapshot.values
            .filter { !$0.isNew && $0.taskId != $0.originalTaskId }
            .map { (boardTaskId: $0.id, newTaskId: $0.taskId, placement: $0.placement) }

        // (4) Task-field overrides — keyed by the STAGED task id (= the placed
        // task id since slice 3a). Applied AFTER replacements + adds (step 7b)
        // so a freshly placed square's placement exists to carry parameters.
        let pendingTaskIds = Set(draftSnapshot.values.compactMap { $0.pending?.task.id })
        let stagedOverrides: [StagedOverrideInput] = editTaskOverrides.map { taskId, override in
            StagedOverrideInput(
                stagedId: taskId, override: override, mapTask: taskMap[taskId],
                isPending: pendingTaskIds.contains(taskId)
            )
        }
        let stagedCellRefs: [StagedCellRef] = draftSnapshot.compactMap { key, cell in
            guard let (row, col) = parseSquareCellKey(key) else { return nil }
            return StagedCellRef(
                boardTaskId: cell.id, isNew: cell.isNew, row: row, col: col, stagedTaskId: cell.taskId
            )
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
        let cellAdds: [(row: Int, col: Int, taskId: String, isLocked: Bool, placement: PlacementParamsDraft?)] = draftSnapshot
            .compactMap { key, cell -> (row: Int, col: Int, taskId: String, isLocked: Bool, placement: PlacementParamsDraft?)? in
                guard cell.isNew, let (row, col) = parseSquareCellKey(key) else { return nil }
                return (row: row, col: col, taskId: cell.taskId, isLocked: cell.isLocked, placement: cell.placement)
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

        // Compound overrides (conversion / edited compound): reject BEFORE
        // opening the write so the user gets the specific alert, not a failed
        // transaction. `applyStagedOverrides` re-checks inside the transaction.
        if let problem = Self.compoundOverrideProblem(
            database: database, overrides: overridesSnapshot,
            pendingPayloads: draftSnapshot.values.compactMap(\.pending),
            placedTaskIds: Set(draftSnapshot.values.map(\.taskId))
        ) {
            emitEdit(.saveFailed(problem))
            return false
        }

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
                        var draft = payload.task
                        draft.createdInWizard = false
                        // Counter kinds (D5): a linked row carries its root's kind.
                        let task = try AppDatabase.withRootCountKind(db: db, draft)
                        try task.save(db)
                        try SyncQueueBuilder.makeItem(
                            entityType: "tasks", entityId: task.id,
                            operationType: .create, payload: task, now: now
                        ).enqueue(db)
                        // Child tasks and links are written INDEPENDENTLY: a
                        // picked EXISTING library sub-task has a link but no
                        // child task in the payload, so the two arrays differ
                        // in length (a zip misaligned / dropped them).
                        for childTask in payload.childTasks {
                            var childDraft = childTask
                            childDraft.createdInWizard = false
                            let child = try AppDatabase.withRootCountKind(db: db, childDraft)
                            try child.save(db)
                            try SyncQueueBuilder.makeItem(
                                entityType: "tasks", entityId: child.id,
                                operationType: .create, payload: child, now: now
                            ).enqueue(db)
                        }
                        for link in payload.childLinks {
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
                        // Slice 3b: the pick's parameters (a goal) land on the swapped placement.
                        if let p = replacement.placement {
                            _ = try AppDatabase.setPlacementParams(
                                db: db, boardTaskId: replacement.boardTaskId,
                                patch: PlacementParamsPatch(
                                    targetOverride: p.targetOverride.map { .set($0) } ?? .keep,
                                    targetKind: p.targetKind.map { .set($0) } ?? .keep,
                                    titleOverride: p.titleOverride.map { .set($0) } ?? .keep
                                ),
                                now: now
                            )
                        }
                    }

                    // 4. (moved to 7b — overrides remap to the placed ids.)

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
                            isLocked: add.isLocked,
                            targetOverride: add.placement?.targetOverride,
                            targetKind: add.placement?.targetKind,
                            titleOverride: add.placement?.titleOverride
                        )
                    }

                    // 7b. Staged task-field overrides: parameters onto the
                    //     placement, everything else board-scoped.
                    try Self.applyStagedOverrides(
                        db: db, boardId: bid, overrides: stagedOverrides, cells: stagedCellRefs, now: now
                    )

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
            } catch AppDatabase.TaskEditError.invalid(let message) {
                await MainActor.run {
                    self.editSaveInFlight = false
                    self.emitEdit(.saveFailed(message))
                }
            } catch CountKindSwitchError.hasContributors {
                await MainActor.run {
                    self.editSaveInFlight = false
                    self.emitEdit(.saveFailed(CountKindSwitchError.countsTowardMessage))
                }
            } catch let countsToward as AppDatabase.CountsTowardError {
                await MainActor.run {
                    self.editSaveInFlight = false
                    self.emitEdit(.saveFailed(countsToward.label ?? "Couldn’t save your changes — please try again."))
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

    /// One staged "Edit task…" override with the pre-save `taskMap` row it
    /// would patch when its task is placed as-is.
    struct StagedOverrideInput {
        let stagedId: String
        let override: StagedTaskOverride
        let mapTask: Task?
        /// A not-yet-created task staged through the picker (inserted at step 1).
        var isPending: Bool = false
    }

    /// One draft cell, reduced to what override remapping needs.
    struct StagedCellRef {
        let boardTaskId: String
        let isNew: Bool
        let row: Int
        let col: Int
        let stagedTaskId: String
    }

    /// Step 7b — commit each staged override, split into PLACEMENT PARAMETERS
    /// and everything else (TASK_WINDOW_REWORK slice 3a, Gate 1 rulings b / c,
    /// `BoardEditParamSplit`):
    ///
    /// - A changed goal on a counting task, a changed title, or a changed goal
    ///   on an existing compound child is written onto this square's
    ///   `BoardTask` (`targetOverride` + `targetKind` / `titleOverride` /
    ///   `childTargets`) through `AppDatabase.setPlacementParams`. The library
    ///   task keeps its own goal and title, and nothing forks.
    /// - Every other field (action, unit, a kind or type switch, compound
    ///   structure) goes through the board-scoped path as before: a task placed
    ///   on any other board is forked first (`AppDatabase.ensureBoardScopedTask`)
    ///   and the edit lands on the fork. The path is skipped when nothing
    ///   non-parameter remains.
    ///
    /// A pending (not-yet-created) task has no `mapTask`; its plain override was
    /// merged into its payload at step 1, so only a compound override still
    /// takes the full path. Runs inside the Save transaction, after the
    /// replacement/add/move writes.
    ///
    /// - Parameters:
    ///   - db: The Save's open write transaction.
    ///   - boardId: The board being edited.
    ///   - overrides: Staged overrides keyed by staged task id.
    ///   - cells: The draft cells (staged task id per cell).
    ///   - now: ISO8601 write stamp.
    nonisolated static func applyStagedOverrides(
        db: Database, boardId: String, overrides: [StagedOverrideInput],
        cells: [StagedCellRef], now: String
    ) throws {
        guard !overrides.isEmpty, let board = try Board.fetchOne(db, key: boardId) else { return }
        var touched = Set<String>()
        for input in overrides {
            // Only a square still on the board commits its staged edit: a
            // removed / replaced square's override is dropped.
            guard cells.contains(where: { $0.stagedTaskId == input.stagedId }) else { continue }
            var target = input.stagedId
            // A pending task's plain override was merged into its payload at step 1;
            // only a compound override still needs the inserted row (child CRUD + rule).
            if input.isPending && input.override.compound == nil { continue }
            guard let stored = try Task.fetchOne(db, key: target) ?? input.mapTask else { continue }
            // A linked counter is never converted or given sub-tasks.
            if stored.sharedCounterId != nil,
               input.override.type != stored.type || input.override.compound != nil {
                throw AppDatabase.TaskEditError.invalid(message: Self.linkedCounterTypeMessage)
            }
            let isPending = input.isPending
            let storedChildren: [Task]? = stored.type == .compound ? try Self.storedChildren(db: db, parentId: stored.id) : nil
            let hasNonParameter = isPending
                || BoardEditParamSplit.hasNonParameterFields(task: stored, override: input.override, storedChildren: storedChildren)
            if hasNonParameter {
                let override = isPending
                    ? input.override
                    : BoardEditParamSplit.nonParameterOverride(input.override, task: stored, storedChildren: storedChildren)
                if let forked = try Self.applyNonParameterOverride(
                    db: db, board: board, target: target, base: stored, override: override,
                    goalForGuard: input.override.maxCount, now: now, touched: &touched
                ) { target = forked }
            }
            guard !isPending, let final = try Task.fetchOne(db, key: target),
                  let placement = try BoardTask
                    .filter(Column("boardId") == boardId && Column("taskId") == target && Column("isDeleted") == false)
                    .fetchOne(db) else { continue }
            let patch = BoardEditParamSplit.parameterPatch(
                override: input.override, task: final, placement: placement,
                storedChildren: final.type == .compound ? try Self.storedChildren(db: db, parentId: final.id) : nil,
                titleSettings: try final.sharedCounterId.flatMap { try Task.fetchOne(db, key: $0) }
                    .map(CounterSettings.TitleSettings.init(task:))
            )
            try AppDatabase.setPlacementParams(db: db, boardTaskId: placement.id, patch: patch, now: now)
        }
        // Re-run the loop check against the post-edit rows so a loop closed by
        // this Save's sub-task edit never persists.
        for id in touched.sorted() {
            try AppDatabase.recheckCountsToward(db: db, taskId: id, strict: false)
        }
    }

    /// A compound's live sub-tasks in `childIndex` order.
    nonisolated static func storedChildren(db: Database, parentId: String) throws -> [Task] {
        let links = try CompoundChild
            .filter(Column("compoundTaskId") == parentId && Column("isDeleted") == false)
            .fetchAll(db)
            .sorted { ($0.childIndex, $0.childTaskId) < ($1.childIndex, $1.childTaskId) }
        var out: [Task] = []
        for link in links {
            if let child = try Task.fetchOne(db, key: link.childTaskId), !child.isDeleted { out.append(child) }
        }
        return out
    }

    /// The board-scoped, non-parameter half of one staged override (the pre-3a
    /// body of `applyStagedOverrides`, minus the staged-id remap).
    ///
    /// - Returns: The fork's id when the edit forked the task, else nil.
    nonisolated private static func applyNonParameterOverride(
        db: Database, board: Board, target initialTarget: String, base initialBase: Task, override: StagedTaskOverride,
        goalForGuard: CountValue?, now: String, touched: inout Set<String>
    ) throws -> String? {
        var target = initialTarget
        var base = initialBase
        // Board-scoped (docs/BOARD_SCOPED_TASK_EDITS.md): a task placed on any
        // other board is forked first; the edit lands on the fork.
        let scoped = try AppDatabase.ensureBoardScopedTask(
            db: db, taskId: target, board: board, editedType: Self.editedType(override, base), now: now
        )
        if scoped.forked {
            target = scoped.targetId
            guard let forkRow = try Task.fetchOne(db, key: target) else { return nil }
            base = forkRow
        }
        touched.insert(target)
        // A stored counter ROOT switches kind first (inside this Save),
        // then the typed goal is guarded at the final kind — a refused
        // goal throws `goalNotWhole` and the whole Save rolls back.
        if base.type == .counting, override.type == .counting, base.sharedCounterId == nil {
            if try AppDatabase.applyKindSwitchThenGoalGuard(
                db: db, taskId: target, to: override.countKind, maxCount: goalForGuard, now: Date()
            ) {
                guard let refreshed = try Task.fetchOne(db, key: target) else { return scoped.forked ? target : nil }
                base = refreshed
            }
        }
        var updated = Self.applyingOverride(override, to: base, writesKind: override.type != base.type)
        if updated.type != base.type {
            // The shared type-switch write (also the global editor's).
            try AppDatabase.saveTypeSwitchedTask(
                db: db, original: base, switched: updated, structure: override.compound,
                now: now, scopeBoard: board
            )
            try AppDatabase.stampForkCaches(db: db, target: scoped, now: now)
            return scoped.forked ? target : nil
        }
        if let structure = override.compound {
            // Mirrors `applyTaskEditPatch`'s compound branch (an existing
            // compound; a conversion took the branch above).
            guard updated.type == .compound else { return scoped.forked ? target : nil }
            var titled = structure
            titled.title = override.title
            if let problem = try AppDatabase.compoundLinkProblem(db: db, parentId: updated.id, patch: titled) {
                throw AppDatabase.TaskEditError.invalid(message: problem)
            }
            if let problem = titled.validate(type: .compound, countsToward: updated.countsTowardCounterId != nil) {
                throw AppDatabase.TaskEditError.invalid(message: problem)
            }
            updated.updatedAt = now
            updated.version += 1
            try AppDatabase.applyStagedCompoundChildEdits(
                db: db, parent: updated, patch: titled, now: now, scopeBoard: board
            )
            try AppDatabase.saveTaskAndCascade(db: db, task: updated)
            try AppDatabase.stampForkCaches(db: db, target: scoped, now: now)
            return scoped.forked ? target : nil
        }
        updated.updatedAt = now
        updated.version += 1
        try AppDatabase.saveTaskAndCascade(db: db, task: updated)
        try AppDatabase.stampForkCaches(db: db, target: scoped, now: now)
        return scoped.forked ? target : nil
    }

    /// The task type an override leaves `task` with — what the board-scoped
    /// fork plan migrates events for (mirrors `applyingOverride`'s type rule).
    nonisolated static func editedType(_ override: StagedTaskOverride, _ task: Task) -> TaskType {
        guard task.sharedCounterId == nil, boardEditAllowsTypeSwitch(from: task.type, to: override.type) else {
            return task.type
        }
        if override.type == .compound && override.compound == nil { return task.type }
        return override.type
    }

    /// The first blocking problem among staged compound overrides (a
    /// conversion into Compound or an edited compound), or nil. Pure
    /// `validate(type: .compound)` plus the link guard against the live DB
    /// (a pending compound's own sub-tasks aren't in the DB yet, so they are
    /// excluded from the guard — their payload already vetted them).
    ///
    /// - Parameters:
    ///   - database: The injected database (read only).
    ///   - overrides: Staged overrides keyed by staged task id.
    ///   - pendingPayloads: The staged not-yet-created tasks.
    /// - Returns: A user-facing message, or nil when every compound override is saveable.
    static func compoundOverrideProblem(
        database: AppDatabase, overrides: [String: StagedTaskOverride], pendingPayloads: [PendingTaskPayload],
        placedTaskIds: Set<String>
    ) -> String? {
        let pendingChildIds = Set(pendingPayloads.flatMap { $0.childTasks.map(\.id) })
        for (taskId, override) in overrides.sorted(by: { $0.key < $1.key }) {
            // An override for a square no longer on the board never commits.
            guard placedTaskIds.contains(taskId) else { continue }
            // A linked counter can't change type or gain sub-tasks.
            let stored = try? database.fetchTask(id: taskId)
            if let stored, stored.sharedCounterId != nil,
               override.type != stored.type || override.compound != nil {
                return linkedCounterTypeMessage
            }
            guard var structure = override.compound else { continue }
            structure.title = override.title
            let flagAfter = stored?.countsTowardCounterId != nil
            if let problem = structure.validate(type: .compound, countsToward: flagAfter) {
                return problem
            }
            var guarded = structure
            guarded.children.removeAll { $0.childTaskId.map(pendingChildIds.contains) ?? false }
            do {
                if let problem = try database.read({ db in
                    try AppDatabase.compoundLinkProblem(db: db, parentId: taskId, patch: guarded)
                }) { return problem }
            } catch {
                return "Couldn’t check the sub-tasks — please try again."
            }
        }
        return nil
    }

    /// Shown when a staged edit would change a linked counter's type.
    nonisolated static let linkedCounterTypeMessage = TaskTypeSwitch.linkedCounterMessage

    /// Whether Board Edit may switch a task from `from` to `to`: Simple ⇄
    /// Counting, and Simple / Counting → Compound (the sheet's compound editor
    /// supplies the rule + sub-tasks). Never OUT of Compound (its sub-tasks'
    /// fate is undecided) and never into/out of Achievement (it carries its
    /// trigger + board/template target, edited from Task Detail).
    nonisolated static func boardEditAllowsTypeSwitch(from: TaskType, to: TaskType) -> Bool {
        TaskTypeSwitch.allows(from: from, to: to)
    }

    /// Applies a staged "Edit task…" override to a task's fields (title,
    /// type — see `boardEditAllowsTypeSwitch` — the counting fields, and a
    /// compound's rule). Shared by the Save's step 7b (existing tasks), step 1
    /// (pending tasks) and the staged grid (`editDraftTaskMap`). A switch INTO
    /// Compound needs the override's `compound` patch (otherwise it is ignored,
    /// never minting a zero-child compound); child Task/link CRUD is NOT done
    /// here (`applyStagedCompoundChildEdits` at Save). A BLANK Counting title
    /// is regenerated from the resulting action / goal / unit (the sheet
    /// opens an auto-titled counter blank — `SquareEditTaskSheet.seededTitle`
    /// — so a goal-only edit re-derives the title instead of keeping the
    /// stored one at the old goal), mirroring `TaskEditPatch.applied(to:)`.
    ///
    /// - Parameters:
    ///   - override: The staged override.
    ///   - task: The stored / pending task it lays over.
    ///   - writesKind: True ⇒ the override's `countKind` is set directly (a
    ///     PENDING task, a Simple → Counting conversion, or the staged grid);
    ///     false ⇒ a stored counting row's kind is left to the switch guard in
    ///     `applyStagedOverrides`. A linked row's kind never changes here.
    nonisolated static func applyingOverride(
        _ override: StagedTaskOverride, to task: Task, writesKind: Bool = false
    ) -> Task {
        var updated = task
        updated.title = override.title
        if task.sharedCounterId == nil,
           boardEditAllowsTypeSwitch(from: task.type, to: override.type),
           override.type != .compound || override.compound != nil {
            // Sets the type and clears what it can't carry (shared rule).
            updated = TaskTypeSwitch.converting(updated, to: override.type)
        }
        switch updated.type {
        case .counting:
            updated.action = override.action
            if let u = override.unit   { updated.unit   = u }
            if let m = override.maxCount { updated.maxCount = m }
            // A conversion INTO Counting with no staged kind lands Discrete
            // explicitly (web `compoundStructureEdit`: `stagedKind ?? 'discrete'`).
            let convertsIntoCounting = task.type != .counting
            if writesKind, task.sharedCounterId == nil,
               let kind = override.countKind ?? (convertsIntoCounting ? .discrete : nil) {
                // A PENDING task (no events yet) or a Simple → Counting
                // conversion takes the chosen kind directly; a stored counting
                // row's kind changes only through the guard in applyStagedOverrides.
                // Always explicit (Discrete included): sync merge-writes and
                // `countKind` is not clearable, so a stale kind on a converted
                // Simple row must be overwritten, never left absent.
                if task.type == .counting, let m = updated.maxCount, let rounded = planCountKindSwitch(
                    maxCount: m, defaultLogAmount: nil, from: resolveCountKind(task.countKind), to: kind
                )?.maxCount { updated.maxCount = rounded }
                updated.countKind = kind
            }
            // Duration keeps the row's own unit (a hub counter's noun); the sheet sends it back.
            if override.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.title = TaskTitle.generateCounterTaskTitle(
                    action: updated.action ?? "", maxCount: updated.maxCount, unit: updated.unit ?? "",
                    countKind: resolveCountKind(updated.countKind)
                )
            }
        case .compound:
            // A conversion's counting fields + own latch were cleared by
            // `TaskTypeSwitch.converting` (its old events become inert).
            if var structure = override.compound {
                structure.title = override.title
                updated = structure.applied(to: updated)
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
