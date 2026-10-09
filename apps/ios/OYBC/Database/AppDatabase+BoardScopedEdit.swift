import Foundation
import GRDB

// MARK: - Board-scoped task edits — commit half (PR 2)
//
// Swift twin of `apps/web/src/db/operations/boardScopedEdit.ts`
// (docs/BOARD_SCOPED_TASK_EDITS.md). An edit made from a board (Board Edit's
// square sheet, the board wizard's inline row edit) affects the task on THAT
// board only: when the task is placed on any other board the edit lands on a
// deterministic fork that replaces the original there.
//
// `ensureBoardScopedTask` is the one entry point both commit paths call
// BEFORE applying their edit. It runs `BoardScopedFork.plan` against the SAME
// transaction's rows and, for a fork, writes:
//   1. the fork row, its in-window event copies and (compound) copied child
//      links — each enqueued as a create; an already-present row (a replayed
//      commit, or another device's identical fork) is kept, so replay
//      converges on the same rows (§7);
//   2. the direct placement on this board repointed through
//      `updateBoardTaskAndCascade` (bump + enqueue + cascade, like Replace);
//   3. every compound placed on this board that contains the task
//      (`onBoardHolderCompoundIds`): the holder is made board-private FIRST
//      (forked itself when placed elsewhere), then the link to the task in
//      its subtree is rewritten to the fork (intermediate compounds on the
//      path made board-private the same way);
//   4. one batched cascade over the fork and the original (sealed boards are
//      skipped by the derivation itself).
// The caller then applies its edit to the returned id and calls
// `stampForkCaches` so the fork's lifetime caches derive from its own events
// AFTER the edit (they depend on the post-edit type / goal).
extension AppDatabase {

    /// Outcome of `ensureBoardScopedTask`.
    struct BoardScopedTarget: Equatable {
        /// The id the edit must land on — the task itself, or its fork.
        let targetId: String
        /// Whether a fork was planned (the caller stamps its caches after editing).
        let forked: Bool
    }

    /// The placement-side inputs of the fork test for one task: every link,
    /// the placements of the task and its transitive parent compounds, and
    /// those placements' boards.
    private static func placementContext(
        db: Database, taskId: String
    ) throws -> (placements: [BoardTask], boards: [Board], links: [CompoundChild]) {
        let links = try CompoundChild.fetchAll(db)
        var reach = DerivationPass.findTransitiveParentCompounds(changedTaskId: taskId, children: links)
        reach.insert(taskId)
        let placements = try BoardTask.filter(reach.contains(Column("taskId"))).fetchAll(db)
        let boardIds = Set(placements.map(\.boardId))
        let boards = try Board.filter(boardIds.contains(Column("id"))).fetchAll(db)
        return (placements, boards, links)
    }

    /// Whether a Board Edit of `taskId` from `boardId` would land on a fork —
    /// the square sheet's "Save for this board" label, from the same
    /// `BoardScopedFork.wouldFork` test the Save's planner runs. A task not
    /// stored yet (a staged new task) never forks. Read-only.
    ///
    /// - Parameters:
    ///   - taskId: The task the sheet edits.
    ///   - boardId: The board being edited.
    /// - Returns: `true` when the Save would fork the task; `false` on a read failure.
    func wouldForkOnBoard(taskId: String, boardId: String) -> Bool {
        (try? read { db in
            guard let task = try Task.fetchOne(db, key: taskId), !task.isDeleted else { return false }
            let ctx = try Self.placementContext(db: db, taskId: taskId)
            return BoardScopedFork.wouldFork(
                task: task, boardId: boardId, placements: ctx.placements, boards: ctx.boards,
                compoundChildren: ctx.links
            )
        }) ?? false
    }

