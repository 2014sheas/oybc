import Foundation
import GRDB

/// Pull-path board cascades (moved out of `SyncService.swift`, which sits at its
/// `scripts/audit/file-size-allowlist.json` cap, so they are unit-testable
/// against `AppDatabase.makeTestInstance()` without a `SyncService`).
///
/// A pulled `tasks` / `compoundChildren` / `boardTasks` / `taskEvents` row can
/// change a board's derived stats, so the pull re-derives every affected live
/// board inside the pull's own write transaction (the atomic pull-path rule) —
/// a cascade error throws and rolls the pulled upsert back. Write shape is
/// unchanged from the SyncService originals: raw-SQL stats UPDATE with a
/// `version` bump + a raw `sync_queue` INSERT owned by the PULL's uid, and no
/// greenlog status transition (the pull cascades never flip status).
///
/// Sync-churn fix: a board whose derived stats come out unchanged is NOT
/// written, version-bumped or enqueued. Before, every pulled echo of this
/// device's own push re-bumped and re-pushed every containing board.
extension AppDatabase {

    /// The derivation lookups every pull cascade builds once per call.
    private struct PullCascadeLookups {
        let allChildren: [CompoundChild]
        let allBoardTasks: [BoardTask]
        let allBoards: [Board]
        let taskById: [String: Task]
        let childrenByCompound: [String: [CompoundChild]]
        let windowContext: WindowEvaluationContext
    }

    private static func loadPullCascadeLookups(db: Database) throws -> PullCascadeLookups {
        let allChildren = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
        let allBoardTasks = try BoardTask.filter(Column("isDeleted") == false).fetchAll(db)
        var taskById: [String: Task] = [:]
        for t in try Task.fetchAll(db) { taskById[t.id] = t }
        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in allChildren { childrenByCompound[c.compoundTaskId, default: []].append(c) }
        return PullCascadeLookups(
            allChildren: allChildren,
            allBoardTasks: allBoardTasks,
            // Phase 6.3 — the achievement branches evaluate against real
            // cross-board state, so the workspace's boards are fed in.
            allBoards: try Board.fetchAll(db),
            taskById: taskById,
            childrenByCompound: childrenByCompound,
            // Windowed Completion — every board evaluates windowed (docs §Sync).
            windowContext: try buildWindowContext(db: db)
        )
    }

    /// Run the derivation pass for a Task (or compound parent) whose row was
    /// just upserted by a pull. B2 final-review FI1: refreshes a pulled
    /// window-stamped derived counter's baseline first (non-authored).
    ///
    /// - Parameters:
    ///   - db: The pull's write transaction.
    ///   - changedTaskId: The task that was just upserted.
    ///   - ownerUid: The uid the pull runs for (owns the enqueues).
    static func runPullCascade(db: Database, changedTaskId: String, ownerUid: String) throws {
        try refreshPulledDerivedBaseline(db: db, taskId: changedTaskId)
        try runPullCascadeForTasks(db: db, changedTaskIds: [changedTaskId], ownerUid: ownerUid)
    }

    /// Batched multi-task pull cascade (Windowed Completion, docs §Sync):
    /// unions the boards affected across every changed task (directly or via a
    /// containing compound) and re-derives each live one exactly once.
    ///
    /// - Parameters:
    ///   - db: The pull's write transaction.
    ///   - changedTaskIds: The tasks whose state changed.
    ///   - ownerUid: The uid the pull runs for (owns the enqueues).
    static func runPullCascadeForTasks(db: Database, changedTaskIds: Set<String>, ownerUid: String) throws {
        let lookups = try loadPullCascadeLookups(db: db)
        var affectedBoardIds = Set<String>()
        for changedTaskId in changedTaskIds {
            let parentCompounds = DerivationPass.findTransitiveParentCompounds(
                changedTaskId: changedTaskId, children: lookups.allChildren
            )
            affectedBoardIds.formUnion(DerivationPass.findAffectedBoardIds(
                changedTaskId: changedTaskId, parentCompounds: parentCompounds, boardTasks: lookups.allBoardTasks
            ))
        }
        let now = currentTimestamp()
        for boardId in affectedBoardIds {
            guard let board = try Board.fetchOne(db, key: boardId), !board.isDeleted, board.sealedAt == nil else { continue }
            try writePullCascadeBoardStats(db: db, board: board, lookups: lookups, now: now, ownerUid: ownerUid)
        }
    }

