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

        // v37: windowed linked-counter heal — retired (TASK_WINDOW_REWORK slice 3a);
        // the slice-4 sweep repoints stamped rows. Registered as a no-op to keep the version.
        migrator.registerMigration("v37") { _ in }

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

        // v43: "counts toward" (docs/SHARED_COUNTER_SETTINGS.md §3a) — a
        // contributing task's `countsTowardCounterId` (the Discrete counter root
        // it increments on completion) and `countsTowardAmount` (nil = 1).
        // Nullable; every pre-v43 row stays NULL = counts toward nothing. No
        // index (the contributors read is a rare guard). Web: no Dexie bump.
        migrator.registerMigration("v43") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN countsTowardCounterId TEXT")
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN countsTowardAmount INTEGER")
            // D11 — the instant the flag was set; only occurrences at or after it credit.
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN countsTowardSince TEXT")
        }

        // v44: heal re-run — retired (TASK_WINDOW_REWORK slice 3a); the slice-4
        // sweep repoints stamped rows. Registered as a no-op to keep the version.
        migrator.registerMigration("v44") { _ in }

        // v45: Task/window rework slice 1 (docs/TASK_WINDOW_REWORK.md) — the
        // per-placement parameters on `board_tasks`: `targetOverride` (REAL),
        // `targetKind` (TEXT), `childTargets` (TEXT, sorted-keys JSON array of
        // {childId, target}) and `titleOverride` (TEXT). All nullable, no
        // backfill (absent = the task's own goal / title), no index. INERT
        // until slice 2 reads and slice 3 writes them; synced under the
        // existing `boardTasks` per-row LWW with the four as clearable fields.
        // No rules change. Web: no Dexie bump (unindexed — the v39/v41
        // precedent).
        migrator.registerMigration("v45") { db in
            try db.execute(sql: "ALTER TABLE board_tasks ADD COLUMN targetOverride REAL")
            try db.execute(sql: "ALTER TABLE board_tasks ADD COLUMN targetKind TEXT")
            try db.execute(sql: "ALTER TABLE board_tasks ADD COLUMN childTargets TEXT")
            try db.execute(sql: "ALTER TABLE board_tasks ADD COLUMN titleOverride TEXT")
        }

        // v46: Task/window rework slice 3b — `manualTaskTargets` on templates: a
        // hand-added task's frozen target / kind / title, copied by Repeat from
        // the placement and applied by spawn. Nullable TEXT (sorted-keys-free
        // JSON object, like v31's `manualTaskVary`); no backfill, no index.
        // Synced under the existing per-row LWW as a clearable field. Web: no
        // Dexie bump (unindexed).
        migrator.registerMigration("v46") { db in
            try db.execute(sql: "ALTER TABLE recurring_board_templates ADD COLUMN manualTaskTargets TEXT")
        }

        // v47: Task/window rework slice 4a — the placement sweep's first trigger
        // (docs/TASK_WINDOW_REWORK.md §Migration sweep). No schema change: runs
        // the gated, state-based sweep for every local user (repoint derived
        // counters' placements at their roots, strip refused boards' window
        // marks, re-key stored rules). A failure is logged and never bricks
        // database open — the post-pull and per-launch triggers retry.
        migrator.registerMigration("v47") { db in
            let now = AppDatabase.currentTimestamp()
            for userId in try String.fetchAll(db, sql: "SELECT id FROM users ORDER BY id") {
                do {
                    try db.inSavepoint {
                        try AppDatabase.runPlacementSweepTx(db: db, userId: userId, now: now)
                        return .commit
                    }
                } catch {
                    dlog("[PlacementSweep] v47 sweep skipped for \(userId): \(error.localizedDescription)")
                }
            }
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
