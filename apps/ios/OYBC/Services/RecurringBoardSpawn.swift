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

/// Single-spawn outcome.
enum RecurringSpawnOutcome {
    case spawned(boardId: String, templateId: String, windowStart: String)
    case skipped(templateId: String, reason: SpawnPoolFailureReason)
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

        // Resolve seedTaskIds → [Task] in seedTaskIds order. The validator
        // catches `pool_too_small` if any IDs failed to resolve.
        let allTasks = try AppDatabase.shared.read { db -> [Task] in
            try Task
                .filter(template.seedTaskIds.contains(Column("id")))
                .fetchAll(db)
        }
        let tasksById = Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })
        let orderedPool: [Task] = template.seedTaskIds.compactMap { tasksById[$0] }

        if orderedPool.isEmpty {
            return .skipped(templateId: template.id, reason: .noPoolTasksResolved)
        }

        let validation = validateSpawnPool(template: template, poolTasks: orderedPool)
        if case .failure(let reason) = validation {
            return .skipped(templateId: template.id, reason: reason)
        }

        let placement = buildSpawnPlacement(template: template, poolTasks: orderedPool)

        let boardId = AppDatabase.generateUUID()
        let now = AppDatabase.currentTimestamp()
        let size = template.boardSize

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
        ]
        if let custom = template.centerSquareCustomName, !custom.isEmpty {
            boardDict["centerSquareCustomName"] = custom
        }

        let boardData = try JSONSerialization.data(withJSONObject: boardDict)
        let board = try JSONDecoder().decode(Board.self, from: boardData)

        let centerCellIndex = size % 2 == 1 ? (size * size) / 2 : -1

        var boardTasks: [BoardTask] = []
        for (cell, t) in placement.enumerated() {
            guard let task = t else { continue } // FREE / CUSTOM_FREE center
            let row = cell / size
            let col = cell % size
            boardTasks.append(BoardTask(
                id: AppDatabase.generateUUID(),
                boardId: boardId,
                taskId: task.id,
                row: row,
                col: col,
                isCenter: cell == centerCellIndex,
                createdAt: now,
                updatedAt: now,
                version: 1
            ))
        }

        var updatedTemplate = template
        updatedTemplate.lastSpawnedWindowKey = spawn.windowStart
        updatedTemplate.updatedAt = now
        updatedTemplate.version += 1

        try AppDatabase.shared.write { db in
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
        }

        return .spawned(boardId: boardId, templateId: template.id, windowStart: spawn.windowStart)
    }
}
