import Foundation
import GRDB

extension AppDatabase {
    // MARK: - BoardTasks

    func fetchBoardTasks(boardId: String) throws -> [BoardTask] {
        return try read { db in
            try BoardTask
                .filter(Column("boardId") == boardId)
                .fetchAll(db)
        }
    }

    func fetchBoardTask(id: String) throws -> BoardTask? {
        return try read { db in
            try BoardTask.fetchOne(db, key: id)
        }
    }

    /// Fetch every `BoardTask` row that references a specific Task. Used
    /// by the Task detail view to list "placed on N boards" and by the
    /// cascade-delete impact preview.
    func fetchBoardTasksForTask(taskId: String) throws -> [BoardTask] {
        return try read { db in
            try BoardTask
                .filter(Column("taskId") == taskId)
                .fetchAll(db)
        }
    }

    /// Hard-deletes every `BoardTask` row for the given board. Used
    /// when re-saving a draft whose task placement has changed —
    /// simpler than diffing old vs new layout, and tolerable at scale
    /// (boards have at most 25 cells).
    ///
    /// `BoardTask` has no `isDeleted` flag, so the deletion is literal;
    /// the web twin uses the same pattern.
    func deleteBoardTasksForBoard(boardId: String) throws {
        try write { db in
            _ = try BoardTask
                .filter(Column("boardId") == boardId)
                .deleteAll(db)
        }
    }

    func saveBoardTask(_ boardTask: BoardTask) throws {
        try write { db in
            try boardTask.save(db)
        }
    }

    // MARK: - updateBoardTaskAndCascade (M3 — live-edit cell swap)

