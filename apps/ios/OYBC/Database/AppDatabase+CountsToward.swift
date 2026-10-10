import Foundation
import GRDB

// MARK: - "Counts toward" — the cascade-written increment (data half)
//
// docs/SHARED_COUNTER_SETTINGS.md §3b. Web twin: `db/operations/countsToward.ts`.
// The pure rules live in `Helpers/CountsToward.swift`.
//
//   - `writeCountsToward` / `finishCountsTowardRoots` — the cascade hook,
//     wrapped around the board pass of every cascade entry point
//     (`runBoardCascadeForTasks`, the completion orchestration's
//     `runBoardCascadeForTaskWithResults`, the shared-counter cascade, the pull
//     cascade, the late-log re-derivation; the cascade delete via
//     `applyCountsTowardInTransaction`) inside the same write transaction: for
//     each changed task and each compound containing it, insert / revise /
//     tombstone the deterministic event on its counter root (version bump +
//     enqueue) and write the root's log like a hand log; the board pass derives
//     the copies' boards, the finish phase re-derives sealed boards + watchers.
//   - `setCountsToward` — the write-time entry (validated by `CountsToward.problem`).
//   - `countsTowardContributors` / `unflagCountsTowardContributors` — the
//     kind-switch and delete-counter guards.
extension AppDatabase {

    /// Deepest chain of counts-toward cascades one write may trigger.
    static let maxCountsTowardDepth = 3

    /// Refused `setCountsToward`; nothing is written.
    enum CountsTowardError: Error, Equatable {
        case taskMissing
        case refused(CountsToward.Problem)
    }

    /// Live tasks that count toward `counterId`.
    static func countsTowardContributors(db: Database, counterId: String) throws -> [Task] {
        try Task
            .filter(Column("countsTowardCounterId") == counterId && Column("isDeleted") == false)
            .fetchAll(db)
    }

    /// What `writeCountsToward` touched, for the caller's board pass.
    struct CountsTowardWrites {
        /// Counter roots + live / reached-frozen copies whose boards must re-derive.
        var cascadeIds: Set<String> = []
        /// Counter roots whose events moved (sealed re-derive + watchers after the pass).
        var rootIds: Set<String> = []
    }

