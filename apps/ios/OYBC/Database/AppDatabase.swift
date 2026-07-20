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

        // v15: Phase 2 — Shared Counters. Adds `sharedCounterId` (TEXT)
        // and `baseline` (INTEGER) to `tasks`. Both are NULL for non-linked
        // tasks. No index needed — source lookups are small-N in practice.
        // Additive nullable columns; no data backfill required.
        migrator.registerMigration("v15") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN sharedCounterId TEXT")
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN baseline INTEGER")
        }

        // v16: Phase 4 — Shared Counter Sync. Adds `lastSyncedCount` (INTEGER)
        // to `tasks`. RETIRED by Windowed Completion: it was the common-ancestor
        // for the additive-merge conflict resolver, which is gone (counting-task
        // conflicts now resolve by union-of-events —
        // docs/WINDOWED_COMPLETION.md §Shared counters interaction). The column
        // stays (this migration is history; the field decodes old rows) but is
        // inert — nothing reads or writes it. Do NOT drop it (breaks decode).
        //
        // Dead-scaffolding note (Decision 1 / Phase 4 cleanup): the `progress_counters`
        // SQLite table remains in place — SQLite cannot drop a table without
        // recreating all referencing tables, and the table is already inert (no
        // live reads/writes, not in SYNCABLE_COLLECTIONS). The v11 Dexie
        // migration drops the IndexedDB equivalent. The iOS table is intentionally
        // left as a zero-row artifact; a future major-version cleanup could
        // replace the schema with a fresh `CREATE TABLE` at a higher migration
        // version if disk space becomes a concern.
        migrator.registerMigration("v16") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN lastSyncedCount INTEGER")
        }

        // v17: Draft-board provenance. Adds `createdInWizard` (INTEGER 0/1) to
        // `tasks`. `true` marks a task created inside the board wizard's
        // deferred-persist path (Bug #85) — used by library-browse surfaces to
        // hide it until its board is active (visibility rule: hide iff
        // createdInWizard AND placed only on draft boards). Existing rows
        // default to 0 (visible) — the fix is forward-looking; tasks that
        // already leaked into the library before this migration stay visible.
        migrator.registerMigration("v17") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN createdInWizard INTEGER NOT NULL DEFAULT 0")
        }

        // v18: Indefinite boards. Relaxes `boards.endDate` from `NOT NULL` to
        // nullable so an INDEFINITE board (ongoing, no deadline) can store a
        // genuine SQL NULL — which serializes to Firestore as an absent field
        // (no sentinel string leaking into the wire format).
        //
        // SQLite cannot drop a NOT NULL constraint via ALTER, so this performs
        // the standard table rebuild: create a twin with the relaxed column,
        // copy every row, drop the old table, rename, and recreate the indexes.
        // The migrator's default `.deferred` foreign-key mode disables FK
        // enforcement during the migration and re-checks at commit — required
        // because `board_tasks.boardId REFERENCES boards(id) ON DELETE CASCADE`
        // would otherwise cascade-delete placements when the old table is
        // dropped. A row-count parity assertion guards against a silent copy
        // failure. Columns mirror the post-v17 table exactly (Schema.sql base +
        // the v4/v8/v12 ALTERs: centerSquareCustomName, centerTaskId,
        // spawnedFromTemplateId, isCore).
        migrator.registerMigration("v18") { db in
            let before = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM boards") ?? 0

            try db.execute(sql: """
                CREATE TABLE boards_new (
                    id TEXT PRIMARY KEY NOT NULL,
                    userId TEXT NOT NULL,
                    name TEXT NOT NULL,
                    description TEXT,
                    status TEXT NOT NULL,
                    boardSize INTEGER NOT NULL,
                    timeframe TEXT NOT NULL, -- daily, weekly, monthly, yearly, custom, indefinite
                    startDate TEXT NOT NULL,
                    endDate TEXT, -- nullable: NULL = INDEFINITE board (no deadline)
                    centerSquareType TEXT NOT NULL,
                    isRandomized INTEGER NOT NULL DEFAULT 0,
                    totalTasks INTEGER NOT NULL DEFAULT 0,
                    completedTasks INTEGER NOT NULL DEFAULT 0,
                    linesCompleted INTEGER NOT NULL DEFAULT 0,
                    completedLineIds TEXT,
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL,
                    completedAt TEXT,
                    lastSyncedAt TEXT,
                    version INTEGER NOT NULL DEFAULT 1,
                    isDeleted INTEGER NOT NULL DEFAULT 0,
                    deletedAt TEXT,
                    centerSquareCustomName TEXT,
                    centerTaskId TEXT REFERENCES tasks(id),
                    spawnedFromTemplateId TEXT,
                    isCore INTEGER NOT NULL DEFAULT 0,
                    FOREIGN KEY (userId) REFERENCES users(id)
                )
                """)

            try db.execute(sql: """
                INSERT INTO boards_new (
                    id, userId, name, description, status, boardSize, timeframe,
                    startDate, endDate, centerSquareType, isRandomized, totalTasks,
                    completedTasks, linesCompleted, completedLineIds, createdAt,
                    updatedAt, completedAt, lastSyncedAt, version, isDeleted,
                    deletedAt, centerSquareCustomName, centerTaskId,
                    spawnedFromTemplateId, isCore
                )
                SELECT
                    id, userId, name, description, status, boardSize, timeframe,
                    startDate, endDate, centerSquareType, isRandomized, totalTasks,
                    completedTasks, linesCompleted, completedLineIds, createdAt,
                    updatedAt, completedAt, lastSyncedAt, version, isDeleted,
                    deletedAt, centerSquareCustomName, centerTaskId,
                    spawnedFromTemplateId, isCore
                FROM boards
                """)

            let copied = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM boards_new") ?? -1
            guard copied == before else {
                throw DatabaseError(message: "v18 migration row-count mismatch: \(before) boards but \(copied) copied")
            }

            try db.execute(sql: "DROP TABLE boards")
            try db.execute(sql: "ALTER TABLE boards_new RENAME TO boards")

            // Recreate the indexes (they were dropped with the old table).
            try db.execute(sql: "CREATE INDEX idx_boards_user_deleted ON boards(userId, isDeleted)")
            try db.execute(sql: "CREATE INDEX idx_boards_user_timeframe_status ON boards(userId, timeframe, status)")
            try db.execute(sql: "CREATE INDEX idx_boards_user_timeframe_lines ON boards(userId, timeframe, linesCompleted)")
            try db.execute(sql: "CREATE INDEX idx_boards_updated ON boards(updatedAt)")
            try db.execute(sql: "CREATE INDEX idx_boards_status ON boards(status)")
        }

        // v19: Windowed Completion (docs/WINDOWED_COMPLETION.md §New entity +
        // §Migration & backfill). New `task_events` table — one soft-deletable
        // occurrence row per completion/increment on an event-owning task,
        // synced per-row LWW like compound_children. PR B sub-slice 1 is
        // FOUNDATIONS ONLY: the table is created empty; no backfill and no
        // write/read paths yet (those land in later sub-slices), so it syncs
        // harmlessly empty. `delta` is nullable (present only on increments);
        // `boardId` is provenance-only. Indexes mirror the Dexie v12 store:
        // `[taskId+occurredAt]` is the windowed-evaluation hot path,
        // `[userId+occurredAt]` backs lifetime/library reads, and
        // `[userId+isDeleted]` scopes the sync pull like every other table.
        migrator.registerMigration("v19") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS task_events (
                    id TEXT PRIMARY KEY NOT NULL,
                    userId TEXT NOT NULL,
                    taskId TEXT NOT NULL,
                    kind TEXT NOT NULL, -- completion, increment
                    delta INTEGER,      -- increment only; signed non-zero
                    occurredAt TEXT NOT NULL, -- ISO8601; windows key on this
                    boardId TEXT,       -- provenance only; never read in evaluation
                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL,
                    lastSyncedAt TEXT,
                    version INTEGER NOT NULL DEFAULT 1,
                    isDeleted INTEGER NOT NULL DEFAULT 0,
                    deletedAt TEXT,
                    FOREIGN KEY (userId) REFERENCES users(id)
                    -- Deliberately NO `FOREIGN KEY (taskId) REFERENCES tasks(id)`:
                    -- per-collection sync listeners have no cross-collection
                    -- ordering, so a taskEvent can legitimately arrive before its
                    -- Task row (docs §Sync → Pull ordering). Unlike
                    -- compound_children (which defers the upsert until its parent
                    -- exists), task_events are applied as rows immediately and
                    -- skipped by recompute until the Task lands — a tasks FK
                    -- would reject that insert. Matches the Dexie store, which
                    -- has no FK constraints at all.
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_task_events_task_occurred ON task_events(taskId, occurredAt)")
            try db.execute(sql: "CREATE INDEX idx_task_events_user_occurred ON task_events(userId, occurredAt)")
            try db.execute(sql: "CREATE INDEX idx_task_events_user_deleted ON task_events(userId, isDeleted)")
        }

        // v20: Windowed Completion — TaskEvent backfill (PR B, sub-slice 3;
        // docs/WINDOWED_COMPLETION.md §Migration & backfill, step 2). Twin of
        // web's Dexie v13 `runMigrationV13`. v19 created `task_events` empty;
        // this pass synthesizes the DETERMINISTIC backfill events from existing
        // lifetime task state so a task placed on a live board whose window
        // contains its `completedAt` keeps its green (bleed preserved once),
        // while later windows start empty.
        //
        // Only step 2 (event backfill) is B's responsibility. Step 3 (sealing
        // expired boards) is assigned to PR C by the phasing table; this
        // migration seals nothing. Step 4 (cache restamp) is a no-op — the events
        // are DERIVED FROM the caches, so they're already consistent.
        //
        // Carve-out (doc §Derived-task carve-out rule 2): `buildBackfillTaskEvent`
        // returns nil for derived / compound / achievement tasks, so they're
        // skipped — minting an event from a derived counter's mirrored
        // currentCount would double-count the source's history.
        //
        // Determinism: `buildBackfillTaskEvent` assigns a kind-qualified uuidv5
        // id and takes timestamps from the task snapshot (not migration
        // wall-clock), so two devices mint the same-id row and LWW picks the one
        // derived from the fresher task state. Backfilled events are enqueued for
        // sync CREATE (they MUST reach Firestore or another device's pull
        // recompute would zero the caches).
        migrator.registerMigration("v20") { db in
            let allTasks: [Task] = try Task.fetchAll(db)
            for task in allTasks {
                guard let event = buildBackfillTaskEvent(task: task) else { continue }
                // Idempotency belt: the deterministic id means a re-run (or a
                // peer's already-synced row) would collide. Skip if present.
                if try TaskEvent.fetchOne(db, key: event.id) != nil { continue }
                try event.save(db)
                // Enqueue sync CREATE directly (raw SQL — the migration owns its
                // own transaction; SyncQueueBuilder is not migration-tx-aware in
                // the same way, mirroring how v7/v14 write sync rows inline).
                let payloadData = try JSONEncoder().encode(event)
                let payloadStr = String(data: payloadData, encoding: .utf8) ?? "{}"
                try db.execute(sql: """
                    INSERT INTO sync_queue
                        (id, entityType, entityId, operationType, payload, status, retryCount, createdAt, priority)
                    VALUES (?, 'taskEvents', ?, 'create', ?, 'pending', 0, ?, 0)
                    """, arguments: [UUID().uuidString, event.id, payloadStr, Self.currentTimestamp()])
            }
        }

        // v21: Windowed Completion — board SEALING schema (docs §Sealing →
        // Board schema delta). Three additive nullable columns on `boards`.
        // `sealedCompletedCells` is TEXT (JSON string, same encoding as
        // `completedLineIds`). All decode forward-compatibly (missing → nil).
        migrator.registerMigration("v21") { db in
            try db.execute(sql: "ALTER TABLE boards ADD COLUMN sealedAt TEXT")
            try db.execute(sql: "ALTER TABLE boards ADD COLUMN sealedCompletedCells TEXT")
            try db.execute(sql: "ALTER TABLE boards ADD COLUMN activatedAt TEXT")
        }

        // v22: Windowed Completion — expired-board SEALING (docs §Migration &
        // backfill step 3). Twin of web's Dexie v14 `runMigrationV14`. Runs
        // AFTER v20's event backfill. Every non-deleted, non-draft,
        // non-indefinite board ALREADY past its auto-seal backstop deadline at
        // upgrade time is sealed silently; boards still inside their backstop
        // window are left for the normal close-out prompt (slice 2).
        //
        // The frozen snapshot is computed from the PRE-MIGRATION rendered state
        // (lifetime Task caches + compound evaluation — NO window context), so
        // it reproduces exactly what the user currently sees and is
        // deterministic across devices (the caches were made consistent by v20).
        // The backstop deadline keys off `endDate` here (boards have no
        // `activatedAt` pre-v22), which is deterministic and endDate-based.
        migrator.registerMigration("v22") { db in
            try AppDatabase.sealExpiredBoardsAtMigration(db: db, now: Self.currentTimestamp())
        }

        // v23: P5 hub-born counters. Adds `isCounter` (INTEGER 0/1) to `tasks`.
        migrator.registerMigration("v23") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN isCounter INTEGER NOT NULL DEFAULT 0")
        }

        // v24: Task Pools + Recurring Boards Rework (P1) — schema only
        // (docs/POOLS_RECURRING.md §Data model). New `pools` +
        // `core_board_defaults` tables (JSON-string TEXT arrays, same
        // house style as `default_pools`/`recurring_board_templates`), plus
        // three additive NULLABLE TEXT columns on `recurring_board_templates`
        // (`poolIds`, `manualTaskIds`, `removedTaskIds` — see
        // `RecurringBoardTemplate.swift`'s tri-state null-preserving
        // decode/encode). Mirrors web's Dexie v15 (store creation). Data
        // backfill is v25, run AFTER these tables/columns exist.
        migrator.registerMigration("v24") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pools (
                    id TEXT PRIMARY KEY NOT NULL,
                    userId TEXT NOT NULL,
                    name TEXT NOT NULL,
                    taskIds TEXT NOT NULL DEFAULT '[]',

                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL,
                    lastSyncedAt TEXT,
                    version INTEGER NOT NULL DEFAULT 1,
                    isDeleted INTEGER NOT NULL DEFAULT 0,
                    deletedAt TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_pools_user_deleted ON pools(userId, isDeleted)")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS core_board_defaults (
                    id TEXT PRIMARY KEY NOT NULL,
                    userId TEXT NOT NULL,
                    timeframe TEXT NOT NULL,
                    corePoolIds TEXT NOT NULL DEFAULT '[]',
                    coreDefaultTaskIds TEXT NOT NULL DEFAULT '[]',

                    createdAt TEXT NOT NULL,
                    updatedAt TEXT NOT NULL,
                    lastSyncedAt TEXT,
                    version INTEGER NOT NULL DEFAULT 1,
                    isDeleted INTEGER NOT NULL DEFAULT 0,
                    deletedAt TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_core_board_defaults_user_timeframe ON core_board_defaults(userId, timeframe)")
            try db.execute(sql: "CREATE INDEX idx_core_board_defaults_user_deleted ON core_board_defaults(userId, isDeleted)")

            try db.execute(sql: "ALTER TABLE recurring_board_templates ADD COLUMN poolIds TEXT")
            try db.execute(sql: "ALTER TABLE recurring_board_templates ADD COLUMN manualTaskIds TEXT")
            try db.execute(sql: "ALTER TABLE recurring_board_templates ADD COLUMN removedTaskIds TEXT")
        }

        // v25: Task Pools + Recurring Boards Rework (P1) — first-launch data
        // migration (docs/POOLS_RECURRING.md §Migration). Twin of web's
        // Dexie `runMigrationV16`. Two independent steps, both idempotent
        // by construction (state-based, no separate "migration completed"
        // marker — mirrors the v20/v22 backfill precedent):
        //
        //   1. Each non-deleted `DefaultPool` row → a `Pool` named
        //      "<Timeframe> default" + a `CoreBoardDefault` row for that
        //      timeframe with `corePoolIds: [newPool.id]`,
        //      `coreDefaultTaskIds: []`. The `DefaultPool` row is then
        //      soft-deleted (tombstone drains to Firestore via the push
        //      path; `defaultPools` joins `LEGACY_PULL_SKIP_COLLECTIONS`
        //      in SyncService.swift).
        //   2. Each `RecurringBoardTemplate` whose `poolIds` column IS NULL
        //      (the "genuinely un-migrated" half of `PoolMix.isLegacyShapedRecord`)
        //      has its `seedTaskIds` extracted into a `Pool` named
        //      "<template name> pool"; the template is stamped with
        //      `poolIds: [newPool.id]`, `manualTaskIds: []`,
        //      `removedTaskIds: []`. `seedTaskIds` itself is left VERBATIM
        //      (decode-compat, the `lastSyncedCount` precedent) and is
        //      never read live post-migration.
        //
        // Both steps enqueue sync entries via raw SQL inline inserts
        // (`MigrationV25Helpers.enqueueMigrationSync`, mirrors v20/v14 —
        // the migration owns its own transaction, which `SyncQueueBuilder`'s
        // coalescing `enqueue(db)` isn't written to participate in). Raw SQL
        // is fine here specifically because every row minted by this
        // migration is a brand-new id with no pre-existing PENDING row to
        // coalesce against — there's nothing for the coalescer to do.
        migrator.registerMigration("v25") { db in
            try MigrationV25Helpers.run(db, now: Self.currentTimestamp())
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
