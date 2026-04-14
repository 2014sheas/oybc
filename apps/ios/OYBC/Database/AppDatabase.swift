import Foundation
import GRDB

/// AppDatabase - Main database manager using GRDB
///
/// Singleton instance managing SQLite database with offline-first architecture
final class AppDatabase {
    // MARK: - Singleton

    static let shared = AppDatabase()

    // MARK: - Database

    /// Exposed to the module (not public) so `AuthService` can attach a
    /// `ValueObservation` to the users row without needing a wrapper for
    /// every observable column.
    let dbQueue: DatabaseQueue

    // MARK: - Initialization

    private init() {
        do {
            let databaseURL = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("oybc.sqlite")

            // WAL journal mode reduces write I/O significantly — especially important
            // during first-run migration when all tables and indexes are created.
            // Must be passed to DatabaseQueue at creation time; configuring it after
            // the fact has no effect on the already-opened database connection.
            var config = Configuration()
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA foreign_keys = ON")
            }

            let start = Date()
            dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: config)
            try migrator.migrate(dbQueue)
            let elapsed = Date().timeIntervalSince(start)
            print("✅ Database initialized at: \(databaseURL.path) (\(String(format: "%.2f", elapsed))s)")
        } catch {
            fatalError("Database initialization failed: \(error)")
        }
    }

    // MARK: - Database Access

    /// Access database for reading
    func read<T>(_ block: (Database) throws -> T) throws -> T {
        return try dbQueue.read(block)
    }

    /// Access database for writing
    func write<T>(_ block: (Database) throws -> T) throws -> T {
        return try dbQueue.write(block)
    }

    /// Access database reader (for async operations)
    var reader: DatabaseReader {
        return dbQueue
    }

    // MARK: - Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // v1: Initial schema
        migrator.registerMigration("v1") { db in
            try self.createInitialSchema(db)
        }

        // v2: Composite task tables
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS composite_tasks (
                    id TEXT PRIMARY KEY NOT NULL,
                    userId TEXT NOT NULL,
                    title TEXT NOT NULL,
                    description TEXT,
                    rootNodeId TEXT NOT NULL,

                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL,
                    lastSyncedAt TEXT,
                    version INTEGER NOT NULL DEFAULT 1,
                    isDeleted INTEGER NOT NULL DEFAULT 0,
                    deletedAt TEXT,

                    FOREIGN KEY (userId) REFERENCES users(id)
                )
                """)

            try db.execute(sql: """
                CREATE INDEX idx_composite_tasks_user_deleted
                    ON composite_tasks(userId, isDeleted)
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS composite_nodes (
                    id TEXT PRIMARY KEY NOT NULL,
                    compositeTaskId TEXT NOT NULL,
                    parentNodeId TEXT,
                    nodeIndex INTEGER NOT NULL,

                    nodeType TEXT NOT NULL,
                    operatorType TEXT,
                    threshold INTEGER,

                    taskId TEXT,

                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL,
                    lastSyncedAt TEXT,
                    version INTEGER NOT NULL DEFAULT 1,
                    isDeleted INTEGER NOT NULL DEFAULT 0,
                    deletedAt TEXT,

                    FOREIGN KEY (compositeTaskId) REFERENCES composite_tasks(id) ON DELETE CASCADE,
                    FOREIGN KEY (parentNodeId) REFERENCES composite_nodes(id),
                    FOREIGN KEY (taskId) REFERENCES tasks(id)
                )
                """)

            try db.execute(sql: """
                CREATE INDEX idx_composite_nodes_composite
                    ON composite_nodes(compositeTaskId)
                """)

            try db.execute(sql: """
                CREATE INDEX idx_composite_nodes_parent_index
                    ON composite_nodes(parentNodeId, nodeIndex)
                """)

            try db.execute(sql: """
                CREATE INDEX idx_composite_nodes_task
                    ON composite_nodes(taskId)
                """)
        }

        // v3: Add childCompositeTaskId column and index to composite_nodes
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                ALTER TABLE composite_nodes
                ADD COLUMN childCompositeTaskId TEXT
                REFERENCES composite_tasks(id)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_composite_nodes_child_composite
                    ON composite_nodes(childCompositeTaskId)
                """)
        }

        // v4: Add missing Board columns (centerSquareCustomName, centerTaskId)
        migrator.registerMigration("v4") { db in
            try db.execute(sql: "ALTER TABLE boards ADD COLUMN centerSquareCustomName TEXT")
            try db.execute(sql: "ALTER TABLE boards ADD COLUMN centerTaskId TEXT REFERENCES tasks(id)")
        }

        // v5: Synced user preferences JSON column. The current schema holds
        // `weekStartDay`, `defaultBoardSize`, `defaultCenterType`,
        // `defaultTimeframe`, `defaultRandomize`, `defaultCenterCustomName`,
        // and `theme` — but the migration itself only adds the column;
        // future field additions don't need a migration because the JSON
        // is decoded by `UserPreferences.init(from:)` which tolerates
        // missing keys. Stored as a JSON string to mirror how other
        // nested/array fields are persisted on iOS, and so the record can
        // round-trip through Firestore with the same shape the web app
        // writes.
        migrator.registerMigration("v5") { db in
            try db.execute(sql: "ALTER TABLE users ADD COLUMN preferences TEXT")
        }

        return migrator
    }

    private func createInitialSchema(_ db: Database) throws {
        // Load and execute schema.sql
        guard let schemaURL = Bundle.main.url(forResource: "Schema", withExtension: "sql"),
              let schemaSQL = try? String(contentsOf: schemaURL) else {
            throw DatabaseError(message: "Schema.sql not found")
        }

        try db.execute(sql: schemaSQL)
    }
}

