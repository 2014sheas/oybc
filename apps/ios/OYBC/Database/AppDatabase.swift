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

            let start = Date()
            dbQueue = try DatabaseQueue(path: databaseURL.path, configuration: Self.databaseConfiguration())
            try migrator.migrate(dbQueue)
            let elapsed = Date().timeIntervalSince(start)
            print("✅ Database initialized at: \(databaseURL.path) (\(String(format: "%.2f", elapsed))s)")
        } catch {
            fatalError("Database initialization failed: \(error)")
        }
    }

    /// Designated throwing initialiser used by `makeTestInstance()`. Keeps
    /// the production singleton's non-throwing `init()` (with fatalError
    /// on failure) untouched so existing call sites stay simple.
    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try migrator.migrate(dbQueue)
    }

    /// Shared GRDB configuration used by both the production on-disk
    /// database and the in-memory test factory. Keeping one source of
    /// truth means tests can't pass while production rejects the same
    /// write for a config-dependent reason (e.g. FK enforcement).
    ///
    /// `prepareDatabase` runs once per connection open, before any
    /// schema migration or query, so these pragmas take effect for
    /// everything the app does.
    ///
    /// - WAL: reduces write I/O, crucial during first-run migration.
    ///   Has no effect on an in-memory database (SQLite ignores
    ///   journal_mode for `:memory:`) but it's harmless to set.
    /// - foreign_keys = ON: enforces FK constraints defined in the
    ///   schema. Required so FK violations fail the same way in both
    ///   production and tests.
    private static func databaseConfiguration() -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return config
    }

    #if DEBUG
    /// Returns a fresh `AppDatabase` backed by an in-memory `DatabaseQueue`.
    /// Each call returns a completely isolated instance — safe to use in
    /// XCTest's per-method `setUp`. Wrapped in `#if DEBUG` so it can't be
    /// shipped into production code accidentally.
    ///
    /// Uses the same `Configuration` as production (notably
    /// `foreign_keys = ON`), so FK violations fail in tests the same
    /// way they would in the shipping app. The migrator runs identically,
    /// so tests exercise the v5 schema end-to-end.
    static func makeTestInstance() throws -> AppDatabase {
        let queue = try DatabaseQueue(configuration: databaseConfiguration())
        return try AppDatabase(dbQueue: queue)
    }
    #endif

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

        // v6: Compound tasks unification — schema changes only.
        //   - Create compound_children table (replaces the role of task_steps +
        //     composite_nodes leaves under the unified model).
        //   - Widen tasks with compound fields (operator, threshold, isOrdered)
        //     and global completion fields (isCompleted, completedAt, currentCount).
        //
        // The board_tasks completion-column rebuild that was originally here has
        // been moved to v7 (MigrationV7Helpers.swift). It must run AFTER the data
        // migration so that steps 5 (Task completion backfill), 6 (step completion
        // backfill), and 8 (board stats recompute) can still read the legacy
        // board_tasks.isCompleted / completedAt / currentCount / completedStepIds
        // columns before they are dropped.
        migrator.registerMigration("v6") { db in
            // (a) compound_children
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS compound_children (
                    id TEXT PRIMARY KEY NOT NULL,
                    compoundTaskId TEXT NOT NULL,
                    childTaskId TEXT NOT NULL,
                    childIndex INTEGER NOT NULL,

                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL,
                    lastSyncedAt TEXT,
                    version INTEGER NOT NULL DEFAULT 1,
                    isDeleted INTEGER NOT NULL DEFAULT 0,
                    deletedAt TEXT,

                    FOREIGN KEY (compoundTaskId) REFERENCES tasks(id) ON DELETE CASCADE,
                    FOREIGN KEY (childTaskId) REFERENCES tasks(id)
                )
                """)

            try db.execute(sql: "CREATE INDEX idx_compound_children_compound_index ON compound_children(compoundTaskId, childIndex)")
            try db.execute(sql: "CREATE INDEX idx_compound_children_child ON compound_children(childTaskId)")

            // (b) Widen tasks with compound + global completion columns.
            // isCompleted is NOT NULL DEFAULT 0 so existing rows get a value.
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN \"operator\" TEXT")
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN threshold INTEGER")
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN isOrdered INTEGER")
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN isCompleted INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN completedAt TEXT")
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN currentCount INTEGER")
        }

        // v7: Data migration for the compound unification. Transforms legacy
        // progress + composite rows into the unified compound shape, backfills
        // global Task completion, enqueues legacy doc deletes, recomputes board
        // stats via DerivationPass, and finally rebuilds board_tasks to drop
        // the per-board completion columns (moved here from v6).
        migrator.registerMigration("v7") { db in
            try MigrationV7Helpers.run(db)
        }

        // v8: Phase 6.2 — recurring board templates.
        //
        //   (a) recurring_board_templates table — user-curated task pools that
        //       automatically create boards each window. seedTaskIds is stored as a JSON
        //       string TEXT column (mirror of boards.completedLineIds) since
        //       SQLite has no native array type.
        //   (b) Add boards.spawnedFromTemplateId TEXT column. Plain TEXT,
        //       no FK constraint — adding a FK to an existing table in
        //       SQLite requires a full table rebuild, and the only
        //       reason to want one (cascading delete behavior) doesn't
        //       apply: templates are soft-deleted (isDeleted=true) and
        //       never hard-deleted, so a FK's ON DELETE clause would
        //       never fire. Spawned boards remain independent from the
        //       template they came from by design.
        migrator.registerMigration("v8") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS recurring_board_templates (
                    id TEXT PRIMARY KEY NOT NULL,
                    userId TEXT NOT NULL,
                    name TEXT NOT NULL,
                    timeframe TEXT NOT NULL,
                    boardSize INTEGER NOT NULL,
                    centerSquareType TEXT NOT NULL,
                    centerSquareCustomName TEXT,
                    isRandomized INTEGER NOT NULL DEFAULT 1,
                    seedTaskIds TEXT NOT NULL DEFAULT '[]',
                    lastSpawnedWindowKey TEXT,
                    isActive INTEGER NOT NULL DEFAULT 1,

                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL,
                    lastSyncedAt TEXT,
                    version INTEGER NOT NULL DEFAULT 1,
                    isDeleted INTEGER NOT NULL DEFAULT 0,
                    deletedAt TEXT
                )
                """)

            try db.execute(sql: "CREATE INDEX idx_recurring_templates_user_active ON recurring_board_templates(userId, isActive)")
            try db.execute(sql: "CREATE INDEX idx_recurring_templates_user_deleted ON recurring_board_templates(userId, isDeleted)")

            try db.execute(sql: "ALTER TABLE boards ADD COLUMN spawnedFromTemplateId TEXT")
        }

        // v9: Phase 6.3 — original draft added `referencedBoardId` /
        // `referencedTemplateId` columns to `board_tasks`. The refactor
        // moves those fields to `Task` instead (see v10 below). v9 is
        // kept around so dev installs that already migrated through it
        // don't fail — the no-op columns it added to `board_tasks` are
        // harmless (Swift's BoardTask model doesn't reference them
        // post-refactor, so they're dead weight in storage).
        //
        // For fresh installs that have never run v9: the ALTER TABLE
        // is still useful as a stepping stone toward v10 so the schema
        // history is linear, but the columns it creates are not
        // referenced anywhere in code. A future cleanup could drop the
        // columns via a table rebuild; not worth doing for an unshipped
        // feature.
        migrator.registerMigration("v9") { db in
            try db.execute(sql: "ALTER TABLE board_tasks ADD COLUMN referencedBoardId TEXT")
            try db.execute(sql: "ALTER TABLE board_tasks ADD COLUMN referencedTemplateId TEXT")
        }

        // v10: Phase 6.3 refactor — ACHIEVEMENT as a TaskType.
        //
        //   Add `referencedBoardId` and `referencedTemplateId` columns
        //   to the `tasks` table (cross-board watcher fields now live
        //   on Task, not BoardTask). Only ACHIEVEMENT-typed Tasks
        //   populate them:
        //     - referencedBoardId TEXT — specific-board mode. Cell
        //       completes when the named board's status is COMPLETED
        //       and !isDeleted.
        //     - referencedTemplateId TEXT — recurring-template mode.
        //       Cell completes when ALL in-window non-deleted spawns
        //       of that template are COMPLETED.
        //
        //   Both fields are nullable, additive, and NOT indexed (lookups
        //   happen inside derivationPass per-row, not via table scans).
        //   No FK constraints — adding a FK to an existing table in
        //   SQLite requires a full table rebuild, and templates/boards
        //   are soft-deleted only so a FK ON DELETE clause would never
        //   fire (mirrors the 6.2 spawnedFromTemplateId precedent).
        //
        //   Mutual exclusion (at most one set per row) is enforced at
        //   the Zod refinement layer in the shared package's TaskSchema,
        //   plus a defensive check in the iOS task-write helpers.
        migrator.registerMigration("v10") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN referencedBoardId TEXT")
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN referencedTemplateId TEXT")
        }

        // v11: Phase 6.3 — Achievement trigger + required count.
        //
        //   Adds two optional columns to `tasks`:
        //     - achievementTrigger TEXT — 'bingo' or 'greenlog'. When
        //       null, derivation defaults to 'greenlog' at read time
        //       (matches the pre-trigger shipped behavior and the
        //       shared Zod schema's defensive decode).
        //     - requiredCount INTEGER — positive integer required when
        //       referencedTemplateId is set; null otherwise. Forbidden
        //       on non-ACHIEVEMENT tasks.
        //
        //   No indexes; lookups happen per-row inside DerivationPass.
        //   Both fields are nullable + additive so back-fill is a no-op.
        migrator.registerMigration("v11") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN achievementTrigger TEXT")
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN requiredCount INTEGER")
        }

        // v12: Phase 6.1 — core-board marker on boards.
        //
        //   Adds `isCore INTEGER NOT NULL DEFAULT 0` to `boards`. True
        //   iff the board was created from the recurring banner OR
        //   auto-spawned from a RecurringBoardTemplate (Phase 6.2).
        //   `findPendingRecurringBoards` suppresses the banner only
        //   when an isCore board exists for the active window — ad-hoc
        //   wizard boards (isCore = false) no longer silently dismiss
        //   the suggestion. Pre-migration rows back-fill to 0 (false)
        //   automatically via the DEFAULT.
        migrator.registerMigration("v12") { db in
            try db.execute(sql: "ALTER TABLE boards ADD COLUMN isCore INTEGER NOT NULL DEFAULT 0")
        }

        // v13: Phase 6.X — Default Pools.
        //
        //   Adds a new `default_pools` table holding one pool per
        //   `(userId, timeframe)`. Mirrors the Phase 6.2
        //   `recurring_board_templates` schema where applicable, minus
        //   the spawn-state columns (DefaultPool doesn't auto-spawn).
        //   `taskIds` is JSON-encoded text (same pattern as
        //   `seedTaskIds` on templates and `completedLineIds` on boards).
        //   Uniqueness on `(userId, timeframe)` is enforced at the
        //   application layer (`upsertDefaultPool`); no SQL UNIQUE
        //   constraint so soft-deleted rows can coexist with their
        //   recreated replacements during sync.
        migrator.registerMigration("v13") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS default_pools (
                    id TEXT PRIMARY KEY NOT NULL,
                    userId TEXT NOT NULL,
                    timeframe TEXT NOT NULL,
                    taskIds TEXT NOT NULL DEFAULT '[]',

                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL,
                    lastSyncedAt TEXT,
                    version INTEGER NOT NULL DEFAULT 1,
                    isDeleted INTEGER NOT NULL DEFAULT 0,
                    deletedAt TEXT
                )
                """)

            try db.execute(sql: "CREATE INDEX idx_default_pools_user_timeframe ON default_pools(userId, timeframe)")
            try db.execute(sql: "CREATE INDEX idx_default_pools_user_deleted ON default_pools(userId, isDeleted)")
        }

        // v14: Phase 6.Y — Timeboxed Tasks. Adds `timeframe`,
        // `startDate`, `endDate` to `tasks` and backfills each
        // non-deleted task with the values from its most-recently-
        // updated non-deleted BoardTask's Board. Tasks with zero
        // placements stay indefinite (all three columns NULL).
        //
        // Bumps `version + updatedAt` so the change syncs to remote
        // peers (each peer runs its own migration; LWW resolves any
        // overlap because timestamps are within milliseconds).
        migrator.registerMigration("v14") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN timeframe TEXT")
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN startDate TEXT")
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN endDate TEXT")

            // Backfill from most-recent BoardTask → Board. SQLite's
            // correlated UPDATE form keeps the whole pass to one
            // statement; the inner subquery finds the latest BoardTask
            // (by updatedAt) for each task whose Board is alive, then
            // returns its Board's timeframe/startDate/endDate.
            let nowISO = Self.currentTimestamp()
            try db.execute(sql: """
                UPDATE tasks
                SET timeframe = (
                        SELECT b.timeframe
                        FROM board_tasks bt
                        JOIN boards b ON b.id = bt.boardId
                        WHERE bt.taskId = tasks.id
                          AND b.isDeleted = 0
                        ORDER BY bt.updatedAt DESC
                        LIMIT 1
                    ),
                    startDate = (
                        SELECT b.startDate
                        FROM board_tasks bt
                        JOIN boards b ON b.id = bt.boardId
                        WHERE bt.taskId = tasks.id
                          AND b.isDeleted = 0
                        ORDER BY bt.updatedAt DESC
                        LIMIT 1
                    ),
                    endDate = (
                        SELECT b.endDate
                        FROM board_tasks bt
                        JOIN boards b ON b.id = bt.boardId
                        WHERE bt.taskId = tasks.id
                          AND b.isDeleted = 0
                        ORDER BY bt.updatedAt DESC
                        LIMIT 1
                    ),
                    updatedAt = ?,
                    version = version + 1
                WHERE tasks.isDeleted = 0
                  AND tasks.endDate IS NULL
                  AND EXISTS (
                      SELECT 1 FROM board_tasks bt
                      JOIN boards b ON b.id = bt.boardId
                      WHERE bt.taskId = tasks.id
                        AND b.isDeleted = 0
                  )
                """, arguments: [nowISO])
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

    /// Fetch boards by id. Used by the task detail view to render
    /// "placed on" links for the cells where this task lives.
    func fetchBoards(ids: [String]) throws -> [Board] {
        guard !ids.isEmpty else { return [] }
        return try read { db in
            try Board
                .filter(ids.contains(Column("id")) && Column("isDeleted") == false)
                .fetchAll(db)
        }
    }

    /// Boards eligible to act as a "source" in the wizard's
    /// `From a board…` filter — active boards plus boards completed
    /// within the last 30 days. Drafts and archived are excluded.
    /// Sorted recently-active first (`updatedAt desc`). Mirror of
    /// web's `useSourceBoards` hook.
    ///
    /// Opens its own `read` block. For callers that already hold a
    /// transaction (e.g., `SourceBoardsViewModel.reload` which also
    /// needs to read board_tasks atomically with the eligibility
    /// list), use `fetchEligibleSourceBoards(_:userId:)` instead so
    /// both queries see one consistent snapshot.
    func fetchEligibleSourceBoards(userId: String) throws -> [Board] {
        try read { db in
            try AppDatabase.fetchEligibleSourceBoards(db, userId: userId)
        }
    }

    /// Transaction-aware variant. Runs the same eligibility filter as
    /// `fetchEligibleSourceBoards(userId:)` but inside the caller's
    /// `read` block so the resulting boards + any subsequent reads
    /// (placements, tasks) share a single snapshot.
    static func fetchEligibleSourceBoards(_ db: Database, userId: String) throws -> [Board] {
        let completedLookbackDays = 30
        let cutoff = Date().addingTimeInterval(
            -Double(completedLookbackDays) * 24 * 60 * 60
        )
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFrac = ISO8601DateFormatter()

        let boards = try Board
            .filter(Column("userId") == userId && Column("isDeleted") == false)
            .order(Column("updatedAt").desc)
            .fetchAll(db)
        return boards.filter { board in
            if board.status == .active { return true }
            guard board.status == .completed else { return false }
            guard let completedAt = board.completedAt else { return false }
            // ISO8601 strings round-trip from JS (fractional) and Swift
            // (no fractional). Try both parsers so we don't reject valid
            // timestamps from either platform.
            let parsed = isoFormatter.date(from: completedAt)
                ?? isoFormatterNoFrac.date(from: completedAt)
            guard let ts = parsed else { return false }
            return ts >= cutoff
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

    /// Soft-delete a board.
    ///
    /// Increments `version` so LWW treats the deletion as later-wins
    /// against a concurrent update on another device. A soft delete
    /// without a version bump can be overwritten by a stale edit whose
    /// `updatedAt` happens to be newer.
    func deleteBoard(id: String) throws {
        try write { db in
            guard var board = try Board.fetchOne(db, key: id) else { return }
            let now = Self.currentTimestamp()
            board.isDeleted = true
            board.deletedAt = now
            board.updatedAt = now
            board.version += 1
            try board.update(db)
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

    /// Atomic save + sync-enqueue used by the Task detail view's edit
    /// flow. Replaces the prior pattern of calling `saveTask` followed
    /// by `enqueueTaskSyncUpdate` in two separate transactions — a
    /// crash between the two left the local row updated but no
    /// Firestore sync, silently dropping the edit on other devices.
    func saveTaskAndEnqueueUpdate(_ task: Task) throws {
        try write { db in
            try task.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: task.id,
                operationType: .update,
                payload: task,
                now: Self.currentTimestamp(),
            ).save(db)
        }
    }

    // MARK: - Task cascade helpers (M1 — live-edit)

    /// Run the cross-board derivation cascade for a task that just changed.
    ///
    /// Mirrors `bpvRunCrossBoardCascade` in `BoardPlayView.swift` but lives
    /// on `AppDatabase` so it can be called from the Tasks-tab edit path
    /// without importing the Board play surface.
    ///
    /// - Parameters:
    ///   - db: GRDB database handle (must be inside a write transaction).
    ///   - changedTaskId: The task whose state just changed.
    ///   - now: ISO8601 timestamp for stamping updated board rows.
    ///
    /// Must be called inside an active write transaction covering
    /// `tasks`, `boardTasks`, `compoundChildren`, `boards`, and `syncQueue`.
    static func runBoardCascadeForTask(
        db: Database,
        changedTaskId: String,
        now: String
    ) throws {
        let allChildren: [CompoundChild] = try CompoundChild
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allBoardTasks: [BoardTask] = try BoardTask.fetchAll(db)
        let allTasks: [Task] = try Task.fetchAll(db)
        let allBoards: [Board] = try Board.fetchAll(db)

        var taskById: [String: Task] = [:]
        for t in allTasks { taskById[t.id] = t }
        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in allChildren {
            childrenByCompound[c.compoundTaskId, default: []].append(c)
        }

        let parentCompounds = DerivationPass.findTransitiveParentCompounds(
            changedTaskId: changedTaskId,
            children: allChildren
        )
        let affectedBoardIds = DerivationPass.findAffectedBoardIds(
            changedTaskId: changedTaskId,
            parentCompounds: parentCompounds,
            boardTasks: allBoardTasks
        )

        for boardId in affectedBoardIds {
            guard var board = try Board.fetchOne(db, key: boardId), !board.isDeleted else { continue }
            let boardTasksOnBoard = allBoardTasks.filter { $0.boardId == boardId }
            let update = DerivationPass.computeBoardStatsUpdate(
                board: board,
                boardTasksOnBoard: boardTasksOnBoard,
                childrenByCompound: childrenByCompound,
                taskById: taskById,
                allBoards: allBoards
            )

            let totalSquares = board.boardSize * board.boardSize
            let isGreenlogNow = update.completedTasks >= totalSquares

            board.completedTasks = update.completedTasks
            board.totalTasks = totalSquares
            board.linesCompleted = update.linesCompleted
            board.completedLineIds = update.completedLineIds.isEmpty ? nil : update.completedLineIds
            board.updatedAt = now
            board.version += 1

            if isGreenlogNow, board.status == .active {
                board.status = .completed
                board.completedAt = now
            } else if !isGreenlogNow, board.status == .completed {
                board.status = .active
                board.completedAt = nil
            }

            try board.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "boards",
                entityId: boardId,
                operationType: .update,
                payload: board,
                now: now
            ).save(db)
        }
    }

    /// Save a task + enqueue sync + run the board derivation cascade.
    ///
    /// UI-edit path wrapper (Tasks tab + Task detail sheet). Keeps the
    /// cascade write in the same transaction as the task save so a crash
    /// mid-write can't leave boards stale.
    ///
    /// - Parameter task: The updated task value (caller has already bumped
    ///   `updatedAt` and `version`).
    func saveTaskAndCascade(_ task: Task) throws {
        try write { db in
            try task.save(db)
            let now = Self.currentTimestamp()
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: task.id,
                operationType: .update,
                payload: task,
                now: now
            ).save(db)
            try Self.runBoardCascadeForTask(db: db, changedTaskId: task.id, now: now)
        }
    }

    // MARK: - Board metadata edit helpers (M2 — live-edit board metadata)

    /// Editable fields for an ACTIVE board (M2).
    ///
    /// Immutable on active boards:
    ///   - `boardSize` — render as read-only chip (too disruptive to change).
    ///   - `isCore`, `spawnedFromTemplateId`, `isRandomized` — internal state.
    ///   - Placement set (`BoardTask` rows) — M3/M4.
    ///
    /// NOTE (center-switch asymmetry): switching CHOSEN → FREE/CUSTOM_FREE
    /// preserves the underlying `BoardTask` row; the board.centerTaskId column
    /// is cleared so the cell renders as FREE on top, but the placement is
    /// retained in case the user switches back. Do not treat this as a bug.
    struct UpdateActiveBoardPatch {
        var name: String?
        var timeframe: Timeframe?
        /// Local-ISO8601 snap to 00:00:00.000 start-of-day (via `wizardLocalISOString`).
        var startDate: String?
        /// Local-ISO8601 snap to 23:59:59.999 end-of-day (via `wizardLocalISOString`).
        var endDate: String?
        var centerSquareType: CenterSquareType?
        /// Only meaningful when `centerSquareType == .customFree`.
        var centerSquareCustomName: String?
        /// Only meaningful when `centerSquareType == .chosen`.
        var centerTaskId: String?

        init(
            name: String? = nil,
            timeframe: Timeframe? = nil,
            startDate: String? = nil,
            endDate: String? = nil,
            centerSquareType: CenterSquareType? = nil,
            centerSquareCustomName: String? = nil,
            centerTaskId: String? = nil
        ) {
            self.name = name
            self.timeframe = timeframe
            self.startDate = startDate
            self.endDate = endDate
            self.centerSquareType = centerSquareType
            self.centerSquareCustomName = centerSquareCustomName
            self.centerTaskId = centerTaskId
        }
    }

    /// Apply a metadata patch to an ACTIVE board and re-derive stats for
    /// every placed task.
    ///
    /// Sequence:
    ///   1. Apply the patch atomically (bumps version, enqueues boards sync).
    ///   2. Sanitize center-square auxiliary fields (clear centerTaskId for
    ///      non-CHOSEN types; clear centerSquareCustomName for non-CUSTOM_FREE).
    ///   3. Fetch every `BoardTask` that places a task on this board.
    ///   4. Run `Self.runBoardCascadeForTask` for each unique placed task
    ///      inside the same write transaction.
    ///
    /// Per-task cascade (not per-board) is deliberate: timeframe/dates changes
    /// can flip expiry state on placed tasks, and each task's derivation reads
    /// from board.timeframe + board.endDate. Mirrors the web-side
    /// `updateBoardAndCascade` in `apps/web/src/db/operations/boards.ts`.
    ///
    /// NOTE on renaming: references to this board (Achievement tasks,
    /// recurring-template spawn records) are always by id, so renaming is
    /// safe with no additional propagation. Renaming does NOT update the
    /// spawning template name or historical spawn names.
    ///
    /// - Parameters:
    ///   - boardId: Board to update.
    ///   - patch: Editable fields for ACTIVE boards.
    func updateBoardAndCascade(boardId: String, patch: UpdateActiveBoardPatch) throws {
        try write { db in
            guard var board = try Board.fetchOne(db, key: boardId) else { return }
            let now = Self.currentTimestamp()

            // 1. Apply scalar fields.
            if let n = patch.name { board.name = n }
            if let tf = patch.timeframe { board.timeframe = tf }
            if let sd = patch.startDate { board.startDate = sd }
            if let ed = patch.endDate { board.endDate = ed }

            // 2. Center-square fields with sanitization.
            if let ct = patch.centerSquareType {
                board.centerSquareType = ct
                switch ct {
                case .customFree:
                    // Keep caller-supplied custom name; clear any stale centerTaskId.
                    board.centerSquareCustomName = patch.centerSquareCustomName
                    board.centerTaskId = nil
                case .chosen:
                    // Keep caller-supplied centerTaskId; clear custom name.
                    // NOTE (asymmetry): switching CHOSEN → FREE/CUSTOM_FREE later
                    // will clear centerTaskId but NOT the BoardTask row, preserving
                    // the placement for a potential future switch back.
                    if let tid = patch.centerTaskId { board.centerTaskId = tid }
                    board.centerSquareCustomName = nil
                default:
                    // FREE / NONE: clear both auxiliary fields.
                    // The BoardTask row (if any) is preserved — only the board-level
                    // reference is cleared.
                    board.centerSquareCustomName = nil
                    board.centerTaskId = nil
                }
            }

            board.updatedAt = now
            board.version += 1
            try board.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "boards",
                entityId: boardId,
                operationType: .update,
                payload: board,
                now: now
            ).save(db)

            // 3. Batch cascade: load shared tables ONCE, find the union of
            //    affected board IDs across all placed tasks, then write one
            //    stats update per affected board. This replaces the previous
            //    per-task loop which did O(N) full-table scans (one per task
            //    on a 5×5 board = 25 cascade calls). (Copilot review #9)
            let placements = try BoardTask
                .filter(Column("boardId") == boardId)
                .fetchAll(db)
            let taskIds = Array(Set(placements.map { $0.taskId }))

            guard !taskIds.isEmpty else { return }

            let allChildren: [CompoundChild] = try CompoundChild
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
            let allBoardTasks: [BoardTask] = try BoardTask.fetchAll(db)
            let allTasks: [Task] = try Task.fetchAll(db)
            let allBoards: [Board] = try Board.fetchAll(db)

            var taskById: [String: Task] = [:]
            for t in allTasks { taskById[t.id] = t }
            var childrenByCompound: [String: [CompoundChild]] = [:]
            for c in allChildren {
                childrenByCompound[c.compoundTaskId, default: []].append(c)
            }

            // Collect the union of all affected board IDs across every placed task.
            var affectedBoardIds = Set<String>()
            for taskId in taskIds {
                let parents = DerivationPass.findTransitiveParentCompounds(
                    changedTaskId: taskId,
                    children: allChildren
                )
                let ids = DerivationPass.findAffectedBoardIds(
                    changedTaskId: taskId,
                    parentCompounds: parents,
                    boardTasks: allBoardTasks
                )
                affectedBoardIds.formUnion(ids)
            }

            // Update each affected board exactly once.
            for affectedBoardId in affectedBoardIds {
                // Re-fetch to see the just-written metadata update above.
                guard var affectedBoard = try Board.fetchOne(db, key: affectedBoardId),
                      !affectedBoard.isDeleted else { continue }
                let boardTasksOnBoard = allBoardTasks.filter { $0.boardId == affectedBoardId }
                let update = DerivationPass.computeBoardStatsUpdate(
                    board: affectedBoard,
                    boardTasksOnBoard: boardTasksOnBoard,
                    childrenByCompound: childrenByCompound,
                    taskById: taskById,
                    allBoards: allBoards
                )

                let totalSquares = affectedBoard.boardSize * affectedBoard.boardSize
                let isGreenlogNow = update.completedTasks >= totalSquares

                affectedBoard.completedTasks = update.completedTasks
                affectedBoard.totalTasks = totalSquares
                affectedBoard.linesCompleted = update.linesCompleted
                affectedBoard.completedLineIds = update.completedLineIds.isEmpty ? nil : update.completedLineIds
                affectedBoard.updatedAt = now
                affectedBoard.version += 1

                if isGreenlogNow, affectedBoard.status == .active {
                    affectedBoard.status = .completed
                    affectedBoard.completedAt = now
                } else if !isGreenlogNow, affectedBoard.status == .completed {
                    affectedBoard.status = .active
                    affectedBoard.completedAt = nil
                }

                try affectedBoard.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "boards",
                    entityId: affectedBoardId,
                    operationType: .update,
                    payload: affectedBoard,
                    now: now
                ).save(db)
            }
        }
    }

    // MARK: - Copy-from-source helpers
    //
    // The wizard's `From a board…` filter long-press menu exposes
    // `⎘ Add a copy of this task…`. The Copy modal collects per-type
    // editable fields, pre-filled from the source. These helpers
    // construct the new Task value, persist it + its compound children
    // (when applicable), and enqueue the sync write — all atomically.
    // iOS twin of web's `copyTask` / `copyCompound` in
    // `apps/web/src/db/operations/tasks.ts`. See
    // docs/ARCHITECTURE.md § "Wizard 'From a board' picker" for the
    // shallow-compound-copy invariant. Achievement copies are NOT
    // cycle-checked here — the gate runs at wizard-commit time when
    // the Task is placed on the new board (Phase 6.3 behavior).

    /// Editable fields the Copy sheet may override when copying a
    /// primitive (normal / counting / achievement) task. Any property
    /// left `nil` inherits from the source.
    ///
    /// For achievement copies: if EITHER `referencedBoardId` or
    /// `referencedTemplateId` is provided, both override values are
    /// used as-is (treating the other's `nil` as "clear"). This is
    /// how the sheet switches between specific-board and
    /// recurring-template modes. If neither is provided, both
    /// inherit from the source.
    struct CopyTaskOverrides {
        var title: String?
        var description: String?
        // Counting
        var action: String?
        var unit: String?
        var maxCount: Int?
        // Achievement
        var achievementTrigger: AchievementTrigger?
        var referencedBoardId: String?
        var referencedTemplateId: String?
        var requiredCount: Int?

        init(
            title: String? = nil,
            description: String? = nil,
            action: String? = nil,
            unit: String? = nil,
            maxCount: Int? = nil,
            achievementTrigger: AchievementTrigger? = nil,
            referencedBoardId: String? = nil,
            referencedTemplateId: String? = nil,
            requiredCount: Int? = nil,
            overrodeReference: Bool = false
        ) {
            self.title = title
            self.description = description
            self.action = action
            self.unit = unit
            self.maxCount = maxCount
            self.achievementTrigger = achievementTrigger
            self.referencedBoardId = referencedBoardId
            self.referencedTemplateId = referencedTemplateId
            self.requiredCount = requiredCount
            self.overrodeReference = overrodeReference
        }

        /// True when the sheet touched the reference fields. Distinguishes
        /// "inherit from source" (false → use source's pair) from
        /// "user picked board mode but left template blank" (true → use
        /// overrides as-is, blanks become clears). Swift can't infer this
        /// from `nil` alone the way TS infers from `=== undefined`.
        var overrodeReference: Bool = false
    }

    /// Copy a primitive task (normal / counting / achievement). Throws
    /// if the source is a compound — call `copyCompound` instead.
    @discardableResult
    func copyTask(
        userId: String,
        source: Task,
        overrides: CopyTaskOverrides = CopyTaskOverrides()
    ) throws -> Task {
        if source.type == .compound {
            throw NSError(
                domain: "AppDatabase.copyTask",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "copyTask cannot copy a compound source — use copyCompound instead"]
            )
        }

        let now = Self.currentTimestamp()
        let newId = Self.generateUUID()

        // Resolve reference fields: if the sheet touched either field,
        // both come from overrides (nil-as-clear so a switch from
        // board → template doesn't leave both set and trip the XOR
        // refinement). Otherwise inherit from the source.
        let refBoard: String? = overrides.overrodeReference
            ? overrides.referencedBoardId
            : source.referencedBoardId
        let refTemplate: String? = overrides.overrodeReference
            ? overrides.referencedTemplateId
            : source.referencedTemplateId

        let newTask = Task(
            id: newId,
            userId: userId,
            title: overrides.title ?? source.title,
            description: overrides.description ?? source.description,
            type: source.type,
            action: source.type == .counting
                ? (overrides.action ?? source.action) : nil,
            unit: source.type == .counting
                ? (overrides.unit ?? source.unit) : nil,
            maxCount: source.type == .counting
                ? (overrides.maxCount ?? source.maxCount) : nil,
            referencedBoardId: source.type == .achievement ? refBoard : nil,
            referencedTemplateId: source.type == .achievement ? refTemplate : nil,
            achievementTrigger: source.type == .achievement
                ? (overrides.achievementTrigger ?? source.achievementTrigger) : nil,
            requiredCount: source.type == .achievement
                ? (overrides.requiredCount ?? source.requiredCount) : nil,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            currentCount: source.type == .counting ? 0 : nil,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false,
            timeframe: source.timeframe,
            startDate: source.startDate,
            endDate: source.endDate
        )

        try write { db in
            try newTask.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: newId,
                operationType: .create,
                payload: newTask,
                now: now
            ).save(db)
        }
        return newTask
    }

    /// Copy a compound task. Shallow: the new compound parent has a
    /// fresh id but its `compound_children` rows reference the SAME
    /// primitive child Tasks the source had. Deep-clone is intentionally
    /// not provided (see ARCHITECTURE.md doc).
    @discardableResult
    func copyCompound(
        userId: String,
        source: Task,
        title: String? = nil,
        description: String? = nil
    ) throws -> Task {
        guard source.type == .compound else {
            throw NSError(
                domain: "AppDatabase.copyCompound",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "copyCompound requires a compound source task"]
            )
        }
        guard let op = source.operatorType else {
            throw NSError(
                domain: "AppDatabase.copyCompound",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "compound source missing operatorType field"]
            )
        }
        guard let isOrdered = source.isOrdered else {
            throw NSError(
                domain: "AppDatabase.copyCompound",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "compound source missing isOrdered field"]
            )
        }

        let now = Self.currentTimestamp()
        let newParentId = Self.generateUUID()

        let newParent = Task(
            id: newParentId,
            userId: userId,
            title: title ?? source.title,
            description: description ?? source.description,
            type: .compound,
            operatorType: op,
            threshold: source.threshold,
            isOrdered: isOrdered,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false,
            timeframe: source.timeframe,
            startDate: source.startDate,
            endDate: source.endDate
        )

        // Read children OUTSIDE the write transaction so we don't hold a
        // writer lock open across the read. `fetchCompoundChildren`
        // already filters !isDeleted and orders by childIndex.
        let sourceChildren = try fetchCompoundChildren(compoundTaskId: source.id)

        try write { db in
            try newParent.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: newParentId,
                operationType: .create,
                payload: newParent,
                now: now
            ).save(db)

            for (index, child) in sourceChildren.enumerated() {
                let linkId = Self.generateUUID()
                let link = CompoundChild(
                    id: linkId,
                    compoundTaskId: newParentId,
                    childTaskId: child.childTaskId,
                    childIndex: index,
                    createdAt: now,
                    updatedAt: now,
                    lastSyncedAt: nil,
                    version: 1,
                    isDeleted: false,
                    deletedAt: nil
                )
                try link.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "compoundChildren",
                    entityId: linkId,
                    operationType: .create,
                    payload: link,
                    now: now
                ).save(db)
            }
        }

        return newParent
    }

    /// Soft-delete a task. See `deleteBoard` for the version-bump rationale.
    func deleteTask(id: String) throws {
        try write { db in
            guard var task = try Task.fetchOne(db, key: id) else { return }
            let now = Self.currentTimestamp()
            task.isDeleted = true
            task.deletedAt = now
            task.updatedAt = now
            task.version += 1
            try task.update(db)
        }
    }

    /// Summary of what `deleteTaskWithCascade` would remove. Lets the
    /// detail view surface affected counts in the confirm dialog before
    /// the user commits. Mirrors web's `TaskDeletionImpact`.
    struct TaskDeletionImpact {
        /// Count of `BoardTask` rows that reference this task as a placement.
        let boardTaskCount: Int
        /// Distinct boards the placements span (cells on the same board count once).
        let affectedBoardIds: [String]
        /// The live (non-deleted) board records the placements live on. Same
        /// set as `affectedBoardIds` — included so the confirm sheet can
        /// surface board name + status without a second fetch.
        let affectedBoards: [Board]
        /// `CompoundChild` rows where the task is the CHILD. The parent
        /// compound loses this child; sibling children remain.
        let childLinkCount: Int
        /// `CompoundChild` rows where the task IS the parent compound.
        /// Each parent link is severed; the child Tasks remain.
        let parentLinkCount: Int
    }

    /// Read-only impact calculation; safe to call before showing the
    /// confirm dialog. Filters BoardTask placements to those on
    /// non-deleted boards — `BoardTask` has no `isDeleted` column, so
    /// orphan placements on soft-deleted boards would otherwise inflate
    /// the user-facing count. The actual cascade still hard-deletes
    /// every matching placement (storage cleanup); the dialog only
    /// reports cells the user can still see.
    func computeTaskDeletionImpact(taskId: String) throws -> TaskDeletionImpact {
        try read { db in
            let allPlacements = try BoardTask
                .filter(Column("taskId") == taskId)
                .fetchAll(db)
            let placementBoardIds = Array(Set(allPlacements.map { $0.boardId }))
            let liveBoards: [Board] = placementBoardIds.isEmpty
                ? []
                : try Board
                    .filter(placementBoardIds.contains(Column("id"))
                            && Column("isDeleted") == false)
                    .fetchAll(db)
            let liveBoardIds = Set(liveBoards.map { $0.id })
            let visiblePlacements = allPlacements.filter { liveBoardIds.contains($0.boardId) }
            let childLinks = try CompoundChild
                .filter(Column("childTaskId") == taskId && Column("isDeleted") == false)
                .fetchCount(db)
            let parentLinks = try CompoundChild
                .filter(Column("compoundTaskId") == taskId && Column("isDeleted") == false)
                .fetchCount(db)
            return TaskDeletionImpact(
                boardTaskCount: visiblePlacements.count,
                affectedBoardIds: Array(liveBoardIds),
                affectedBoards: liveBoards,
                childLinkCount: childLinks,
                parentLinkCount: parentLinks,
            )
        }
    }

    /// Cascade-delete a task. Mirrors web's `deleteTaskWithCascade`:
    ///
    /// 1. **BoardTask placements** referencing this task — *hard-
    ///    deleted* (BoardTask has no `isDeleted` field). Each removal
    ///    queued for sync DELETE so other devices drop the placement.
    /// 2. **`CompoundChild` rows where the task IS the parent compound**
    ///    — soft-deleted (version bump + isDeleted + deletedAt). The
    ///    child Tasks themselves stay alive.
    /// 3. **`CompoundChild` rows where the task IS a child** — soft-
    ///    deleted. Sibling links + the parent Task itself are untouched.
    /// 4. **The Task itself** — soft-deleted with version bump (matches
    ///    `deleteTask`'s LWW semantics).
    ///
    /// All operations run in a single GRDB write transaction so a
    /// crash mid-cascade leaves a consistent local DB.
    func deleteTaskWithCascade(taskId: String) throws {
        try write { db in
            guard var task = try Task.fetchOne(db, key: taskId) else { return }
            let now = Self.currentTimestamp()

            // 1. Hard-delete BoardTask placements.
            let placements = try BoardTask
                .filter(Column("taskId") == taskId)
                .fetchAll(db)
            for bt in placements {
                _ = try bt.delete(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "boardTasks",
                    entityId: bt.id,
                    operationType: .delete,
                    payload: bt,
                    now: now,
                ).save(db)
            }

            // 2 + 3. Soft-delete compound-child links — both directions.
            let parentLinks = try CompoundChild
                .filter(Column("compoundTaskId") == taskId && Column("isDeleted") == false)
                .fetchAll(db)
            let childLinks = try CompoundChild
                .filter(Column("childTaskId") == taskId && Column("isDeleted") == false)
                .fetchAll(db)
            for var link in parentLinks + childLinks {
                link.isDeleted = true
                link.deletedAt = now
                link.updatedAt = now
                link.version += 1
                try link.update(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "compoundChildren",
                    entityId: link.id,
                    operationType: .delete,
                    payload: link,
                    now: now,
                ).save(db)
            }

            // 4. Soft-delete the Task itself.
            task.isDeleted = true
            task.deletedAt = now
            task.updatedAt = now
            task.version += 1
            try task.update(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: task.id,
                operationType: .delete,
                payload: task,
                now: now,
            ).save(db)
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

    /// Fetch every `BoardTask` row that references a specific Task. Used
    /// by the Task detail view to list "placed on N boards" and by the
    /// cascade-delete impact preview.
    func fetchBoardTasksForTask(taskId: String) throws -> [BoardTask] {
        return try read { db in
            try BoardTask
                .filter(Column("taskId") == taskId)
                .fetchAll(db)
        }
    }

    /// Hard-deletes every `BoardTask` row for the given board. Used
    /// when re-saving a draft whose task placement has changed —
    /// simpler than diffing old vs new layout, and tolerable at scale
    /// (boards have at most 25 cells).
    ///
    /// `BoardTask` has no `isDeleted` flag, so the deletion is literal;
    /// the web twin uses the same pattern.
    func deleteBoardTasksForBoard(boardId: String) throws {
        try write { db in
            _ = try BoardTask
                .filter(Column("boardId") == boardId)
                .deleteAll(db)
        }
    }

    func saveBoardTask(_ boardTask: BoardTask) throws {
        try write { db in
            try boardTask.save(db)
        }
    }

    /// Fetch every BoardTask in the workspace. Used by the derivation pass
    /// to find which boards contain a given task (directly or via a compound).
    /// Small-N: typical user has under a few thousand BoardTasks.
    func fetchAllBoardTasks() throws -> [BoardTask] {
        return try read { db in
            try BoardTask.fetchAll(db)
        }
    }

    // MARK: - CompoundChildren

    /// Fetch every non-deleted compound_children row in the workspace.
    /// Used by the derivation pass to find transitive parent compounds and
    /// build the childrenByCompound map fed into computeBoardStatsUpdate.
    func fetchAllCompoundChildren() throws -> [CompoundChild] {
        return try read { db in
            try CompoundChild
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
        }
    }

    /// Fetch the parent compound Tasks that reference the given task as a child
    /// (via non-deleted compound_children rows where childTaskId == taskId).
    /// Returns de-duplicated, non-deleted Task rows ordered by title.
    ///
    /// - Parameter taskId: The child task's ID.
    /// - Returns: Non-deleted compound Task rows that are parents of this task.
    func fetchCompoundParents(forTaskId taskId: String) throws -> [Task] {
        return try read { db in
            let links = try CompoundChild
                .filter(Column("childTaskId") == taskId && Column("isDeleted") == false)
                .fetchAll(db)
            let parentIds = Array(Set(links.map { $0.compoundTaskId }))
            guard !parentIds.isEmpty else { return [] }
            return try Task
                .filter(parentIds.contains(Column("id")) && Column("isDeleted") == false)
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    /// Fetch the child Tasks of a compound, ordered by childIndex.
    /// Returns non-deleted Task rows only; soft-deleted children are excluded.
    ///
    /// - Parameter parentTaskId: The parent compound task's ID.
    /// - Returns: Child Task rows ordered by compound_children.childIndex.
    func fetchCompoundChildrenTasks(parentTaskId: String) throws -> [Task] {
        return try read { db in
            let links = try CompoundChild
                .filter(Column("compoundTaskId") == parentTaskId && Column("isDeleted") == false)
                .order(Column("childIndex"))
                .fetchAll(db)
            guard !links.isEmpty else { return [] }
            // Preserve the childIndex ordering: look up tasks and re-sort.
            let childIds = links.map { $0.childTaskId }
            let tasks = try Task
                .filter(childIds.contains(Column("id")) && Column("isDeleted") == false)
                .fetchAll(db)
            let taskById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
            return links.compactMap { taskById[$0.childTaskId] }
        }
    }

    /// Fetch all non-deleted recurring templates whose seedTaskIds contain the
    /// given taskId. Soft-deleted tasks are intentionally retained in
    /// seedTaskIds per the schema, so this query filters only on template
    /// isDeleted — not on the task's own deletion state.
    ///
    /// - Parameter taskId: The task ID to search for.
    /// - Returns: Non-deleted templates referencing the task.
    func fetchTemplatesReferencingTask(_ taskId: String) throws -> [RecurringBoardTemplate] {
        return try read { db in
            // Fetch all non-deleted templates, then filter in-process.
            // seedTaskIds is stored as a JSON string; LIKE '%taskId%' would
            // be a cheaper SQL predicate, but it risks false-positives on
            // UUID prefix collisions and is harder to read. The template
            // table is small (tens of rows per user), so in-process filter
            // is acceptable here.
            let all = try RecurringBoardTemplate
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
            return all.filter { $0.seedTaskIds.contains(taskId) }
        }
    }

    /// Fetch all non-deleted compound_children rows for a single parent compound,
    /// ordered by childIndex.
    ///
    /// - Parameter compoundTaskId: The parent compound task's ID.
    /// - Returns: All matching children ordered by `childIndex`.
    func fetchCompoundChildren(compoundTaskId: String) throws -> [CompoundChild] {
        return try read { db in
            try CompoundChild
                .filter(Column("compoundTaskId") == compoundTaskId && Column("isDeleted") == false)
                .order(Column("childIndex"))
                .fetchAll(db)
        }
    }

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

    // MARK: - DefaultPools (Phase 6.X)

    /// Fetch all non-deleted DefaultPools for a user. Used by the
    /// Profile editor to render the per-timeframe summary.
    func fetchDefaultPools(userId: String) throws -> [DefaultPool] {
        return try read { db in
            try DefaultPool
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .fetchAll(db)
        }
    }

    /// Fetch the (at-most-one) non-deleted DefaultPool for
    /// `(userId, timeframe)`. Returns nil when the user has no pool for
    /// this timeframe. Used by the wizard's banner-launch prefill path.
    func fetchDefaultPool(userId: String, timeframe: Timeframe) throws -> DefaultPool? {
        return try read { db in
            try DefaultPool
                .filter(
                    Column("userId") == userId
                        && Column("timeframe") == timeframe.rawValue
                        && Column("isDeleted") == false
                )
                .fetchOne(db)
        }
    }

    /// Insert / update a pool. Caller is responsible for bumping
    /// `version` + `updatedAt` (mirror of `saveRecurringBoardTemplate`).
    func saveDefaultPool(_ pool: DefaultPool) throws {
        try write { db in
            try pool.save(db)
        }
    }

    /// Atomic upsert by `(userId, timeframe)`. Preferred UI-side entry
    /// point — guarantees per-timeframe uniqueness without leaking the
    /// create-vs-update decision to callers.
    @discardableResult
    func upsertDefaultPool(userId: String, timeframe: Timeframe, taskIds: [String]) throws -> DefaultPool {
        return try write { db in
            let now = Self.currentTimestamp()
            if var existing = try DefaultPool
                .filter(
                    Column("userId") == userId
                        && Column("timeframe") == timeframe.rawValue
                        && Column("isDeleted") == false
                )
                .fetchOne(db)
            {
                existing.taskIds = taskIds
                existing.updatedAt = now
                existing.version += 1
                try existing.update(db)
                return existing
            }
            let pool = DefaultPool(
                id: Self.generateUUID(),
                userId: userId,
                timeframe: timeframe,
                taskIds: taskIds,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil,
                version: 1,
                isDeleted: false,
                deletedAt: nil
            )
            try pool.insert(db)
            return pool
        }
    }

    /// Soft-delete a DefaultPool. The Profile editor's "Clear pool"
    /// action calls this — distinct from saving an empty taskIds list
    /// (which keeps the row, just empties the pool).
    func softDeleteDefaultPool(id: String) throws {
        try write { db in
            guard var pool = try DefaultPool.fetchOne(db, key: id) else { return }
            let now = Self.currentTimestamp()
            pool.isDeleted = true
            pool.deletedAt = now
            pool.updatedAt = now
            pool.version += 1
            try pool.update(db)
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
            user.updatedAt = Self.currentTimestamp()
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
        let cutoffISO = Self.isoFormatter.string(from: cutoff)

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
                    .flatMap { Self.parseISO8601($0) }
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
            board?.lastSyncedAt = Self.currentTimestamp()
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

}

// MARK: - Utilities

extension AppDatabase {
    /// Generate UUID for new entities
    static func generateUUID() -> String {
        return UUID().uuidString.lowercased()
    }

    /// Shared ISO8601 formatter. `ISO8601DateFormatter` is expensive
    /// to instantiate (~10–50ms on first use) and identical across
    /// every call site that just wants `Date.now` in ISO8601 — hoist
    /// it to a single static so write transactions don't pay the cost
    /// per row. `Foundation` documents the type as thread-safe.
    private static let isoFormatter = ISO8601DateFormatter()

    /// Get current ISO8601 timestamp.
    static func currentTimestamp() -> String {
        return isoFormatter.string(from: Date())
    }

    /// Parse an ISO8601 string back to a `Date` (or nil). Used by the
    /// sync-pull validators.
    static func parseISO8601(_ s: String) -> Date? {
        return isoFormatter.date(from: s)
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
