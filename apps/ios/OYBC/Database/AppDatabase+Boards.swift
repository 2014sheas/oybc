import Foundation
import GRDB

extension AppDatabase {
    // MARK: - Boards

    func fetchBoards(userId: String) throws -> [Board] {
        return try read { db in
            try Board
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }.healingDisplayNames()
    }

    /// The user's live DRAFT boards, most recently edited first, with display
    /// names healed. Feeds the Create hub's drafts list.
    func fetchDraftBoards(userId: String) throws -> [Board] {
        return try read { db in
            try Board
                .filter(Column("userId") == userId && Column("status") == "draft" && Column("isDeleted") == false)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }.healingDisplayNames()
    }

    /// Fetch boards by id. Used by the task detail view to render
    /// "placed on" links for the cells where this task lives.
    func fetchBoards(ids: [String]) throws -> [Board] {
        guard !ids.isEmpty else { return [] }
        return try read { db in
            try Board
                .filter(ids.contains(Column("id")) && Column("isDeleted") == false)
                .fetchAll(db)
        }.healingDisplayNames()
    }

    func fetchBoard(id: String) throws -> Board? {
        return try read { db in
            try Board.fetchOne(db, key: id)
        }?.healingDisplayName()
    }

    func saveBoard(_ board: Board) throws {
        try write { db in
            try board.save(db)
        }
    }

    /// Soft-delete a board.
    ///
    /// Increments `version` so LWW treats the deletion as later-wins
    /// against a concurrent update on another device. A soft delete
    /// without a version bump can be overwritten by a stale edit whose
    /// `updatedAt` happens to be newer. Enqueues a `boards` DELETE sync
    /// item so the tombstone reaches Firestore — without this, the
    /// deletion never propagates and the board resurrects (reinstall,
    /// re-auth, or any other device that never saw the local tombstone).
    /// Does NOT cascade to BoardTask placements — see
    /// `deleteDraftWithCascade` for the draft-only cascading variant.
    ///
    /// Board Sources §Member rules (B2, RB5) — the board's window-stamped
    /// derived rows go with it, once nothing else holds them: a derived
    /// counter/compound left behind by its last board is a row the user never
    /// authored, pointing at a window that no longer has a board. One still
    /// placed on another LIVE board survives. The board's OWN `board_tasks`
    /// rows stay as they are (see above) — the sweep's candidate query reads
    /// tombstoned placements too, so it does not depend on that. The board
    /// tombstone and the derived cascade share one transaction so a mid-flight
    /// failure can't leave retired tasks under a live board.
    func deleteBoard(id: String) throws {
        try write { db in
            guard var board = try Board.fetchOne(db, key: id) else { return }
            let now = Self.currentTimestamp()
            board.isDeleted = true
            board.deletedAt = now
            board.updatedAt = now
            board.version += 1
            try board.update(db)
            try SyncQueueBuilder.makeItem(
                entityType: "boards",
                entityId: id,
                operationType: .delete,
                payload: board,
                now: now
            ).enqueue(db)

            // After the tombstone, so the "live placement" test excludes this board.
            let orphaned = try Self.windowStampedDerivedOrphanedByBoard(db: db, boardId: id)
            try Self.softDeleteWindowStampedDerived(db: db, taskIds: orphaned, now: now)
        }
    }