    /// Patch a BoardTask's `taskId` (cell swap) and re-derive stats for every board
    /// affected by either the OLD task or the NEW task.
    ///
    /// Design mirrors `saveTaskAndCascade` (M1) and the batched cascade in
    /// `updateBoardAndCascade` (M2/PR #95):
    ///   1. Validate + no-op guard (swap to same task returns immediately).
    ///   2. Apply the taskId patch atomically (bumps version, enqueues boardTask sync).
    ///   3. Compute the union of affected board IDs across both old and new tasks,
    ///      using pre- and post-patch boardTask snapshots.
    ///   4. Re-derive stats + GREENLOG transitions for each affected board (one pass).
    ///
    /// Counter-overshoot invariant: this function never clamps `currentCount`.
    /// The derivation delegates to `DerivationPass.computeBoardStatsUpdate` which
    /// reads `task.isCompleted` — the actual count value on the Task row is untouched.
    ///
    /// - Parameters:
    ///   - boardTaskId: The `BoardTask.id` placement record to update.
    ///   - newTaskId: The new `Task.id` to write into `BoardTask.taskId`.
    /// - Throws: GRDB write errors.
    func updateBoardTaskAndCascade(boardTaskId: String, newTaskId: String) throws {
        try write { db in
            guard var boardTask = try BoardTask.fetchOne(db, key: boardTaskId) else { return }

            let oldTaskId = boardTask.taskId
            // No-op guard: swapping to the same task writes nothing.
            guard oldTaskId != newTaskId else { return }

            let now = Self.currentTimestamp()

            // ── Pre-patch workspace snapshot (for old-task cascade side) ──

            let allChildren: [CompoundChild] = try CompoundChild
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
            let allBoardTasksPre: [BoardTask] = try BoardTask.fetchAll(db)

            // ── Apply the boardTask patch ──

            boardTask.taskId = newTaskId
            boardTask.updatedAt = now
            boardTask.version += 1
            try boardTask.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "boardTasks",
                entityId: boardTaskId,
                operationType: .update,
                payload: boardTask,
                now: now
            ).enqueue(db)

            // ── Post-patch workspace snapshot (for new-task cascade side) ──

            let allBoardTasksPost: [BoardTask] = try BoardTask.fetchAll(db)
            let allTasks: [Task] = try Task.fetchAll(db)
            let allBoards: [Board] = try Board.fetchAll(db)

            var taskById: [String: Task] = [:]
            for t in allTasks { taskById[t.id] = t }
            var childrenByCompound: [String: [CompoundChild]] = [:]
            for c in allChildren {
                childrenByCompound[c.compoundTaskId, default: []].append(c)
            }

            // ── Compute union of affected board IDs ──

            let oldParents = DerivationPass.findTransitiveParentCompounds(
                changedTaskId: oldTaskId, children: allChildren
            )
            let oldAffected = DerivationPass.findAffectedBoardIds(
                changedTaskId: oldTaskId,
                parentCompounds: oldParents,
                boardTasks: allBoardTasksPre
            )

            let newParents = DerivationPass.findTransitiveParentCompounds(
                changedTaskId: newTaskId, children: allChildren
            )
            let newAffected = DerivationPass.findAffectedBoardIds(
                changedTaskId: newTaskId,
                parentCompounds: newParents,
                boardTasks: allBoardTasksPost
            )

            let affectedBoardIds = Set(oldAffected).union(newAffected)

            // ── One derivation pass per affected board ──

            // Windowed Completion: resolve each board against its own
            // `[startDate, ∞)` window from the event log, not the lifetime
            // `Task.isCompleted` cache (which would count out-of-window cells
            // into bingo lines → phantom bingos).
            let windowContext = try Self.buildWindowContext(db: db)

            for affectedBoardId in affectedBoardIds {
                guard var affectedBoard = try Board.fetchOne(db, key: affectedBoardId),
                      !affectedBoard.isDeleted, affectedBoard.sealedAt == nil else { continue }

                let boardTasksOnBoard = allBoardTasksPost.filter { $0.boardId == affectedBoardId }
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
    }

    /// Fetch every BoardTask in the workspace. Used by the derivation pass
    /// to find which boards contain a given task (directly or via a compound).
    /// Small-N: typical user has under a few thousand BoardTasks.
    func fetchAllBoardTasks() throws -> [BoardTask] {
        return try read { db in
            try BoardTask.fetchAll(db)
        }
    }

    // MARK: - Phase 3 — Rearrange commit op

    /// A single position move produced by the Rearrange sub-mode.
    struct BoardTaskPositionMove: Sendable {
        /// The `BoardTask.id` whose grid position changed.
        let boardTaskId: String
        /// New 0-based grid row.
        let row: Int
        /// New 0-based grid column.
        let col: Int
    }

    /// Writes new `row`/`col` for each moved `BoardTask` row atomically, then
    /// re-derives the board's positional bingo lines (`completedLineIds` /
    /// `linesCompleted`) in the same transaction.
    ///
    /// Design principles:
    ///   - **Atomic**: all moves + bingo re-derive land in ONE `write { db in … }`
    ///     block — no two rows transiently collide on the same `(row, col)` from
    ///     the perspective of any external reader.
    ///   - **Bingo-only re-derive**: rearranging doesn't change Task completion
    ///     state, so `completedTasks` stays constant; only the positional line
    ///     detection (`completedLineIds` / `linesCompleted`) needs a fresh pass.
    ///     `DerivationPass.computeBoardStatsUpdate` recomputes both — the pass is
    ///     cheap for boards ≤ 5×5 and keeps the logic in one canonical place.
    ///   - **Global Task completion untouched**: `Task.isCompleted` / `currentCount`
    ///     are never read or written here.
    ///   - **Sync queue**: one `boardTasks` UPDATE is enqueued per moved row + one
    ///     `boards` UPDATE for the updated bingo state.
    ///   - **Empty `moves` list**: returns immediately (no-op).
    ///
    /// - Parameters:
    ///   - boardId: The board whose tiles are being reordered.
    ///   - moves: Array of `(boardTaskId, row, col)` tuples — only cells that
    ///     actually changed position should be included (callers compare against
    ///     original positions; sending unchanged rows is harmless but wasteful).
    func updateBoardTaskPositions(
        boardId: String,
        moves: [BoardTaskPositionMove]
    ) throws {
        guard !moves.isEmpty else { return }

        let now = Self.currentTimestamp()

        try write { db in
            // ── 1. Apply position patches ──
            for move in moves {
                guard var boardTask = try BoardTask.fetchOne(db, key: move.boardTaskId),
                      boardTask.boardId == boardId else { continue }
                boardTask.row = move.row
                boardTask.col = move.col
                // `isCenter` follows the center-square-type rule set by the board,
                // not the position. Center is fixed and never in the moves list.
                boardTask.updatedAt = now
                boardTask.version += 1
                try boardTask.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "boardTasks",
                    entityId: move.boardTaskId,
                    operationType: .update,
                    payload: boardTask,
                    now: now
                ).enqueue(db)
            }

            // ── 2. Re-derive bingo lines for this board ──
            // Only one board is affected — the one being rearranged.
            guard var board = try Board.fetchOne(db, key: boardId),
                  !board.isDeleted else { return }

            let allBoardTasksPost: [BoardTask] = try BoardTask.fetchAll(db)
            let allTasks: [Task] = try Task.fetchAll(db)
            let allBoards: [Board] = try Board.fetchAll(db)
            let allChildren: [CompoundChild] = try CompoundChild
                .filter(Column("isDeleted") == false)
                .fetchAll(db)

            var taskById: [String: Task] = [:]
            for t in allTasks { taskById[t.id] = t }
            var childrenByCompound: [String: [CompoundChild]] = [:]
            for c in allChildren {
                childrenByCompound[c.compoundTaskId, default: []].append(c)
            }

            // Windowed Completion: resolve against this board's window from the
            // event log, not the lifetime cache (see updateBoardTaskAndCascade).
            let windowContext = try Self.buildWindowContext(db: db)

            let boardTasksOnBoard = allBoardTasksPost.filter { $0.boardId == boardId }
            let update = DerivationPass.computeBoardStatsUpdate(
                board: board,
                boardTasksOnBoard: boardTasksOnBoard,
                childrenByCompound: childrenByCompound,
                taskById: taskById,
                allBoards: allBoards,
                windowContext: windowContext
            )

            // Rearranging cannot change which tasks are completed, so
            // `completedTasks` is stable. The line-detection geometry changes
            // (a completed task may now be in a different row/col), so update
            // the positional bingo fields unconditionally.
            board.linesCompleted = update.linesCompleted
            board.completedLineIds = update.completedLineIds.isEmpty
                ? nil
                : update.completedLineIds
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
        }
    }

