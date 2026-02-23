import Foundation
import GRDB

/// AppDatabase - Main database manager using GRDB
///
/// Singleton instance managing SQLite database with offline-first architecture
final class AppDatabase {
    // MARK: - Singleton

    static let shared = AppDatabase()

    // MARK: - Database

    private let dbQueue: DatabaseQueue

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

    /// Delete all rows from every table — used by the Playground to reset test data
    func clearAllData() throws {
        try write { db in
            try db.execute(sql: "DELETE FROM sync_queue")
            try db.execute(sql: "DELETE FROM board_tasks")
            try db.execute(sql: "DELETE FROM progress_counters")
            try db.execute(sql: "DELETE FROM task_steps")
            try db.execute(sql: "DELETE FROM tasks")
            try db.execute(sql: "DELETE FROM boards")
            try db.execute(sql: "DELETE FROM users")
        }
    }
}
