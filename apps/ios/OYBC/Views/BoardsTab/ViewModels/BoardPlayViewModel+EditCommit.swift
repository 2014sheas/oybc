import Foundation
import GRDB

// MARK: - BoardPlayViewModel + Edit commit

/// Edit-mode draft mutators + the staged commit path (B2-I3), split out
/// of `BoardPlayViewModel.swift` when the staged REPEATS section pushed
/// the file past its frozen drift-guardrail cap (2026-09-15) — a true
/// ROADMAP-B6-style extraction, not a cap bump. Stored `edit*` state
/// stays on the class (Swift extensions can't hold stored properties);
/// everything behavioral about seeding, mutating, and committing the
/// edit draft — the two-phase repeat save included — lives here.
extension BoardPlayViewModel {
    // MARK: - Edit-mode draft mutators + commit (B2-I3)
    //
    // Moved verbatim from `BoardPlayView`. The pure staged-draft mutators
    // (`seedRearrangeCells` / `handleRearrange` / `handleEditCellReplace` /
    // `handleEditTaskOverride`) only touch the `@Published` draft fields. The
    // DB-touching functions (`seedEditDraft` / `handleEditSave` /
    // `handleEditArchive`) write through the injected `database` (I2's
    // precedent) and signal the residual view-owned UI mutations back through
    // the one-shot `editEvent`.
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
        editName = b.name
        editTimeframe = b.timeframe

        let cal = Calendar.current
        let fallbackStart = cal.startOfDay(for: Date())
        let fallbackEnd = cal.date(byAdding: .day, value: 30, to: fallbackStart) ?? Date()
        let seedStart = parseWizardCalendarDate(b.startDate) ?? fallbackStart
        let seedEnd: Date = {
            if let endStr = b.endDate, let parsed = parseWizardCalendarDate(endStr) { return parsed }
            return fallbackEnd
        }()
        editCustomStartDate = seedStart
        editOriginalCustomStartDate = seedStart
        editCustomEndDate = seedEnd
        editOriginalCustomEndDate = seedEnd
        editCenterType = b.centerSquareType
        editSubMode = .editTasks
        editHasCandidateTasks = false

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
        // Phase 3 — reset rearrange cells so they're rebuilt fresh on next entry.
        editRearrangeCells = nil

        // Repeat-in-edit — reset the staged REPEATS draft on (re-)entry and
        // (for a repeating board) recompute the spawn-provenance note.
        editRepeatCadence = nil
        editRepeatActive = editSourceTemplate?.isActive ?? true
        recomputeEditSpawnNote(board: b)