    /// The cascade hook, WRITE phase (§3b; twin of the web
    /// `writeCountsTowardForTasks`). For every task in `changedTaskIds` and
    /// every compound transitively containing one, reconcile its credit SET —
    /// one credit per completion occurrence (D10): `resolveContributionCredits`
    /// vs the stored events at `candidateContributionIds` → `plan` → apply
    /// each action (event row, version bump, enqueue); then, for each counter
    /// root whose events moved, run a hand log's writes — restamp the root's
    /// caches, refresh window-stamped baselines, write its live copies — and
    /// re-enter one level deeper for contributors containing those copies.
    /// Board derivation is left to the caller's ONE pass over `cascadeIds` (so
    /// a copy on the contributor's own board is read with the new increment);
    /// `finishCountsTowardRoots` runs after it. Idempotent. Cheap when nothing
    /// counts toward anything (candidates, their placements, own events and
    /// stored credits are read by key / index).
    ///
    /// - Parameters:
    ///   - db: The caller's write transaction.
    ///   - changedTaskIds: Tasks whose derived state may have changed.
    ///   - now: The write instant.
    ///   - pullOwnerUid: `nil` for a local write; the PULL's uid on the pull
    ///     path (it owns every enqueue).
    ///   - depth: Chain depth (0 for a top-level call).
    /// - Returns: The ids the caller's board pass must add, and the roots to finish.
    static func writeCountsToward(
        db: Database, changedTaskIds: [String], now: String, pullOwnerUid: String? = nil, depth: Int = 0
    ) throws -> CountsTowardWrites {
        var out = CountsTowardWrites()
        guard depth <= maxCountsTowardDepth, !changedTaskIds.isEmpty else { return out }
        let allChildren = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
        var candidates: [String] = []
        for id in changedTaskIds {
            if !candidates.contains(id) { candidates.append(id) }
            for parent in DerivationPass.findTransitiveParentCompounds(changedTaskId: id, children: allChildren)
            where !candidates.contains(parent) {
                candidates.append(parent)
            }
        }
        let candidateTasks = try Task.fetchAll(db, keys: candidates)
        guard !candidateTasks.isEmpty else { return out }

        // The candidates' keyed data (indexed reads): fork ancestors, own
        // events (any state — the candidate keys), placements and their boards.
        let data = try loadCountsTowardCandidateData(db: db, rows: candidateTasks)
        func liteInputs(_ task: Task) -> CountsToward.Inputs {
            CountsToward.Inputs(
                taskById: data.lineageById, childrenByCompound: [:], eventsByTaskId: [:],
                allEventsByTaskId: data.allEventsByTaskId,
                placements: data.placements.filter { $0.taskId == task.id }, boardById: data.boardById
            )
        }
        var candidateIdsByTask: [String: [String]] = [:]
        for task in candidateTasks {
            candidateIdsByTask[task.id] = CountsToward.candidateContributionIds(task, inputs: liteInputs(task))
        }
        var storedById: [String: TaskEvent] = [:]
        for e in try TaskEvent.fetchAll(db, keys: Set(candidateIdsByTask.values.joined())) { storedById[e.id] = e }
        let relevant = candidateTasks.filter { task in
            task.countsTowardCounterId != nil
                || (candidateIdsByTask[task.id] ?? []).contains { storedById[$0] != nil }
        }
        guard !relevant.isEmpty else { return out }

        var taskById: [String: Task] = [:]
        for t in try Task.fetchAll(db) { taskById[t.id] = t }
        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in allChildren { childrenByCompound[c.compoundTaskId, default: []].append(c) }
        let eventsByTaskId = try buildWindowContext(db: db).eventsByTaskId

        var reach: [(rootId: String, instants: [String])] = []
        for task in relevant {
            var inputs = liteInputs(task)
            inputs.taskById = taskById
            inputs.childrenByCompound = childrenByCompound
            inputs.eventsByTaskId = eventsByTaskId
            let wanted = CountsToward.resolveContributionCredits(task, inputs: inputs)
            let missing = wanted.map(\.eventId).filter { storedById[$0] == nil }
            for e in try TaskEvent.fetchAll(db, keys: missing) { storedById[e.id] = e }
            let actions = CountsToward.plan(
                contributor: task, taskById: taskById, wanted: wanted,
                candidateIds: candidateIdsByTask[task.id] ?? [], storedById: storedById
            )
            for action in actions {
                try writeCountsTowardAction(
                    db: db, action: action, userId: task.userId, existing: storedById[action.eventId], now: now, pullOwnerUid: pullOwnerUid
                )
                for r in action.reach {
                    if let i = reach.firstIndex(where: { $0.rootId == r.rootId }) {
                        if !reach[i].instants.contains(r.occurredAt) { reach[i].instants.append(r.occurredAt) }
                    } else {
                        reach.append((r.rootId, [r.occurredAt]))
                    }
                }
            }
        }
        for r in reach {
            let ids = try writeCounterRootLog(db: db, rootId: r.rootId, instants: r.instants, now: now, pullOwnerUid: pullOwnerUid)
            guard !ids.isEmpty else { continue }
            out.rootIds.insert(r.rootId)
            out.cascadeIds.formUnion(ids)
            // Chained contributors: a compound containing one of these copies.
            let deeper = try writeCountsToward(
                db: db, changedTaskIds: Array(ids), now: now, pullOwnerUid: pullOwnerUid, depth: depth + 1
            )
            out.cascadeIds.formUnion(deeper.cascadeIds)
            out.rootIds.formUnion(deeper.rootIds)
        }
        return out
    }

    /// The per-candidate rows the planner reads (twin of the web `CandidateData`).
    private struct CountsTowardCandidateData {
        /// The candidates plus their fork ancestors.
        var lineageById: [String: Task]
        var allEventsByTaskId: [String: [TaskEvent]]
        var placements: [BoardTask]
        var boardById: [String: Board]
    }

    /// Deepest `forkedFromTaskId` chain loaded for a candidate (a fork of a fork…).
    private static let maxCountsTowardForkLineage = 8

