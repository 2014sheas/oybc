import Foundation
import GRDB

/// P5 (Shared Counters Hub, docs/SHARED_COUNTERS.md §P5) constants for the
/// task-event write paths. Kept as a top-level namespace (not nested in
/// `AppDatabase`) so counter write ops elsewhere can reference
/// `TaskEvents.seedEventOccurredAt` directly, mirroring the TS import style.
enum TaskEvents {
    /// Sentinel `occurredAt` for a hub counter's seed increment event
    /// (`createCounterTask`, P5 decision — see `AppDatabase+Counters.swift`).
    /// Anchoring the seed event here — rather than at `now` — keeps it
    /// outside every board window, so it never counts toward a windowed
    /// board read; it exists purely so the lifetime event sum matches the
    /// task row's authoritative `currentCount`. Mirrors the TS
    /// `SEED_EVENT_OCCURRED_AT` export in
    /// `packages/shared/src/algorithms/taskEvents.ts`.
    static let seedEventOccurredAt = "1970-01-01T00:00:00.000Z"
}

// MARK: - Task Event write choke points + cache recompute
//
// Swift twin of `apps/web/src/db/operations/taskEvents.ts` (Windowed Completion,
// docs/WINDOWED_COMPLETION.md §Write paths + §Task caches). The TS module is the
// parity reference; the cache-stamp formula (`computeTaskCachesFromEvents`) MUST
// stay byte-identical to `computeTaskCachesFromEvents` there so the on-pull
// recompute converges across devices.
//
// Every helper here takes an open GRDB `Database` handle and MUST be called from
// inside a write transaction that the caller owns (the board-play orchestration /
// shared-counter engine / pull batch). Appending an event and stamping the
// lifetime caches ride the SAME transaction so a peer / older surface never sees
// an event without its cache stamp (or vice versa).
//
// `Task.isCompleted` / `currentCount` / `completedAt` are demoted to LIFETIME
// caches: recomputed from the full non-deleted event set, never trusted for
// anything windowed (grids + derivation read events via
// `resolveTaskWindowState` / `computeBoardStatsUpdate`).

extension AppDatabase {

    /// The lifetime cache fields recomputed from a task's event set. Mirrors the
    /// TS `TaskCacheFields` interface.
    struct TaskCacheFields {
        let isCompleted: Bool
        let currentCount: Int?
        let completedAt: String?
    }

    /// Pure recompute of an event-owning task's LIFETIME caches from its events
    /// (docs §Task caches). Deterministic function of the (converged) event
    /// union, so on-pull recompute converges across devices.
    ///
    /// NORMAL: `isCompleted` iff any non-deleted completion event exists;
    /// `completedAt` is the latest such event's `occurredAt`; `currentCount`
    /// stays whatever it was (nil for a normal task).
    /// COUNTING (plain / source): `currentCount` is the lifetime delta sum
    /// (low-clamped at 0 — overshoot preserved); `isCompleted` iff sum ≥
    /// maxCount; `completedAt` is the latest increment's `occurredAt` when
    /// complete.
    ///
    /// Mirrors `computeTaskCachesFromEvents` in taskEvents.ts.
    ///
    /// - Parameters:
    ///   - task: The event-owning task (caller guarantees `isEventOwningTask`).
    ///   - events: The task's events (deleted rows ignored internally).
    /// - Returns: The cache fields to stamp onto the Task row.
    static func computeTaskCachesFromEvents(task: Task, events: [TaskEvent]) -> TaskCacheFields {
        let live = events.filter { !$0.isDeleted }

        if task.type == .counting {
            let state = resolveTaskWindowState(task: task, events: live, windowStart: nil) // lifetime sum
            let count = state.count
            let isCompleted = task.maxCount != nil && count >= task.maxCount!
            var completedAt: String? = nil
            if isCompleted {
                for e in live where e.kind == .increment {
                    if completedAt == nil || e.occurredAt > completedAt! { completedAt = e.occurredAt }
                }
            }
            return TaskCacheFields(isCompleted: isCompleted, currentCount: count, completedAt: completedAt)
        }

        // NORMAL (and defensive non-counting owners).
        var completedAt: String? = nil
        var hasCompletion = false
        for e in live where e.kind == .completion {
            hasCompletion = true
            if completedAt == nil || e.occurredAt > completedAt! { completedAt = e.occurredAt }
        }
        return TaskCacheFields(isCompleted: hasCompletion, currentCount: task.currentCount, completedAt: completedAt)
    }

