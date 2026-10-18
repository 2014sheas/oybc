import Foundation
import GRDB

// MARK: - Placement sweep applier (TASK_WINDOW_REWORK slice 4a — derived counters)
//
// Writes the plan `BoardSources.planPlacementSweep` computes (the Swift twin of
// web `db/operations/placementSweep.ts`): repoints placements at the root with
// the frozen goal as a placement parameter, strips the window marks of rows on
// refused boards, tombstones orphans, re-keys stored rules (templates, pools,
// draft blobs), and re-derives the touched boards. State-based and
// idempotent: a second run over its own output plans nothing except the
// deferred orphans (a row this run repointed away from retires next run).
// Runs at database open (migration v47), after every clean pull and once per
// launch for the signed-in user. Never throws into a pull or launch.

/// What one sweep run wrote.
struct PlacementSweepSummary: Equatable {
    var repointed = 0
    var sealedRepointed = 0
    var stripped = 0
    var orphansTombstoned = 0
    var templatesRekeyed = 0
    var poolsRekeyed = 0
    var draftsRekeyed = 0
    /// Boards the equivalence gate (or a missing / duplicate root) refused.
    var refused: [BoardSources.SweepBoardOutcome] = []

    /// True when the run authored at least one row.
    var wroteAnything: Bool {
        repointed + sealedRepointed + stripped + orphansTombstoned + templatesRekeyed + poolsRekeyed + draftsRekeyed > 0
    }

    /// Total authored rows the run touched (for the pull's details line).
    var writeCount: Int {
        repointed + sealedRepointed + stripped + orphansTombstoned + templatesRekeyed + poolsRekeyed + draftsRekeyed
    }
}

extension AppDatabase {

    /// Runs the sweep for one user inside the caller's write transaction.
    ///
    /// - Parameters:
    ///   - db: The open write transaction.
    ///   - userId: The user whose workspace is swept.
    ///   - now: ISO8601 write stamp.
    /// - Returns: What was written; an empty plan writes nothing.
    @discardableResult
    static func runPlacementSweepTx(db: Database, userId: String, now: String) throws -> PlacementSweepSummary {
        var summary = PlacementSweepSummary()
        let tasks = try Task.filter(Column("userId") == userId).fetchAll(db)
        let boards = try Board.filter(Column("userId") == userId).fetchAll(db)
        let boardIds = Set(boards.map(\.id))
        let boardTasks = try BoardTask.fetchAll(db).filter { boardIds.contains($0.boardId) }
        let taskIds = Set(tasks.map(\.id))
        let links = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
            .filter { taskIds.contains($0.compoundTaskId) }
        let events = try TaskEvent.filter(Column("userId") == userId && Column("isDeleted") == false).fetchAll(db)

        let ws = BoardSources.SweepWorkspace(
            tasks: tasks, boards: boards, boardTasks: boardTasks, compoundChildren: links, events: events
        )
        let plan = BoardSources.planPlacementSweep(ws: ws, now: now)
        if plan.isEmpty && plan.rekey.isEmpty { return summary }
        summary.refused = plan.outcomes.filter { $0.outcome == .refused }

        // Repoints (sealed ones through the named exception path).
        var sealedTouched = Set<String>()
        for r in plan.repoints {
            if r.sealed {
                if try repointSealedPlacement(db: db, boardTaskId: r.boardTaskId, repoint: r, now: now) {
                    summary.sealedRepointed += 1
                    sealedTouched.insert(r.boardId)
                }
            } else if try repointLivePlacement(db: db, boardTaskId: r.boardTaskId, repoint: r, now: now) {
                summary.repointed += 1
            }
        }

        // Strips: a refused board's marked rows lose their window marks.
        for id in plan.strips where try stripWindowMarks(db: db, taskId: id, now: now) { summary.stripped += 1 }

        // Orphans (marked, unplaced and unlinked before this run).
        summary.orphansTombstoned = try softDeleteWindowStampedDerived(db: db, taskIds: plan.orphanTombstones, now: now)

        // Rule re-keys.
        if !plan.rekey.isEmpty {
            let taskById = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            summary.templatesRekeyed = try rekeyTemplates(db: db, userId: userId, map: plan.rekey, taskById: taskById, now: now)
            summary.poolsRekeyed = try rekeyPools(db: db, userId: userId, map: plan.rekey, now: now)
            summary.draftsRekeyed = try rekeyDraftBlobs(db: db, boards: boards, map: plan.rekey, now: now)
        }

        // Re-derive: sealed boards deterministically (no version bump), live ones through the live path.
        if !sealedTouched.isEmpty { try reDeriveSealedBoardSnapshots(db: db, boardIds: sealedTouched) }
        for id in plan.touchedBoardIds where !sealedTouched.contains(id) {
            try reDeriveLiveBoardTx(db: db, boardId: id, now: now)
        }
        return summary
    }