    /// Load the keyed rows every candidate's keys derive from (indexed reads only).
    private static func loadCountsTowardCandidateData(db: Database, rows: [Task]) throws -> CountsTowardCandidateData {
        var lineageById: [String: Task] = [:]
        for t in rows { lineageById[t.id] = t }
        var frontier = rows.compactMap(\.forkedFromTaskId).filter { lineageById[$0] == nil }
        var depth = 0
        while !frontier.isEmpty, depth < maxCountsTowardForkLineage {
            let found = try Task.fetchAll(db, keys: Set(frontier))
            for t in found { lineageById[t.id] = t }
            frontier = found.compactMap(\.forkedFromTaskId).filter { lineageById[$0] == nil }
            depth += 1
        }
        var allEventsByTaskId: [String: [TaskEvent]] = [:]
        for e in try TaskEvent.filter(Array(lineageById.keys).contains(Column("taskId"))).fetchAll(db) {
            allEventsByTaskId[e.taskId, default: []].append(e)
        }
        let placements = try BoardTask.filter(rows.map(\.id).contains(Column("taskId"))).fetchAll(db)
        var boardById: [String: Board] = [:]
        for b in try Board.fetchAll(db, keys: Set(placements.map(\.boardId))) { boardById[b.id] = b }
        return CountsTowardCandidateData(
            lineageById: lineageById, allEventsByTaskId: allEventsByTaskId, placements: placements, boardById: boardById
        )
    }

    /// Apply one planned write: the event row + its sync entry.
    private static func writeCountsTowardAction(
        db: Database, action: CountsToward.Action, userId: String, existing: TaskEvent?, now: String, pullOwnerUid: String?
    ) throws {
        let owner = pullOwnerUid ?? SyncQueueOwnership.currentUid()
        func enqueue(_ e: TaskEvent, _ op: SyncOperationType) throws {
            try SyncQueueBuilder.makeItem(
                entityType: "taskEvents", entityId: e.id, operationType: op, payload: e, now: now, ownerUid: owner
            ).enqueue(db)
        }
        switch action {
        case let .insert(eventId, rootId, delta, occurredAt):
            let event = TaskEvent(
                id: eventId, userId: userId, taskId: rootId, kind: .increment, delta: CountValue(delta),
                occurredAt: occurredAt, boardId: nil, createdAt: now, updatedAt: now, lastSyncedAt: nil,
                version: 1, isDeleted: false, deletedAt: nil
            )
            try event.save(db)
            try enqueue(event, .create)
        case .tombstone:
            guard var e = existing else { return }
            e.isDeleted = true
            e.deletedAt = now
            e.updatedAt = now
            e.version += 1
            try e.save(db)
            try enqueue(e, .delete)
        case let .revise(_, rootId, delta, occurredAt, _, _, _):
            guard var e = existing else { return }
            e.taskId = rootId
            e.kind = .increment
            e.delta = CountValue(delta)
            e.occurredAt = occurredAt
            e.isDeleted = false
            e.deletedAt = nil
            e.updatedAt = now
            e.version += 1
            try e.save(db)
            // `save` skips nil keys — clear the tombstone stamp explicitly.
            try db.execute(sql: "UPDATE task_events SET deletedAt = NULL WHERE id = ?", arguments: [e.id])
            try enqueue(e, .update)
        }
    }

    /// A counter root's events moved: a hand log's writes without the board
    /// cascade — restamp the root's caches, refresh window-stamped baselines,
    /// write its live copies, name the frozen copies whose window holds a
    /// moved instant. Returns the root + copy ids (empty for a deleted root).
    private static func writeCounterRootLog(
        db: Database, rootId: String, instants: [String], now: String, pullOwnerUid: String?
    ) throws -> Set<String> {
        guard let root = try Task.fetchOne(db, key: rootId), !root.isDeleted, let first = instants.first else { return [] }
        let owner = pullOwnerUid ?? SyncQueueOwnership.currentUid()
        try stampTaskCachesAuthored(db: db, taskId: rootId, now: now, ownerUid: owner)
        try refreshDerivedBaselines(db: db, rootTaskId: rootId)
        var ids: Set<String> = [rootId]
        ids.formUnion(try propagateRootLogToLinkedRows(db: db, rootId: rootId, reachOccurredAt: first, now: now, ownerUid: owner))
        for at in instants.dropFirst() {
            ids.formUnion(try fetchLinkedTasksForLog(db: db, sourceTaskId: rootId, reachOccurredAt: at, now: now).reachedFrozenIds)
        }
        return ids
    }

