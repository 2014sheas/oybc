import Foundation
import GRDB

// MARK: - Recurring board spawn — Phase 6.2 orchestration
//
// Atomically creates a Board + BoardTasks from a `PendingTemplateSpawn`
// and updates the template's `lastSpawnedWindowKey` in the same GRDB
// transaction. If the multi-step write fails partway, the entire
// transaction rolls back — the next Boards-tab open will retry.
//
// Mirrors the wizard's `BoardWizardPersist.swift` JSON-dict construction
// pattern (Board has no memberwise init, so we round-trip through
// JSONDecoder). Web twin: `apps/web/src/db/operations/recurringBoardSpawn.ts`.

/// Single-spawn outcome. `reason` is `SpawnAttentionReason` (the wider
/// driver-level union) so it can carry the driver-only outcomes
/// (`noPoolTasksResolved`, `spawnFailed`) that are not part of the
/// pure-validation `SpawnPoolFailureReason` contract.
enum RecurringSpawnOutcome {
    case spawned(boardId: String, templateId: String, windowStart: String)
    case skipped(templateId: String, reason: SpawnAttentionReason)
}

enum RecurringBoardSpawn {

    /// Spawn a single board from the pending-spawn descriptor. Returns
    /// `.spawned(...)` on success or `.skipped(...)` with a failure reason
    /// to surface as a "needs attention" indicator on the template row.
    ///
    /// Throws on infrastructure errors (GRDB exceptions, JSON encoding
    /// failures); validation failures are non-throwing skip outcomes.
    static func spawnTemplateBoard(_ spawn: PendingTemplateSpawn) throws -> RecurringSpawnOutcome {
        let template = spawn.template
        let boardId = AppDatabase.generateUUID()
        let now = AppDatabase.currentTimestamp()
        let size = template.boardSize

        // Single transaction covers task resolution + pool validation +
        // placement + writes. Folding the read inside the same write
        // block closes the soft-delete race — without it, sync could
        // soft-delete a seed task between the read and the writes,
        // allowing a board to spawn against stale pool data.
        //
        // Skip outcomes (`pool_too_small`, `has_deleted_tasks`, etc.)
        // are returned by setting an outer `var` from inside the write
        // closure and short-circuiting via a do/break-style guard. We
        // can't `return` from the GRDB write closure directly because
        // the `try ... write` signature is `(Database) throws -> T`,
        // and an early-exit outcome must NOT trigger the write either —
        // so we set the outcome and then `throw SkipMarker` to abort
        // the txn cleanly, then catch + translate. A custom thrown
        // sentinel is the GRDB-idiomatic way to do "validate inside the
        // transaction, skip without committing".
        var outcome: RecurringSpawnOutcome?
        do {
            try AppDatabase.shared.write { db in
                let allTasks = try Task
                    .filter(template.seedTaskIds.contains(Column("id")))
                    .fetchAll(db)
                let tasksById = Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })
                let orderedPool: [Task] = template.seedTaskIds.compactMap { tasksById[$0] }

                if orderedPool.isEmpty {
                    outcome = .skipped(templateId: template.id, reason: .noPoolTasksResolved)
                    throw SpawnAbort.skip
                }

                let validation = validateSpawnPool(template: template, poolTasks: orderedPool)
                if case .failure(let reason) = validation {
                    outcome = .skipped(templateId: template.id, reason: SpawnAttentionReason(reason))
                    throw SpawnAbort.skip
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
                if let custom = template.centerSquareCustomName, !custom.isEmpty {
                    boardDict["centerSquareCustomName"] = custom
                }

                let boardData = try JSONSerialization.data(withJSONObject: boardDict)
                let board = try JSONDecoder().decode(Board.self, from: boardData)

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

                var updatedTemplate = template
                updatedTemplate.lastSpawnedWindowKey = spawn.windowStart
                updatedTemplate.updatedAt = now
                updatedTemplate.version += 1

                try board.insert(db)
                for bt in boardTasks {
                    try bt.insert(db)
                }
                try updatedTemplate.update(db)

                try SyncQueueBuilder.makeItem(
                    entityType: "boards",
                    entityId: board.id,
                    operationType: .create,
                    payload: board,
                    now: now
                ).insert(db)

                for bt in boardTasks {
                    try SyncQueueBuilder.makeItem(
                        entityType: "boardTasks",
                        entityId: bt.id,
                        operationType: .create,
                        payload: bt,
                        now: now
                    ).insert(db)
                }

                try SyncQueueBuilder.makeItem(
                    entityType: "recurringBoardTemplates",
                    entityId: updatedTemplate.id,
                    operationType: .update,
                    payload: updatedTemplate,
                    now: now
                ).insert(db)

                outcome = .spawned(
                    boardId: boardId,
                    templateId: template.id,
                    windowStart: spawn.windowStart
                )
            }
        } catch SpawnAbort.skip {
            // Expected: validation failed inside the txn, the GRDB write
            // rolled back, and `outcome` was set to a `.skipped(...)`
            // before the throw. Fall through to the return below.
        }

        return outcome ?? .skipped(templateId: template.id, reason: .spawnFailed)
    }

    /// Sentinel used to abort the spawn write transaction cleanly when
    /// validation fails inside the txn. Caught at the call site; not
    /// surfaced to callers (translated to `.skipped` outcome).
    private enum SpawnAbort: Error {
        case skip
    }
}