    /// The once-per-launch trigger (signed-in hook): sweeps one user's workspace
    /// in its own async write. Errors are logged, never thrown — the app opens
    /// regardless. State-based, so a repeat launch finds nothing to do.
    ///
    /// - Parameter userId: The signed-in user.
    /// - Returns: What the run wrote (empty on failure).
    @discardableResult
    func runPlacementSweepOnOpen(userId: String) async -> PlacementSweepSummary {
        do {
            let now = Self.currentTimestamp()
            return try await writeAsync { db in try AppDatabase.runPlacementSweepTx(db: db, userId: userId, now: now) }
        } catch {
            dlog("[PlacementSweep] open sweep skipped: \(error.localizedDescription)")
            return PlacementSweepSummary()
        }
    }

    // MARK: Placement writes

    /// A live placement's repoint: `taskId`, the override / kind / title set or
    /// cleared (explicit SQL NULL), `childTargets` set or cleared likewise, `version += 1`,
    /// one `boardTasks` UPDATE enqueue.
    ///
    /// - Returns: True when the placement was written (false when it moved on since the plan).
    @discardableResult
    static func repointLivePlacement(db: Database, boardTaskId: String, repoint: BoardSources.SweepRepoint, now: String) throws -> Bool {
        try writeSweepRepoint(db: db, boardTaskId: boardTaskId, repoint: repoint, now: now)
    }

    /// The documented exception to "sealed boards never mutate" (TASK_WINDOW_REWORK
    /// §Migration sweep, slice 4): the same write as a live repoint, on a sealed
    /// board's placement. Deterministic content, re-derivation proven equal by
    /// the planner's gate; the caller re-derives the sealed snapshot afterwards.
    ///
    /// - Returns: True when the placement was written.
    @discardableResult
    static func repointSealedPlacement(db: Database, boardTaskId: String, repoint: BoardSources.SweepRepoint, now: String) throws -> Bool {
        try writeSweepRepoint(db: db, boardTaskId: boardTaskId, repoint: repoint, now: now)
    }

    private static func writeSweepRepoint(db: Database, boardTaskId: String, repoint: BoardSources.SweepRepoint, now: String) throws -> Bool {
        guard let current = try BoardTask.fetchOne(db, key: boardTaskId), !current.isDeleted,
              current.taskId == repoint.fromTaskId else { return false }
        var patch = PlacementParamsPatch()
        if let t = repoint.targetOverride {
            patch.targetOverride = .set(t)
            patch.targetKind = repoint.targetKind.map { .set($0) } ?? .clear
        } else {
            patch.targetOverride = .clear
            patch.targetKind = .clear
        }
        patch.childTargets = repoint.childTargets.map { .set($0) } ?? .clear
        patch.titleOverride = repoint.titleOverride.map { .set($0) } ?? .clear
        var next = current.applyingPlacementParams(patch)
        next.taskId = repoint.toTaskId
        next.updatedAt = now
        next.version += 1
        try next.save(db)
        try db.execute(sql: "UPDATE board_tasks SET taskId = ? WHERE id = ?", arguments: [next.taskId, next.id])
        try writePlacementParamColumns(db: db, boardTask: next)
        try SyncQueueBuilder.makeItem(
            entityType: "boardTasks", entityId: next.id, operationType: .update, payload: next, now: now
        ).enqueue(db)
        return true
    }

    // MARK: Strips

    /// NULLs a refused board's marked row's `timeframe` / `startDate` / `endDate`,
    /// zeroes `baseline`, bumps `version` and enqueues the UPDATE (the clearable
    /// fields carry the clears). A row that is no longer marked is left alone.
    private static func stripWindowMarks(db: Database, taskId: String, now: String) throws -> Bool {
        guard let task = try Task.fetchOne(db, key: taskId), !task.isDeleted,
              BoardSources.isWindowStampedDerived(task) || BoardSources.isWindowStampedDerivedCompound(task) else { return false }
        try db.execute(
            sql: "UPDATE tasks SET timeframe = NULL, startDate = NULL, endDate = NULL, baseline = 0, version = version + 1, updatedAt = ? WHERE id = ?",
            arguments: [now, taskId]
        )
        guard let stripped = try Task.fetchOne(db, key: taskId) else { return false }
        try SyncQueueBuilder.makeItem(
            entityType: "tasks", entityId: taskId, operationType: .update, payload: stripped, now: now
        ).enqueue(db)
        return true
    }

    // MARK: Re-keys

