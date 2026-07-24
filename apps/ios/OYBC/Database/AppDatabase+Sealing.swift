import Foundation
import GRDB

// MARK: - Board sealing data layer
//
// Swift twin of `apps/web/src/db/operations/sealing.ts` (Windowed Completion,
// docs/WINDOWED_COMPLETION.md §Sealing). Three surfaces:
//   - `sealBoard` — the seal transaction (user Seal + migration + backstop):
//     stamp `sealedAt`, freeze the snapshot from the event union, bump
//     `version`, enqueue Board sync. Idempotent.
//   - `runBackstopAutoSeal` — the lazy app-open backstop check: seal every board
//     past its timeframe-scaled deadline via `sealBoardTx`.
//   - `reDeriveSealedBoards` — the pull-path re-derivation hook: late pre-seal
//     events for a placed task deterministically re-derive an affected sealed
//     board's frozen snapshot. Local-only (no version bump / enqueue).
//
// The frozen snapshot is a pure function of the events in `[startDate,
// sealedAt]`. We bound the upper end explicitly (events with `occurredAt >
// sealedAt` belong to the NEXT window's board and must never leak into a sealed
// record — the exact cross-window bleed this design prevents). Since
// `resolveTaskWindowState` has only a start bound, the upper bound is applied by
// pre-filtering events.

extension AppDatabase {

    /// The lookups the shared derivation kernel needs, loaded once. The event
    /// map is ALL non-deleted events grouped by taskId (unbounded on the upper
    /// end); callers apply their own upper bound per board.
    struct SealLookups {
        let childrenByCompound: [String: [CompoundChild]]
        let taskById: [String: Task]
        let allBoards: [Board]
        let allBoardTasks: [BoardTask]
        let allChildren: [CompoundChild]
        let eventsByTaskId: [String: [TaskEvent]]
    }

    /// Load workspace lookups + a full non-deleted-event map within `db`.
    static func loadSealLookups(db: Database) throws -> SealLookups {
        let allChildren = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
        let allBoardTasks = try BoardTask.fetchAll(db)
        let allTasks = try Task.fetchAll(db)
        let allBoards = try Board.fetchAll(db)
        let events = try TaskEvent.filter(Column("isDeleted") == false).fetchAll(db)

        var eventsByTaskId: [String: [TaskEvent]] = [:]
        for e in events { eventsByTaskId[e.taskId, default: []].append(e) }
        var taskById: [String: Task] = [:]
        for t in allTasks { taskById[t.id] = t }
        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in allChildren { childrenByCompound[c.compoundTaskId, default: []].append(c) }

        return SealLookups(
            childrenByCompound: childrenByCompound,
            taskById: taskById,
            allBoards: allBoards,
            allBoardTasks: allBoardTasks,
            allChildren: allChildren,
            eventsByTaskId: eventsByTaskId
        )
    }

    /// Build a windowed-evaluation context bounded to `occurredAt <= sealedAtMs`
    /// (the `[startDate, sealedAt]` window). At seal time `sealedAtMs = now`, so
    /// nothing is dropped; the filter matters for re-derivation.
    private static func boundedWindowContext(
        eventsByTaskId: [String: [TaskEvent]],
        sealedAtMs: Double
    ) -> WindowEvaluationContext {
        var bounded: [String: [TaskEvent]] = [:]
        for (taskId, evs) in eventsByTaskId {
            let kept = evs.filter {
                guard let occurred = DateFormatting.parseISO($0.occurredAt) else { return false }
                return occurred.timeIntervalSince1970 * 1000 <= sealedAtMs
            }
            if !kept.isEmpty { bounded[taskId] = kept }
        }
        return WindowEvaluationContext(eventsByTaskId: bounded)
    }

    /// The frozen fields written to a sealed board row.
    struct SealSnapshot {
        let completedTasks: Int
        let linesCompleted: Int
        let completedLineIds: [String]
        let sealedCompletedCells: [Int]
    }

    /// Compute the frozen snapshot for `board` from the event union bounded at
    /// `sealedAtMs` (docs §Seal snapshots re-derive). Deterministic: same
    /// converged union → same snapshot on any device.
    static func computeSealSnapshot(board: Board, lookups: SealLookups, sealedAtMs: Double) -> SealSnapshot {
        let boardTasksOnBoard = lookups.allBoardTasks.filter { $0.boardId == board.id }
        let windowContext = boundedWindowContext(eventsByTaskId: lookups.eventsByTaskId, sealedAtMs: sealedAtMs)
        let stats = DerivationPass.computeBoardStatsUpdate(
            board: board,
            boardTasksOnBoard: boardTasksOnBoard,
            childrenByCompound: lookups.childrenByCompound,
            taskById: lookups.taskById,
            allBoards: lookups.allBoards,
            windowContext: windowContext
        )
        let cells = DerivationPass.computeSealedCompletedCells(
            board: board,
            boardTasksOnBoard: boardTasksOnBoard,
            childrenByCompound: lookups.childrenByCompound,
            taskById: lookups.taskById,
            allBoards: lookups.allBoards,
            windowContext: windowContext
        )
        return SealSnapshot(
            completedTasks: stats.completedTasks,
            linesCompleted: stats.linesCompleted,
            completedLineIds: stats.completedLineIds,
            sealedCompletedCells: cells
        )
    }

