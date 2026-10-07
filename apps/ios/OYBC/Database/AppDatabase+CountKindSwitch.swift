import Foundation
import GRDB

// MARK: - Counter kinds — family-wide kind rules (docs/COUNTER_KINDS.md D4/D5)
//
// Swift twin of `apps/web/src/db/operations/countKindSwitch.ts`:
//   - `switchCounterKind(rootTaskId:to:now:)` — switch a counter ROOT between
//     `.discrete` and `.continuous`, cascading to its live family
//     (`switchCounterKind(db:…)` inside a caller's write).
//   - `applyKindSwitchThenGoalGuard(db:…)` — the one switch-then-guard step
//     every editing save runs (Ruling U7).
//   - `previewCounterKindSwitch` / `KindSwitchPreview` — the confirm's preview.
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
    /// A whole kind received a fractional goal (D4). Thrown by
    /// `applyKindSwitchThenGoalGuard` — the caller's transaction rolls back.
    case goalNotWhole
}

/// What the Continuous → Discrete confirm shows (docs/COUNTER_KINDS.md §5).
/// Web twin: `KindSwitchPreview` in `countKindSwitch.ts`.
struct KindSwitchPreview: Equatable, Identifiable {
    let from: CountKind
    let to: CountKind
    let titleBefore: String
    let titleAfter: String
    let loggedBefore: CountValue
    let loggedAfter: CountValue
    /// Live family rows the switch also writes.
    let linkedCount: Int

    var id: String { "\(from.rawValue)-\(to.rawValue)" }

    /// Pure preview from a task's own fields (pending tasks use it directly).
    /// Twin of `planKindSwitchPreview`.
    ///
    /// - Parameters:
    ///   - task: The task (or editor draft) being switched.
    ///   - to: The requested kind.
    ///   - linkedCount: Live family rows the switch would also write.
    /// - Returns: The preview, or nil when the switch is refused.
    static func planned(task: Task, to: CountKind, linkedCount: Int) -> KindSwitchPreview? {
        let from = resolveCountKind(task.countKind)
        guard let patch = planCountKindSwitch(
            maxCount: task.maxCount, defaultLogAmount: task.defaultLogAmount, from: from, to: to
        ) else { return nil }
        let action = task.action ?? ""
        let unit = task.unit ?? ""
        let auto = TaskTitle.isAutoCounterTitle(
            title: task.title, action: action, maxCount: task.maxCount, unit: unit, countKind: from
        )
        let loggedBefore = quantizeCount(task.currentCount ?? 0)
        return KindSwitchPreview(
            from: from,
            to: to,
            titleBefore: task.title,
            titleAfter: auto
                ? TaskTitle.generateCounterTaskTitle(
                    action: action, maxCount: patch.maxCount ?? task.maxCount, unit: unit, countKind: to
                )
                : task.title,
            loggedBefore: loggedBefore,
            loggedAfter: finalizeWindowCount(loggedBefore, kind: to),
            linkedCount: linkedCount
        )
    }
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
    /// back restores the exact fractional count. Lifetime caches
    /// (`isCompleted` / `currentCount` / `completedAt`) are restamped from
    /// events in the same write.
    ///
    /// - Parameters:
    ///   - rootTaskId: The counter root (a COUNTING task with no `sharedCounterId`).
    ///   - to: The requested kind.
    ///   - now: The switch instant (also the freeze clock).
    /// - Throws: `CountKindSwitchError` for a refused switch; a database
    ///   error if the write fails.
    func switchCounterKind(rootTaskId: String, to: CountKind, now: Date = Date()) throws {
        try write { db in
            _ = try Self.switchCounterKind(db: db, rootTaskId: rootTaskId, to: to, now: now)
        }
    }