    private static func rekeyTemplates(
        db: Database, userId: String, map: [String: String], taskById: [String: Task], now: String
    ) throws -> Int {
        var count = 0
        let templates = try RecurringBoardTemplate.filter(Column("userId") == userId && Column("isDeleted") == false).fetchAll(db)
        for original in templates {
            var t = original
            t.seedTaskIds = BoardSources.rekeyIds(t.seedTaskIds, map: map)
            t.manualTaskIds = t.manualTaskIds.map { BoardSources.rekeyIds($0, map: map) }
            t.removedTaskIds = t.removedTaskIds.map { BoardSources.rekeyIds($0, map: map) }
            t.sources = t.sources.map { rekeySources($0, map: map) }
            t.manualTaskVary = t.manualTaskVary.map { BoardSources.rekeyRecordKeys($0, map: map) }
            var targets = t.manualTaskTargets.map { BoardSources.rekeyRecordKeys($0, map: map) }
            // A hand-added derived task re-keyed to its root keeps its frozen goal.
            for id in original.manualTaskIds ?? [] {
                guard let root = map[id], let row = taskById[id], let goal = row.maxCount, goal > 0 else { continue }
                var m = targets ?? [:]
                if m[root] == nil {
                    m[root] = ManualTaskTarget(target: goal, kind: resolveCountKind(row.countKind))
                    targets = m
                }
            }
            t.manualTaskTargets = targets
            if t.seedTaskIds == original.seedTaskIds, t.manualTaskIds == original.manualTaskIds,
               t.removedTaskIds == original.removedTaskIds, t.sources == original.sources,
               t.manualTaskVary == original.manualTaskVary, t.manualTaskTargets == original.manualTaskTargets { continue }
            t.updatedAt = now
            t.version += 1
            try t.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "recurringBoardTemplates", entityId: t.id, operationType: .update, payload: t, now: now
            ).enqueue(db)
            count += 1
        }
        return count
    }

    private static func rekeyPools(db: Database, userId: String, map: [String: String], now: String) throws -> Int {
        var count = 0
        let pools = try Pool.filter(Column("userId") == userId && Column("isDeleted") == false).fetchAll(db)
        for original in pools {
            var p = original
            p.taskIds = BoardSources.rekeyIds(p.taskIds, map: map)
            p.memberVary = BoardSources.rekeyRecordKeys(p.memberVary, map: map)
            if p.taskIds == original.taskIds, p.memberVary == original.memberVary { continue }
            p.updatedAt = now
            p.version += 1
            try p.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "pools", entityId: p.id, operationType: .update, payload: p, now: now
            ).enqueue(db)
            count += 1
        }
        return count
    }

    /// Every DRAFT board's `recurringDraftMix` blob: re-key `sources`,
    /// `manualTaskVary` and `placementParams`. A blob that fails to decode is left alone.
    private static func rekeyDraftBlobs(db: Database, boards: [Board], map: [String: String], now: String) throws -> Int {
        var count = 0
        for board in boards where !board.isDeleted && board.status == .draft {
            guard let json = board.recurringDraftMix, let data = json.data(using: .utf8),
                  var payload = try? JSONDecoder().decode(RecurringDraftMixPayload.self, from: data) else { continue }
            if payload.sources == nil {
                payload.sources = BoardSources.sourcesFromMixFields(poolIds: payload.poolIds, removedTaskIds: payload.removedTaskIds)
            }
            let before = payload
            payload.sources = payload.sources.map { rekeySources($0, map: map) }
            payload.manualTaskVary = BoardSources.rekeyRecordKeys(payload.manualTaskVary, map: map)
            payload.placementParams = BoardSources.rekeyRecordKeys(payload.placementParams, map: map)
            if payload.sources == before.sources, payload.manualTaskVary == before.manualTaskVary,
               payload.placementParams == before.placementParams { continue }
            guard let encoded = payload.encoded() else { continue }
            try db.execute(
                sql: "UPDATE boards SET recurringDraftMix = ?, version = version + 1, updatedAt = ? WHERE id = ?",
                arguments: [encoded, now, board.id]
            )
            if let updated = try Board.fetchOne(db, key: board.id) {
                try SyncQueueBuilder.makeItem(
                    entityType: "boards", entityId: board.id, operationType: .update, payload: updated, now: now
                ).enqueue(db)
                count += 1
            }
        }
        return count
    }

    /// `excludedTaskIds` via `rekeyIds`; `memberRules` and each rule's `parts` via `rekeyRecordKeys`.
    private static func rekeySources(_ sources: [BoardSource], map: [String: String]) -> [BoardSource] {
        sources.map { s in
            var out = s
            out.excludedTaskIds = BoardSources.rekeyIds(s.excludedTaskIds, map: map)
            if let rules = s.memberRules {
                var rekeyed = BoardSources.rekeyRecordKeys(rules, map: map)
                for (k, rule) in rekeyed {
                    guard let parts = rule.parts else { continue }
                    var r = rule
                    r.parts = BoardSources.rekeyRecordKeys(parts, map: map)
                    rekeyed[k] = r
                }
                out.memberRules = rekeyed
            }
            return out
        }
    }
}