    /// Stamp the recomputed lifetime caches onto a task as an AUTHORED write
    /// (docs §Task caches — "Cache stamps are authored writes: they ride the same
    /// transaction as the event append, bump `Task.version`, and enqueue a Task
    /// sync entry"). Called by the local write choke points after an event
    /// append/tombstone. No-op if the task is missing / not event-owning.
    ///
    /// - Parameters:
    ///   - db: The active GRDB write transaction.
    ///   - taskId: The event-owning task whose caches to restamp.
    ///   - now: The write timestamp (shared with the event for coherence).
    static func stampTaskCachesAuthored(db: Database, taskId: String, now: String) throws {
        guard var task = try Task.fetchOne(db, key: taskId), isEventOwningTask(task) else { return }
        let events = try TaskEvent.filter(Column("taskId") == taskId).fetchAll(db)
        let caches = computeTaskCachesFromEvents(task: task, events: events)
        task.isCompleted = caches.isCompleted
        task.currentCount = caches.currentCount
        task.completedAt = caches.completedAt
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
    }

    /// Recompute the lifetime caches from events on the PULL path (docs §Sync —
    /// "On pull, event-owning tasks' caches are recomputed from events, not
    /// trusted"). Unlike the authored stamp, this does NOT bump `version` and
    /// does NOT enqueue a sync entry — pull paths don't author writes; the
    /// recompute overwrites only the completion-cache fields.
    ///
    /// - Parameters:
    ///   - db: The active GRDB write transaction.
    ///   - taskId: The event-owning task whose caches to recompute.
    static func recomputeTaskCachesFromPull(db: Database, taskId: String) throws {
        guard let task = try Task.fetchOne(db, key: taskId), isEventOwningTask(task) else { return }
        let events = try TaskEvent.filter(Column("taskId") == taskId).fetchAll(db)
        let caches = computeTaskCachesFromEvents(task: task, events: events)
        // Overwrite only the completion-cache fields — no version bump, no enqueue.
        try db.execute(
            sql: "UPDATE tasks SET isCompleted = ?, currentCount = ?, completedAt = ? WHERE id = ?",
            arguments: [caches.isCompleted, caches.currentCount, caches.completedAt, taskId]
        )
    }

    /// Sealed-window immunity boundary (docs §Write paths → "Sealed-window
    /// immunity", Decision 9). Build the immune windows for a task from the
    /// non-deleted SEALED boards that place it — directly or via a placed
    /// compound (the same reachability the pull-path re-derivation uses). An
    /// event whose `occurredAt` falls inside one of these `[startDate,
    /// sealedAt]` windows can NEVER be tombstoned by any un-complete /
    /// decrement gesture — history stays history.
    ///
    /// MUST be called inside the ambient tombstone transaction (covers
    /// boards / boardTasks / compoundChildren). Returns `[]` (a fast no-op)
    /// when the user has no sealed boards, so unsealed workspaces pay
    /// nothing. Mirrors web's `getSealImmuneWindowsForTask`.
    ///
    /// - Parameters:
    ///   - db: The active GRDB write transaction.
    ///   - taskId: The event-owning task whose immune windows to resolve.
    static func sealImmuneWindows(db: Database, taskId: String) throws -> [SealImmuneWindow] {
        let sealedBoards = try Board
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
            .filter { $0.sealedAt != nil }
        guard !sealedBoards.isEmpty else { return [] }
        // Board-integrity PR-1: BoardTask is soft-deleted now, like every
        // other synced collection — filter tombstones so a removed
        // placement doesn't keep granting sealed-window immunity.
        // Filter in SWIFT, not SQL: static db-helpers can be reached from
        // pre-v27 migration contexts where the column doesn't exist yet
        // (decode defaults false; pre-v27 rows are all live).
        let boardTasks = try BoardTask.fetchAll(db).filter { !$0.isDeleted }
        let children = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
        let parents = DerivationPass.findTransitiveParentCompounds(changedTaskId: taskId, children: children)
        let affected = DerivationPass.findAffectedBoardIds(changedTaskId: taskId, parentCompounds: parents, boardTasks: boardTasks)
        let placing = sealedBoards.filter { affected.contains($0.id) }
        return buildSealImmuneWindows(
            sealedBoards: placing.compactMap { b in
                guard let sealedAt = b.sealedAt else { return nil }
                return (startDate: b.startDate, sealedAt: sealedAt)
            }
        )
    }

