import Foundation
import GRDB

// MARK: - Counter kinds — family-wide kind rules (docs/COUNTER_KINDS.md D4/D5)
//
// Swift twin of `apps/web/src/db/operations/countKindSwitch.ts`:
//   - `switchCounterKind(rootTaskId:to:now:)` — switch a counter ROOT between
//     Count and Amount (`discrete ⇄ continuous`), cascading to its live family.
//   - `withRootCountKind(db:_:)` — the write-time rule that a new linked row
//     carries its root's kind.

/// Why `switchCounterKind(rootTaskId:to:now:)` refused. Nothing is written.
enum CountKindSwitchError: Error, Equatable {
    /// The id is not a live COUNTING task.
    case notCounting
    /// The task is a linked row — only roots switch.
    case notARoot
    /// The root cannot move from its kind to the requested one (duration
    /// either way, or no change).
    case refused
}

extension AppDatabase {
    /// Switch a counter root's kind and cascade it to the root's family, in
    /// ONE write transaction.
    ///
    /// Writes `countKind = to` (always explicit — the field is never cleared)
    /// plus the `planCountKindSwitch` goal / default-amount rounding on the
    /// root and on every live row whose `sharedCounterId` is the root, each
    /// with a version bump + `.update` enqueue. A window-stamped derived row
    /// whose window has ended (`BoardSources.isFrozenDerivedRow`) is a
    /// permanent record and keeps its kind and goal. Then the board cascade
    /// re-derives every board placing a written row. `task_events` are never
    /// touched: a whole kind rounds the window SUM at read time, so switching
    /// back restores the exact fractional count.
    ///
    /// - Parameters:
    ///   - rootTaskId: The counter root (a COUNTING task with no `sharedCounterId`).
    ///   - to: The requested kind.
    ///   - now: The switch instant (also the freeze clock).
    /// - Throws: `CountKindSwitchError` for a refused switch; a database
    ///   error if the write fails.
    func switchCounterKind(rootTaskId: String, to: CountKind, now: Date = Date()) throws {
        let nowIso = DateFormatting.utcISOString(now)
        try write { db in
            guard let root = try Task.fetchOne(db, key: rootTaskId),
                  !root.isDeleted, root.type == .counting else {
                throw CountKindSwitchError.notCounting
            }
            guard root.sharedCounterId == nil else { throw CountKindSwitchError.notARoot }
            guard let rootPatch = planCountKindSwitch(
                maxCount: root.maxCount,
                defaultLogAmount: root.defaultLogAmount,
                from: resolveCountKind(root.countKind),
                to: to
            ) else {
                throw CountKindSwitchError.refused
            }
            try Self.writeKindSwitch(db: db, task: root, to: to, patch: rootPatch, now: nowIso)
            var writtenIds = [root.id]

            let family = try Task
                .filter(Column("sharedCounterId") == root.id)
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
            for row in family where !BoardSources.isFrozenDerivedRow(row, now: nowIso) {
                guard let rowPatch = planCountKindSwitch(
                    maxCount: row.maxCount,
                    defaultLogAmount: row.defaultLogAmount,
                    from: resolveCountKind(row.countKind),
                    to: to
                ) else { continue } // already `to` (or a kind that never switches)
                try Self.writeKindSwitch(db: db, task: row, to: to, patch: rowPatch, now: nowIso)
                writtenIds.append(row.id)
            }

            for id in writtenIds {
                try Self.runBoardCascadeForTask(db: db, changedTaskId: id, now: nowIso)
            }
        }
    }

    /// One authored kind-switch write: kind + rounded fields, version bump,
    /// `.update` enqueue. Runs inside the caller's write transaction.
    private static func writeKindSwitch(
        db: Database, task: Task, to: CountKind, patch: CountKindSwitchPatch, now: String
    ) throws {
        var updated = task
        if let maxCount = patch.maxCount { updated.maxCount = maxCount }
        if let amount = patch.defaultLogAmount { updated.defaultLogAmount = amount }
        updated.countKind = to
        updated.updatedAt = now
        updated.version += 1
        try updated.save(db)
        try SyncQueueBuilder.makeItem(
            entityType: "tasks",
            entityId: updated.id,
            operationType: .update,
            payload: updated,
            now: now
        ).enqueue(db)
    }

    /// The write-time family rule (D5): a new LINKED counting row carries its
    /// root's kind. Returns `task` unchanged for anything else, or when the
    /// root cannot be read. Call it inside the transaction that inserts `task`.
    ///
    /// - Parameters:
    ///   - db: The open write transaction.
    ///   - task: The row about to be inserted.
    /// - Returns: The row with the root's `countKind` copied onto it.
    static func withRootCountKind(db: Database, _ task: Task) throws -> Task {
        guard task.type == .counting, let rootId = task.sharedCounterId,
              let root = try Task.fetchOne(db, key: rootId) else { return task }
        var copy = task
        copy.countKind = root.countKind
        return copy
    }
}
