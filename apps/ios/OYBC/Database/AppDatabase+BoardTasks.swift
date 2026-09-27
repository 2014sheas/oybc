import Foundation
import GRDB

extension AppDatabase {
    // MARK: - BoardTasks

    /// Board-integrity PR-2 (Part 2): stable `(row, col, id)` ordering at
    /// the SQL layer so every reader of a board's raw placement rows sees
    /// the same array order — matching `PlacementIntegrity.resolvePlacements`'s
    /// own sort, so composing an already-ordered fetch with the resolver is
    /// a no-op re-sort rather than a behavior change.
    func fetchBoardTasks(boardId: String) throws -> [BoardTask] {
        return try read { db in
            try BoardTask
                .filter(Column("boardId") == boardId && Column("isDeleted") == false)
                .order(Column("row"), Column("col"), Column("id"))
                .fetchAll(db)
        }
    }

    /// Fetch a single `BoardTask` by id, regardless of `isDeleted`. Internal
    /// cascade helpers (`updateBoardTaskAndCascade`, `updateBoardTaskPositions`,
    /// `removeBoardTaskFromBoard`) look up a row they already have the id for —
    /// including a not-yet-tombstoned row mid-cascade — so this intentionally
    /// does NOT filter tombstones, mirroring `fetchTask(id:)` / `fetchBoard(id:)`.
    func fetchBoardTask(id: String) throws -> BoardTask? {
        return try read { db in
            try BoardTask.fetchOne(db, key: id)
        }
    }

    /// Fetch every LIVE `BoardTask` row that references a specific Task. Used
    /// by the Task detail view to list "placed on N boards" and by the
    /// cascade-delete impact preview.
    func fetchBoardTasksForTask(taskId: String) throws -> [BoardTask] {
        return try read { db in
            try BoardTask
                .filter(Column("taskId") == taskId && Column("isDeleted") == false)
                .fetchAll(db)
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
            try Self.updateBoardTaskAndCascade(db: db, boardTaskId: boardTaskId, newTaskId: newTaskId)
        }
    }