    /// Enqueue a taskEvent row for sync (append-only precedence lives in the D3
    /// coalescer).
    private static func enqueueEventSync(db: Database, event: TaskEvent, op: SyncOperationType, now: String) throws {
        try SyncQueueBuilder.makeItem(
            entityType: "taskEvents",
            entityId: event.id,
            operationType: op,
            payload: event,
            now: now
        ).enqueue(db)
    }

    /// Append a `completion` event for a NORMAL task (docs §Write paths —
    /// Complete), then restamp its caches. Completing an already-lifetime-complete
    /// task from a new window appends a new event (the "re-complete" gesture).
    /// No-op if the task is missing / not event-owning.
    ///
    /// Mirrors `appendCompletionEvent` in taskEvents.ts.
    static func appendCompletionEvent(db: Database, taskId: String, boardId: String?, now: String) throws {
        guard let task = try Task.fetchOne(db, key: taskId), isEventOwningTask(task) else { return }
        let event = TaskEvent(
            id: generateUUID(),
            userId: task.userId,
            taskId: taskId,
            kind: .completion,
            delta: nil,
            occurredAt: now,
            boardId: boardId,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil
        )
        try event.save(db)
        try enqueueEventSync(db: db, event: event, op: .create, now: now)
        try stampTaskCachesAuthored(db: db, taskId: taskId, now: now)
    }

    /// Window-scoped un-complete (docs §Write paths — "Un-complete is
    /// window-scoped"): tombstone ALL non-deleted completion events with
    /// `occurredAt >= windowStart` for the viewed context, then restamp caches.
    /// Sealed-window-immune events (docs Decision 9) are skipped — an event
    /// inside a sealed board's frozen window can never be tombstoned, so a
    /// live-board un-complete whose window overlaps a sealed window leaves the
    /// immune event (and its green) intact.
    ///
    /// Mirrors `tombstoneWindowCompletions` in taskEvents.ts.
    static func tombstoneWindowCompletions(db: Database, taskId: String, windowStart: String, now: String) throws {
        let lowerDate = DateFormatting.parseISO(windowStart)
        let immuneWindows = try sealImmuneWindows(db: db, taskId: taskId)
        let events = try TaskEvent.filter(Column("taskId") == taskId).fetchAll(db)
        for var e in events {
            if e.isDeleted { continue }
            if e.kind != .completion { continue }
            // windowStart provided but unparseable → tombstone nothing (defensive).
            guard let lower = lowerDate, let occurred = DateFormatting.parseISO(e.occurredAt) else { continue }
            if occurred < lower { continue }
            if isOccurredAtSealImmune(e.occurredAt, windows: immuneWindows) { continue } // sealed history is immutable
            e.isDeleted = true
            e.deletedAt = now
            e.updatedAt = now
            e.version += 1
            try e.save(db)
            try enqueueEventSync(db: db, event: e, op: .delete, now: now)
        }
        try stampTaskCachesAuthored(db: db, taskId: taskId, now: now)
    }

