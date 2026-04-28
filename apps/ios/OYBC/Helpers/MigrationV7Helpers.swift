import Foundation
import GRDB

/// MigrationV7Helpers — iOS twin of @oybc/web's migrationV4.ts.
///
/// Runs inside GRDB's v7 migration closure (one atomic transaction).
/// Transforms legacy progress + composite rows into the unified compound
/// shape, backfills global Task completion, enqueues legacy doc deletes,
/// recomputes board stats via DerivationPass, and finally rebuilds
/// `board_tasks` to drop the per-board completion columns.
///
/// v6 rework: the board_tasks rebuild originally placed in Task 3.4's v6
/// migration is moved here (as the final step) so that steps 5, 6, and 8
/// can read the legacy board_tasks.isCompleted / completedAt / currentCount
/// / completedStepIds columns before they are dropped.
enum MigrationV7Helpers {

    // MARK: - Entry Point

    /// Execute all 8 data-migration steps plus the board_tasks rebuild.
    ///
    /// Must be called from inside a GRDB migration closure — GRDB wraps the
    /// closure in an exclusive write transaction automatically.
    ///
    /// - Parameter db: The GRDB `Database` handle (already in a transaction).
    /// - Throws: Any GRDB / JSON encoding error. The transaction rolls back.
    static func run(_ db: Database) throws {
        let now = isoNow()

        // Track ids that need sync entries enqueued at the end (step 6.5).
        // Without this, the legacy DELETEs in step 7 tombstone the old
        // collections in Firestore while the replacement Tasks/compound_children
        // never push — leaving a second device with no progress/composite
        // content after the next pull.
        var transformedTaskIds: Set<String> = []   // step 1 (UPDATE) + step 3 (CREATE)
        var newCompoundTaskIds: Set<String> = []   // step 3 only — distinguishes CREATE from UPDATE
        var newCompoundChildIds: [String] = []     // step 2 + step 4 (CREATE)

        // ── Step 1: Progress Tasks → Compound ────────────────────────────────
        // Set type='compound', operator='AND', isOrdered=1 on every progress Task.
        let progressRows = try Row.fetchAll(db, sql: "SELECT id FROM tasks WHERE type = 'progress'")
        for row in progressRows {
            let id: String = row["id"]
            try db.execute(
                sql: """
                    UPDATE tasks
                    SET type = 'compound',
                        "operator" = 'AND',
                        isOrdered = 1,
                        updatedAt = ?
                    WHERE id = ?
                    """,
                arguments: [now, id]
            )
            transformedTaskIds.insert(id)
        }

        // ── Step 2: TaskSteps → CompoundChildren ──────────────────────────────
        // Each task_steps row becomes a compound_children row.
        // compoundTaskId = step.taskId (the parent progress/compound task)
        // childTaskId    = step.linkedTaskId (the extracted standalone task)
        let allStepRows = try Row.fetchAll(db, sql: """
            SELECT id, taskId, stepIndex, linkedTaskId,
                   createdAt, updatedAt, lastSyncedAt,
                   isDeleted, deletedAt
            FROM task_steps
            """)
        for row in allStepRows {
            guard let linkedTaskId: String = row["linkedTaskId"] else {
                // Step with no linkedTaskId — skip defensively.
                // Shouldn't happen under the existing progress-task-create
                // invariant but legacy data may be inconsistent.
                continue
            }
            let parentTaskId: String = row["taskId"]
            let stepIndex: Int = row["stepIndex"]
            let createdAt: String = row["createdAt"]
            let updatedAt: String = row["updatedAt"]
            let lastSyncedAt: String? = row["lastSyncedAt"]
            let isDeleted: Bool = (row["isDeleted"] as Int? ?? 0) != 0
            let deletedAt: String? = row["deletedAt"]

            let newChildId = UUID().uuidString.lowercased()
            try db.execute(
                sql: """
                    INSERT INTO compound_children (
                        id, compoundTaskId, childTaskId, childIndex,
                        createdAt, updatedAt, lastSyncedAt,
                        version, isDeleted, deletedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                    """,
                arguments: [
                    newChildId,
                    parentTaskId, linkedTaskId, stepIndex,
                    createdAt, updatedAt, lastSyncedAt,
                    isDeleted ? 1 : 0, deletedAt
                ]
            )
            newCompoundChildIds.append(newChildId)
        }

        // ── Step 3: CompositeTasks → Tasks ────────────────────────────────────
        // Each composite_tasks row becomes a tasks row (preserving its id).
        // The operator + threshold come from the root CompositeNode.
        let allCompositeRows = try Row.fetchAll(db, sql: """
            SELECT id, userId, title, description, rootNodeId,
                   createdAt, updatedAt, lastSyncedAt,
                   version, isDeleted, deletedAt
            FROM composite_tasks
            """)
        let allNodeRows = try Row.fetchAll(db, sql: """
            SELECT id, compositeTaskId, parentNodeId, nodeIndex,
                   nodeType, operatorType, threshold,
                   taskId, childCompositeTaskId,
                   createdAt, updatedAt, lastSyncedAt,
                   version, isDeleted, deletedAt
            FROM composite_nodes
            """)

        for ctRow in allCompositeRows {
            let ctId: String = ctRow["id"]
            let rootNodeId: String = ctRow["rootNodeId"]

            // Find the root node.
            guard let rootNode = allNodeRows.first(where: { ($0["id"] as String?) == rootNodeId }) else {
                continue  // missing root node — skip
            }
            let nodeType: String = rootNode["nodeType"]
            guard nodeType == "operator" else { continue }
            guard let opType: String = rootNode["operatorType"] else { continue }
            let threshold: Int? = rootNode["threshold"]

            let userId: String = ctRow["userId"]
            let title: String = ctRow["title"]
            let descriptionVal: String? = ctRow["description"]
            let createdAt: String = ctRow["createdAt"]
            let updatedAt: String = ctRow["updatedAt"]
            let lastSyncedAt: String? = ctRow["lastSyncedAt"]
            let version: Int = ctRow["version"]
            let isDeleted: Bool = (ctRow["isDeleted"] as Int? ?? 0) != 0
            let deletedAt: String? = ctRow["deletedAt"]

            // Only pass threshold for M_OF_N operators.
            let effectiveThreshold: Int? = (opType == "M_OF_N") ? threshold : nil

            try db.execute(
                sql: """
                    INSERT INTO tasks (
                        id, userId, title, description, type,
                        "operator", threshold, isOrdered,
                        isCompleted, totalCompletions, totalInstances,
                        createdAt, updatedAt, lastSyncedAt,
                        version, isDeleted, deletedAt
                    ) VALUES (?, ?, ?, ?, 'compound', ?, ?, 0,
                        0, 0, 0, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    ctId, userId, title, descriptionVal,
                    opType, effectiveThreshold,
                    createdAt, updatedAt, lastSyncedAt,
                    version, isDeleted ? 1 : 0, deletedAt
                ]
            )
            transformedTaskIds.insert(ctId)
            newCompoundTaskIds.insert(ctId)
        }

        // ── Step 4: Leaf CompositeNodes → CompoundChildren ────────────────────
        // Leaf nodes reference an existing Task (taskId) or a nested composite
        // (childCompositeTaskId, now migrated to a tasks row in step 3).
        // Operator nodes are discarded.
        for nodeRow in allNodeRows {
            let nodeType: String = nodeRow["nodeType"]
            guard nodeType == "leaf" else { continue }

            // childTaskId prefers taskId, falls back to childCompositeTaskId.
            let childTaskId: String? = (nodeRow["taskId"] as String?)
                ?? (nodeRow["childCompositeTaskId"] as String?)
            guard let childTaskId = childTaskId else { continue }

            let compositeTaskId: String = nodeRow["compositeTaskId"]
            let nodeIndex: Int = nodeRow["nodeIndex"]
            let createdAt: String = nodeRow["createdAt"]
            let updatedAt: String = nodeRow["updatedAt"]
            let lastSyncedAt: String? = nodeRow["lastSyncedAt"]
            let isDeleted: Bool = (nodeRow["isDeleted"] as Int? ?? 0) != 0
            let deletedAt: String? = nodeRow["deletedAt"]

            let newChildId = UUID().uuidString.lowercased()
            try db.execute(
                sql: """
                    INSERT INTO compound_children (
                        id, compoundTaskId, childTaskId, childIndex,
                        createdAt, updatedAt, lastSyncedAt,
                        version, isDeleted, deletedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                    """,
                arguments: [
                    newChildId,
                    compositeTaskId, childTaskId, nodeIndex,
                    createdAt, updatedAt, lastSyncedAt,
                    isDeleted ? 1 : 0, deletedAt
                ]
            )
            newCompoundChildIds.append(newChildId)
        }

        // ── Step 5: Backfill global Task completion ───────────────────────────
        // Read legacy board_tasks via raw SQL — the Swift BoardTask struct no
        // longer carries these columns (Task 3.3) but they're still in the
        // database at this point because the board_tasks rebuild is the LAST
        // step of v7.
        struct LegacyBTRow {
            let taskId: String
            let isCompleted: Bool
            let completedAt: String?
            let currentCount: Int?
            let completedStepIds: [String]
        }

        let legacyBtRows = try Row.fetchAll(db, sql: """
            SELECT taskId, isCompleted, completedAt, currentCount, completedStepIds
            FROM board_tasks
            """)

        var legacyBtByTask: [String: [LegacyBTRow]] = [:]
        var everCompletedStepIds: Set<String> = []

        for row in legacyBtRows {
            let taskId: String = row["taskId"]
            let isCompleted: Bool = (row["isCompleted"] as Int? ?? 0) != 0
            let completedAt: String? = row["completedAt"]
            let currentCount: Int? = row["currentCount"]
            var stepIds: [String] = []
            if let json: String = row["completedStepIds"],
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                stepIds = decoded
                for sid in decoded { everCompletedStepIds.insert(sid) }
            }
            let legacy = LegacyBTRow(
                taskId: taskId,
                isCompleted: isCompleted,
                completedAt: completedAt,
                currentCount: currentCount,
                completedStepIds: stepIds
            )
            legacyBtByTask[taskId, default: []].append(legacy)
        }

        // Walk every non-compound Task and backfill.
        let allTaskRows = try Row.fetchAll(db, sql: "SELECT id, type FROM tasks")
        for taskRow in allTaskRows {
            let taskId: String = taskRow["id"]
            let typeStr: String = taskRow["type"]
            guard typeStr != "compound" else { continue }

            let rows = legacyBtByTask[taskId] ?? []
            guard !rows.isEmpty else { continue }

            let isCompleted = rows.contains { $0.isCompleted }
            // Pick the LATEST completedAt across boards. Under the global
            // completion model, `Task.completedAt` reads as "when this task
            // became globally complete" — the most recent completion is the
            // correct anchor, especially for tasks that were un-completed
            // and re-completed across boards. Mirrors shared backfillTaskCompletion.
            let completedAt = rows
                .filter { $0.isCompleted }
                .compactMap { $0.completedAt }
                .sorted()
                .last
            let currentCount = rows.compactMap { $0.currentCount }.max()

            try db.execute(
                sql: """
                    UPDATE tasks
                    SET isCompleted = ?,
                        completedAt = ?,
                        currentCount = ?,
                        updatedAt = ?
                    WHERE id = ?
                    """,
                arguments: [isCompleted ? 1 : 0, completedAt, currentCount, now, taskId]
            )

            // Enqueue sync so Firestore gets the backfilled completion state —
            // without this, a second device would overwrite it with the stale
            // pre-migration Firestore rows that had no global isCompleted field.
            if isCompleted || currentCount != nil {
                try enqueueTaskSync(db: db, taskId: taskId, now: now)
            }
        }

        // ── Step 6: Step completion backfill ─────────────────────────────────
        // Any TaskStep.id that appeared in ANY legacy BoardTask.completedStepIds
        // means that step was completed on at least one board → flip its
        // linkedTaskId Task to globally complete.
        for row in allStepRows {
            let stepId: String = row["id"]
            guard everCompletedStepIds.contains(stepId) else { continue }
            guard let linkedTaskId: String = row["linkedTaskId"] else { continue }

            // Check if already completed by step 5 (avoid redundant enqueue).
            let currentRow = try Row.fetchOne(
                db,
                sql: "SELECT isCompleted FROM tasks WHERE id = ?",
                arguments: [linkedTaskId]
            )
            let alreadyDone = (currentRow?["isCompleted"] as Int? ?? 0) != 0
            if alreadyDone { continue }

            try db.execute(
                sql: """
                    UPDATE tasks
                    SET isCompleted = 1,
                        completedAt = COALESCE(completedAt, ?),
                        updatedAt = ?
                    WHERE id = ?
                    """,
                arguments: [now, now, linkedTaskId]
            )
            try enqueueTaskSync(db: db, taskId: linkedTaskId, now: now)
        }

        // ── Step 6.5: Enqueue migrated entities ──────────────────────────────
        // Web parity: without this, the legacy DELETEs in step 7 tombstone the
        // old Firestore collections while the replacement Tasks + compound_children
        // never push, leaving a second device with no progress/composite content
        // after the next pull. Run AFTER backfill so the payloads carry the
        // final post-migration state (incl. backfilled isCompleted etc).
        for taskId in transformedTaskIds {
            let op = newCompoundTaskIds.contains(taskId) ? "create" : "update"
            try enqueueTaskSync(db: db, taskId: taskId, op: op, now: now)
        }
        for childId in newCompoundChildIds {
            try enqueueCompoundChildCreate(db: db, childId: childId, now: now)
        }

        // ── Step 7: Enqueue legacy DELETE sync ops ────────────────────────────
        // Tell Firestore to remove the now-defunct task_steps, composite_tasks,
        // and composite_nodes documents on every participating device.
        for row in allStepRows {
            let stepId: String = row["id"]
            try enqueueDelete(db: db, entityType: "taskSteps", entityId: stepId, now: now)
        }
        for ctRow in allCompositeRows {
            let ctId: String = ctRow["id"]
            try enqueueDelete(db: db, entityType: "compositeTasks", entityId: ctId, now: now)
        }
        for nodeRow in allNodeRows {
            let nodeId: String = nodeRow["id"]
            try enqueueDelete(db: db, entityType: "compositeNodes", entityId: nodeId, now: now)
        }

        // ── Step 8: Recompute board stats via DerivationPass ──────────────────
        // Build the lookup maps DerivationPass.computeBoardStatsUpdate needs.
        // GRDB's FetchableRecord init(row:) decodes via the Swift Codable path —
        // unknown columns (legacy completion cols still in board_tasks at this
        // point) are simply ignored by the BoardTask decoder.
        let allTaskStructs = try Task.fetchAll(db)
        var taskById: [String: Task] = [:]
        for t in allTaskStructs { taskById[t.id] = t }

        let allChildStructs = try CompoundChild
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in allChildStructs {
            childrenByCompound[c.compoundTaskId, default: []].append(c)
        }

        // BoardTask.init(from:) only reads its declared CodingKeys — extra
        // legacy columns in the result set are silently ignored by Swift's
        // Codable decoder.
        let allBoardTaskStructs = try BoardTask.fetchAll(db)

        let boardRows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM boards WHERE isDeleted = 0"
        )
        for bRow in boardRows {
            let board = try Board(row: bRow)
            let boardTasksOnBoard = allBoardTaskStructs.filter { $0.boardId == board.id }
            let update = DerivationPass.computeBoardStatsUpdate(
                board: board,
                boardTasksOnBoard: boardTasksOnBoard,
                childrenByCompound: childrenByCompound,
                taskById: taskById
            )
            let newVersion = board.version + 1

            try db.execute(
                sql: """
                    UPDATE boards
                    SET completedTasks  = ?,
                        linesCompleted  = ?,
                        completedLineIds = ?,
                        updatedAt = ?,
                        version   = ?
                    WHERE id = ?
                    """,
                arguments: [
                    update.completedTasks,
                    update.linesCompleted,
                    encodeJSONArray(update.completedLineIds),
                    now,
                    newVersion,
                    board.id
                ]
            )

            // Build the updated Board for the sync payload.
            var updatedBoard = board
            updatedBoard.completedTasks = update.completedTasks
            updatedBoard.linesCompleted = update.linesCompleted
            updatedBoard.completedLineIds = update.completedLineIds
            updatedBoard.updatedAt = now
            updatedBoard.version = newVersion

            try enqueueBoardSync(db: db, board: updatedBoard, now: now)
        }

        // ── Final: Rebuild board_tasks to drop completion columns ─────────────
        // Moved from v6 (Task 3.4). Runs LAST so steps 5, 6, and 8 above can
        // still read the legacy isCompleted / completedAt / currentCount /
        // completedStepIds columns.
        try db.execute(sql: """
            CREATE TABLE board_tasks_new (
                id TEXT PRIMARY KEY NOT NULL,
                boardId TEXT NOT NULL,
                taskId TEXT NOT NULL,
                row INTEGER NOT NULL,
                col INTEGER NOT NULL,
                isCenter INTEGER NOT NULL DEFAULT 0,
                isAchievementSquare INTEGER DEFAULT 0,
                achievementType TEXT,
                achievementCount INTEGER,
                achievementTimeframe TEXT,
                achievementProgress INTEGER,
                createdAt TEXT NOT NULL,
                updatedAt TEXT NOT NULL,
                lastSyncedAt TEXT,
                version INTEGER NOT NULL DEFAULT 1,
                FOREIGN KEY (boardId) REFERENCES boards(id) ON DELETE CASCADE,
                FOREIGN KEY (taskId) REFERENCES tasks(id)
            )
            """)

        try db.execute(sql: """
            INSERT INTO board_tasks_new (
                id, boardId, taskId, row, col, isCenter,
                isAchievementSquare, achievementType, achievementCount,
                achievementTimeframe, achievementProgress,
                createdAt, updatedAt, lastSyncedAt, version
            )
            SELECT
                id, boardId, taskId, row, col, isCenter,
                isAchievementSquare, achievementType, achievementCount,
                achievementTimeframe, achievementProgress,
                createdAt, updatedAt, lastSyncedAt, version
            FROM board_tasks
            """)

        try db.execute(sql: "DROP TABLE board_tasks")
        try db.execute(sql: "ALTER TABLE board_tasks_new RENAME TO board_tasks")

        // Recreate indexes (the table rebuild drops them with the old table).
        try db.execute(sql: "CREATE INDEX idx_board_tasks_board ON board_tasks(boardId)")
        try db.execute(sql: "CREATE INDEX idx_board_tasks_task ON board_tasks(taskId)")
        try db.execute(sql: "CREATE INDEX idx_board_tasks_achievement ON board_tasks(isAchievementSquare)")
        try db.execute(sql: "CREATE INDEX idx_board_tasks_achievement_timeframe ON board_tasks(isAchievementSquare, achievementTimeframe)")
    }

    // MARK: - Private Helpers

    /// Returns the current timestamp as an ISO 8601 string with millisecond
    /// precision — matching the format used throughout the rest of the app.
    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// JSON-encodes a string array, returning "[]" on failure.
    private static func encodeJSONArray(_ arr: [String]) -> String {
        guard let data = try? JSONEncoder().encode(arr),
              let s = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return s
    }

    /// Enqueues a sync item for a Task row.
    ///
    /// Fetches the current Task state from the DB so the payload reflects the
    /// post-migration row. Must be called AFTER the UPDATE/INSERT that produced
    /// the row.
    ///
    /// - Parameter op: "create" for tasks the migration introduced (composites
    ///                 moved into `tasks`); "update" for in-place transforms +
    ///                 backfills.
    private static func enqueueTaskSync(
        db: Database,
        taskId: String,
        op: String = "update",
        now: String
    ) throws {
        guard let taskRow = try Row.fetchOne(
            db,
            sql: "SELECT * FROM tasks WHERE id = ?",
            arguments: [taskId]
        ) else { return }
        let task = try Task(row: taskRow)
        let payloadData = try JSONEncoder().encode(task)
        guard let payload = String(data: payloadData, encoding: .utf8) else { return }
        try insertSyncItem(
            db: db,
            entityType: "tasks",
            entityId: taskId,
            op: op,
            payload: payload,
            now: now
        )
    }

    /// Enqueues a CREATE sync item for a CompoundChild row.
    ///
    /// Required for migrated compound_children rows (taskSteps + compositeNodes
    /// transforms) so other devices receive the new shape — without this, the
    /// legacy DELETE sync would tombstone the legacy collections in Firestore
    /// while the replacement compoundChildren never push.
    private static func enqueueCompoundChildCreate(
        db: Database,
        childId: String,
        now: String
    ) throws {
        guard let childRow = try Row.fetchOne(
            db,
            sql: "SELECT * FROM compound_children WHERE id = ?",
            arguments: [childId]
        ) else { return }
        let child = try CompoundChild(row: childRow)
        let payloadData = try JSONEncoder().encode(child)
        guard let payload = String(data: payloadData, encoding: .utf8) else { return }
        try insertSyncItem(
            db: db,
            entityType: "compoundChildren",
            entityId: childId,
            op: "create",
            payload: payload,
            now: now
        )
    }

    /// Enqueues an UPDATE sync item for a Board row.
    private static func enqueueBoardSync(db: Database, board: Board, now: String) throws {
        let payloadData = try JSONEncoder().encode(board)
        guard let payload = String(data: payloadData, encoding: .utf8) else { return }
        try insertSyncItem(
            db: db,
            entityType: "boards",
            entityId: board.id,
            op: "update",
            payload: payload,
            now: now
        )
    }

    /// Enqueues a DELETE sync item for a legacy collection row.
    private static func enqueueDelete(
        db: Database,
        entityType: String,
        entityId: String,
        now: String
    ) throws {
        try insertSyncItem(
            db: db,
            entityType: entityType,
            entityId: entityId,
            op: "delete",
            payload: "null",
            now: now
        )
    }

    /// Inserts a raw row into sync_queue. Called directly from the migration
    /// closure rather than through AppDatabase helpers so the insert shares
    /// the same GRDB transaction and can't silently open a second one.
    private static func insertSyncItem(
        db: Database,
        entityType: String,
        entityId: String,
        op: String,
        payload: String,
        now: String
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO sync_queue (
                    id, entityType, entityId, operationType,
                    payload, status, retryCount, createdAt, priority
                ) VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, 0)
                """,
            arguments: [
                UUID().uuidString.lowercased(),
                entityType, entityId, op, payload, now
            ]
        )
    }
}
