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
    }
}
