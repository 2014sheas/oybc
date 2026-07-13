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
        }
    }

    /// Fetch boards by id. Used by the task detail view to render
    /// "placed on" links for the cells where this task lives.
    func fetchBoards(ids: [String]) throws -> [Board] {
        guard !ids.isEmpty else { return [] }
        return try read { db in
            try Board
                .filter(ids.contains(Column("id")) && Column("isDeleted") == false)
                .fetchAll(db)
        }
    }

    /// Boards eligible to act as a "source" in the wizard's
    /// `From a board…` filter — active boards plus boards completed
    /// within the last 30 days. Drafts and archived are excluded.
    /// Sorted recently-active first (`updatedAt desc`). Mirror of
    /// web's `useSourceBoards` hook.
    ///
    /// Opens its own `read` block. For callers that already hold a
    /// transaction (e.g., `SourceBoardsViewModel.reload` which also
    /// needs to read board_tasks atomically with the eligibility
    /// list), use `fetchEligibleSourceBoards(_:userId:)` instead so
    /// both queries see one consistent snapshot.
    func fetchEligibleSourceBoards(userId: String) throws -> [Board] {
        try read { db in
            try AppDatabase.fetchEligibleSourceBoards(db, userId: userId)
        }
    }

    /// Transaction-aware variant. Runs the same eligibility filter as
    /// `fetchEligibleSourceBoards(userId:)` but inside the caller's
    /// `read` block so the resulting boards + any subsequent reads
    /// (placements, tasks) share a single snapshot.
    static func fetchEligibleSourceBoards(_ db: Database, userId: String) throws -> [Board] {
        let completedLookbackDays = 30
        let cutoff = Date().addingTimeInterval(
            -Double(completedLookbackDays) * 24 * 60 * 60
        )
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFrac = ISO8601DateFormatter()

        let boards = try Board
            .filter(Column("userId") == userId && Column("isDeleted") == false)
            .order(Column("updatedAt").desc)
            .fetchAll(db)
        return boards.filter { board in
            if board.status == .active { return true }
            guard board.status == .completed else { return false }
            guard let completedAt = board.completedAt else { return false }
            // ISO8601 strings round-trip from JS (fractional) and Swift
            // (no fractional). Try both parsers so we don't reject valid
            // timestamps from either platform.
            let parsed = isoFormatter.date(from: completedAt)
                ?? isoFormatterNoFrac.date(from: completedAt)
            guard let ts = parsed else { return false }
            return ts >= cutoff
        }
    }

    func fetchBoard(id: String) throws -> Board? {
        return try read { db in
            try Board.fetchOne(db, key: id)
        }
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
    /// `updatedAt` happens to be newer.
    func deleteBoard(id: String) throws {
        try write { db in
            guard var board = try Board.fetchOne(db, key: id) else { return }
            let now = Self.currentTimestamp()
            board.isDeleted = true
            board.deletedAt = now
            board.updatedAt = now
            board.version += 1
            try board.update(db)
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
    /// the Board (sync queue carries the tombstone) and hard-deletes the
    /// BoardTask rows (BoardTask has no isDeleted flag — placement removal
    /// is always a literal delete; see `deleteBoardTasksForBoard`). Both
    /// happen inside one GRDB write transaction so a mid-flight failure
    /// rolls back instead of leaving orphan BoardTask rows pointing at a
    /// soft-deleted Board.
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
                .filter(Column("boardId") == id)
                .fetchAll(db)
            for bt in placements {
                try bt.delete(db)
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
    /// NOTE (center-switch asymmetry): switching CHOSEN → FREE/CUSTOM_FREE
    /// preserves the underlying `BoardTask` row; the board.centerTaskId column
    /// is cleared so the cell renders as FREE on top, but the placement is
    /// retained in case the user switches back. Do not treat this as a bug.
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
        /// Only meaningful when `centerSquareType == .customFree`.
        var centerSquareCustomName: String?
        /// Only meaningful when `centerSquareType == .chosen`.
        var centerTaskId: String?

        init(
            name: String? = nil,
            timeframe: Timeframe? = nil,
            startDate: String? = nil,
            endDate: String? = nil,
            clearEndDate: Bool = false,
            centerSquareType: CenterSquareType? = nil,
            centerSquareCustomName: String? = nil,
            centerTaskId: String? = nil
        ) {
            self.name = name
            self.timeframe = timeframe
            self.startDate = startDate
            self.endDate = endDate
            self.clearEndDate = clearEndDate
            self.centerSquareType = centerSquareType
            self.centerSquareCustomName = centerSquareCustomName
            self.centerTaskId = centerTaskId
        }
    }

    /// Apply a metadata patch to an ACTIVE board and re-derive stats for
    /// every placed task.
    ///
    /// Sequence:
    ///   1. Apply the patch atomically (bumps version, enqueues boards sync).
    ///   2. Sanitize center-square auxiliary fields (clear centerTaskId for
    ///      non-CHOSEN types; clear centerSquareCustomName for non-CUSTOM_FREE).
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
            guard var board = try Board.fetchOne(db, key: boardId) else { return }
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
                case .customFree:
                    // Keep caller-supplied custom name; clear any stale centerTaskId.
                    board.centerSquareCustomName = patch.centerSquareCustomName
                    board.centerTaskId = nil
                case .chosen:
                    // Keep caller-supplied centerTaskId; clear custom name.
                    // NOTE (asymmetry): switching CHOSEN → FREE/CUSTOM_FREE later
                    // will clear centerTaskId but NOT the BoardTask row, preserving
                    // the placement for a potential future switch back.
                    if let tid = patch.centerTaskId { board.centerTaskId = tid }
                    board.centerSquareCustomName = nil
                default:
                    // FREE / NONE: clear both auxiliary fields.
                    // The BoardTask row (if any) is preserved — only the board-level
                    // reference is cleared.
                    board.centerSquareCustomName = nil
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
                .filter(Column("boardId") == boardId)
                .fetchAll(db)
            let taskIds = Array(Set(placements.map { $0.taskId }))

            guard !taskIds.isEmpty else { return }

            let allChildren: [CompoundChild] = try CompoundChild
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
            let allBoardTasks: [BoardTask] = try BoardTask.fetchAll(db)
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

            // Update each affected board exactly once.
            for affectedBoardId in affectedBoardIds {
                // Re-fetch to see the just-written metadata update above.
                guard var affectedBoard = try Board.fetchOne(db, key: affectedBoardId),
                      !affectedBoard.isDeleted, affectedBoard.sealedAt == nil else { continue }
                let boardTasksOnBoard = allBoardTasks.filter { $0.boardId == affectedBoardId }
                let update = DerivationPass.computeBoardStatsUpdate(
                    board: affectedBoard,
                    boardTasksOnBoard: boardTasksOnBoard,
                    childrenByCompound: childrenByCompound,
                    taskById: taskById,
                    allBoards: allBoards
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
    }

    // MARK: - Wizard board persist (B4 — absorbed from BoardWizardPersist)

    /// Persist a wizard-built board in a single atomic transaction: any
    /// deferred (Bug #85) pending tasks that are actually placed, then the
    /// `Board` row + its `BoardTask` rows — plus all matching `SyncQueueItem`
    /// records — commit or roll back together. Without the sync items the
    /// board stays local-only (`SyncService.pushSync` reads exclusively from
    /// `sync_queue`), so every write path below enqueues one.
    ///
    /// Moved VERBATIM from `BoardWizardPersist.persistWizardBoard`'s write
    /// block so the sync-enqueue lives in the data layer, not the view-layer
    /// helper. The caller resolves the board dict, placement rows, and the
    /// placed-only pending payloads before invoking.
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
    ///   - isUpdate: `true` when updating an existing draft (old placements
    ///     are hard-deleted + DELETE-enqueued first); `false` for fresh create.
    ///   - now: ISO8601 timestamp for the sync-queue rows.
    func saveWizardBoard(
        board: Board,
        boardTasks: [BoardTask],
        pendingTasks: [PendingTaskPayload],
        isUpdate: Bool,
        now: String
    ) throws {
        try write { db in
            // ── Bug #85: pending tasks (placed-only) ───────────────
            for payload in pendingTasks {
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

            // ── Board + BoardTask rows ─────────────────────────────
            // Windowed Completion — stamp the activation instant on an active
            // wizard board (fresh-active OR a resumed draft saved active) if not
            // already set, so the auto-seal backstop keys off max(endDate,
            // activatedAt) (docs §Sealing → backstop).
            var boardToSave = board
            if boardToSave.status == .active, boardToSave.activatedAt == nil {
                boardToSave.activatedAt = now
            }
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
                // Snapshot the existing BoardTasks before deleting
                // so each gets a matching DELETE sync item whose
                // payload reflects the row that actually existed.
                let oldBoardTasks = try BoardTask
                    .filter(Column("boardId") == board.id)
                    .fetchAll(db)
                _ = try BoardTask
                    .filter(Column("boardId") == board.id)
                    .deleteAll(db)
                for old in oldBoardTasks {
                    try SyncQueueBuilder.makeItem(
                        entityType: "boardTasks",
                        entityId: old.id,
                        operationType: .delete,
                        payload: old,
                        now: now
                    ).enqueue(db)
                }
            }

            for bt in boardTasks {
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