    /// Deterministic sealed board-status transition, mirroring the LIVE cascade's
    /// completion predicate (`isGreenlogNow = completedTasks >= boardSize²`;
    /// greenlog + active → completed; !greenlog + completed → active). Twin of
    /// web's `applySealedStatus`.
    ///
    /// Without this, a board sealed while `.active` whose FINAL completing event
    /// only arrives (via pull) after the seal re-derives to fully-complete stats
    /// yet stays frozen `.active` forever — and a greenlog-trigger ACHIEVEMENT
    /// (which gates on `status == .completed`) never fires. This is derivation
    /// OUTPUT inside the deterministic pull path, so it does not violate "sealed
    /// boards only mutate via deterministic pull-path re-derivation" — it IS that
    /// path.
    ///
    /// `completedAtTs` is the seal instant (`board.sealedAt`), NOT wall-clock, so
    /// every device computes the same status/completedAt from the same converged
    /// event union — no LWW/version race. Returns the resolved (status,
    /// completedAt); unchanged inputs return the board's current values.
    static func resolveSealedStatus(
        board: Board,
        snapshot: SealSnapshot,
        completedAtTs: String
    ) -> (status: BoardStatus, completedAt: String?) {
        let isGreenlog = snapshot.completedTasks >= board.boardSize * board.boardSize
        if isGreenlog && board.status == .active {
            return (.completed, completedAtTs)
        } else if !isGreenlog && board.status == .completed {
            return (.active, nil)
        }
        return (board.status, board.completedAt)
    }

