import Foundation
import GRDB

/// Board Sources schema migrations (docs/BOARD_SOURCES.md), split out of
/// `AppDatabase.swift` so that file shrinks instead of growing past its
/// frozen `scripts/audit/file-size-allowlist.json` count (ROADMAP B6
/// posture — new migrations land here, not in the god file).
///
/// Registered from `AppDatabase.migrator` at the exact position v30 used to
/// occupy: after v29 and immediately before the migrator is returned. Order
/// matters — `DatabaseMigrator` applies migrations in registration order.
extension AppDatabase {

    /// Registers every Board Sources migration, in version order.
    ///
    /// - Parameter migrator: The migrator being assembled by
    ///   `AppDatabase.migrator`; migrations are appended in place.
    static func registerBoardSourcesMigrations(_ migrator: inout DatabaseMigrator) {
        // v30: Board Sources P1 (docs/BOARD_SOURCES.md) — JSON-string
        // `sources` column on templates. Column-only, no backfill: reads
        // go through `BoardSources.sourcesForRecord` (derives [0, all]
        // from the legacy trio for pre-stamp rows); NULL = pre-stamp.
        migrator.registerMigration("v30") { db in
            try db.execute(sql: "ALTER TABLE recurring_board_templates ADD COLUMN sources TEXT")
        }

        // v31: Board Sources §Member rules (B1) — JSON-string
        // `manualTaskVary` column on templates: the dice a user set on
        // HAND-ADDED counting members (source members carry their rules
        // inside the `sources` blob). Column-only, no backfill; NULL =
        // no dice, which is also the pre-B1 meaning of an absent column.
        migrator.registerMigration("v31") { db in
            try db.execute(sql: "ALTER TABLE recurring_board_templates ADD COLUMN manualTaskVary TEXT")
        }

        // v32: Board Sources §Member rules (B2) — index `tasks.sharedCounterId`.
        //
        // v15 added the column with "no index needed — source lookups are
        // small-N in practice"; B2 made that false. Every window-stamped
        // derived read (`fetchWindowStampedDerived`, the baseline refresh, the
        // deletion sweeps) filters on this column, and the pull path runs one
        // per affected task inside the write transaction — an unindexed full
        // `tasks` scan per row, against "sync: background only, never block
        // UI". The web twin has always been index-backed
        // (`db.tasks.where('sharedCounterId')`), so this also closes a port
        // asymmetry; it speeds up the pre-existing `linkedTasks` scans too.
        //
        // NOT in `Schema.sql`: that file is the v1 base schema, and
        // `sharedCounterId` does not exist in it (v15 adds the column), so an
        // index there would fail at first launch. The column and its index
        // both arrive by migration.
        //
        // `IF NOT EXISTS` so a DB that somehow already carries the index
        // (hand-repaired, or a re-run) migrates cleanly.
        migrator.registerMigration("v32") { db in
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS idx_tasks_shared_counter ON tasks(sharedCounterId)"
            )
        }

        // v33: sync-queue owner stamp (docs/GUEST_MODE.md §Collision) — not a
        // Board Sources change, registered here only because new migrations
        // land in this file (AppDatabase.swift is size-capped). Nullable,
        // column-only, no backfill: NULL = a pre-stamp row, which the push
        // path treats as legacy and pushes as before. LOCAL queue column only —
        // never part of any synced payload.
        migrator.registerMigration("v33") { db in
            try db.execute(sql: "ALTER TABLE sync_queue ADD COLUMN ownerUid TEXT")
        }

        // v34: Board Edit redesign slice 1 (docs/BOARD_EDIT_REDESIGN.md) —
        // per-square lock on the placement record. A locked placement never
        // changes position: Shuffle and every move skip it and it is not a
        // drop target; it stays completable. `NOT NULL DEFAULT 0` backfills
        // every existing row as unlocked, and `BoardTask.init(from:)` decodes
        // an absent key as `false` (mirrors the v27 `isDeleted` posture) so a
        // pre-feature peer payload or a fixture without the field still
        // decodes. Synced as part of the `boardTasks` collection under the
        // existing per-row LWW — no rules change (`firestore.rules` validates
        // no per-field shape for boardTasks).
        migrator.registerMigration("v34") { db in
            try db.execute(sql: "ALTER TABLE board_tasks ADD COLUMN isLocked INTEGER NOT NULL DEFAULT 0")
        }

        // v35: Board Edit redesign slice 4 (docs/BOARD_EDIT_REDESIGN.md, D1) —
        // `boards.reopenedAt`, stamped on every Reopen and never cleared. A
        // non-NULL value means "manually reopened → never auto-closes". Nullable,
        // no backfill (no board has ever been reopened). `Board.init(from:)`
        // decodes an absent key as nil. Rides the `boards` collection under the
        // existing per-row LWW — no rules change (`firestore.rules` validates no
        // per-field board shape) and no sync-contract change.
        migrator.registerMigration("v35") { db in
            try db.execute(sql: "ALTER TABLE boards ADD COLUMN reopenedAt TEXT")
        }

