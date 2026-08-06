import Foundation
import GRDB

/// Sentinel used to abort the recurring-spawn write transaction cleanly when
/// pool validation fails inside the txn. Caught at the call site; not surfaced
/// to callers (translated to a `.skipped` outcome). Moved here alongside the
/// `spawnRecurringBoard` transaction body (B4).
private enum RecurringSpawnAbort: Error {
    case skip
}

extension AppDatabase {
    // MARK: - RecurringBoardTemplates (Phase 6.2)

    /// Fetch all non-deleted templates for a user, ordered by `updatedAt desc`.
    func fetchRecurringBoardTemplates(userId: String) throws -> [RecurringBoardTemplate] {
        return try read { db in
            try RecurringBoardTemplate
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    /// Fetch a single template by id (including soft-deleted, for completeness).
    func fetchRecurringBoardTemplate(id: String) throws -> RecurringBoardTemplate? {
        return try read { db in
            try RecurringBoardTemplate.fetchOne(db, key: id)
        }
    }

    /// Insert / update a template. The caller is responsible for bumping
    /// `version` and `updatedAt` (mirror of `saveBoard`).
    func saveRecurringBoardTemplate(_ template: RecurringBoardTemplate) throws {
        try write { db in
            try template.save(db)
        }
    }

    /// Soft-delete a template. Spawned boards remain — they're independent
    /// once spawned (per Phase 6.2 design). Bumps `version` so LWW treats
    /// the deletion as later-wins.
    func softDeleteRecurringBoardTemplate(id: String) throws {
        try write { db in
            guard var template = try RecurringBoardTemplate.fetchOne(db, key: id) else { return }
            let now = Self.currentTimestamp()
            template.isDeleted = true
            template.deletedAt = now
            template.updatedAt = now
            template.version += 1
            try template.update(db)
        }
    }

    // MARK: - Atomic save + sync-enqueue (templates & pools)
    //
    // Mirror of `saveTaskAndEnqueueUpdate`: the model write and its
    // sync-queue item live in ONE transaction so a crash between them
    // can't leave the local row ahead of Firestore with no recovery.

    /// Save a template and enqueue its sync op atomically. The caller
    /// bumps `version`/`updatedAt` before calling; `operation` is
    /// `.create` for the first save, `.update` thereafter.
    func saveRecurringBoardTemplateAndEnqueue(
        _ template: RecurringBoardTemplate,
        operation: SyncOperationType,
        now: String
    ) throws {
        try write { db in
            try template.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "recurringBoardTemplates",
                entityId: template.id,
                operationType: operation,
                payload: template,
                now: now
            ).enqueue(db)
        }
    }

    /// Atomically spawn a Board + BoardTasks from a `PendingTemplateSpawn`
    /// and bump the template's `lastSpawnedWindowKey` — all sync-enqueued —
    /// in ONE transaction. Task resolution + pool validation happen INSIDE
    /// the write so a concurrent sync can't soft-delete a seed task between
    /// the read and the writes (which would let a board spawn against stale
    /// pool data). Validation failures roll the txn back and return a
    /// `.skipped(...)` outcome.
    ///
    /// Moved VERBATIM from `RecurringBoardSpawn.spawnTemplateBoard`'s write
    /// block so the sync-enqueue lives in the data layer. The service is now a
    /// thin wrapper that mints the `boardId` / `now` and delegates here.
    ///
    /// - Parameters:
    ///   - spawn: The pending-spawn descriptor (template + resolved window).
    ///   - boardId: The client-generated id for the new board.
    ///   - now: ISO8601 timestamp stamped on every row written here.
    /// - Returns: `.spawned(...)` on success or `.skipped(...)` with a reason.
    func spawnRecurringBoard(
        _ spawn: PendingTemplateSpawn,
        boardId: String,
        now: String
    ) throws -> RecurringSpawnOutcome {
        let template = spawn.template
        let size = template.boardSize

        // Skip outcomes are returned by setting an outer `var` from inside the
        // write closure and short-circuiting via a thrown sentinel — the
        // GRDB-idiomatic "validate inside the transaction, skip without
        // committing". The `try ... write` signature is `(Database) throws -> T`,
        // and an early-exit outcome must NOT trigger the write either, so we
        // set the outcome, `throw` to abort the txn cleanly, then catch.
        var outcome: RecurringSpawnOutcome?
        do {
            try write { db in
                // P1 (Task Pools + Recurring Boards Rework,
                // docs/POOLS_RECURRING.md §Changed: the spawn record) — the
                // task source is the resolved pool-mix, not
                // `template.seedTaskIds` directly. Post-migration EVERY
                // live template has `poolIds` set, so `seedTaskIds` is
                // never read here (left verbatim on the record for
                // decode-compat only — see `RecurringBoardTemplate`'s
                // "seedTaskIds end state" doc).
                //
                // Full-table task read (not a targeted seedTaskIds lookup):
                // `PoolMix.resolveMix` needs a `tasksById` map to filter
                // each pool's OWN resolvable supply (deleted tasks skipped
                // — derived detachment), and the same map is reused below
                // for the spawn-time derivation pass, so this isn't an
                // added read (mirrors web's `spawnTemplateBoard`).
                let allTasks = try Task.fetchAll(db)
                let tasksById = Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })

                let poolIds = template.poolIds ?? []
                let pools = poolIds.isEmpty
                    ? []
                    : try Pool.filter(poolIds.contains(Column("id"))).fetchAll(db)
                let poolsById = Dictionary(uniqueKeysWithValues: pools.map { ($0.id, $0) })

                let mix = PoolMix.resolveMix(template, poolsById: poolsById, tasksById: tasksById)
                // Resolve mix task ids → Task[] in mix order. Drops any ids
                // that don't resolve at all (e.g. a hard-gone manual
                // reference — the manual layer isn't deleted-filtered by
                // resolveMix itself); the validator below catches a
                // resolved-but-deleted task (possible for a manual-sourced
                // id) as `.hasDeletedTasks`.
                let orderedPool: [Task] = mix.taskIds.compactMap { tasksById[$0] }

                if orderedPool.isEmpty {
                    outcome = .skipped(templateId: template.id, reason: .noPoolTasksResolved)
                    throw RecurringSpawnAbort.skip
                }

                let validation = validateSpawnPool(template: template, poolTasks: orderedPool)
                if case .failure(let reason) = validation {
                    outcome = .skipped(templateId: template.id, reason: SpawnAttentionReason(reason))
                    throw RecurringSpawnAbort.skip
                }

                let placement = buildSpawnPlacement(template: template, poolTasks: orderedPool)

                // Construct Board via JSON-dict round-trip — mirrors
                // BoardWizardPersist.swift since Board has no memberwise init.
                var boardDict: [String: Any] = [
                    "id": boardId,
                    "userId": template.userId,
                    "name": spawn.suggestedName,
                    "status": BoardStatus.active.rawValue,
                    "boardSize": size,
                    "timeframe": template.timeframe.rawValue,
                    "startDate": spawn.windowStart,
                    "endDate": spawn.windowEnd,
                    "centerSquareType": template.centerSquareType.rawValue,
                    "isRandomized": template.isRandomized,
                    "totalTasks": size * size,
                    "completedTasks": 0,
                    "linesCompleted": 0,
                    "createdAt": now,
                    "updatedAt": now,
                    "version": 1,
                    "isDeleted": false,
                    "spawnedFromTemplateId": template.id,
                    // Phase 6.1 — template-spawned boards are core by
                    // construction. They fulfill the same "recurring
                    // board for this window exists" promise as banner-
                    // spawned boards, so the recurring banner detector
                    // must treat them the same.
                    "isCore": true,
                ]
                let boardData = try JSONSerialization.data(withJSONObject: boardDict)
                var board = try JSONDecoder().decode(Board.self, from: boardData)

                // Shared with the wizard-save path so the `isCenter` rule
                // stays identical: only a `.chosen` centre task is flagged
                // (a `.none` centre holds an ordinary task, not a FREE cell).
                let boardTasks = makeWizardBoardTaskRows(
                    placement: placement,
                    boardId: boardId,
                    size: size,
                    centerType: template.centerSquareType,
                    now: now
                )

                // Windowed Completion (docs/WINDOWED_COMPLETION.md §What this
                // closes — respawn-bleed row): run the derivation pass at spawn so
                // stored stats are derivation output, not a hand-initialized 0. A
                // fresh window has no events, so event-owning squares resolve
                // incomplete (no respawn bleed); a FREE center still
                // auto-fills. The invariant "stored stats are always derivation
                // output" now holds from the first row written. Mirrors the web
                // `spawnTemplateBoard` change.
                let windowContext = try AppDatabase.buildWindowContext(db: db)
                let allChildren = try CompoundChild
                    .filter(Column("isDeleted") == false)
                    .fetchAll(db)
                var childrenByCompound: [String: [CompoundChild]] = [:]
                for c in allChildren { childrenByCompound[c.compoundTaskId, default: []].append(c) }
                // Reuse the `tasksById` map read at the top of this closure
                // for mix resolution — no writes to `tasks` happen in
                // between, so it's still an accurate snapshot for the
                // derivation pass (mirrors web's reuse of `tasksById`).
                let taskById: [String: Task] = tasksById
                let allBoardsForDerivation = try Board
                    .filter(Column("isDeleted") == false)
                    .fetchAll(db)
                let stats = DerivationPass.computeBoardStatsUpdate(
                    board: board,
                    boardTasksOnBoard: boardTasks,
                    childrenByCompound: childrenByCompound,
                    taskById: taskById,
                    allBoards: allBoardsForDerivation,
                    windowContext: windowContext
                )
                board.completedTasks = stats.completedTasks
                board.linesCompleted = stats.linesCompleted
                board.completedLineIds = stats.completedLineIds

                var updatedTemplate = template
                updatedTemplate.lastSpawnedWindowKey = spawn.windowStart
                updatedTemplate.updatedAt = now
                updatedTemplate.version += 1

                try board.insert(db)

                // Board-integrity PR-5 (Item 3) — isCenter uniqueness guard,
                // same rationale + fresh in-txn read as `saveWizardBoard`
                // (AppDatabase+Boards.swift): a spawned board is always
                // brand-new so this reads 0 today, but the check (rather
                // than trusting `makeWizardBoardTaskRows`'s current
                // single-center invariant) protects against a future
                // placement-builder bug slipping a second `isCenter: true`
                // row onto the freshly-spawned board.
                var liveCenterCount = try BoardTask
                    .filter(Column("boardId") == board.id
                            && Column("isDeleted") == false
                            && Column("isCenter") == true)
                    .fetchCount(db)
                for bt in boardTasks {
                    if bt.isCenter {
                        guard liveCenterCount == 0 else {
                            throw AppDatabaseError.invalidPlacement(
                                "Board already has a center placement."
                            )
                        }
                        liveCenterCount += 1
                    }
                    try bt.insert(db)
                }
                try updatedTemplate.update(db)

                try SyncQueueBuilder.makeItem(
                    entityType: "boards",
                    entityId: board.id,
                    operationType: .create,
                    payload: board,
                    now: now
                ).enqueue(db)

                for bt in boardTasks {
                    try SyncQueueBuilder.makeItem(
                        entityType: "boardTasks",
                        entityId: bt.id,
                        operationType: .create,
                        payload: bt,
                        now: now
                    ).enqueue(db)
                }

                try SyncQueueBuilder.makeItem(
                    entityType: "recurringBoardTemplates",
                    entityId: updatedTemplate.id,
                    operationType: .update,
                    payload: updatedTemplate,
                    now: now
                ).enqueue(db)

                outcome = .spawned(
                    boardId: boardId,
                    templateId: template.id,
                    windowStart: spawn.windowStart
                )
            }
        } catch RecurringSpawnAbort.skip {
            // Expected: validation failed inside the txn, the GRDB write
            // rolled back, and `outcome` was set to a `.skipped(...)`
            // before the throw. Fall through to the return below.
        }

        return outcome ?? .skipped(templateId: template.id, reason: .spawnFailed)
    }

    /// Soft-delete a template and enqueue the delete op atomically.
    func softDeleteRecurringBoardTemplateAndEnqueue(id: String, now: String) throws {
        try write { db in
            guard var t = try RecurringBoardTemplate.fetchOne(db, key: id) else { return }
            t.isDeleted = true
            t.deletedAt = now
            t.updatedAt = now
            t.version += 1
            try t.update(db)
            try SyncQueueBuilder.makeItem(
                entityType: "recurringBoardTemplates",
                entityId: t.id,
                operationType: .delete,
                payload: t,
                now: now
            ).enqueue(db)
        }
    }

}