    /// Core seal within an existing transaction (docs §Sealing → Lifecycle step
    /// 3). Idempotent — already-sealed / missing / deleted boards are a no-op.
    ///
    /// - Returns: `true` if the board was sealed by this call.
    @discardableResult
    static func sealBoardTx(db: Database, boardId: String, now: String) throws -> Bool {
        guard var board = try Board.fetchOne(db, key: boardId),
              !board.isDeleted, board.sealedAt == nil else { return false }

        let lookups = try loadSealLookups(db: db)
        let sealedAtMs = (DateFormatting.parseISO(now)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000
        let snapshot = computeSealSnapshot(board: board, lookups: lookups, sealedAtMs: sealedAtMs)

        board.sealedAt = now
        board.sealedCompletedCells = snapshot.sealedCompletedCells
        board.completedTasks = snapshot.completedTasks
        board.linesCompleted = snapshot.linesCompleted
        board.completedLineIds = snapshot.completedLineIds.isEmpty ? nil : snapshot.completedLineIds
        // Deterministic status from the sealed snapshot. `now` is the sealedAt
        // instant being stamped, so this matches the re-derivation path's source.
        let resolvedStatus = AppDatabase.resolveSealedStatus(board: board, snapshot: snapshot, completedAtTs: now)
        board.status = resolvedStatus.status
        board.completedAt = resolvedStatus.completedAt
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
        return true
    }

    /// Migration expired-board sealing (docs §Migration & backfill step 3).
    /// Seal every board past its backstop deadline from the PRE-MIGRATION
    /// LIFETIME rendered state (NO window context — reproduces exactly what the
    /// user currently sees, "bleed preserved once" at the boundary). Twin of
    /// web's `runMigrationV14`. Enqueues a Board sync UPDATE via raw SQL (matches
    /// the v20 backfill migration's inline-enqueue pattern). Runs inside the
    /// migration transaction.
    ///
    /// This deliberately differs from `sealBoardTx` (which seals from the WINDOWED
    /// event union): at migration time we freeze the lifetime caches, not the
    /// windowed re-evaluation, so an already-green board stays green when sealed.
    static func sealExpiredBoardsAtMigration(db: Database, now: String) throws {
        let nowMs = (DateFormatting.parseISO(now)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000

        let allBoards = try Board.fetchAll(db)
        let allBoardTasks = try BoardTask.fetchAll(db)
        let allTasks = try Task.fetchAll(db)
        let allChildren = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)

        var taskById: [String: Task] = [:]
        for t in allTasks { taskById[t.id] = t }
        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in allChildren { childrenByCompound[c.compoundTaskId, default: []].append(c) }

        for board in allBoards where isBoardPastBackstop(board, nowMs: nowMs) {
            let boardTasksOnBoard = allBoardTasks.filter { $0.boardId == board.id }
            // Lifetime derivation (explicit nil window context) = pre-migration
            // state. Deliberate: freeze the caches the user currently sees.
            let stats = DerivationPass.computeBoardStatsUpdate(
                board: board,
                boardTasksOnBoard: boardTasksOnBoard,
                childrenByCompound: childrenByCompound,
                taskById: taskById,
                allBoards: allBoards,
                windowContext: nil
            )
            let cells = DerivationPass.computeSealedCompletedCells(
                board: board,
                boardTasksOnBoard: boardTasksOnBoard,
                childrenByCompound: childrenByCompound,
                taskById: taskById,
                allBoards: allBoards,
                windowContext: nil
            )

            var sealed = board
            sealed.sealedAt = now
            sealed.sealedCompletedCells = cells
            sealed.completedTasks = stats.completedTasks
            sealed.linesCompleted = stats.linesCompleted
            sealed.completedLineIds = stats.completedLineIds.isEmpty ? nil : stats.completedLineIds
            sealed.updatedAt = now
            sealed.version += 1
            try sealed.save(db)

            let payloadStr = String(data: try JSONEncoder().encode(sealed), encoding: .utf8) ?? "{}"
            try db.execute(sql: """
                INSERT INTO sync_queue
                    (id, entityType, entityId, operationType, payload, status, retryCount, createdAt, priority)
                VALUES (?, 'boards', ?, 'update', ?, 'pending', 0, ?, 0)
                """, arguments: [UUID().uuidString, board.id, payloadStr, now])
        }
    }

    /// Seal a board in its own transaction (docs §Sealing → Lifecycle step 3).
    ///
    /// - Returns: `true` if the board was sealed by this call.
    @discardableResult
    func sealBoard(boardId: String, now: String = AppDatabase.currentTimestamp()) throws -> Bool {
        try write { db in
            try AppDatabase.sealBoardTx(db: db, boardId: boardId, now: now)
        }
    }

    /// Lazy auto-seal backstop (docs §Sealing → Lifecycle step 4). On app-open /
    /// Boards-visible, seal every board past its timeframe-scaled backstop
    /// deadline (keyed off `max(endDate, activatedAt)`) with no prompt. Same
    /// lazy-detection posture as recurring spawn — no background scheduling, no
    /// DB write without the user having opened the app. One transaction.
    ///
    /// - Returns: The ids of boards sealed by this pass.
    @discardableResult
    func runBackstopAutoSeal(userId: String, now: String = AppDatabase.currentTimestamp()) throws -> [String] {
        try write { db in
            let nowMs = (DateFormatting.parseISO(now)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000
            let boards = try Board
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .fetchAll(db)
            var sealedIds: [String] = []
            for board in boards where isBoardPastBackstop(board, nowMs: nowMs) {
                if try AppDatabase.sealBoardTx(db: db, boardId: board.id, now: now) {
                    sealedIds.append(board.id)
                }
            }
            return sealedIds
        }
    }

    /// Pull-path seal re-derivation (docs §Seal snapshots re-derive from the
    /// event union). For every sealed board that places one of `changedTaskIds`
    /// (directly or via a compound), re-derive its frozen snapshot from the
    /// converged event union bounded at its own `sealedAt`. Local-only:
    /// overwrites the snapshot fields WITHOUT bumping `version` or enqueuing
    /// sync (pull paths don't author writes; the input converges, so every
    /// device converges independently).
    ///
    /// MUST run inside the caller's pull transaction, after event rows upsert.
    static func reDeriveSealedBoards(db: Database, changedTaskIds: Set<String>) throws {
        guard !changedTaskIds.isEmpty else { return }
        let lookups = try loadSealLookups(db: db)

        var affectedBoardIds = Set<String>()
        for taskId in changedTaskIds {
            let parents = DerivationPass.findTransitiveParentCompounds(
                changedTaskId: taskId,
                children: lookups.allChildren
            )
            let ids = DerivationPass.findAffectedBoardIds(
                changedTaskId: taskId,
                parentCompounds: parents,
                boardTasks: lookups.allBoardTasks
            )
            affectedBoardIds.formUnion(ids)
        }

        for boardId in affectedBoardIds {
            guard let board = try Board.fetchOne(db, key: boardId),
                  !board.isDeleted, let sealedAt = board.sealedAt else { continue }
            let sealedAtMs = (DateFormatting.parseISO(sealedAt)?.timeIntervalSince1970 ?? 0) * 1000
            let snapshot = computeSealSnapshot(board: board, lookups: lookups, sealedAtMs: sealedAtMs)
            // Local-only re-derivation: snapshot fields + deterministic status,
            // no version bump / enqueue. Raw UPDATE so no save-side version
            // machinery fires. `status`/`completedAt` derive from the converged
            // event union via the same greenlog predicate the live cascade uses,
            // with `completedAt` stamped from the deterministic `sealedAt`
            // instant — so a board sealed while active whose final completing
            // event lands post-seal converges to completed on every device.
            let resolvedStatus = AppDatabase.resolveSealedStatus(board: board, snapshot: snapshot, completedAtTs: sealedAt)
            let cellsJson: String? = {
                guard let data = try? JSONEncoder().encode(snapshot.sealedCompletedCells) else { return nil }
                return String(data: data, encoding: .utf8)
            }()
            let linesJson: String? = {
                guard !snapshot.completedLineIds.isEmpty,
                      let data = try? JSONEncoder().encode(snapshot.completedLineIds) else { return nil }
                return String(data: data, encoding: .utf8)
            }()
            try db.execute(
                sql: """
                    UPDATE boards
                    SET sealedCompletedCells = ?, completedTasks = ?, linesCompleted = ?, completedLineIds = ?, status = ?, completedAt = ?
                    WHERE id = ?
                    """,
                arguments: [
                    cellsJson, snapshot.completedTasks, snapshot.linesCompleted, linesJson,
                    resolvedStatus.status.rawValue, resolvedStatus.completedAt, boardId
                ]
            )
        }
    }

    /// One-shot windowed re-derivation self-heal (Windowed-bingo-cascade fix).
    ///
    /// Existing boards may carry stale `completedLineIds` / `linesCompleted`
    /// written by the pre-fix edit/structure cascades, which resolved from the
    /// lifetime `Task.isCompleted` cache instead of the board window — a cell
    /// holding a lifetime-complete-but-out-of-window task could be counted into
    /// a bingo line while rendering un-green (phantom bingo). This pass
    /// recomputes each live board's stats against its own `[startDate, ∞)`
    /// window and rewrites only the boards whose stats actually changed.
    ///
    /// Idempotent (a converged board is a no-op) and lazy/app-open only — same
    /// posture as `runBackstopAutoSeal`: no background scheduling, one
    /// transaction, only touches live (non-draft/archived, non-sealed,
    /// non-deleted) boards. Sealed boards are untouched (they re-derive on the
    /// pull path via `reDeriveSealedBoards`).
    ///
    /// - Returns: The ids of boards whose stats were rewritten by this pass.
    @discardableResult
    func reDeriveActiveBoards(userId: String, now: String = AppDatabase.currentTimestamp()) throws -> [String] {
        try write { db in
            let boards = try Board
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .fetchAll(db)
                // Every non-sealed status is in scope. DRAFT/ARCHIVED matter
                // because achievement bingo-triggers read ANY non-deleted
                // board's persisted lines — a stale phantom line on a draft/
                // archived board would poison a watcher forever if the heal
                // skipped it. Status transitions below gate on
                // ACTIVE/COMPLETED, so drafts/archived only get stats
                // corrected, never status-flipped.
                .filter { $0.sealedAt == nil }
            guard !boards.isEmpty else { return [] }

            let allBoardTasks: [BoardTask] = try BoardTask.fetchAll(db)
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

            // Windowed resolution: each board evaluated against its own window.
            let windowContext = try Self.buildWindowContext(db: db)

            var changedIds: [String] = []
            for board in boards {
                var updated = board
                let boardTasksOnBoard = allBoardTasks.filter { $0.boardId == board.id }
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
                let newCompletedLineIds = update.completedLineIds.isEmpty ? nil : update.completedLineIds

                var newStatus = board.status
                var newCompletedAt = board.completedAt
                if isGreenlogNow, board.status == .active {
                    newStatus = .completed
                    newCompletedAt = now
                } else if !isGreenlogNow, board.status == .completed {
                    newStatus = .active
                    newCompletedAt = nil
                }

                // Idempotent: only write when the windowed derivation actually
                // differs from what's stored.
                let changed = board.completedTasks != update.completedTasks
                    || board.linesCompleted != update.linesCompleted
                    || Set(board.completedLineIds ?? []) != Set(newCompletedLineIds ?? [])
                    || board.status != newStatus
                guard changed else { continue }

                updated.completedTasks = update.completedTasks
                updated.linesCompleted = update.linesCompleted
                updated.completedLineIds = newCompletedLineIds
                updated.status = newStatus
                updated.completedAt = newCompletedAt
                updated.updatedAt = now
                updated.version += 1

                try updated.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "boards",
                    entityId: board.id,
                    operationType: .update,
                    payload: updated,
                    now: now
                ).enqueue(db)
                changedIds.append(board.id)
            }
            return changedIds
        }
    }
}