    /// `db`-scoped core of `updateBoardTaskAndCascade` — Board-integrity PR-4
    /// (Item 3, docs/BOARD_INTEGRITY.md): lets `BoardPlayViewModel.handleEditSave`
    /// compose this cascade with the other Save sub-ops into ONE outer
    /// `database.write { db in }` transaction (GRDB's `write` is not reentrant, so
    /// the instance method above can't be called from inside another `write`
    /// block). Identical body to the instance method.
    ///
    /// Must be called inside an active write transaction covering `boardTasks`,
    /// `boards`, and `syncQueue`.
    static func updateBoardTaskAndCascade(db: Database, boardTaskId: String, newTaskId: String) throws {
            // Tombstone guard: a placement deleted on another device mid-edit
            // must not be resurrected/mutated by a stale swap (PR-1 review).
            guard var boardTask = try BoardTask.fetchOne(db, key: boardTaskId),
                  !boardTask.isDeleted else { return }

            // Board-integrity PR-2 (Part 4): re-fetch the OWNING board
            // inside the write txn — a sealed board's snapshot is a frozen,
            // read-only record, so a swap on a just-sealed board (mid-
            // session) must not mutate its placement. Matches the #357
            // guard idiom in `updateBoardAndCascade` / `updateBoardTaskPositions`.
            guard let owningBoard = try Board.fetchOne(db, key: boardTask.boardId),
                  !owningBoard.isDeleted, owningBoard.sealedAt == nil else { return }

            let oldTaskId = boardTask.taskId
            // No-op guard: swapping to the same task writes nothing.
            guard oldTaskId != newTaskId else { return }

            let now = Self.currentTimestamp()

            // ── Pre-patch workspace snapshot (for old-task cascade side) ──

            let allChildren: [CompoundChild] = try CompoundChild
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
            let allBoardTasksPre: [BoardTask] = try BoardTask
                .filter(Column("isDeleted") == false)
                .fetchAll(db)

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

            let allBoardTasksPost: [BoardTask] = try BoardTask
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
            // `[startDate, endDate]` window from the event log, not the lifetime
            // `Task.isCompleted` cache (which would count out-of-window cells
            // into bingo lines → phantom bingos).
            let windowContext = try Self.buildWindowContext(db: db)

            for affectedBoardId in affectedBoardIds {
                guard var affectedBoard = try Board.fetchOne(db, key: affectedBoardId),
                      !affectedBoard.isDeleted, affectedBoard.sealedAt == nil else { continue }

                // Board-integrity PR-2 (Part 2): resolve collisions/OOB
                // before deriving, so a corrupted (pre-repair or sealed-
                // exempt) board's stats agree with what the same resolver
                // shows the user in `btByPosition`/`seedEditDraft`.
                let boardTasksOnBoard = PlacementIntegrity.resolvePlacements(
                    allBoardTasksPost.filter { $0.boardId == affectedBoardId },
                    boardSize: affectedBoard.boardSize
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

    /// Fetch every LIVE BoardTask in the workspace. Used by the derivation
    /// pass to find which boards contain a given task (directly or via a
    /// compound). Small-N: typical user has under a few thousand BoardTasks.
    func fetchAllBoardTasks() throws -> [BoardTask] {
        return try read { db in
            try BoardTask
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
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
        try write { db in
            try Self.updateBoardTaskPositions(db: db, boardId: boardId, moves: moves)
        }
    }

    /// Board Edit redesign slice 1 (docs/BOARD_EDIT_REDESIGN.md) — sets a
    /// placement's per-square lock. A locked placement never changes
    /// position (`updateBoardTaskPositions` rejects a move set that relocates
    /// one) but stays completable.
    ///
    /// Sync: one `boardTasks` UPDATE (version bump) is enqueued; no board
    /// stats are re-derived — a lock never affects completion or bingo lines.
    /// Silent no-op (matching the sibling placement writes) when the row is
    /// deleted, the owning board is deleted or sealed, or the value is
    /// unchanged.
    ///
    /// - Parameters:
    ///   - boardTaskId: The `BoardTask.id` placement record to lock / unlock.
    ///   - locked: The new lock state.
    /// - Throws: GRDB write errors.
    func setBoardTaskLocked(boardTaskId: String, locked: Bool) throws {
        try write { db in
            try Self.setBoardTaskLocked(db: db, boardTaskId: boardTaskId, locked: locked)
        }
    }

    /// `db`-scoped core of `setBoardTaskLocked` — lets
    /// `BoardPlayViewModel.handleEditSave` compose it into the ONE outer
    /// `database.write { db in }` Save transaction (GRDB's `write` is not
    /// reentrant). Identical body to the instance method.
    ///
    /// Must be called inside an active write transaction covering `boardTasks`,
    /// `boards`, and `syncQueue`.
    static func setBoardTaskLocked(db: Database, boardTaskId: String, locked: Bool) throws {
        guard var boardTask = try BoardTask.fetchOne(db, key: boardTaskId),
              !boardTask.isDeleted else { return }
        guard let owningBoard = try Board.fetchOne(db, key: boardTask.boardId),
              !owningBoard.isDeleted, owningBoard.sealedAt == nil else { return }
        guard boardTask.isLocked != locked else { return }

        let now = Self.currentTimestamp()
        boardTask.isLocked = locked
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
    }

    /// `db`-scoped core of `updateBoardTaskPositions` — Board-integrity PR-4
    /// (Item 3, docs/BOARD_INTEGRITY.md): lets `BoardPlayViewModel.handleEditSave`
    /// compose this cascade with the other Save sub-ops into ONE outer
    /// `database.write { db in }` transaction (GRDB's `write` is not reentrant, so
    /// the instance method above can't be called from inside another `write`
    /// block). Identical body to the instance method (including the empty-`moves`
    /// no-op guard, now evaluated inside the shared transaction rather than
    /// short-circuiting before one is opened).
    ///
    /// Must be called inside an active write transaction covering `boardTasks`
    /// and `boards`/`syncQueue`.
    static func updateBoardTaskPositions(
        db: Database,
        boardId: String,
        moves: [BoardTaskPositionMove]
    ) throws {
        guard !moves.isEmpty else { return }

        // Board Edit redesign slice 1 (docs/BOARD_EDIT_REDESIGN.md): a LOCKED
        // placement never changes position. The whole move set is rejected
        // BEFORE any row is written — nothing partial — so a stale draft
        // that would relocate a locked square (locked on another device
        // mid-edit, or a UI that failed to pin it) can't land half a
        // rearrange. The Rearrange grid treats locked cells like the pinned
        // center, so this is the DB-level backstop for that UI rule.
        for move in moves {
            guard let locked = try BoardTask.fetchOne(db, key: move.boardTaskId),
                  locked.isLocked, !locked.isDeleted else { continue }
            if locked.row != move.row || locked.col != move.col {
                throw AppDatabaseError.invalidPlacement("Locked squares can't be moved.")
            }
        }

        let now = Self.currentTimestamp()

            // Board-integrity PR-2 (Part 3): resolve the board's size up
            // front so each staged move can be bounds-checked before it's
            // applied. A missing board falls through with `nil` — the
            // moves proceed unchecked, matching the existing "position
            // write is unguarded either way" posture documented on the
            // sealed-board test below for a board this call can't find.
            let boardSizeForBounds = try Board.fetchOne(db, key: boardId)?.boardSize

            // ── 1. Apply position patches ──
            for move in moves {
                // Tombstone guard mirrors updateBoardTaskAndCascade (PR-1 review).
                guard var boardTask = try BoardTask.fetchOne(db, key: move.boardTaskId),
                      boardTask.boardId == boardId,
                      !boardTask.isDeleted else { continue }
                // Board-integrity PR-2 (Part 3): reject an out-of-bounds
                // staged target — skip the move rather than writing a
                // corrupt row (defense-in-depth; the Rearrange grid UI
                // can't produce one by construction).
                if let size = boardSizeForBounds,
                   move.row < 0 || move.row >= size || move.col < 0 || move.col >= size {
                    continue
                }
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
            // Only one board is affected — the one being rearranged. UI
            // gates rearrange on an unsealed/live board already, but the DB
            // level must hold too (hardening item 6) — a sealed board's
            // snapshot is a frozen, read-only record and must never be
            // overwritten by a stats recompute.
            guard var board = try Board.fetchOne(db, key: boardId),
                  !board.isDeleted, board.sealedAt == nil else { return }

            let allBoardTasksPost: [BoardTask] = try BoardTask
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
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

            // Board-integrity PR-2 (Part 2): resolve collisions/OOB before
            // deriving (see updateBoardTaskAndCascade).
            let boardTasksOnBoard = PlacementIntegrity.resolvePlacements(
                allBoardTasksPost.filter { $0.boardId == boardId },
                boardSize: board.boardSize
            )
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

    // MARK: - M4 Live-Edit: Placement Add / Remove

    /// Remove a single BoardTask placement from an ACTIVE board (live-edit M4).
    ///
    /// Board-integrity PR-1 (tombstones, docs/BOARD_INTEGRITY.md): SOFT-
    /// deletes the BoardTask row — `isDeleted = true`, `deletedAt`/`updatedAt`
    /// stamped, `version` bumped — mirroring every other synced collection
    /// (`deleteBoard`, `CompoundChild`'s soft-delete in `deleteTaskWithCascadeInDb`).
    /// The row STAYS in the local table as a tombstone; only the LIVE-filtered
    /// readers (`fetchBoardTasks`, `fetchAllBoardTasks`, …) stop seeing it.
    ///
    /// The version bump is load-bearing for LWW: bumping BEFORE enqueue means
    /// the tombstone's version is strictly greater than whatever this device
    /// last pushed, so it beats an already-synced remote row on the next pull
    /// — closing the self-restore hole where a same-version conflict tie used
    /// to let the push loop's "remote wins" branch `table.put` the row back
    /// locally within one sync cycle.
    ///
    /// Sequence:
    ///   - Soft-delete the BoardTask row.
    ///   - Enqueue a DELETE sync item whose payload is the POST-mutation
    ///     tombstone (carries `isDeleted: true`) — mirrors how `deleteTaskWithCascadeInDb`
    ///     enqueues soft-deleted CompoundChild links.
    ///   - Runs the batched cascade for every board affected by the removed task
    ///     (directly or via a compound parent), re-deriving stats + status.
    ///
    /// The underlying Task is NOT touched. It stays in the library and on any
    /// other boards where it appears. Only this board loses the placement.
    ///
    /// - Parameter boardTaskId: The `BoardTask.id` placement record to remove.
    func removeBoardTaskFromBoard(_ boardTaskId: String) throws {
        try write { db in
            try Self.removeBoardTaskFromBoard(db: db, boardTaskId: boardTaskId)
        }
    }

    /// `db`-scoped core of `removeBoardTaskFromBoard` — Board-integrity PR-4
    /// (Item 3, docs/BOARD_INTEGRITY.md): lets `BoardPlayViewModel.handleEditSave`
    /// compose this cascade with the other Save sub-ops into ONE outer
    /// `database.write { db in }` transaction. GRDB's `write` (and `read`) are not
    /// reentrant, so the instance method above — which used to fetch `existing` /
    /// `allBoardTasksPre` / `allCompoundChildrenPre` via separate `read {}` calls
    /// BEFORE opening its own `write {}` — can't have those pre-reads called from
    /// inside another already-open `write` block either. They're folded into this
    /// transaction (against the passed `db`) instead — a strict atomicity
    /// improvement over the original (which had a read-then-write gap an
    /// interleaved write from another thread/device could race).
    ///
    /// Must be called inside an active write transaction covering `boardTasks`
    /// and `boards`/`syncQueue`.
    static func removeBoardTaskFromBoard(db: Database, boardTaskId: String) throws {
        guard var existing = try BoardTask.fetchOne(db, key: boardTaskId), !existing.isDeleted else { return }
        let now = AppDatabase.currentTimestamp()
        let removedTaskId = existing.taskId

        let allBoardTasksPre: [BoardTask] = try BoardTask
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allCompoundChildrenPre: [CompoundChild] = try CompoundChild
            .filter(Column("isDeleted") == false)
            .fetchAll(db)

        let parentCompounds = DerivationPass.findTransitiveParentCompounds(
            changedTaskId: removedTaskId,
            children: allCompoundChildrenPre
        )
        let affectedBoardIds = DerivationPass.findAffectedBoardIds(
            changedTaskId: removedTaskId,
            parentCompounds: parentCompounds,
            boardTasks: allBoardTasksPre
        )

            // Board-integrity PR-2 (Part 4): re-fetch the OWNING board
            // inside the write txn — a sealed board's placements are part
            // of its frozen record and must not be removed out from under
            // it. Matches the #357 guard idiom in `updateBoardAndCascade` /
            // `updateBoardTaskPositions`.
            guard let owningBoard = try Board.fetchOne(db, key: existing.boardId),
                  !owningBoard.isDeleted, owningBoard.sealedAt == nil else { return }

            existing.isDeleted = true
            existing.deletedAt = now
            existing.updatedAt = now
            existing.version += 1
            try existing.update(db)

            try SyncQueueBuilder.makeItem(
                entityType: "boardTasks",
                entityId: boardTaskId,
                operationType: .delete,
                payload: existing,
                now: now
            ).enqueue(db)

            let allBoardTasksPost: [BoardTask] = try BoardTask
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
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
                // Board-integrity PR-2 (Part 2): resolve collisions/OOB
                // before deriving (see updateBoardTaskAndCascade).
                let boardTasksOnBoard = PlacementIntegrity.resolvePlacements(
                    allBoardTasksPost.filter { $0.boardId == boardId },
                    boardSize: board.boardSize
                )
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
    func addBoardTaskToBoard(
        _ boardId: String,
        taskId: String,
        position: (row: Int, col: Int),
        isLocked: Bool = false
    ) throws -> BoardTask {
        try write { db in
            try Self.addBoardTaskToBoard(
                db: db, boardId: boardId, taskId: taskId, position: position, isLocked: isLocked
            )
        }
    }

    /// `db`-scoped core of `addBoardTaskToBoard` (Board Edit slice 3, D15): lets
    /// the squares Save compose a staged add into its ONE outer
    /// `database.write { db in }` transaction (GRDB's `write` is not reentrant).
    /// The pre-reads that seed the affected-board search run against the passed
    /// `db`, so the whole add — guards, insert, cascade — is atomic.
    ///
    /// Must be called inside an active write transaction covering `boardTasks`,
    /// `boards`, and `syncQueue`.
    ///
    /// - Parameters:
    ///   - db: The open write transaction.
    ///   - boardId: The board receiving the new placement.
    ///   - taskId: The task to place.
    ///   - position: Grid position `(row, col)` (0-based).
    ///   - isLocked: Initial lock state of the new placement (a staged add can
    ///     carry a lock from the draft).
    /// - Returns: The newly-created `BoardTask` record.
    /// - Throws: `AppDatabaseError.invalidPlacement` for a closed / missing
    ///   board, an out-of-bounds or occupied cell, or a duplicate task; GRDB errors.
    @discardableResult
    static func addBoardTaskToBoard(
        db: Database,
        boardId: String,
        taskId: String,
        position: (row: Int, col: Int),
        isLocked: Bool = false
    ) throws -> BoardTask {
        let now = AppDatabase.currentTimestamp()

        let newBoardTask = BoardTask(
            id: AppDatabase.generateUUID(),
            boardId: boardId,
            taskId: taskId,
            row: position.row,
            col: position.col,
            isCenter: false,
            isLocked: isLocked,
            createdAt: now,
            updatedAt: now,
            version: 1
        )

        let allBoardTasksPre: [BoardTask] = try BoardTask
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allCompoundChildrenPre: [CompoundChild] = try CompoundChild
            .filter(Column("isDeleted") == false)
            .fetchAll(db)

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

        // Board-integrity PR-2 (Part 4): re-fetch the OWNING board
        // inside the write txn — a sealed/deleted/missing board
        // refuses a new placement. Matches the #357 guard idiom in
        // `updateBoardAndCascade` / `updateBoardTaskPositions`.
        guard let owningBoard = try Board.fetchOne(db, key: boardId),
              !owningBoard.isDeleted, owningBoard.sealedAt == nil else {
            throw AppDatabaseError.invalidPlacement("This board is closed or no longer exists.")
        }

        // Board-integrity PR-2 (Part 3): reject placements that would
        // violate the placement invariants. Checked against the board's
        // LIVE rows (`allBoardTasksPre` above only seeds the
        // affected-board-id search).
        guard position.row >= 0, position.row < owningBoard.boardSize,
              position.col >= 0, position.col < owningBoard.boardSize else {
            throw AppDatabaseError.invalidPlacement("Position is out of bounds for this board.")
        }
        let liveOnBoard = try BoardTask
            .filter(Column("boardId") == boardId && Column("isDeleted") == false)
            .fetchAll(db)
        guard !liveOnBoard.contains(where: { $0.row == position.row && $0.col == position.col }) else {
            throw AppDatabaseError.invalidPlacement("That cell is already occupied.")
        }
        guard !liveOnBoard.contains(where: { $0.taskId == taskId }) else {
            throw AppDatabaseError.invalidPlacement("This task is already placed on this board.")
        }

        try newBoardTask.save(db)
        try SyncQueueBuilder.makeItem(
            entityType: "boardTasks",
            entityId: newBoardTask.id,
            operationType: .create,
            payload: newBoardTask,
            now: now
        ).enqueue(db)

        let allBoardTasksPost: [BoardTask] = try BoardTask
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
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
            // Board-integrity PR-2 (Part 2): resolve collisions/OOB
            // before deriving (see updateBoardTaskAndCascade).
            let boardTasksOnBoard = PlacementIntegrity.resolvePlacements(
                allBoardTasksPost.filter { $0.boardId == affectedBoardId },
                boardSize: board.boardSize
            )
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

        return newBoardTask
    }


    // MARK: - Legacy CHOSEN center (Board Edit slice 3)

    /// One-time AUTHORED conversion of a legacy CHOSEN board (slice 3, D2).
    ///
    /// Live code already reads CHOSEN as "NONE + a locked center placement"
    /// via `CenterSquare.effectiveCenter` / `isLegacyChosenCenterLocked` (D1);
    /// this writes that shape to disk when the user's next squares Save commits
    /// an edit: the board becomes `.none` with no `centerTaskId` (the same
    /// sanitization `updateBoardAndCascade` applies), and the live placement at
    /// the positional center gets `isLocked = keepLocked, isCenter = false`.
    /// Each changed row gets a version bump + one sync-queue item. No stats
    /// cascade: CHOSEN and NONE derive identically (neither auto-completes).
    ///
    /// No-op unless the stored row is CHOSEN. Never touches a sealed row:
    /// `assertBoardEditable` runs first and throws. Must be called inside an
    /// active write transaction covering `boards`, `boardTasks`, `syncQueue`.
    ///
    /// Twin of web `normalizeLegacyChosenCenter` (`db/operations/boardTasks.ts`).
    ///
    /// - Parameters:
    ///   - db: The open write transaction.
    ///   - boardId: The board being saved.
    ///   - keepLocked: The draft's lock state for the center placement.
    /// - Throws: `BoardEditError.boardNotEditable` for a sealed / deleted /
    ///   missing board (nothing written); any GRDB error.
    static func normalizeLegacyChosenCenter(db: Database, boardId: String, keepLocked: Bool) throws {
        try Self.assertBoardEditable(db: db, boardId: boardId)
        guard var board = try Board.fetchOne(db, key: boardId),
              CenterSquare.isLegacyChosen(board.centerSquareType) else { return }

        let now = Self.currentTimestamp()
        board.centerSquareType = .none
        board.centerTaskId = nil
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

        let centerIndex = CenterSquare.getCenterSquareIndex(gridSize: board.boardSize)
        guard centerIndex >= 0 else { return }
        let centerRow = centerIndex / board.boardSize
        let centerCol = centerIndex % board.boardSize
        guard var center = try BoardTask
            .filter(Column("boardId") == boardId && Column("isDeleted") == false)
            .filter(Column("row") == centerRow && Column("col") == centerCol)
            .fetchOne(db)
        else { return }

        center.isLocked = keepLocked
        center.isCenter = false
        center.updatedAt = now
        center.version += 1
        try center.save(db)
        try SyncQueueBuilder.makeItem(
            entityType: "boardTasks",
            entityId: center.id,
            operationType: .update,
            payload: center,
            now: now
        ).enqueue(db)
    }
}