    /// Board-integrity PR-1 (tombstones) — the `boardTasks`-pull cascade. A
    /// pulled placement (live OR tombstone) changes ONE board's geometry
    /// directly, so that board re-derives (a sealed board takes the sealed
    /// re-derive instead), then its achievement watchers refresh.
    ///
    /// - Parameters:
    ///   - db: The pull's write transaction.
    ///   - boardId: The `boardId` of the pulled `BoardTask` row.
    ///   - ownerUid: The uid the pull runs for (owns the enqueues).
    static func runPullCascadeForBoardTask(db: Database, boardId: String, ownerUid: String) throws {
        guard let board = try Board.fetchOne(db, key: boardId), !board.isDeleted else { return }
        if board.sealedAt != nil {
            try reDeriveSealedBoardSnapshots(db: db, boardIds: [boardId])
            return try refreshWatchersAfterPull(db: db, boardIds: [boardId])
        }
        let lookups = try loadPullCascadeLookups(db: db)
        try writePullCascadeBoardStats(db: db, board: board, lookups: lookups, now: currentTimestamp(), ownerUid: ownerUid)
        try refreshWatchersAfterPull(db: db, boardIds: [boardId])
    }

    /// Re-derive one live board and persist its stats — only when they changed.
    private static func writePullCascadeBoardStats(
        db: Database, board: Board, lookups: PullCascadeLookups, now: String, ownerUid: String
    ) throws {
        // Board-integrity PR-2 (issue #375): resolve collisions/OOB before
        // deriving, so persisted stats can never disagree with the render.
        let boardTasksOnBoard = PlacementIntegrity.resolvedRows(
            boardId: board.id, in: lookups.allBoardTasks, boardSize: board.boardSize
        )
        let update = DerivationPass.computeBoardStatsUpdate(
            board: board,
            boardTasksOnBoard: boardTasksOnBoard,
            childrenByCompound: lookups.childrenByCompound,
            taskById: lookups.taskById,
            allBoards: lookups.allBoards,
            windowContext: lookups.windowContext
        )
        var next = board
        next.completedTasks = update.completedTasks
        next.linesCompleted = update.linesCompleted
        next.completedLineIds = update.completedLineIds
        guard next.derivedStateDiffers(from: board) else { return }

        let linesJson = (try? JSONEncoder().encode(update.completedLineIds))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try db.execute(sql: """
            UPDATE boards
            SET completedTasks = ?, linesCompleted = ?, completedLineIds = ?,
                updatedAt = ?, version = version + 1
            WHERE id = ?
            """, arguments: [update.completedTasks, update.linesCompleted, linesJson, now, board.id])
        guard let updatedBoard = try Board.fetchOne(db, key: board.id) else { return }
        let payload = String(data: try JSONEncoder().encode(updatedBoard), encoding: .utf8) ?? "{}"
        try insertPullCascadeBoardSync(db: db, boardId: board.id, payload: payload, now: now, ownerUid: ownerUid)
    }

    /// Enqueue the board-stats UPDATE a pull cascade produces, stamped with the
    /// uid the PULL runs for — never the live auth uid, which can flip mid-pull
    /// during the guest-collision switch (docs/GUEST_MODE.md §Collision). Raw
    /// SQL, no coalescing — the write shape the pull cascades always used.
    ///
    /// - Throws: A GRDB error if the insert fails (rolls back the pull).
    static func insertPullCascadeBoardSync(
        db: Database, boardId: String, payload: String, now: String, ownerUid: String
    ) throws {
        try db.execute(sql: """
            INSERT INTO sync_queue
                (id, entityType, entityId, operationType, payload, status, retryCount, createdAt, priority, ownerUid)
            VALUES (?, 'boards', ?, 'update', ?, 'pending', 0, ?, 0, ?)
            """, arguments: [UUID().uuidString, boardId, payload, now, ownerUid])
    }
}