    /// `switchCounterKind(rootTaskId:to:now:)`'s body, for a caller that
    /// already holds a write transaction (editing saves fold the switch into
    /// their own write).
    ///
    /// - Parameters:
    ///   - db: The open write transaction.
    ///   - rootTaskId: The counter root.
    ///   - to: The requested kind.
    ///   - now: The switch instant (also the freeze clock).
    /// - Returns: The ids written (root first, then each live family row).
    /// - Throws: `CountKindSwitchError` for a refused switch; a database error.
    @discardableResult
    static func switchCounterKind(db: Database, rootTaskId: String, to: CountKind, now: Date) throws -> [String] {
        let nowIso = DateFormatting.utcISOString(now)
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
        // Lifetime caches recomputed from events in the same write (the root
        // via computeTaskCachesFromEvents, linked rows via propagateIncrement
        // from the root's new count — the event-append path's rules).
        var patchedRoot = root
        if let maxCount = rootPatch.maxCount { patchedRoot.maxCount = maxCount }
        patchedRoot.countKind = to
        let rootEvents = try TaskEvent.filter(Column("taskId") == root.id).fetchAll(db)
        let rootCaches = Self.computeTaskCachesFromEvents(task: patchedRoot, events: rootEvents)
        try Self.writeKindSwitch(
            db: db, task: root, to: to, patch: rootPatch, now: nowIso,
            caches: (rootCaches.isCompleted, rootCaches.currentCount, rootCaches.completedAt)
        )
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
            let derived = propagateIncrement(
                sourceAfterCurrentCount: rootCaches.currentCount ?? 0,
                linkedTasks: [PropagateIncrementLinkedTask(
                    id: row.id, baseline: row.baseline,
                    maxCount: rowPatch.maxCount ?? row.maxCount,
                    isCompleted: row.isCompleted, countKind: to
                )]
            )[0]
            let completedAt = !row.isCompleted && derived.newIsCompleted ? nowIso : row.completedAt
            try Self.writeKindSwitch(
                db: db, task: row, to: to, patch: rowPatch, now: nowIso,
                caches: (derived.newIsCompleted, derived.newCurrentCount, completedAt)
            )
            writtenIds.append(row.id)
        }

        try Self.runBoardCascadeForTasks(db: db, changedTaskIds: writtenIds, now: nowIso)
        return writtenIds
    }

    /// The ONE "switch if changed, then guard the goal" step every editing
    /// save runs inside its own write (Ruling U7). Throwing after the switch
    /// rolls the caller's transaction back. Twin of the web
    /// `applyKindSwitchThenGoalGuard`.
    ///
    /// - Parameters:
    ///   - db: The caller's open write transaction.
    ///   - taskId: The edited task.
    ///   - to: The kind the editor chose; nil = unchanged.
    ///   - maxCount: The goal the caller is about to write, if any.
    ///   - now: Switch instant / freeze clock.
    /// - Returns: True when a switch was written (only a live COUNTING root
    ///   whose kind differs switches).
    /// - Throws: `CountKindSwitchError.goalNotWhole` when `maxCount` is
    ///   fractional at a whole final kind.
    @discardableResult
    static func applyKindSwitchThenGoalGuard(
        db: Database, taskId: String, to: CountKind?, maxCount: CountValue?, now: Date
    ) throws -> Bool {
        guard let task = try Task.fetchOne(db, key: taskId), !task.isDeleted, task.type == .counting else {
            return false
        }
        let from = resolveCountKind(task.countKind)
        var switched = false
        if let to, to != from, task.sharedCounterId == nil {
            try switchCounterKind(db: db, rootTaskId: taskId, to: to, now: now)
            switched = true
        }
        let finalKind = switched ? (to ?? from) : from
        if let maxCount, isWholeCountKind(finalKind), maxCount.rounded() != maxCount {
            throw CountKindSwitchError.goalNotWhole
        }
        return switched
    }

    /// Read-only preview of `switchCounterKind` for a stored root. Twin of
    /// the web `previewCounterKindSwitch`.
    ///
    /// - Parameters:
    ///   - rootTaskId: The counter root.
    ///   - to: The requested kind.
    ///   - now: Freeze clock for the family count.
    /// - Returns: The preview, or nil for a missing / non-counting / linked
    ///   task or a refused switch.
    func previewCounterKindSwitch(rootTaskId: String, to: CountKind, now: Date = Date()) throws -> KindSwitchPreview? {
        let nowIso = DateFormatting.utcISOString(now)
        return try read { db in
            guard let root = try Task.fetchOne(db, key: rootTaskId), !root.isDeleted,
                  root.type == .counting, root.sharedCounterId == nil else { return nil }
            let family = try Task
                .filter(Column("sharedCounterId") == root.id)
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
            // Exactly the rows switchCounterKind(db:…) would write.
            let linkedCount = family.filter { row in
                !BoardSources.isFrozenDerivedRow(row, now: nowIso)
                    && planCountKindSwitch(
                        maxCount: row.maxCount, defaultLogAmount: row.defaultLogAmount,
                        from: resolveCountKind(row.countKind), to: to
                    ) != nil
            }.count
            return KindSwitchPreview.planned(task: root, to: to, linkedCount: linkedCount)
        }
    }

    /// One authored kind-switch write: kind + rounded fields, version bump,
    /// `.update` enqueue. Runs inside the caller's write transaction.
    private static func writeKindSwitch(
        db: Database, task: Task, to: CountKind, patch: CountKindSwitchPatch, now: String,
        caches: (isCompleted: Bool, currentCount: CountValue?, completedAt: String?)
    ) throws {
        var updated = task
        updated.isCompleted = caches.isCompleted
        updated.currentCount = caches.currentCount
        updated.completedAt = caches.completedAt
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
