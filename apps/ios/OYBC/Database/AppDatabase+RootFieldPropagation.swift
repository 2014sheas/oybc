import Foundation
import GRDB

// MARK: - Root → copy field propagation (board-scoped edits PR 3)
//
// Swift twin of `apps/web/src/db/operations/rootFieldPropagation.ts`
// (docs/BOARD_SCOPED_TASK_EDITS.md §6). The rule is the pure
// `RootFieldPropagation.plan`; this extension reads its inputs and writes its
// output inside `applyTaskEditPatch`'s write transaction.

extension AppDatabase {

    /// The root + its candidate copies, read BEFORE the root edit is written.
    struct RootPropagationSnapshot {
        let root: Task
        /// Every row with `sharedCounterId == root.id`, annotated with sealed-board placement.
        let copies: [RootFieldPropagation.Copy]
    }

    /// Read what `propagateRootFields(db:snapshot:patch:now:)` needs. Run it
    /// inside the caller's write, before any write of the save.
    ///
    /// - Parameters:
    ///   - db: The open write transaction.
    ///   - taskId: The task being edited.
    /// - Returns: The snapshot, or nil when the task is not a live counting
    ///   root with copies (nothing to propagate).
    /// - Throws: A database error if a read fails.
    static func readRootPropagationSnapshot(db: Database, taskId: String) throws -> RootPropagationSnapshot? {
        guard let root = try Task.fetchOne(db, key: taskId), !root.isDeleted,
              root.type == .counting, root.sharedCounterId == nil else { return nil }
        let rows = try Task.filter(Column("sharedCounterId") == root.id).fetchAll(db)
        guard !rows.isEmpty else { return nil }
        let copies = try rows.map { row in
            RootFieldPropagation.Copy(task: row, onSealedBoard: try isPlacedOnSealedBoard(db: db, taskId: row.id))
        }
        return RootPropagationSnapshot(root: root, copies: copies)
    }

    /// Apply the planned copy writes for a root edit, then cascade the copies'
    /// boards. Each changed copy gets ONE authored write: a version bump +
    /// `.update` enqueue — unless the kind switch already bumped that row in
    /// this same transaction, in which case the fields join that write (no
    /// second bump; the enqueue coalesces onto the switch's pending item).
    ///
    /// - Parameters:
    ///   - db: The open write transaction.
    ///   - snapshot: From `readRootPropagationSnapshot`, read before the save's writes.
    ///   - patch: The root's edit.
    ///   - now: ISO8601 write time / freeze clock.
    /// - Returns: The copy ids written.
    /// - Throws: A database error if a write fails.
    @discardableResult
    static func propagateRootFields(
        db: Database,
        snapshot: RootPropagationSnapshot,
        patch: RootFieldPropagation.EditPatch,
        now: String
    ) throws -> [String] {
        let plan = RootFieldPropagation.plan(root: snapshot.root, patch: patch, copies: snapshot.copies, now: now)
        let versionBefore = Dictionary(
            snapshot.copies.map { ($0.task.id, $0.task.version) }, uniquingKeysWith: { first, _ in first }
        )
        var written: [String] = []
        for entry in plan {
            guard var copy = try Task.fetchOne(db, key: entry.copyId) else { continue }
            let alreadyAuthored = copy.version != versionBefore[entry.copyId]
            if let title = entry.patch.title { copy.title = title }
            if let action = entry.patch.action { copy.action = action }
            if let unit = entry.patch.unit { copy.unit = unit }
            copy.updatedAt = now
            if !alreadyAuthored { copy.version += 1 }
            try copy.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: copy.id,
                operationType: .update,
                payload: copy,
                now: now
            ).enqueue(db)
            written.append(copy.id)
        }
        if !written.isEmpty {
            try Self.runBoardCascadeForTasks(db: db, changedTaskIds: written, now: now)
        }
        return written
    }

    /// Whether `taskId` has a live placement on a live sealed board.
    private static func isPlacedOnSealedBoard(db: Database, taskId: String) throws -> Bool {
        let boardIds = try BoardTask
            .filter(Column("taskId") == taskId && Column("isDeleted") == false)
            .fetchAll(db)
            .map(\.boardId)
        guard !boardIds.isEmpty else { return false }
        return try Board
            .filter(boardIds.contains(Column("id")))
            .filter(Column("isDeleted") == false)
            .filter(Column("sealedAt") != nil)
            .fetchCount(db) > 0
    }
}