    /// Move an ACTIVE board to the `.archived` status.
    ///
    /// Mirrors the pattern of `deleteBoard(id:)` + `updateBoardAndCascade`:
    ///   - Mutates status, bumps version, writes `updatedAt`.
    ///   - Enqueues a `boards` UPDATE item in the sync queue so the change
    ///     propagates to Firestore (and thence to other devices) on the next
    ///     sync pass.
    ///   - Does NOT touch BoardTask rows — placements stay intact so the board
    ///     appears correctly in the archive view.
    ///
    /// Caller is responsible for any pre-confirmation UI (e.g., the alert in
    /// `BoardEditPanel`).
    func archiveBoard(id: String) throws {
        try write { db in
            guard var board = try Board.fetchOne(db, key: id) else { return }
            let now = Self.currentTimestamp()
            board.status = .archived
            board.updatedAt = now
            board.version += 1
            try board.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "boards",
                entityId: id,
                operationType: .update,
                payload: board,
                now: now
            ).enqueue(db)
        }
    }

    /// Delete a DRAFT board and its attached BoardTask placements atomically.
    ///
    /// Used by the Create Hub's drafts-list delete affordance (per-row
    /// `xmark` button gated behind a confirmation `Alert`). Soft-deletes
    /// the Board AND its BoardTask placements (Board-integrity PR-1,
    /// docs/BOARD_INTEGRITY.md — BoardTask placement removal is a tombstone
    /// now, matching the Board itself). Both happen inside one GRDB write
    /// transaction so a mid-flight failure rolls back instead of leaving
    /// orphan live BoardTask rows pointing at a soft-deleted Board.
    ///
    /// Helper is draft-only by design — throws if called with a
    /// non-DRAFT board so misuse from a future caller surfaces loudly
    /// rather than silently destroying ACTIVE/COMPLETED placements.
    /// For "delete an active board", use `deleteBoard(id:)` (which
    /// leaves BoardTask rows in place).
    ///
    /// Caller is responsible for confirming the user wants the deletion.
    /// Web twin: `deleteDraftWithCascade` in `apps/web/src/db/operations/boards.ts`.
    func deleteDraftWithCascade(id: String) throws {
        try write { db in
            guard var board = try Board.fetchOne(db, key: id) else { return }
            guard board.status == .draft else {
                throw DatabaseError(
                    message: "deleteDraftWithCascade: board \(id) has status \"\(board.status.rawValue)\", not \"draft\". " +
                    "Use deleteBoard(id:) for non-draft boards."
                )
            }
            let now = Self.currentTimestamp()

            let placements = try BoardTask
                .filter(Column("boardId") == id && Column("isDeleted") == false)
                .fetchAll(db)
            for var bt in placements {
                bt.isDeleted = true
                bt.deletedAt = now
                bt.updatedAt = now
                bt.version += 1
                try bt.update(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "boardTasks",
                    entityId: bt.id,
                    operationType: .delete,
                    payload: bt,
                    now: now
                ).enqueue(db)
            }

            board.isDeleted = true
            board.deletedAt = now
            board.updatedAt = now
            board.version += 1
            try board.update(db)
            try SyncQueueBuilder.makeItem(
                entityType: "boards",
                entityId: id,
                operationType: .delete,
                payload: board,
                now: now
            ).enqueue(db)
        }
    }

    // MARK: - Board metadata edit helpers (M2 — live-edit board metadata)

    /// Editable fields for an ACTIVE board (M2).
    ///
    /// Immutable on active boards:
    ///   - `boardSize` — render as read-only chip (too disruptive to change).
    ///   - `isCore`, `spawnedFromTemplateId`, `isRandomized` — internal state.
    ///   - Placement set (`BoardTask` rows) — M3/M4.
    ///
    /// NOTE (center-switch asymmetry): switching CHOSEN → FREE preserves the
    /// underlying `BoardTask` row; the board.centerTaskId column is cleared
    /// so the cell renders as FREE on top, but the placement is retained in
    /// case the user switches back. Do not treat this as a bug.
    struct UpdateActiveBoardPatch {
        var name: String?
        var timeframe: Timeframe?
        /// Local-ISO8601 snap to 00:00:00.000 start-of-day (via `wizardLocalISOString`).
        var startDate: String?
        /// Local-ISO8601 snap to 23:59:59.999 end-of-day (via `wizardLocalISOString`).
        var endDate: String?
        /// Explicitly clear the board's `endDate` (convert to an indefinite /
        /// ongoing board). A plain `endDate == nil` means "leave unchanged" —
        /// this flag is the distinct "remove the deadline" signal, since a nil
        /// value alone can't express clearing. Setting `timeframe = .indefinite`
        /// also forces the clear (see `updateBoardAndCascade`).
        var clearEndDate: Bool
        var centerSquareType: CenterSquareType?
        /// Only meaningful when `centerSquareType == .chosen`.
        var centerTaskId: String?

        init(
            name: String? = nil,
            timeframe: Timeframe? = nil,
            startDate: String? = nil,
            endDate: String? = nil,
            clearEndDate: Bool = false,
            centerSquareType: CenterSquareType? = nil,
            centerTaskId: String? = nil
        ) {
            self.name = name
            self.timeframe = timeframe
            self.startDate = startDate
            self.endDate = endDate
            self.clearEndDate = clearEndDate
            self.centerSquareType = centerSquareType
            self.centerTaskId = centerTaskId
        }
    }

    /// Apply a metadata patch to an ACTIVE board and re-derive stats for
    /// every placed task.
    ///
    /// Sequence:
    ///   1. Apply the patch atomically (bumps version, enqueues boards sync).
    ///   2. Sanitize center-square auxiliary fields (clear centerTaskId for
    ///      non-CHOSEN types).
    ///   3. Fetch every `BoardTask` that places a task on this board.
    ///   4. Run `Self.runBoardCascadeForTask` for each unique placed task
    ///      inside the same write transaction.
    ///
    /// Per-task cascade (not per-board) is deliberate: timeframe/dates changes
    /// can flip expiry state on placed tasks, and each task's derivation reads
    /// from board.timeframe + board.endDate. Mirrors the web-side
    /// `updateBoardAndCascade` in `apps/web/src/db/operations/boards.ts`.
    ///
    /// NOTE on renaming: references to this board (Achievement tasks,
    /// recurring-template spawn records) are always by id, so renaming is
    /// safe with no additional propagation. Renaming does NOT update the
    /// spawning template name or historical spawn names.
    ///
    /// - Parameters:
    ///   - boardId: Board to update.
    ///   - patch: Editable fields for ACTIVE boards.
    func updateBoardAndCascade(boardId: String, patch: UpdateActiveBoardPatch) throws {
        try write { db in
            try Self.updateBoardAndCascade(db: db, boardId: boardId, patch: patch)
        }
    }

    /// `db`-scoped core of `updateBoardAndCascade` — Board-integrity PR-4 (Item 3,
    /// docs/BOARD_INTEGRITY.md): lets `BoardPlayViewModel.handleEditSave` compose
    /// this cascade with the other Save sub-ops into ONE outer
    /// `database.write { db in }` transaction. GRDB's `DatabaseQueue.write` is not
    /// reentrant — calling the instance method above (which opens its own
    /// `write { }`) from inside another `write` block traps, so a caller composing
    /// multiple cascades into one transaction must call this `db:`-parameterized
    /// variant directly instead. Identical body to the instance method; the
    /// instance method is now a one-line wrapper so every other call site
    /// (Task detail, Tasks tab, tests) is unaffected.
    ///
    /// Must be called inside an active write transaction covering `boards`,
    /// `boardTasks`, and `syncQueue`.
    static func updateBoardAndCascade(db: Database, boardId: String, patch: UpdateActiveBoardPatch) throws {
            // UI gates Board Edit on `!sealedAt` already, but the DB level
            // must hold too (hardening item 6) — a sealed board's snapshot is
            // a frozen, read-only record, so a metadata edit on a sealed or
            // already-deleted board is a no-op rather than silently writing
            // through.
            guard var board = try Board.fetchOne(db, key: boardId),
                  !board.isDeleted, board.sealedAt == nil else { return }
            let now = Self.currentTimestamp()

            // 1. Apply scalar fields.
            if let n = patch.name { board.name = n }
            if let tf = patch.timeframe { board.timeframe = tf }
            if let sd = patch.startDate { board.startDate = sd }
            // Clear the deadline when explicitly requested or when converting to
            // an indefinite board; otherwise apply a provided endDate. A bare
            // nil endDate (no clear flag) leaves the existing value untouched.
            if patch.clearEndDate || patch.timeframe == .indefinite {
                board.endDate = nil
            } else if let ed = patch.endDate {
                board.endDate = ed
            }

            // 2. Center-square fields with sanitization.
            if let ct = patch.centerSquareType {
                board.centerSquareType = ct
                switch ct {
                case .chosen:
                    // Keep caller-supplied centerTaskId.
                    // NOTE (asymmetry): switching CHOSEN → FREE later will clear
                    // centerTaskId but NOT the BoardTask row, preserving the
                    // placement for a potential future switch back.
                    if let tid = patch.centerTaskId { board.centerTaskId = tid }
                default:
                    // FREE / NONE: clear the auxiliary field.
                    // The BoardTask row (if any) is preserved — only the board-level
                    // reference is cleared.
                    board.centerTaskId = nil
                }
            }

            board.updatedAt = now
            board.version += 1
            try board.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "boards",
                entityId: boardId,
                operationType: .update,
                payload: board,
                now: now
            ).enqueue(db)

            // 3. Batch cascade: load shared tables ONCE, find the union of
            //    affected board IDs across all placed tasks, then write one
            //    stats update per affected board. This replaces the previous
            //    per-task loop which did O(N) full-table scans (one per task
            //    on a 5×5 board = 25 cascade calls). (Copilot review #9)
            let placements = try BoardTask
                .filter(Column("boardId") == boardId && Column("isDeleted") == false)
                .fetchAll(db)
            let taskIds = Array(Set(placements.map { $0.taskId }))

            guard !taskIds.isEmpty else { return }

            let allChildren: [CompoundChild] = try CompoundChild
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
            let allBoardTasks: [BoardTask] = try BoardTask
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
            let allTasks: [Task] = try Task.fetchAll(db)
            let allBoards: [Board] = try Board.fetchAll(db)

            var taskById: [String: Task] = [:]
            for t in allTasks { taskById[t.id] = t }
            var childrenByCompound: [String: [CompoundChild]] = [:]
            for c in allChildren {
                childrenByCompound[c.compoundTaskId, default: []].append(c)
            }

            // Collect the union of all affected board IDs across every placed task.
            var affectedBoardIds = Set<String>()
            for taskId in taskIds {
                let parents = DerivationPass.findTransitiveParentCompounds(
                    changedTaskId: taskId,
                    children: allChildren
                )
                let ids = DerivationPass.findAffectedBoardIds(
                    changedTaskId: taskId,
                    parentCompounds: parents,
                    boardTasks: allBoardTasks
                )
                affectedBoardIds.formUnion(ids)
            }

            // Windowed Completion: resolve each board against its own
            // `[startDate, endDate]` window from the event log, not the lifetime
            // `Task.isCompleted` cache (which would count out-of-window cells
            // into bingo lines → phantom bingos).
            let windowContext = try Self.buildWindowContext(db: db)

            // Update each affected board exactly once.
            for affectedBoardId in affectedBoardIds {
                // Re-fetch to see the just-written metadata update above.
                guard var affectedBoard = try Board.fetchOne(db, key: affectedBoardId),
                      !affectedBoard.isDeleted, affectedBoard.sealedAt == nil else { continue }
                // Board-integrity PR-2 (issue #375): resolve before deriving.
                let boardTasksOnBoard = PlacementIntegrity.resolvedRows(
                    boardId: affectedBoardId, in: allBoardTasks, boardSize: affectedBoard.boardSize
                )
                let update = DerivationPass.computeBoardStatsUpdate(
                    board: affectedBoard,
                    boardTasksOnBoard: boardTasksOnBoard,
                    childrenByCompound: childrenByCompound,
                    taskById: taskById,
                    allBoards: allBoards,
                    windowContext: windowContext
                )

                let totalSquares = affectedBoard.boardSize * affectedBoard.boardSize
                let isGreenlogNow = update.completedTasks >= totalSquares

                affectedBoard.completedTasks = update.completedTasks
                affectedBoard.totalTasks = totalSquares
                affectedBoard.linesCompleted = update.linesCompleted
                affectedBoard.completedLineIds = update.completedLineIds.isEmpty ? nil : update.completedLineIds
                affectedBoard.updatedAt = now
                affectedBoard.version += 1

                if isGreenlogNow, affectedBoard.status == .active {
                    affectedBoard.status = .completed
                    affectedBoard.completedAt = now
                } else if !isGreenlogNow, affectedBoard.status == .completed {
                    affectedBoard.status = .active
                    affectedBoard.completedAt = nil
                }

                try affectedBoard.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "boards",
                    entityId: affectedBoardId,
                    operationType: .update,
                    payload: affectedBoard,
                    now: now
                ).enqueue(db)
            }
    }

    // MARK: - Wizard board persist (B4 — absorbed from BoardWizardPersist)

    /// Core write for a single deferred (Bug #85) pending-task payload: saves
    /// the parent task, any inline-created child tasks, and any
    /// `compound_children` links, enqueuing a sync item for each. Shared by
    /// `saveWizardBoard` (called inline, inside that method's own
    /// transaction — the one-off / draft-resume wizard-save path) and
    /// `writeWizardPendingTasksAndEnqueue` below (its own standalone
    /// transaction — the Task Pools + Recurring Boards Rework P4 unified
    /// persist path, `BoardWizardPersist.persistRecurringTemplate`, which
    /// has no Board row to share a transaction with).
    private static func writePendingTaskPayload(
        _ payload: PendingTaskPayload, db: Database, now: String
    ) throws {
        try payload.task.save(db)
        try SyncQueueBuilder.makeItem(
            entityType: "tasks",
            entityId: payload.task.id,
            operationType: .create,
            payload: payload.task,
            now: now
        ).enqueue(db)
        for childTask in payload.childTasks {
            try childTask.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: childTask.id,
                operationType: .create,
                payload: childTask,
                now: now
            ).enqueue(db)
        }
        for link in payload.childLinks {
            try link.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "compoundChildren",
                entityId: link.id,
                operationType: .create,
                payload: link,
                now: now
            ).enqueue(db)
        }
    }

    /// Standalone-transaction variant of the pending-task drain (Bug #85).
    /// `persistRecurringTemplate` (`BoardWizardPersist.swift`) calls this to
    /// write the wizard's in-memory `PendingTaskPayload`s BEFORE it creates
    /// or updates a `RecurringBoardTemplate` — a repeating board has no
    /// single Board row to share a transaction with, and the spawn's
    /// `tasksById` lookup silently drops any id that isn't in GRDB (which
    /// could push the supply below the fillable floor and skip the window).
    ///
    /// Also applies the session's staged inline edits in the SAME
    /// transaction, always (a template has no draft state — when editing an
    /// existing template, the cancel dialog's "Save Draft" calls the same
    /// path). Per-type handling matches
    /// `saveWizardBoard`:
    ///   • compound (library OR pending) — parent-field + child/link CRUD via
    ///     `applyStagedCompoundChildEdits`, then `saveTaskAndCascade`. A
    ///     pending compound's rows already exist (the drain runs first).
    ///   • simple/counting — a PENDING one is pre-merged into its payload by
    ///     the caller and skipped here via `pendingIds`; a LIBRARY one is
    ///     applied via `saveTaskAndCascade`.
    ///
    /// - Parameters:
    ///   - pendingTasks: The FULL set of pending payloads whose task is in
    ///     the wizard's final `selectedTaskIds` (not a placement-based
    ///     subset — a repeating board's future windows draw from the whole
    ///     pool, not just what's on today's spawned board). Simple/counting
    ///     payloads should already carry any staged edit merged in (see
    ///     `persistRecurringTemplate`); compound payloads are edited here.
    ///   - stagedEdits: The wizard's full `controller.stagedEdits` snapshot
    ///     (keyed by taskId). A task leaving the pool always purges its
    ///     staged edit (`toggleTaskSelection` /
    ///     `recomputeSelectionFromSources`), so every remaining key is still
    ///     in `selectedTaskIds` — no extra filtering needed, matching the
    ///     one-off path's unfiltered application.
    ///   - now: ISO8601 timestamp for the sync-queue rows.
    func writeWizardPendingTasksAndEnqueue(
        _ pendingTasks: [PendingTaskPayload],
        stagedEdits: [String: TaskEditPatch] = [:],
        now: String
    ) throws {
        try write { db in
            for payload in pendingTasks {
                try Self.writePendingTaskPayload(payload, db: db, now: now)
            }

            guard !stagedEdits.isEmpty else { return }
            let pendingIds = Set(pendingTasks.map { $0.task.id })
            for (taskId, patch) in stagedEdits {
                guard var task = try Task.fetchOne(db, key: taskId) else { continue }
                // Defensive: never persist an invalid edit (the UI blocks
                // Save, but a stale draft shouldn't corrupt the row).
                guard patch.validate(type: task.type) == nil else { continue }
                if task.type == .compound {
                    // An ineligible newly linked existing task skips the whole
                    // edit (never half-applied), exactly like an invalid patch.
                    guard try Self.compoundLinkProblem(db: db, parentId: taskId, patch: patch) == nil else { continue }
                    task = patch.applied(to: task)
                    task.version += 1
                    task.updatedAt = now
                    try Self.applyStagedCompoundChildEdits(db: db, parent: task, patch: patch, now: now)
                    try Self.saveTaskAndCascade(db: db, task: task)
                } else {
                    // simple/counting: a pending task's edit is merged into
                    // its payload already by the caller, so skip it here;
                    // apply library-task edits.
                    if pendingIds.contains(taskId) { continue }
                    task = patch.applied(to: task)
                    task.version += 1
                    task.updatedAt = now
                    try Self.saveTaskAndCascade(db: db, task: task)
                }
            }
        }
    }

    /// Persist a wizard-built board in a single atomic transaction: any
    /// deferred (Bug #85) pending tasks that are actually placed, then any
    /// staged inline task edits (active create only), then the `Board` row + its
    /// `BoardTask` rows — plus all matching `SyncQueueItem` records — commit or
    /// roll back together. Without the sync items the board stays local-only
    /// (`SyncService.pushSync` reads exclusively from `sync_queue`), so every
    /// write path enqueues one.
    ///
    /// Moved VERBATIM from `BoardWizardPersist.persistWizardBoard`'s write
    /// block so the sync-enqueue lives in the data layer, not the view-layer
    /// helper. The caller resolves the board dict, placement rows, the
    /// placed-only pending payloads, and the staged edits before invoking.
    ///
    /// Bug #85: pending tasks are written FIRST (before board_tasks) so the
    /// referential integrity of task → board_task is never violated even
    /// during a crash mid-write (the txn rolls back).
    ///
    /// - Parameters:
    ///   - board: The resolved `Board` row to insert/update.
    ///   - boardTasks: The per-cell `BoardTask` placement rows to insert.
    ///   - pendingTasks: Placed-only deferred payloads (parent + inline
    ///     children + links) to write first.
    ///   - stagedEdits: Inline task edits to apply (active create only); see the
    ///     staged-edits block below for per-type handling.
    ///   - isUpdate: `true` when updating an existing draft (old placements
    ///     are soft-deleted (tombstoned) + DELETE-enqueued first); `false` for
    ///     fresh create.
    ///   - sources: Board Sources §Member rules (B2) — the wizard's pulled
    ///     sources, used to re-resolve each placed member's rules and mint the
    ///     window-stamped derived rows they call for. Empty = nothing to mint.
    ///   - manualTaskIds: The hand-added layer (B2); hand-added members beat
    ///     any source copy in the plan.
    ///   - manualTaskVary: §Member rules (B3) — dice for hand-added counting
    ///     members, keyed by task id. Empty = nothing varies on that layer.
    ///   - now: ISO8601 timestamp for the sync-queue rows.
    func saveWizardBoard(
        board: Board,
        boardTasks: [BoardTask],
        pendingTasks: [PendingTaskPayload],
        stagedEdits: [String: TaskEditPatch] = [:],
        isUpdate: Bool,
        sources: [BoardSource] = [],
        manualTaskIds: [String] = [],
        manualTaskVary: [String: VaryLevel] = [:],
        now: String
    ) throws {
        try write { db in
            // ── Bug #85: pending tasks (placed-only) ───────────────
            for payload in pendingTasks {
                try Self.writePendingTaskPayload(payload, db: db, now: now)
            }

            // ── Staged inline edits (Inline Task Editing) ──────────
            // ONLY on an active board create — a draft must never carry a task
            // edit (invariant: TaskEditPatch / docs/INLINE_TASK_EDITING.md).
            // Runs BEFORE the derivation pass below so a changed counting goal
            // feeds into stored stats. Edits are GLOBAL (same Task on every
            // board), so each mutation goes through saveTaskAndCascade — save +
            // sync enqueue + re-derive every OTHER board / parent compound that
            // shares the Task, in this same transaction. A bare save (no cascade)
            // would leave those boards' cached bingo/greenlog stats stale until
            // the app-open self-heal. Per-type handling:
            //   • compound (library OR pending) — the compound branch owns the
            //     full apply (parent fields + child/link CRUD). Pending compounds
            //     are NOT pre-merged in persistWizardBoard, so this is their one
            //     and only apply; their rows already exist (pending loop above).
            //   • simple/counting — a PENDING one was already merged into its
            //     payload (persistWizardBoard), so skip it here; apply LIBRARY ones.
            if board.status == .active {
                let pendingIds = Set(pendingTasks.map { $0.task.id })
                for (taskId, patch) in stagedEdits {
                    guard var task = try Task.fetchOne(db, key: taskId) else { continue }
                    // Defensive: never persist an invalid edit (the UI blocks
                    // Save, but a stale draft shouldn't corrupt the row).
                    guard patch.validate(type: task.type) == nil else { continue }
                    if task.type == .compound {
                        // An ineligible newly linked existing task skips the
                        // whole edit (never half-applied), like an invalid patch.
                        guard try Self.compoundLinkProblem(db: db, parentId: taskId, patch: patch) == nil else { continue }
                        // Parent fields + child/link CRUD. Works for library AND
                        // pending compounds — the pending loop above already wrote
                        // the pending compound's rows, so they're real rows here.
                        task = patch.applied(to: task)
                        task.version += 1
                        task.updatedAt = now
                        try Self.applyStagedCompoundChildEdits(db: db, parent: task, patch: patch, now: now)
                        try Self.saveTaskAndCascade(db: db, task: task)
                    } else {
                        // simple/counting: a pending task's edit was merged into
                        // its payload already (persistWizardBoard), so skip it
                        // here; apply library-task edits.
                        if pendingIds.contains(taskId) { continue }
                        task = patch.applied(to: task)
                        task.version += 1
                        task.updatedAt = now
                        try Self.saveTaskAndCascade(db: db, task: task)
                    }
                }
            }

            // ── Board Sources §Member rules (B2): mint before placing ──────
            // Each placed member is resolved against THIS board's window; a
            // member governed by a rule is replaced IN PLACE by its
            // window-stamped derived counter (or derived compound), so a
            // pinned/centre square keeps its cell. The rows are written here,
            // before the `board_tasks` rows that reference them, in this txn.
            //
            // ACTIVE SAVES ONLY. A derived id is `uuidv5(boardId, root)` — it
            // does NOT encode the window — while a DRAFT's window is still
            // editable: save a draft weekly, resume it, switch it to daily,
            // save it active, and RB3's "live row → skip" would keep the first
            // row's timeframe / dates / target / baseline for a window the
            // board no longer has. A draft therefore places its original member
            // ids and the activating save derives the window once, from final
            // values. (An abandoned draft then leaves no derived rows at all.)
            var boardToSave = board
            var placedRows = boardTasks
            if board.status == .active, !placedRows.isEmpty {
                let placementIds = try Self.mintWizardDerivedRows(
                    db: db,
                    boardId: board.id,
                    userId: board.userId,
                    now: now,
                    selectedIds: placedRows.map { $0.taskId },
                    sources: sources,
                    manualTaskIds: manualTaskIds,
                    manualTaskVary: manualTaskVary,
                    window: BoardSources.BoardWindow(
                        timeframe: board.timeframe,
                        startDate: board.startDate,
                        endDate: board.endDate
                    )
                )
                // Two members sharing a shared-counter root collapse onto ONE
                // derived counter. Counter-family exclusivity forbids that at
                // selection time, so this is belt-and-braces — but a duplicate
                // `taskId` on one board trips the placement-integrity
                // invariants (docs/BOARD_INTEGRITY.md), so the repeat cell is
                // dropped rather than written.
                //
                // The invariant this trades away, stated plainly: the board
                // comes out one square short, against "boards are always
                // exactly filled". Throwing would be worse (a save the user
                // cannot complete), so the guard drops the cell and LOGS — the
                // log is the only signal that the unreachable path fired, and
                // it exists on both platforms (web `console.warn`s here).
                var seenTaskIds = Set<String>()
                var deduped: [BoardTask] = []
                for (index, var row) in placedRows.enumerated() {
                    if index < placementIds.count { row.taskId = placementIds[index] }
                    guard seenTaskIds.insert(row.taskId).inserted else {
                        #if DEBUG
                        dlog("saveWizardBoard: task \(row.taskId) resolved twice on board \(board.id); leaving cell \(index) empty")
                        #endif
                        continue
                    }
                    deduped.append(row)
                }
                placedRows = deduped
                // A CHOSEN centre that resolved to a derived counter must have
                // the board's stored `centerTaskId` follow it, or a resumed
                // draft would stop recognising its own centre square.
                if let centre = board.centerTaskId,
                   let index = boardTasks.firstIndex(where: { $0.taskId == centre }),
                   index < placementIds.count {
                    boardToSave.centerTaskId = placementIds[index]
                }
            }

            // ── Board + BoardTask rows ─────────────────────────────
            // Windowed Completion — stamp the activation instant on an active
            // wizard board (fresh-active OR a resumed draft saved active) if not
            // already set, so the auto-seal backstop keys off max(endDate,
            // activatedAt) (docs §Sealing → backstop).
            if boardToSave.status == .active, boardToSave.activatedAt == nil {
                boardToSave.activatedAt = now
            }

            // Windowed Completion (docs/WINDOWED_COMPLETION.md §What this
            // closes — respawn-bleed row): run the derivation pass over the
            // just-built placements so stored stats are derivation output,
            // never a hand-init. `persistWizardBoard` seeds `completedTasks:
            // 0` / `linesCompleted: 0` (or preserves the prior draft's value
            // on update) — this overwrites that with the real value. Without
            // it, a board placing an already-in-window-complete task (or a
            // FREE center) would persist + sync wrong stats until
            // the next app-open self-heal. Covers both fresh creation AND
            // draft→active resume — both flow through this one function, and
            // `activatedAt` above is already stamped by the time this runs.
            // Mirrors the recurring-spawn path
            // (`AppDatabase+RecurringTemplates.swift`) exactly, including
            // reading `allBoards` BEFORE this board is inserted (same as
            // spawn — an achievement referencing this board-in-progress is a
            // same-transaction chicken-and-egg case neither path handles).
            // Status logic is deliberately untouched here — a fresh board
            // with a bingo from shared tasks legitimately shows those lines;
            // status transitions stay the live-cascade's job.
            let windowContext = try AppDatabase.buildWindowContext(db: db)
            let allChildrenForDerivation = try CompoundChild
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
            var childrenByCompound: [String: [CompoundChild]] = [:]
            for c in allChildrenForDerivation {
                childrenByCompound[c.compoundTaskId, default: []].append(c)
            }
            let allTasksForDerivation = try Task.fetchAll(db)
            var taskById: [String: Task] = [:]
            for t in allTasksForDerivation { taskById[t.id] = t }
            let allBoardsForDerivation = try Board
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
            let stats = DerivationPass.computeBoardStatsUpdate(
                board: boardToSave,
                boardTasksOnBoard: placedRows,
                childrenByCompound: childrenByCompound,
                taskById: taskById,
                allBoards: allBoardsForDerivation,
                windowContext: windowContext
            )
            boardToSave.completedTasks = stats.completedTasks
            boardToSave.linesCompleted = stats.linesCompleted
            boardToSave.completedLineIds = stats.completedLineIds.isEmpty ? nil : stats.completedLineIds

            try boardToSave.save(db)

            let boardSyncOp: SyncOperationType = isUpdate ? .update : .create
            try SyncQueueBuilder.makeItem(
                entityType: "boards",
                entityId: board.id,
                operationType: boardSyncOp,
                payload: boardToSave,
                now: now
            ).enqueue(db)

            if isUpdate {
                // Board-integrity PR-1 (tombstones): the wizard doesn't diff
                // old vs new layout — it always rewrites the full placement
                // set. SOFT-delete every existing LIVE row (isDeleted, bumped
                // version) rather than a literal SQL DELETE, so an
                // already-synced device sees a tombstone win LWW instead of a
                // hard-deleted row that a stale remote pull could resurrect.
                // The fresh `boardTasks` rows below always carry NEW ids
                // (`BoardWizardPersist` mints them per save), so there's no
                // id collision between the old tombstones and the new rows.
                let oldBoardTasks = try BoardTask
                    .filter(Column("boardId") == board.id && Column("isDeleted") == false)
                    .fetchAll(db)
                for var old in oldBoardTasks {
                    old.isDeleted = true
                    old.deletedAt = now
                    old.updatedAt = now
                    old.version += 1
                    try old.update(db)
                    try SyncQueueBuilder.makeItem(
                        entityType: "boardTasks",
                        entityId: old.id,
                        operationType: .delete,
                        payload: old,
                        now: now
                    ).enqueue(db)
                }
            }

            // Board-integrity PR-5 (Item 3) — isCenter uniqueness guard.
            // Nothing upstream enforced single-center uniqueness before this:
            // `makeWizardBoardTaskRows` only ever computes ONE positional
            // center per placement today, but a future caller or placement
            // bug could otherwise slip a SECOND `isCenter: true` row onto
            // this board at a different cell. Fresh in-txn read (mirrors the
            // `addBoardTaskToBoard` PR-2 guard idiom) — for a fresh create
            // this is always 0; for a draft update the old rows were just
            // tombstoned above, so it's also 0 today, but the read (rather
            // than trusting that invariant) is what makes this guard survive
            // a future change to the update path. Mirrors web's
            // `createBoardTask` guard (the wizard write loop's per-cell
            // equivalent — see docs/BOARD_INTEGRITY.md).
            var liveCenterCount = try BoardTask
                .filter(Column("boardId") == board.id
                        && Column("isDeleted") == false
                        && Column("isCenter") == true)
                .fetchCount(db)
            for bt in placedRows {
                if bt.isCenter {
                    guard liveCenterCount == 0 else {
                        throw AppDatabaseError.invalidPlacement(
                            "Board already has a center placement."
                        )
                    }
                    liveCenterCount += 1
                }
                try bt.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "boardTasks",
                    entityId: bt.id,
                    operationType: .create,
                    payload: bt,
                    now: now
                ).enqueue(db)
            }
        }
    }

}