        // v36: per-timeframe core-board size + centre (docs/POOLS_RECURRING.md
        // §Per-timeframe size + centre, owner-decided 2026-09-29). Two nullable
        // override columns on `core_board_defaults`; NULL = inherit the global
        // `UserPreferences.defaultBoardSize` / `defaultCenterType`. No backfill
        // (no row is migrated — every existing timeframe keeps inheriting).
        // `CoreBoardDefault.init(from:)` decodes an absent key as nil and
        // `encode(to:)` omits nil, so the clear rides the clearable-fields
        // mechanism (`CLEARABLE_FIELDS_BY_COLLECTION.coreBoardDefaults`) on
        // push and is NULLed on pull. Same `coreBoardDefaults` per-row LWW —
        // no rules change, no sync-contract collection change.
        migrator.registerMigration("v36") { db in
            try db.execute(sql: "ALTER TABLE core_board_defaults ADD COLUMN defaultBoardSize INTEGER")
            try db.execute(sql: "ALTER TABLE core_board_defaults ADD COLUMN defaultCenterType TEXT")
        }

        // v37: windowed linked counters (owner rule 2026-10-01 — a counting
        // square accounts only for logs inside its board's window). Heals every
        // pre-rule hub-linked counter placed on a board into per-board
        // window-stamped rows (stamp in place for the earliest board, a
        // deterministic copy for each further one) — AUTHORED writes, so peers
        // converge. Data-only, no schema change; the same sweep re-runs after
        // each clean pull (`SyncService`) to catch rows other devices wrote.
        migrator.registerMigration("v37") { db in
            let userIds = try String.fetchAll(db, sql: "SELECT id FROM users")
            // Best-effort: a heal failure must NEVER brick database open — the
            // post-pull sweep retries it (idempotent), so log and move on.
            for userId in userIds {
                do {
                    // Savepoint: a mid-heal failure rolls back that user's partial writes.
                    try db.inSavepoint {
                        try AppDatabase.healLinkedCounterWindowsTx(
                            db: db, userId: userId, now: AppDatabase.currentTimestamp()
                        )
                        return .commit
                    }
                } catch {
                    #if DEBUG
                    dlog("[Migration v37] linked-counter heal skipped for a user: \(error.localizedDescription)")
                    #endif
                }
            }
        }

        // v38: Pool-level default dice (docs/BOARD_SOURCES.md §Member rules →
        // Pool-level defaults, 2026-10-06) — `Pool.memberVary`, a JSON-string
        // TEXT column exactly like v31's `manualTaskVary`. Nullable: a
        // pre-v38 row stays NULL and `Pool.init(from:)` decodes that to
        // `[:]`; every write after this encodes the map (`{}` when empty).
        // Web: no Dexie bump (no index), `PoolSchema` defaults the key.
        migrator.registerMigration("v38") { db in
            try db.execute(sql: "ALTER TABLE pools ADD COLUMN memberVary TEXT")
        }

        // v39: Counter kinds (docs/COUNTER_KINDS.md §3). Nullable TEXT: every
        // pre-v39 row stays NULL and `Task.init(from:)` decodes it to nil
        // (resolved as `.discrete`). Count columns stay INTEGER — SQLite's
        // INTEGER affinity stores a non-integral REAL losslessly, so no rebuild.
        // Web: no Dexie bump (unindexed).
        migrator.registerMigration("v39") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN countKind TEXT")
        }

        // v40: per-collection pull checkpoints (2026-10-07, the launch-watchdog
        // fix — `AppDatabase+PullApply.swift`). LOCAL-ONLY: never synced, not
        // a sync collection. One row per (user, collection) holding the highest
        // server `_syncedAt` applied, written in the same transaction as the
        // batch it covers, so a pull killed part-way resumes where it stopped.
        // Exact seconds + nanoseconds (a Firestore `Timestamp`). A missing row
        // falls back to `users.lastSyncedAt`. Cleared by `wipeLocalDatabase`.
        // Web twin: the Dexie `syncWatermarks` store (v19).
        //
        // Same migration: `boards.centerTaskId` loses its `REFERENCES tasks(id)`
        // (see `dropBoardsCenterTaskForeignKey`).
        migrator.registerMigration("v40") { db in
            try db.execute(sql: """
                CREATE TABLE sync_watermarks (
                    userId TEXT NOT NULL,
                    collection TEXT NOT NULL,
                    seconds INTEGER NOT NULL,
                    nanoseconds INTEGER NOT NULL,
                    PRIMARY KEY (userId, collection)
                )
                """)
            try AppDatabase.dropBoardsCenterTaskForeignKey(db)
        }

        // v41: board-scoped task edits (docs/BOARD_SCOPED_TASK_EDITS.md §3) —
        // `tasks.forkedFromTaskId`, the original's id on a per-board fork.
        // Nullable TEXT: every pre-v41 row stays NULL and `Task.init(from:)`
        // decodes it to nil (not a fork). No index (nothing queries by it in
        // PR 1). Web: no Dexie bump (unindexed — the v38/v39 precedent).
        migrator.registerMigration("v41") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN forkedFromTaskId TEXT")
        }

        // v42: shared counter settings (docs/SHARED_COUNTER_SETTINGS.md §1) —
        // a counter root's `counterName`, `titleTemplateSingular`,
        // `titleTemplatePlural` and `timeframeGoals` (a JSON string). Nullable
        // TEXT: every pre-v42 row stays NULL = the default (D3 — no backfill).
        // No index. Web: no Dexie bump (unindexed — the v39/v41 precedent).
        migrator.registerMigration("v42") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN counterName TEXT")
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN titleTemplateSingular TEXT")
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN titleTemplatePlural TEXT")
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN timeframeGoals TEXT")
        }
    }
}

