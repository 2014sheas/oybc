import Foundation
import GRDB

// MARK: - Counter write ops (P5 — Counters Hub, PR-2)
//
// Swift twin of `apps/web/src/db/operations/tasks.counter.ts`
// (docs/SHARED_COUNTERS.md §P5). `createCounterTask` (hub "+ New counter"),
// `promoteTaskToCounter` (decision 7 — flag an existing standalone counting
// task as a counter), and `deleteCounterWithUnlink` (decision 8 — deleting a
// source unlinks its members rather than orphaning them) are the three write
// paths that touch `Task.isCounter`. No other code path sets this flag.

extension AppDatabase {

    /// Create a goal-less hub-born counter Task, optionally seeded with a
    /// starting count. Task row + optional seed increment event are written
    /// in ONE GRDB write transaction so a seeded counter never exists
    /// without its founding event (or vice versa).
    ///
    /// The seed event (when `startingCount > 0`) is anchored at
    /// `TaskEvents.seedEventOccurredAt` (not `now`) so it never counts
    /// toward any windowed board read — it exists purely so the lifetime
    /// event sum matches the task row's authoritative `currentCount`. Uses
    /// `insertIncrementEventRaw` (no cache restamp): `currentCount` is
    /// already written authoritatively as `startingCount` below; a restamp
    /// would double-bump `version`.
    ///
    /// - Parameters:
    ///   - userId: Owning user.
    ///   - action: Action verb (trimmed; must be non-blank after trimming).
    ///   - unit: Unit of measurement (trimmed; must be non-blank after trimming).
    ///   - startingCount: Optional non-negative starting count (defaults to 0).
    ///   - now: ISO8601 write timestamp.
    /// - Returns: The newly created counter Task.
    /// - Throws: `AppDatabaseError.invalidCounterInput` if `action`/`unit`
    ///   are blank after trimming, or `startingCount` is negative.
    @discardableResult
    func createCounterTask(
        userId: String,
        action: String,
        unit: String,
        startingCount: Int?,
        now: String
    ) throws -> Task {
        let trimmedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = startingCount ?? 0
        guard !trimmedAction.isEmpty, !trimmedUnit.isEmpty else {
            throw AppDatabaseError.invalidCounterInput(
                "createCounterTask: action and unit are required"
            )
        }
        guard count >= 0 else {
            throw AppDatabaseError.invalidCounterInput(
                "createCounterTask: startingCount must be a non-negative integer"
            )
        }

        let title = TaskTitle.generateCounterTaskTitle(action: trimmedAction, maxCount: nil, unit: trimmedUnit)
        let task = Task(
            id: Self.generateUUID(),
            userId: userId,
            title: title,
            type: .counting,
            action: trimmedAction,
            unit: trimmedUnit,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            currentCount: count,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false,
            isCounter: true
        )

        try write { db in
            try task.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: task.id,
                operationType: .create,
                payload: task,
                now: now
            ).enqueue(db)
            if count > 0 {
                // Raw (no cache restamp): currentCount is already authoritative above.
                try Self.insertIncrementEventRaw(
                    db: db,
                    taskId: task.id,
                    delta: count,
                    boardId: nil,
                    now: now,
                    occurredAt: TaskEvents.seedEventOccurredAt
                )
            }
        }
        return task
    }

    /// P5 decision 7 — flag a standalone (non-derived) COUNTING task as a
    /// counter, so it appears in the Counters Hub. Bumps `version`/`updatedAt`
    /// and enqueues an UPDATE sync entry.
    ///
    /// - Parameters:
    ///   - taskId: The standalone counting task to promote.
    ///   - now: ISO8601 write timestamp.
    /// - Returns: The updated Task.
    /// - Throws: `AppDatabaseError.counterPromotionRejected` if the task is
    ///   missing/deleted, not `.counting`, or is itself a derived (linked)
    ///   task (`sharedCounterId` set) — a derived task can never be a
    ///   counter source.
    @discardableResult
    func promoteTaskToCounter(taskId: String, now: String) throws -> Task {
        try write { db in
            guard var task = try Task.fetchOne(db, key: taskId), !task.isDeleted else {
                throw AppDatabaseError.counterPromotionRejected(
                    "promoteTaskToCounter: task \(taskId) not found"
                )
            }
            guard task.type == .counting else {
                throw AppDatabaseError.counterPromotionRejected(
                    "promoteTaskToCounter: only counting tasks"
                )
            }
            guard task.sharedCounterId == nil else {
                throw AppDatabaseError.counterPromotionRejected(
                    "promoteTaskToCounter: derived tasks cannot be counters"
                )
            }
            task.isCounter = true
            task.updatedAt = now
            task.version += 1
            try task.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: taskId,
                operationType: .update,
                payload: task,
                now: now
            ).enqueue(db)
            return task
        }
    }

    /// P5 decision 8 — delete a counter source by first unlinking every live
    /// member (writing a snapshot increment event so the member's displayed
    /// value survives as its own standalone lifetime count) then cascade-
    /// deleting the source itself. All in ONE GRDB write transaction.
    ///
    /// Each member's `sharedCounterId`/`baseline` are cleared and its
    /// `currentCount` is set to its current derived `displayed` value (via
    /// `deriveDisplayedCount`), so it becomes an independent counting task
    /// that keeps whatever progress it showed. The snapshot event is
    /// anchored at `now` (NOT the seed sentinel) — it's a real, present-day
    /// event, not backfill. No-op (returns without writing) if the source is
    /// missing or already deleted.
    ///
    /// Ordering note: each member row is saved (clearing `sharedCounterId`)
    /// BEFORE `insertIncrementEventRaw` re-fetches it — that re-fetch is
    /// what proves the member `isEventOwningTask` at the moment the
    /// snapshot event is appended. Load-bearing; mirrors the web
    /// implementation's ordering.
    ///
    /// - Parameters:
    ///   - sourceId: The counter source task to delete.
    ///   - now: ISO8601 write timestamp.
    func deleteCounterWithUnlink(sourceId: String, now: String) throws {
        try write { db in
            guard let source = try Task.fetchOne(db, key: sourceId), !source.isDeleted else { return }

            let members = try Task
                .filter(Column("sharedCounterId") == sourceId && Column("isDeleted") == false)
                .fetchAll(db)

            for var member in members {
                let derived = deriveDisplayedCount(
                    derivedBaseline: member.baseline ?? 0,
                    derivedMaxCount: member.maxCount ?? 0,
                    sourceCurrentCount: source.currentCount ?? 0
                )
                member.sharedCounterId = nil
                member.baseline = nil
                member.currentCount = derived.displayed
                member.updatedAt = now
                member.version += 1
                try member.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "tasks",
                    entityId: member.id,
                    operationType: .update,
                    payload: member,
                    now: now
                ).enqueue(db)
                if derived.displayed > 0 {
                    try Self.insertIncrementEventRaw(
                        db: db,
                        taskId: member.id,
                        delta: derived.displayed,
                        boardId: nil,
                        now: now
                    )
                }
            }

            try Self.deleteTaskWithCascadeInDb(db: db, taskId: sourceId, now: now)
        }
    }
}