// MARK: - Database Queries (CRUD Operations)

extension AppDatabase {
    // MARK: - Boards

    func fetchBoards(userId: String) throws -> [Board] {
        return try read { db in
            try Board
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    func fetchBoard(id: String) throws -> Board? {
        return try read { db in
            try Board.fetchOne(db, key: id)
        }
    }

    func saveBoard(_ board: Board) throws {
        try write { db in
            try board.save(db)
        }
    }

    func deleteBoard(id: String) throws {
        try write { db in
            var board = try Board.fetchOne(db, key: id)
            board?.isDeleted = true
            board?.deletedAt = ISO8601DateFormatter().string(from: Date())
            try board?.update(db)
        }
    }

    // MARK: - Tasks

    func fetchTasks(userId: String) throws -> [Task] {
        return try read { db in
            try Task
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    func fetchTask(id: String) throws -> Task? {
        return try read { db in
            try Task.fetchOne(db, key: id)
        }
    }

    func saveTask(_ task: Task) throws {
        try write { db in
            try task.save(db)
        }
    }

    func deleteTask(id: String) throws {
        try write { db in
            var task = try Task.fetchOne(db, key: id)
            task?.isDeleted = true
            task?.deletedAt = ISO8601DateFormatter().string(from: Date())
            try task?.update(db)
        }
    }

    // MARK: - TaskSteps

    func fetchTaskSteps(taskId: String) throws -> [TaskStep] {
        return try read { db in
            try TaskStep
                .filter(Column("taskId") == taskId && Column("isDeleted") == false)
                .order(Column("stepIndex"))
                .fetchAll(db)
        }
    }

    /// Fetches all non-deleted `TaskStep` records for progress tasks owned by a user.
    ///
    /// - Parameter userId: The owning user's ID.
    /// - Returns: All matching steps ordered by `stepIndex`.
    func fetchAllTaskSteps(userId: String) throws -> [TaskStep] {
        return try read { db in
            try TaskStep
                .joining(required: TaskStep.task.filter(Column("userId") == userId))
                .filter(Column("isDeleted") == false)
                .order(Column("stepIndex"))
                .fetchAll(db)
        }
    }

    func saveTaskStep(_ step: TaskStep) throws {
        try write { db in
            try step.save(db)
        }
    }

    // MARK: - BoardTasks

    func fetchBoardTasks(boardId: String) throws -> [BoardTask] {
        return try read { db in
            try BoardTask
                .filter(Column("boardId") == boardId)
                .fetchAll(db)
        }
    }

    func fetchBoardTask(id: String) throws -> BoardTask? {
        return try read { db in
            try BoardTask.fetchOne(db, key: id)
        }
    }

    func saveBoardTask(_ boardTask: BoardTask) throws {
        try write { db in
            try boardTask.save(db)
        }
    }

    // MARK: - ProgressCounters

    func fetchProgressCounters(userId: String) throws -> [ProgressCounter] {
        return try read { db in
            try ProgressCounter
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .order(Column("name"))
                .fetchAll(db)
        }
    }

    func saveProgressCounter(_ counter: ProgressCounter) throws {
        try write { db in
            try counter.save(db)
        }
    }

    // MARK: - Users

    func fetchUser(id: String) throws -> User? {
        return try read { db in
            try User.fetchOne(db, key: id)
        }
    }

    func saveUser(_ user: User) throws {
        try write { db in
            try user.save(db)
        }
    }

    /// Atomically merges a partial preferences update into the authenticated
    /// user's row, bumps `version` + `updatedAt`, and enqueues a sync queue
    /// UPDATE item for the `users` entity. The write and its sync-queue entry
    /// share a single GRDB transaction so they can't drift out of step.
    ///
    /// - Parameters:
    ///   - userId: The User row to update.
    ///   - transform: Receives the current `UserPreferences` and returns the
    ///     new value. Using a closure (rather than a partial struct) keeps the
    ///     merge logic at the call site explicit.
    /// - Returns: The updated User row, or `nil` if no such row exists.
    @discardableResult
    func updateUserPreferences(
        userId: String,
        transform: (UserPreferences) -> UserPreferences
    ) throws -> User? {
        return try write { db -> User? in
            guard var user = try User.fetchOne(db, key: userId) else { return nil }

            let current = user.decodedPreferences
            let next = transform(current)

            user.preferences = User.encodePreferences(next)
            user.version += 1
            user.updatedAt = ISO8601DateFormatter().string(from: Date())
            try user.save(db)

            // Encode the full user record as the sync payload. Propagating
            // any encoding error (rather than falling back to an empty "{}"
            // blob) keeps a malformed push from silently enqueuing and
            // pushing an invalid document — the caller sees the real
            // failure and the transaction rolls back, preserving local
            // state.
            let data = try JSONEncoder().encode(user)
            guard let payload = String(data: data, encoding: .utf8) else {
                throw AppDatabaseError.payloadEncoding(
                    "Failed to convert encoded user payload to UTF-8 for sync queue item"
                )
            }

            let syncItem = SyncQueueItem(
                id: Self.generateUUID(),
                entityType: "users",
                entityId: userId,
                operationType: .update,
                payload: payload,
                status: .pending,
                retryCount: 0,
                lastError: nil,
                createdAt: user.updatedAt,
                lastAttemptAt: nil,
                completedAt: nil,
                priority: 1
            )
            try syncItem.save(db)

            return user
        }
    }

    // MARK: - SyncQueue

    func fetchPendingSyncItems() throws -> [SyncQueueItem] {
        return try read { db in
            try SyncQueueItem
                .filter(Column("status") == SyncStatus.pending.rawValue)
                .order(Column("priority").desc, Column("createdAt"))
                .fetchAll(db)
        }
    }

    func saveSyncItem(_ item: SyncQueueItem) throws {
        try write { db in
            try item.save(db)
        }
    }

    func deleteSyncItem(id: String) throws {
        try write { db in
            try SyncQueueItem.deleteOne(db, key: id)
        }
    }

    /// Reset sync queue items left in `inProgress` from a force-quit
    /// or crashed push back to `pending`. Mirrors the equivalent reset
    /// at the top of the web `pushSync`.
    ///
    /// Only items whose `lastAttemptAt` is older than `staleAfter`
    /// (default 60 s) are reset, so a concurrent push currently
    /// processing an item won't have its row yanked out from under it.
    /// 60 s is a generous upper bound on how long a single Firestore
    /// write should take; anything older is genuinely stuck.
    ///
    /// `SyncService.pushSync` also has an `isSyncing` guard preventing
    /// concurrent pushes, but this staleness check is belt-and-
    /// suspenders for the case where `pushSync` is called from
    /// `fullSync` while another caller is mid-flight (rare, but the
    /// MainActor reentrancy model allows it via async suspension).
    @discardableResult
    func resetStaleInProgressSyncItems(staleAfter: TimeInterval = 60) throws -> Int {
        let cutoff = Date().addingTimeInterval(-staleAfter)
        let cutoffISO = ISO8601DateFormatter().string(from: cutoff)

        return try write { db in
            let inProgress = try SyncQueueItem
                .filter(Column("status") == SyncStatus.inProgress.rawValue)
                .fetchAll(db)

            var resetCount = 0
            for var item in inProgress {
                // No lastAttemptAt = item entered IN_PROGRESS before that
                // field was tracked (or via direct write); treat as stale.
                let isStale: Bool
                if let lastAttemptAt = item.lastAttemptAt {
                    isStale = lastAttemptAt < cutoffISO
                } else {
                    isStale = true
                }
                guard isStale else { continue }

                item.status = .pending
                try item.save(db)
                resetCount += 1
            }
            return resetCount
        }
    }

    /// Promote FAILED sync queue items back to `pending` when their
    /// exponential-backoff window has elapsed and they're under the
    /// retry cap. Items at or above `MAX_SYNC_RETRIES` are left FAILED
    /// indefinitely; they require a fresh enqueue or a manual retry
    /// from the playground SyncDashboard.
    ///
    /// Called at the top of `SyncService.pushSync`. The GRDB
    /// `ValueObservation` on PENDING count re-fires when items are
    /// promoted, which triggers the push-on-enqueue debounce — so
    /// promotion implicitly schedules a fresh push without an explicit
    /// kick.
    @discardableResult
    func promoteEligibleFailedSyncItems() throws -> Int {
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        return try write { db in
            let failed = try SyncQueueItem
                .filter(Column("status") == SyncStatus.failed.rawValue)
                .fetchAll(db)

            var promoted = 0
            for var item in failed {
                if item.retryCount >= SyncRetry.maxRetries { continue }
                let lastAttemptAtMs: Int? = item.lastAttemptAt
                    .flatMap { ISO8601DateFormatter().date(from: $0) }
                    .map { Int($0.timeIntervalSince1970 * 1000) }
                guard SyncRetry.isFailedItemEligibleForRetry(
                    retryCount: item.retryCount,
                    lastAttemptAtMs: lastAttemptAtMs,
                    nowMs: nowMs
                ) else { continue }

                item.status = .pending
                item.lastError = nil
                try item.save(db)
                promoted += 1
            }
            return promoted
        }
    }
}

// MARK: - Sync Queries

extension AppDatabase {
    /// Fetch entities that need syncing (modified since last sync)
    func fetchUnsyncedBoards(userId: String) throws -> [Board] {
        return try read { db in
            try Board
                .filter(Column("userId") == userId)
                .filter(Column("updatedAt") > Column("lastSyncedAt") || Column("lastSyncedAt") == nil)
                .fetchAll(db)
        }
    }

    /// Mark entity as synced
    func markBoardSynced(id: String) throws {
        try write { db in
            var board = try Board.fetchOne(db, key: id)
            board?.lastSyncedAt = ISO8601DateFormatter().string(from: Date())
            try board?.update(db)
        }
    }
}

// MARK: - Cross-Board Queries (for Achievements)

extension AppDatabase {
    /// Count boards with at least one bingo by timeframe
    func countBingos(userId: String, timeframe: Timeframe) throws -> Int {
        return try read { db in
            try Board
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .filter(Column("timeframe") == timeframe.rawValue)
                .filter(Column("linesCompleted") > 0)
                .fetchCount(db)
        }
    }

    /// Count completed boards by timeframe
    func countCompletedBoards(userId: String, timeframe: Timeframe) throws -> Int {
        return try read { db in
            try Board
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .filter(Column("timeframe") == timeframe.rawValue)
                .filter(Column("status") == BoardStatus.completed.rawValue)
                .fetchCount(db)
        }
    }

    /// Find all boards with achievement squares
    func fetchBoardsWithAchievements(userId: String) throws -> [Board] {
        return try read { db in
            // Find distinct board IDs with achievement squares
            let boardIds = try String.fetchAll(db, sql: """
                SELECT DISTINCT boardId 
                FROM board_tasks 
                WHERE isAchievementSquare = 1
                """)

            // Fetch boards
            return try Board
                .filter(keys: boardIds)
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .fetchAll(db)
        }
    }
}

// MARK: - Utilities

extension AppDatabase {
    /// Generate UUID for new entities
    static func generateUUID() -> String {
        return UUID().uuidString.lowercased()
    }

    /// Get current ISO8601 timestamp
    static func currentTimestamp() -> String {
        return ISO8601DateFormatter().string(from: Date())
    }

    /// Errors raised by `AppDatabase` operations.
    enum AppDatabaseError: LocalizedError {
        /// A payload that was encoded by `JSONEncoder` couldn't be converted
        /// to a UTF-8 string for storage as a sync-queue item.
        case payloadEncoding(String)

        var errorDescription: String? {
            switch self {
            case .payloadEncoding(let msg): return msg
            }
        }
    }

    /// Delete all rows from every table — used by the Playground to reset test data
    func clearAllData() throws {
        try write { db in
            // Order: children before parents to satisfy FK constraints
            try db.execute(sql: "DELETE FROM sync_queue")
            try db.execute(sql: "DELETE FROM board_tasks")
            try db.execute(sql: "DELETE FROM progress_counters")
            try db.execute(sql: "DELETE FROM composite_nodes")
            try db.execute(sql: "DELETE FROM composite_tasks")
            try db.execute(sql: "DELETE FROM task_steps")
            try db.execute(sql: "DELETE FROM tasks")
            try db.execute(sql: "DELETE FROM boards")
            try db.execute(sql: "DELETE FROM users")
        }
    }
}
