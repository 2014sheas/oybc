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
            for userId in userIds {
                try AppDatabase.healLinkedCounterWindowsTx(
                    db: db, userId: userId, now: AppDatabase.currentTimestamp()
                )
            }
        }
    }
}