        // Async: check whether the board has any center-task placement so
        // BoardEditPanel can gate the CHOSEN option in BoardSetupFormView.
        let bid = b.id
        let database = self.database
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            let count = (try? database.fetchBoardTasks(boardId: bid).count) ?? 0
            await MainActor.run { self?.editHasCandidateTasks = count > 0 }
        }
    }

    /// Repeat-in-edit — recomputes the panel's read-only spawn-provenance
    /// note off-main (the sources-native supply resolution reads the DB —
    /// `AppDatabase.spawnProvenanceNote`), caching it in `editSpawnNoteText`.
    /// Called ONLY from `seedEditDraft` (edit-mode entry), so the note is
    /// computed only while the panel is open — the play surface no longer
    /// owns this state. Nil (hidden) for a one-off board, an unresolved
    /// source record, or a board that is no longer freshly dealt.
    private func recomputeEditSpawnNote(board b: Board) {
        editSpawnNoteText = nil
        guard let template = editSourceTemplate,
              isFreshlyDealtBoard(
                  completedTasks: b.completedTasks,
                  boardSize: b.boardSize,
                  centerSquareType: b.centerSquareType
              )
        else { return }
        let poolsById = Dictionary(uniqueKeysWithValues: allPoolsInWorkspace.map { ($0.id, $0) })
        let tasksById = taskMap
        let dealt = boardTasks.map { $0.taskId }
        let database = self.database
        _Concurrency.Task.detached(priority: .utility) { [weak self] in
            let text = database.spawnProvenanceNote(
                template: template,
                poolsById: poolsById,
                tasksById: tasksById,
                dealtTaskIds: dealt
            )
            await MainActor.run { self?.editSpawnNoteText = text }
        }
    }

    /// Lazily builds `editRearrangeCells` the first time the user switches to
    /// Rearrange sub-mode. Subsequent sub-mode switches preserve the staged order.
    func seedRearrangeCells(for b: Board) {
        guard editRearrangeCells == nil else { return }
        editRearrangeCells = buildRearrangeCells(
            squaresDraft: editSquaresDraft,
            gridSize: b.boardSize,
            centerSquareType: editCenterType
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

    /// Builds the metadata patch + staged square/override/position commits from
    /// the current draft state and writes them via the injected `database`. On
    /// success it reloads the board and emits `editEvent(.saved)`; on failure it
    /// emits `editEvent(.saveFailed)`.
    ///
    /// The pre-move version set the view's `editSaving = true` synchronously
    /// after validation passed. To preserve that exact timing while keeping
    /// `editSaving` view-side, this returns `true` iff the commit was actually
    /// dispatched (validation passed + not re-entrant) so the view flips
    /// `editSaving = true` in the same synchronous tick; `editEvent` drives the
    /// reset. The authoritative double-save guard is `editSaveInFlight` here.
    ///
    /// - Parameter weekStartDay: The user's week-start (`"monday"` etc.) — an
    ///   `AuthService`-sourced value the view passes in, since the VM has no env.
    /// - Returns: `true` if the DB commit was dispatched (view should show the
    ///   saving state); `false` if validation failed or a save is already in
    ///   flight (view leaves `editSaving` untouched).
    @discardableResult
    func handleEditSave(weekStartDay: String) -> Bool {
        guard !editSaveInFlight else { return false }
        let trimmedName = editName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return false }

        let cal = Calendar.current

        func snapStart(_ d: Date) -> String {
            wizardLocalISOString(cal.startOfDay(for: d))
        }
        func snapEnd(_ d: Date) -> String {
            let nextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: d))!
            return wizardLocalISOString(nextDay.addingTimeInterval(-0.001))
        }

        let startISO: String?
        let endISO: String?
        var clearEnd = false

        // Dates are written ONLY when the user actually changed the window
        // (timeframe conversion, or new custom dates). A metadata-only Save
        // must PRESERVE the stored window: under Windowed Completion,
        // `startDate` is the completion window's lower bound — rewriting it
        // silently re-windows the board and wipes the progress of every task
        // whose events predate the new start. The old code recomputed dates
        // on EVERY save (indefinite → re-anchored to today; core → today's
        // window), resetting all progress except tasks completed on the edit
        // day. Nil startDate/endDate in the patch = "leave unchanged".
        let timeframeChanged = editTimeframe != board?.timeframe
        let customDatesChanged = editTimeframe == .custom
            && (editCustomStartDate != editOriginalCustomStartDate
                || editCustomEndDate != editOriginalCustomEndDate)

        if timeframeChanged {
            // Deliberate re-window: converting the board recomputes its dates.
            if editTimeframe == .indefinite {
                startISO = wizardLocalISOString(cal.startOfDay(for: Date()))
                endISO = nil
                clearEnd = true
            } else if editTimeframe == .custom {
                let snappedStart = snapStart(editCustomStartDate)
                let snappedEnd = snapEnd(editCustomEndDate)
                // Carry over EditBoardSheet's guard: the end-date picker's min can lag a
                // start-date change, so re-validate end >= start before persisting.
                guard snappedEnd >= snappedStart else { return false }
                startISO = snappedStart
                endISO = snappedEnd
            } else if let boundaries = computeTimeframeBoundaries(
                timeframe: editTimeframe,
                referenceDate: Date(),
                weekStartDay: weekStartDay
            ) {
                startISO = wizardLocalISOString(boundaries.start)
                endISO = wizardLocalISOString(boundaries.end)
            } else {
                return false
            }
        } else if customDatesChanged {
            // Same CUSTOM timeframe, user picked new dates.
            let snappedStart = snapStart(editCustomStartDate)
            let snappedEnd = snapEnd(editCustomEndDate)
            guard snappedEnd >= snappedStart else { return false }
            startISO = snappedStart
            endISO = snappedEnd
        } else {
            // Window untouched — nil dates preserve the stored window (and
            // every in-window completion event) across the save.
            startISO = nil
            endISO = nil
        }

        let patch = AppDatabase.UpdateActiveBoardPatch(
            name: trimmedName,
            timeframe: editTimeframe,
            startDate: startISO,
            endDate: endISO,
            clearEndDate: clearEnd,
            centerSquareType: editCenterType
        )

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

        // Repeat-in-edit — snapshot the staged repeat intent on the main
        // actor before detaching (mirrors the value-type snapshots above).
        // nil = the REPEATS draft is a no-op and Save is board-only.
        let repeatIntent: EditRepeatIntent? = {
            if let template = editSourceTemplate {
                // Repeating board: apply the Active toggle only when changed.
                guard editRepeatActive != template.isActive else { return nil }
                return .setActive(template: template, isActive: editRepeatActive)
            }
            // One-off board: a staged cadence starts repeating — but never
            // for a CHOSEN center (a CHOSEN center can never validate a
            // spawn pool — `validateSpawnPool` rejects it as
            // `.unsupportedCenter`; the panel hides the section too, this
            // guard keeps a stale staged cadence inert).
            guard board?.spawnedFromTemplateId == nil,
                  let cadence = editRepeatCadence,
                  editCenterType != .chosen
            else { return nil }
            return .startRepeating(cadence: cadence)
        }()
        let repeatUserId = userId

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
                        updated.type  = override.type
                        switch override.type {
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
                }

                // Repeat-in-edit — TWO-PHASE SAVE, phase 2: the staged repeat
                // mutation runs AFTER the atomic board write above commits
                // (it is deliberately NOT part of that transaction —
                // `repeatBoardAsTemplate` / the active-toggle write open
                // their own transactions). If this phase fails, the board
                // changes from phase 1 STAY SAVED; the `.saveFailed` below
                // keeps the panel open with the error so the user can retry
                // (a retry re-runs a now-clean phase 1 plus this phase).
                if let intent = repeatIntent {
                    do {
                        let repeatNow = AppDatabase.currentTimestamp()
                        switch intent {
                        case .startRepeating(let cadence):
                            // Re-read the just-saved board so the minted
                            // repeat record reflects the new metadata (name)
                            // — `repeatBoardAsTemplate` re-reads the LIVE row
                            // in-transaction for the version back-stamp.
                            if let repeatUserId,
                               let freshBoard = try database.fetchBoard(id: bid) {
                                _ = try database.repeatBoardAsTemplate(
                                    board: freshBoard,
                                    cadence: cadence,
                                    userId: repeatUserId,
                                    weekStartDay: weekStartDay,
                                    now: repeatNow
                                )
                            }
                        case .setActive(let template, let isActive):
                            // Mirrors BoardSettingsView.setActive verbatim:
                            // flip isActive, bump version, save + enqueue.
                            var updated = template
                            updated.isActive = isActive
                            updated.updatedAt = repeatNow
                            updated.version += 1
                            try database.saveRecurringBoardTemplateAndEnqueue(
                                updated, operation: .update, now: repeatNow
                            )
                        }
                    } catch {
                        dlog("⚠️ BoardPlayViewModel.handleEditSave repeat phase: \(error)")
                        await MainActor.run {
                            self.editSaveInFlight = false
                            // Reload so the UI reflects the board changes
                            // that DID save in phase 1.
                            self.reload()
                            self.emitEdit(.saveFailed(
                                "Your board was saved, but the repeat setting couldn’t be applied — please try again."
                            ))
                        }
                        return
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

    /// Archives the board by setting `status = .archived` via the injected
    /// `database`, then emits `editEvent(.archived)` so the view exits edit mode
    /// and dismisses back to the Boards list. On failure it surfaces an error
    /// through `bingoMessage` (which the VM already owns).
    ///
    /// The archive confirm alert in `BoardEditPanel` calls this only after the
    /// user confirms — no further confirmation required here.
    func handleEditArchive() {
        let bid = boardId
        let database = self.database
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                try database.archiveBoard(id: bid)
                // Only leave the board if the archive actually committed.
                await MainActor.run {
                    self.emitEdit(.archived)
                }
            } catch {
                dlog("⚠️ BoardPlayViewModel.handleEditArchive: \(error)")
                await MainActor.run {
                    self.bingoMessage = "Archive failed — please try again."
                }
            }
        }
    }

    /// Publishes a one-shot `editEvent` the view observes to run the residual
    /// edit-commit UI mutations it still owns.
    private func emitEdit(_ outcome: BoardPlayEditEvent.Outcome) {
        editEventCounter += 1
        editEvent = BoardPlayEditEvent(id: editEventCounter, outcome: outcome)
    }

}