    // MARK: - M4 Live-Edit: Placement Add / Remove

    /// Remove a single BoardTask placement from an ACTIVE board (live-edit M4).
    ///
    /// Semantics mirror the web `removeBoardTaskFromBoard`:
    ///   - Hard-deletes the BoardTask row (BoardTask has no isDeleted field;
    ///     consistent with `deleteBoardTasksForBoard`).
    ///   - Enqueues a DELETE sync tombstone.
    ///   - Runs the batched cascade for every board affected by the removed task
    ///     (directly or via a compound parent), re-deriving stats + status.
    ///
    /// The underlying Task is NOT touched. It stays in the library and on any
    /// other boards where it appears. Only this board loses the placement.
    ///
    /// - Parameter boardTaskId: The `BoardTask.id` placement record to remove.
    func removeBoardTaskFromBoard(_ boardTaskId: String) throws {
        guard let existing = try fetchBoardTask(id: boardTaskId) else { return }
        let now = AppDatabase.currentTimestamp()
        let removedTaskId = existing.taskId

        let allBoardTasksPre = try fetchAllBoardTasks()
        let allCompoundChildrenPre = try fetchAllCompoundChildren()

        let parentCompounds = DerivationPass.findTransitiveParentCompounds(
            changedTaskId: removedTaskId,
            children: allCompoundChildrenPre
        )
        let affectedBoardIds = DerivationPass.findAffectedBoardIds(
            changedTaskId: removedTaskId,
            parentCompounds: parentCompounds,
            boardTasks: allBoardTasksPre
        )

        try write { db in
            try BoardTask.deleteOne(db, key: boardTaskId)

            try SyncQueueBuilder.makeItem(
                entityType: "boardTasks",
                entityId: boardTaskId,
                operationType: .delete,
                payload: existing,
                now: now
            ).enqueue(db)

            let allBoardTasksPost: [BoardTask] = try BoardTask.fetchAll(db)
            let allTasks: [Task] = try Task.fetchAll(db)
            let allBoards: [Board] = try Board.fetchAll(db)
            let allChildren: [CompoundChild] = try CompoundChild
                .filter(Column("isDeleted") == false)
                .fetchAll(db)

            var taskById: [String: Task] = [:]
            for t in allTasks { taskById[t.id] = t }
            var childrenByCompound: [String: [CompoundChild]] = [:]
            for c in allChildren {
                childrenByCompound[c.compoundTaskId, default: []].append(c)
            }

            // Windowed Completion: resolve against each board's window from the
            // event log, not the lifetime cache (see updateBoardTaskAndCascade).
            let windowContext = try Self.buildWindowContext(db: db)

            for boardId in affectedBoardIds {
                guard var board = try Board.fetchOne(db, key: boardId), !board.isDeleted, board.sealedAt == nil else { continue }
                let boardTasksOnBoard = allBoardTasksPost.filter { $0.boardId == boardId }
                let update = DerivationPass.computeBoardStatsUpdate(
                    board: board,
                    boardTasksOnBoard: boardTasksOnBoard,
                    childrenByCompound: childrenByCompound,
                    taskById: taskById,
                    allBoards: allBoards,
                    windowContext: windowContext
                )

                let totalSquares = board.boardSize * board.boardSize
                let isGreenlogNow = update.completedTasks >= totalSquares

                board.completedTasks = update.completedTasks
                board.totalTasks = totalSquares
                board.linesCompleted = update.linesCompleted
                board.completedLineIds = update.completedLineIds.isEmpty ? nil : update.completedLineIds
                board.updatedAt = now
                board.version += 1

                if isGreenlogNow, board.status == .active {
                    board.status = .completed
                    board.completedAt = now
                } else if !isGreenlogNow, board.status == .completed {
                    board.status = .active
                    board.completedAt = nil
                }

                try board.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "boards",
                    entityId: boardId,
                    operationType: .update,
                    payload: board,
                    now: now
                ).enqueue(db)
            }
        }
    }

    /// Add a Task to an empty cell on an ACTIVE board (live-edit M4).
    ///
    /// Creates a new BoardTask placement at the given grid position and runs the
    /// batched cascade to re-derive stats for every board affected by the placed task.
    ///
    /// Shared-task semantics: if the task is already globally completed, the cascade
    /// immediately counts this cell as completed and increments `board.completedTasks`.
    /// No cloning, no reset.
    ///
    /// - Parameters:
    ///   - boardId: The board receiving the new placement.
    ///   - taskId: The task to place.
    ///   - position: Grid position `(row, col)` (0-based).
    /// - Returns: The newly-created `BoardTask` record.
    @discardableResult
    func addBoardTaskToBoard(_ boardId: String, taskId: String, position: (row: Int, col: Int)) throws -> BoardTask {
        let now = AppDatabase.currentTimestamp()

        let newBoardTask = BoardTask(
            id: AppDatabase.generateUUID(),
            boardId: boardId,
            taskId: taskId,
            row: position.row,
            col: position.col,
            isCenter: false,
            createdAt: now,
            updatedAt: now,
            version: 1
        )

        let allBoardTasksPre = try fetchAllBoardTasks()
        let allCompoundChildrenPre = try fetchAllCompoundChildren()

        let syntheticBoardTasks = allBoardTasksPre + [newBoardTask]
        let parentCompounds = DerivationPass.findTransitiveParentCompounds(
            changedTaskId: taskId,
            children: allCompoundChildrenPre
        )
        let affectedBoardIds = DerivationPass.findAffectedBoardIds(
            changedTaskId: taskId,
            parentCompounds: parentCompounds,
            boardTasks: syntheticBoardTasks
        )

        try write { db in
            try newBoardTask.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "boardTasks",
                entityId: newBoardTask.id,
                operationType: .create,
                payload: newBoardTask,
                now: now
            ).enqueue(db)

            let allBoardTasksPost: [BoardTask] = try BoardTask.fetchAll(db)
            let allTasks: [Task] = try Task.fetchAll(db)
            let allBoards: [Board] = try Board.fetchAll(db)
            let allChildren: [CompoundChild] = try CompoundChild
                .filter(Column("isDeleted") == false)
                .fetchAll(db)

            var taskById: [String: Task] = [:]
            for t in allTasks { taskById[t.id] = t }
            var childrenByCompound: [String: [CompoundChild]] = [:]
            for c in allChildren {
                childrenByCompound[c.compoundTaskId, default: []].append(c)
            }

            // Windowed Completion: resolve against each board's window from the
            // event log, not the lifetime cache (see updateBoardTaskAndCascade).
            let windowContext = try Self.buildWindowContext(db: db)

            for affectedBoardId in affectedBoardIds {
                guard var board = try Board.fetchOne(db, key: affectedBoardId), !board.isDeleted, board.sealedAt == nil else { continue }
                let boardTasksOnBoard = allBoardTasksPost.filter { $0.boardId == affectedBoardId }
                let update = DerivationPass.computeBoardStatsUpdate(
                    board: board,
                    boardTasksOnBoard: boardTasksOnBoard,
                    childrenByCompound: childrenByCompound,
                    taskById: taskById,
                    allBoards: allBoards,
                    windowContext: windowContext
                )

                let totalSquares = board.boardSize * board.boardSize
                let isGreenlogNow = update.completedTasks >= totalSquares

                board.completedTasks = update.completedTasks
                board.totalTasks = totalSquares
                board.linesCompleted = update.linesCompleted
                board.completedLineIds = update.completedLineIds.isEmpty ? nil : update.completedLineIds
                board.updatedAt = now
                board.version += 1

                if isGreenlogNow, board.status == .active {
                    board.status = .completed
                    board.completedAt = now
                } else if !isGreenlogNow, board.status == .completed {
                    board.status = .active
                    board.completedAt = nil
                }

                try board.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "boards",
                    entityId: affectedBoardId,
                    operationType: .update,
                    payload: board,
                    now: now
                ).enqueue(db)
            }
        }

        return newBoardTask
    }

}