    /// Make `taskId` private to `boardId` ahead of a board-scoped edit,
    /// forking it when it is placed on any other board (see the file header
    /// for every write). Must run inside the caller's write transaction.
    ///
    /// - Parameters:
    ///   - db: The open write transaction.
    ///   - taskId: The task the board edit targets (pre-edit).
    ///   - board: The board the edit is made from — passed as a value because
    ///     the wizard plans against a board whose row is written later in the
    ///     same transaction.
    ///   - editedType: The task's type AFTER the edit (selects migrated events).
    ///   - now: ISO8601 stamp for every minted row.
    /// - Returns: The id to edit, and whether it is a fork.
    @discardableResult
    static func ensureBoardScopedTask(
        db: Database, taskId: String, board: Board, editedType: TaskType, now: String
    ) throws -> BoardScopedTarget {
        let boardId = board.id
        guard let task = try Task.fetchOne(db, key: taskId), !task.isDeleted else {
            return BoardScopedTarget(targetId: taskId, forked: false)
        }
        let ctx = try placementContext(db: db, taskId: taskId)
        let events = try TaskEvent.filter(Column("taskId") == taskId).fetchAll(db)
        let plan = BoardScopedFork.plan(
            task: task, board: board, editedType: editedType, placements: ctx.placements,
            boards: ctx.boards, compoundChildren: ctx.links, events: events, now: now
        )
        guard case let .fork(fork, eventCopies, childLinksToCopy, repoint, holderIds) = plan else {
            return BoardScopedTarget(targetId: taskId, forked: false)
        }

        if try Task.fetchOne(db, key: fork.id) == nil {
            try fork.insert(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks", entityId: fork.id, operationType: .create, payload: fork, now: now
            ).enqueue(db)
        }
        for copy in eventCopies {
            guard try TaskEvent.fetchOne(db, key: copy.id) == nil else { continue }
            try copy.insert(db)
            try SyncQueueBuilder.makeItem(
                entityType: "taskEvents", entityId: copy.id, operationType: .create, payload: copy, now: now
            ).enqueue(db)
        }
        for copy in childLinksToCopy {
            guard try CompoundChild.fetchOne(db, key: copy.id) == nil else { continue }
            try copy.insert(db)
            try SyncQueueBuilder.makeItem(
                entityType: "compoundChildren", entityId: copy.id, operationType: .create, payload: copy, now: now
            ).enqueue(db)
        }

        if let repoint {
            try updateBoardTaskAndCascade(db: db, boardTaskId: repoint.boardTaskId, newTaskId: fork.id)
        }
        for holderId in holderIds {
            try replaceInHolderSubtree(db: db, holderId: holderId, oldId: taskId, newId: fork.id, board: board, now: now)
        }
        try runBoardCascadeForTasks(db: db, changedTaskIds: [fork.id, taskId], now: now)
        return BoardScopedTarget(targetId: fork.id, forked: true)
    }

    /// Replace `oldId` with `newId` inside the subtree of compound `holderId`
    /// (a compound placed on `boardId`): the holder — and every compound on
    /// the path down to `oldId` — is made board-private first, then the link
    /// to `oldId` is rewritten.
    private static func replaceInHolderSubtree(
        db: Database, holderId: String, oldId: String, newId: String, board: Board, now: String
    ) throws {
        guard let holder = try Task.fetchOne(db, key: holderId), !holder.isDeleted else { return }
        let privateHolderId = try ensureBoardScopedTask(
            db: db, taskId: holderId, board: board, editedType: holder.type, now: now
        ).targetId
        let links = try CompoundChild
            .filter(Column("compoundTaskId") == privateHolderId && Column("isDeleted") == false)
            .fetchAll(db)
            .sorted { $0.childIndex != $1.childIndex ? $0.childIndex < $1.childIndex : $0.id < $1.id }
        for link in links {
            if link.childTaskId == oldId {
                try repointCompoundLink(db: db, compoundId: privateHolderId, oldChildId: oldId, newChildId: newId, now: now)
                continue
            }
            // An intermediate compound on the path to `oldId`.
            let live = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
            if DerivationPass.findTransitiveParentCompounds(changedTaskId: oldId, children: live).contains(link.childTaskId) {
                try replaceInHolderSubtree(db: db, holderId: link.childTaskId, oldId: oldId, newId: newId, board: board, now: now)
            }
        }
    }

    /// Rewrite the live link `compoundId → oldChildId` to point at
    /// `newChildId` (version bump + update enqueue). No-op when no such live
    /// link exists — e.g. the holder walk already rewrote it.
    ///
    /// - Parameters:
    ///   - db: The open write transaction.
    ///   - compoundId: The parent compound.
    ///   - oldChildId: The child the link points at today.
    ///   - newChildId: The child it must point at.
    ///   - now: ISO8601 stamp.
    static func repointCompoundLink(
        db: Database, compoundId: String, oldChildId: String, newChildId: String, now: String
    ) throws {
        let links = try CompoundChild
            .filter(Column("compoundTaskId") == compoundId && Column("childTaskId") == oldChildId
                && Column("isDeleted") == false)
            .fetchAll(db)
        for var link in links {
            link.childTaskId = newChildId
            link.version += 1
            link.updatedAt = now
            try link.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "compoundChildren", entityId: link.id, operationType: .update, payload: link, now: now
            ).enqueue(db)
        }
    }

    /// Stamp a fork's lifetime caches from its own (migrated) events, AFTER
    /// the caller applied the edit — the authored `stampTaskCachesAuthored`
    /// write (bump + enqueue). No-op for an in-place target or a
    /// non-event-owning fork.
    ///
    /// - Parameters:
    ///   - db: The open write transaction.
    ///   - target: `ensureBoardScopedTask`'s result.
    ///   - now: ISO8601 stamp.
    static func stampForkCaches(db: Database, target: BoardScopedTarget, now: String) throws {
        guard target.forked else { return }
        try stampTaskCachesAuthored(db: db, taskId: target.targetId, now: now)
    }
}