    /// Tombstone the latest non-deleted, non-immune completion event (docs
    /// §Write paths — library un-complete "acts on the latest event"), then
    /// restamp caches. Used by library-context toggles that have no board
    /// window. Sealed-window-immune events (docs Decision 9) are excluded from
    /// the candidate set: if the latest — or every — live completion is
    /// immune, this is inert (the UI disables the affordance with an
    /// explanation rather than silently eating the tap). Still restamps from
    /// the empty set when no tombstonable completion event exists (reconciles
    /// a stale lifetime cache to "incomplete").
    ///
    /// Mirrors `tombstoneLatestCompletion` in taskEvents.ts.
    static func tombstoneLatestCompletion(db: Database, taskId: String, now: String) throws {
        let immuneWindows = try sealImmuneWindows(db: db, taskId: taskId)
        let live = try TaskEvent
            .filter(Column("taskId") == taskId)
            .fetchAll(db)
            .filter { !$0.isDeleted && $0.kind == .completion && !isOccurredAtSealImmune($0.occurredAt, windows: immuneWindows) }
        guard var latest = live.first else {
            try stampTaskCachesAuthored(db: db, taskId: taskId, now: now)
            return
        }
        for e in live where (DateFormatting.parseISO(e.occurredAt) ?? .distantPast)
            >= (DateFormatting.parseISO(latest.occurredAt) ?? .distantPast) {
            latest = e
        }
        latest.isDeleted = true
        latest.deletedAt = now
        latest.updatedAt = now
        latest.version += 1
        try latest.save(db)
        try enqueueEventSync(db: db, event: latest, op: .delete, now: now)
        try stampTaskCachesAuthored(db: db, taskId: taskId, now: now)
    }

    /// Whether a library-context un-complete for this task would be inert
    /// because its green is held by a sealed-window-immune completion (docs
    /// Decision 9 + §Write paths — "the toggle is disabled with an
    /// explanatory affordance"). True iff there is at least one live
    /// completion event AND every live completion event is sealed-immune (so
    /// `tombstoneLatestCompletion` would find no candidate and the square
    /// would stay green). UI surfaces that offer un-complete read this to
    /// render disabled-with-explanation.
    ///
    /// Mirrors web's `isUncompleteBlockedBySeal`.
    ///
    /// - Parameters:
    ///   - db: The active GRDB transaction (read-only use is fine inside a
    ///     `read` or `write` block).
    ///   - taskId: The event-owning task.
    /// - Returns: `true` iff the un-complete affordance should be disabled + explained.
    static func isUncompleteBlockedBySeal(db: Database, taskId: String) throws -> Bool {
        let immuneWindows = try sealImmuneWindows(db: db, taskId: taskId)
        guard !immuneWindows.isEmpty else { return false }
        let live = try TaskEvent
            .filter(Column("taskId") == taskId)
            .fetchAll(db)
            .filter { !$0.isDeleted && $0.kind == .completion }
        guard !live.isEmpty else { return false }
        return live.allSatisfy { isOccurredAtSealImmune($0.occurredAt, windows: immuneWindows) }
    }

    /// Convenience read-path wrapper of `isUncompleteBlockedBySeal(db:taskId:)`
    /// for UI callers that don't already have an open transaction.
    ///
    /// - Parameter taskId: The event-owning task.
    /// - Returns: `true` iff the un-complete affordance should be disabled + explained.
    func isUncompleteBlockedBySeal(taskId: String) throws -> Bool {
        try read { db in try Self.isUncompleteBlockedBySeal(db: db, taskId: taskId) }
    }

    /// Append a signed-delta `increment` event (docs §Write paths — Increment /
    /// board-context Decrement), then restamp caches. Skips a zero delta. No-op
    /// if the task is missing / not event-owning.
    ///
    /// Mirrors `appendIncrementEvent` in taskEvents.ts.
    static func appendIncrementEvent(db: Database, taskId: String, delta: Int, boardId: String?, now: String) throws {
        let appended = try insertIncrementEventRaw(db: db, taskId: taskId, delta: delta, boardId: boardId, now: now)
        if appended { try stampTaskCachesAuthored(db: db, taskId: taskId, now: now) }
    }