extension AppDatabase {
    /// v40: rebuild `boards` WITHOUT the `centerTaskId REFERENCES tasks(id)`
    /// foreign key (the same deliberate no-FK choice as `task_events`). The
    /// pull applies `boards` before `tasks` (`pullApplyOrder`), so a board
    /// whose chosen centre task isn't local yet (a wizard draft, a legacy
    /// chosen-centre board) made the upsert throw, rolling back its whole
    /// batch and marking the pull failed — no heals, no `lastSyncedAt` stamp.
    /// Dev's old boards-first pull had the same trap. `centerTaskId` stays an
    /// id its readers look up (wizard resume, capacity), and a missing task is
    /// already tolerated there.
    ///
    /// Generic rebuild driven by `sqlite_master` (so every column added by a
    /// later ALTER is kept verbatim): create a twin from the stored CREATE with
    /// only the FK clause removed, copy every row, drop, rename, recreate every
    /// index + trigger. Runs under the migrator's `.deferred` FK mode, so
    /// dropping `boards` doesn't cascade into `board_tasks` (v18 recipe).
    ///
    /// Best-effort on shape: if the stored CREATE doesn't carry the clause in
    /// the expected form, it logs and leaves the table alone (a migration throw
    /// would brick database open) — the pull then behaves as before.
    ///
    /// - Throws: a `DatabaseError` if foreign keys are ON (not inside the
    ///   migrator) or the row / index counts differ after the copy.
    static func dropBoardsCenterTaskForeignKey(_ db: Database) throws {
        // Outside the migrator (FKs on), `DROP TABLE boards` would
        // cascade-delete every `board_tasks` row — refuse.
        guard try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 0 else {
            throw DatabaseError(message: "v40 boards rebuild must run with foreign keys OFF (inside the migrator)")
        }
        let hasFK = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(boards)")
            .contains { ($0["from"] as String?) == "centerTaskId" }
        guard hasFK else { return }
        guard let create = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'boards'"),
              let open = create.firstIndex(of: "("),
              let fkPattern = try? NSRegularExpression(
                pattern: #"centerTaskId\s+TEXT\s+REFERENCES\s+"?tasks"?\s*\(\s*"?id"?\s*\)"#, options: [.caseInsensitive]
              ) else { return }
        let body = String(create[open...])
        let range = NSRange(body.startIndex..., in: body)
        guard fkPattern.numberOfMatches(in: body, range: range) == 1 else {
            dlog("[Migration v40] boards centerTaskId FK not in the expected shape — left in place")
            return
        }
        let twin = "CREATE TABLE boards_v40 " + fkPattern.stringByReplacingMatches(in: body, range: range, withTemplate: "centerTaskId TEXT")
        let extras = try String.fetchAll(db, sql: """
            SELECT sql FROM sqlite_master
            WHERE tbl_name = 'boards' AND type IN ('index', 'trigger') AND sql IS NOT NULL
            """)
        let before = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM boards") ?? 0

        try db.execute(sql: twin)
        try db.execute(sql: "INSERT INTO boards_v40 SELECT * FROM boards")
        let copied = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM boards_v40") ?? -1
        guard copied == before else {
            throw DatabaseError(message: "v40 boards rebuild row-count mismatch: \(before) boards but \(copied) copied")
        }
        try db.execute(sql: "DROP TABLE boards")
        try db.execute(sql: "ALTER TABLE boards_v40 RENAME TO boards")
        for sql in extras { try db.execute(sql: sql) }
        let recreated = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM sqlite_master WHERE tbl_name = 'boards' AND type IN ('index', 'trigger') AND sql IS NOT NULL
            """) ?? -1
        guard recreated == extras.count else {
            throw DatabaseError(message: "v40 boards rebuild recreated \(recreated) of \(extras.count) indexes/triggers")
        }
    }
}
