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
    /// Leaving Discrete while tasks count toward the counter
    /// (docs/SHARED_COUNTER_SETTINGS.md D9) — see `countsTowardMessage`.
    case hasContributors

    /// Refusal line for `hasContributors` (web `COUNTS_TOWARD_KIND_MESSAGE`).
    static let countsTowardMessage = "A counter other tasks count toward stays Discrete."
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
    ///   - settings: The counter ROOT's name + templates — the title is judged
    ///     and re-rendered through them (docs/SHARED_COUNTER_SETTINGS.md §1b);
    ///     nil = the task's own (a root).
    /// - Returns: The preview, or nil when the switch is refused.
    static func planned(
        task: Task, to: CountKind, linkedCount: Int, settings: CounterSettings.TitleSettings? = nil
    ) -> KindSwitchPreview? {
        let settings = settings ?? CounterSettings.TitleSettings(task: task)
        let from = resolveCountKind(task.countKind)
        guard let patch = planCountKindSwitch(
            maxCount: task.maxCount, defaultLogAmount: task.defaultLogAmount, from: from, to: to
        ) else { return nil }
        let action = task.action ?? ""
        let unit = task.unit ?? ""
        let auto = TaskTitle.isAutoCounterTitle(
            title: task.title, action: action, maxCount: task.maxCount, unit: unit, countKind: from,
            settings: settings
        )
        let loggedBefore = quantizeCount(task.currentCount ?? 0)
        return KindSwitchPreview(
            from: from,
            to: to,
            titleBefore: task.title,
            titleAfter: auto
                ? TaskTitle.generateCounterTaskTitle(
                    action: action, maxCount: patch.maxCount ?? task.maxCount, unit: unit, countKind: to,
                    settings: settings
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
    /// root and on every row `familyRowsToSwitch` returns (live linked rows no
    /// sealed board holds — a closed board's copy keeps its kind and goal
    /// until Reopen re-aligns it, the same exclusion as root → copy
    /// propagation), each with a version bump + `.update` enqueue. Then the board cascade re-derives
    /// every board placing a written row (a placement's frozen `targetKind`
    /// keeps its goal's kind). `task_events` are never touched: a whole kind
    /// rounds the window SUM at read time, so switching back restores the
    /// exact fractional count. The root's lifetime caches (`isCompleted` /
    /// `currentCount` / `completedAt` / `totalCompletions`) are restamped from
    /// events in the same write; a linked row's caches are never read (it
    /// resolves from the root's events) and are not written.
    ///
    /// - Parameters:
    ///   - rootTaskId: The counter root (a COUNTING task with no `sharedCounterId`).
    ///   - to: The requested kind.
    ///   - now: The switch instant.
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
    ///   - now: The switch instant.
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
        // D9 — "counts toward" targets Discrete counters only.
        if to != .discrete, try !Self.countsTowardContributors(db: db, counterId: root.id).isEmpty {
            throw CountKindSwitchError.hasContributors
        }
        // The root's lifetime caches recomputed from events in the same write.
        var patchedRoot = root
        if let maxCount = rootPatch.maxCount { patchedRoot.maxCount = maxCount }
        patchedRoot.countKind = to
        let rootEvents = try TaskEvent.filter(Column("taskId") == root.id).fetchAll(db)
        let rootCaches = Self.computeTaskCachesFromEvents(task: patchedRoot, events: rootEvents)
        try Self.writeKindSwitch(db: db, task: root, to: to, patch: rootPatch, now: nowIso, caches: rootCaches)
        var writtenIds = [root.id]

        for (row, rowPatch) in try Self.familyRowsToSwitch(db: db, rootId: root.id, to: to) {
            try Self.writeKindSwitch(db: db, task: row, to: to, patch: rowPatch, now: nowIso, caches: nil)
            writtenIds.append(row.id)
        }

        try Self.runBoardCascadeForTasks(db: db, changedTaskIds: writtenIds, now: nowIso)
        // A root placed on a CLOSED board re-derives deterministically (the
        // sanctioned sealed path — the live cascade skips it). No written copy
        // is on one: `familyRowsToSwitch` leaves those untouched.
        try Self.reDeriveSealedBoards(db: db, changedTaskIds: Set(writtenIds))
        return writtenIds
    }

    /// The linked rows a kind switch of `rootId` to `to` writes, each with its
    /// `planCountKindSwitch` patch: live rows linked to the root whose kind
    /// actually moves, minus any a sealed board holds — directly or as a
    /// sub-task of a compound placed there (issue #576 item 2; the exclusion
    /// `RootFieldPropagation.plan` applies, via the same
    /// `taskIdsReachingSealedBoards`). Shared by the switch and its preview so
    /// the confirm's count is exactly the rows written. Twin of the web
    /// `familyRowsToSwitch`.
    ///
    /// - Parameters:
    ///   - db: An open transaction (read or write).
    ///   - rootId: The counter root.
    ///   - to: The requested kind.
    /// - Returns: The rows to write, in fetch order.
    /// - Throws: A database error if a read fails.
    static func familyRowsToSwitch(
        db: Database, rootId: String, to: CountKind
    ) throws -> [(row: Task, patch: CountKindSwitchPatch)] {
        let family = try Task
            .filter(Column("sharedCounterId") == rootId)
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        var moving: [(row: Task, patch: CountKindSwitchPatch)] = []
        for row in family {
            guard let patch = planCountKindSwitch(
                maxCount: row.maxCount,
                defaultLogAmount: row.defaultLogAmount,
                from: resolveCountKind(row.countKind),
                to: to
            ) else { continue } // already `to` (or a kind that never switches)
            moving.append((row: row, patch: patch))
        }
        let sealed = try taskIdsReachingSealedBoards(db: db, taskIds: Set(moving.map(\.row.id)))
        return moving.filter { !sealed.contains($0.row.id) } // a closed board's record
    }

    /// Reopen's kind re-alignment (docs/COUNTER_KINDS.md D5): a linked row's
    /// kind mirrors its root's except while a sealed board holds it. When
    /// Reopen frees `boardId`, every live linked COUNTING row that board
    /// reaches (directly or through a placed compound) whose kind differs from
    /// its root's — and that no OTHER sealed board still holds — takes the
    /// root's kind through `planCountKindSwitch`, as the kind switch would have
    /// written it: one authored write each (version bump + `.update` enqueue).
    /// Twin of the web `realignLinkedKindsOnReopen`.
    ///
    /// Must run inside Reopen's write, AFTER the seal is cleared. It does not
    /// cascade: the caller re-derives the boards the returned rows reach.
    ///
    /// - Parameters:
    ///   - db: Reopen's open write transaction.
    ///   - boardId: The board just reopened.
    ///   - now: ISO8601 write time.
    /// - Returns: The ids of the rows re-aligned.
    /// - Throws: A database error if a read or write fails.
    static func realignLinkedKindsOnReopen(db: Database, boardId: String, now: String) throws -> [String] {
        let linked = try Task.filter(Column("isDeleted") == false)
            .fetchAll(db)
            .filter { $0.type == .counting && $0.sharedCounterId != nil }
        guard !linked.isEmpty else { return [] }
        let rootIds = Array(Set(linked.compactMap(\.sharedCounterId)))
        let roots = Dictionary(
            try Task.filter(rootIds.contains(Column("id"))).fetchAll(db)
                .filter { !$0.isDeleted && $0.type == .counting }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var drifted: [(row: Task, patch: CountKindSwitchPatch, to: CountKind)] = []
        for row in linked {
            guard let rootId = row.sharedCounterId, let root = roots[rootId] else { continue }
            let to = resolveCountKind(root.countKind)
            guard let patch = planCountKindSwitch(
                maxCount: row.maxCount,
                defaultLogAmount: row.defaultLogAmount,
                from: resolveCountKind(row.countKind),
                to: to
            ) else { continue } // already the root's kind
            drifted.append((row: row, patch: patch, to: to))
        }
        guard !drifted.isEmpty else { return [] }

        let reach = try reachedBoardIdsByTask(db: db, taskIds: Set(drifted.map(\.row.id)))
        let sealed = try liveSealedBoardIds(db: db)
        var written: [String] = []
        for entry in drifted {
            let boards = reach[entry.row.id] ?? []
            guard boards.contains(boardId), boards.isDisjoint(with: sealed) else { continue }
            try writeKindSwitch(db: db, task: entry.row, to: entry.to, patch: entry.patch, now: now, caches: nil)
            written.append(entry.row.id)
        }
        return written
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
    ///   - now: Switch instant.
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
    /// - Returns: The preview, or nil for a missing / non-counting / linked
    ///   task or a refused switch.
    func previewCounterKindSwitch(rootTaskId: String, to: CountKind) throws -> KindSwitchPreview? {
        try read { db in
            guard let root = try Task.fetchOne(db, key: rootTaskId), !root.isDeleted,
                  root.type == .counting, root.sharedCounterId == nil else { return nil }
            // Exactly the rows switchCounterKind(db:…) would write.
            let linkedCount = try Self.familyRowsToSwitch(db: db, rootId: root.id, to: to).count
            return KindSwitchPreview.planned(task: root, to: to, linkedCount: linkedCount)
        }
    }

    /// One authored kind-switch write: kind + rounded fields, version bump,
    /// `.update` enqueue. Runs inside the caller's write transaction.
    private static func writeKindSwitch(
        db: Database, task: Task, to: CountKind, patch: CountKindSwitchPatch, now: String,
        caches: TaskCacheFields?
    ) throws {
        var updated = task
        if let caches {
            updated.isCompleted = caches.isCompleted
            updated.currentCount = caches.currentCount
            updated.completedAt = caches.completedAt
            updated.totalCompletions = caches.totalCompletions
        }
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