    /// Append a signed-delta `increment` event WITHOUT restamping caches. Used by
    /// the shared-counter engine (`incrementSharedCounter` / `decrementSharedCounter`),
    /// which already writes the source's lifetime `currentCount` authoritatively
    /// via its own arithmetic (provably equal to the lifetime event sum) — a
    /// restamp would double-bump `version`. The event still needs to exist so
    /// windowed board reads of the source counting square resolve correctly.
    ///
    /// Mirrors `insertIncrementEventRaw` in taskEvents.ts.
    ///
    /// - Parameter occurredAt: Optional override for the event's `occurredAt`
    ///   (defaults to `now`). Used by seed/backfill paths (P5) that need to
    ///   anchor an event at a sentinel timestamp distinct from the write-time
    ///   `createdAt`/`updatedAt`.
    /// - Returns: `true` if an event row was written; `false` on a zero delta /
    ///            a missing or non-event-owning task.
    @discardableResult
    static func insertIncrementEventRaw(
        db: Database,
        taskId: String,
        delta: Int,
        boardId: String?,
        now: String,
        occurredAt: String? = nil
    ) throws -> Bool {
        if delta == 0 { return false }
        guard let task = try Task.fetchOne(db, key: taskId), isEventOwningTask(task) else { return false }
        let event = TaskEvent(
            id: generateUUID(),
            userId: task.userId,
            taskId: taskId,
            kind: .increment,
            delta: delta,
            occurredAt: occurredAt ?? now,
            boardId: boardId,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil
        )
        try event.save(db)
        try enqueueEventSync(db: db, event: event, op: .create, now: now)
        return true
    }

    /// Fetch every non-deleted TaskEvent for a user (read path). Used by
    /// `BoardPlayViewModel` to build the windowed-read context its grid + tap
    /// handlers resolve against.
    ///
    /// - Parameter userId: The authenticated user's id.
    /// - Returns: All non-deleted TaskEvent rows for the user.
    func fetchNonDeletedTaskEvents(userId: String) throws -> [TaskEvent] {
        try read { db in
            try TaskEvent
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .fetchAll(db)
        }
    }

    // MARK: - Window context

    /// Build the windowed-evaluation context from every non-deleted TaskEvent in
    /// the workspace, grouped by `taskId` (docs §Sync). Passed into
    /// `computeBoardStatsUpdate` so each board evaluates against its own window
    /// (`board.startDate`). Derived / compound / achievement squares are carved
    /// out INSIDE the shared kernel (they read their lifetime caches), so passing
    /// the full event map is always safe. Mirrors `buildWindowContext` in
    /// orchestration.ts.
    static func buildWindowContext(db: Database) throws -> WindowEvaluationContext {
        let events = try TaskEvent.filter(Column("isDeleted") == false).fetchAll(db)
        var eventsByTaskId: [String: [TaskEvent]] = [:]
        for e in events { eventsByTaskId[e.taskId, default: []].append(e) }
        return WindowEvaluationContext(eventsByTaskId: eventsByTaskId)
    }

    /// Resolve a single event-owning task's windowed state for `taskId` in the
    /// given board window. Convenience used by write choke points that need the
    /// current windowed count before computing a delta.
    static func windowedState(db: Database, taskId: String, windowStart: String?) throws -> TaskWindowState {
        guard let task = try Task.fetchOne(db, key: taskId) else {
            return TaskWindowState(isCompleted: false, count: 0)
        }
        let events = try TaskEvent
            .filter(Column("taskId") == taskId && Column("isDeleted") == false)
            .fetchAll(db)
        return resolveTaskWindowState(task: task, events: events, windowStart: windowStart)
    }
}