    /// The cascade hook, FINISH phase — after the caller's board pass:
    /// re-derive the sealed boards placing the roots' copies and refresh the
    /// achievement watchers of every board reached (non-authored on a pull).
    static func finishCountsTowardRoots(db: Database, rootIds: Set<String>, now: String, pullOwnerUid: String? = nil) throws {
        guard !rootIds.isEmpty else { return }
        try reDeriveSealedBoards(db: db, changedTaskIds: rootIds)
        let boardIds = try boardIdsReachedByTasks(db: db, taskIds: rootIds)
        if pullOwnerUid != nil {
            try refreshWatchersAfterPull(db: db, boardIds: boardIds)
        } else {
            try refreshWatchersForBoards(db: db, changedBoardIds: boardIds, now: now)
        }
    }

    /// The whole hook for a write path with no board cascade of its own (the
    /// cascade delete): write phase, a board pass over what it touched, finish.
    static func applyCountsTowardInTransaction(db: Database, taskIds: [String], now: String) throws {
        let writes = try writeCountsToward(db: db, changedTaskIds: taskIds, now: now)
        if !writes.cascadeIds.isEmpty {
            try runBoardCascadeForTasks(db: db, changedTaskIds: Array(writes.cascadeIds), now: now)
        }
        try finishCountsTowardRoots(db: db, rootIds: writes.rootIds, now: now)
    }

    /// Set (or clear, with `counterId == nil`) what a task counts toward, then
    /// run its cascade so the credits follow at once (a cleared flag tombstones
    /// every live credit). Authored: version bump +
    /// UPDATE enqueue; a clear writes NULL to both columns (raw SQL — `encode`
    /// nil-skips; clearable on sync).
    ///
    /// - Throws: `CountsTowardError.refused` with the `CountsToward.problem` code.
    func setCountsToward(taskId: String, counterId: String?, amount: Int? = nil) throws {
        try write { db in
            let now = Self.currentTimestamp()
            guard var task = try Task.fetchOne(db, key: taskId), !task.isDeleted else {
                throw CountsTowardError.taskMissing
            }
            if let counterId, let problem = CountsToward.problem(
                task: task, targetId: counterId, amount: amount.map(Double.init),
                tasks: try Task.fetchAll(db),
                children: try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
            ) {
                throw CountsTowardError.refused(problem)
            }
            task.countsTowardCounterId = counterId
            task.countsTowardAmount = counterId == nil ? nil : amount
            task.updatedAt = now
            task.version += 1
            try task.save(db)
            try Self.writeCountsTowardColumns(db: db, task: task)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks", entityId: task.id, operationType: .update, payload: task, now: now
            ).enqueue(db)
            try Self.runBoardCascadeForTasks(db: db, changedTaskIds: [task.id], now: now)
        }
    }

    /// Write both counts-toward columns as stored on `task`, NULL included
    /// (GRDB's update only SETs encoded keys, and `Task.encode` nil-skips).
    static func writeCountsTowardColumns(db: Database, task: Task) throws {
        try db.execute(
            sql: "UPDATE tasks SET countsTowardCounterId = ?, countsTowardAmount = ? WHERE id = ?",
            arguments: [task.countsTowardCounterId, task.countsTowardAmount, task.id]
        )
    }

    /// Clear `countsTowardCounterId` on every live contributor of a counter that
    /// is being deleted (§3e). Authored; the events stay with the deleted root.
    static func unflagCountsTowardContributors(db: Database, counterId: String, now: String) throws {
        for var c in try countsTowardContributors(db: db, counterId: counterId) {
            c.countsTowardCounterId = nil
            c.countsTowardAmount = nil
            c.updatedAt = now
            c.version += 1
            try c.save(db)
            try writeCountsTowardColumns(db: db, task: c)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks", entityId: c.id, operationType: .update, payload: c, now: now
            ).enqueue(db)
        }
    }
}
