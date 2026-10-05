import Foundation
import GRDB

extension AppDatabase {
    // MARK: - Pools (Task Pools + Recurring Boards Rework, P1)
    //
    // CRUD modeled on the retired per-timeframe DefaultPool API (its
    // test-only helpers now live in
    // `OYBCTests/AppDatabase+DefaultPoolsTestSupport.swift`); the only
    // structural difference is that a Pool is user-named (many per user, no
    // `(userId, timeframe)` uniqueness) rather than one-per-timeframe.

    /// Fetch all non-deleted pools for a user. Used by the Tasks-tab Pools
    /// segment, the wizard's Sources sheet (`BoardWizardView`) and Board
    /// settings.
    func fetchPools(userId: String) throws -> [Pool] {
        return try read { db in
            try Pool
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .fetchAll(db)
        }
    }

    /// Fetch a single pool by id (regardless of `isDeleted`).
    func fetchPool(id: String) throws -> Pool? {
        return try read { db in
            try Pool.fetchOne(db, key: id)
        }
    }

    /// Fetch multiple pools by id in one query, regardless of `isDeleted`
    /// (callers that need to distinguish should check the returned rows).
    /// Used by the wizard's hydration paths (`hydrateSourcesState`, draft
    /// count, core-default prefill) and `RecurringBoardTemplatesViewModel`
    /// when they already have pool ids and need a `poolsById` lookup.
    func fetchPools(ids: [String]) throws -> [Pool] {
        guard !ids.isEmpty else { return [] }
        return try read { db in
            try Pool
                .filter(ids.contains(Column("id")))
                .fetchAll(db)
        }
    }

    /// Insert / update a pool. Caller is responsible for bumping
    /// `version` + `updatedAt`.
    func savePool(_ pool: Pool) throws {
        try write { db in
            try pool.save(db)
        }
    }

    /// Create a new pool + enqueue its sync op atomically (mirrors
    /// `saveTaskAndEnqueueUpdate`: the model write and its sync-queue item
    /// live in ONE transaction so a crash between them can't leave the
    /// local row ahead of Firestore with no recovery).
    @discardableResult
    func createPoolAndEnqueue(userId: String, name: String, taskIds: [String], now: String) throws -> Pool {
        try write { db in
            try Self.insertPool(db: db, userId: userId, name: name, taskIds: taskIds, now: now)
        }
    }

    /// Update an existing pool's `name` and/or `taskIds` + enqueue its
    /// sync op atomically. Bumps `version` + `updatedAt`. Returns nil (no
    /// write) when the id doesn't exist.
    @discardableResult
    func updatePoolAndEnqueue(
        id: String,
        name: String? = nil,
        taskIds: [String]? = nil,
        now: String
    ) throws -> Pool? {
        try write { db in
            try Self.updatePool(db: db, id: id, name: name, taskIds: taskIds, now: now)
        }
    }

    /// Pool editor Save: applies the editor's staged inline task edits
    /// (`stagedEdits`) AND writes pool membership (`createPool…` /
    /// `updatePool…` semantics, incl. the sync enqueue) in ONE transaction.
    /// A throwing edit (strict mode — see `applyStagedTaskEdits`) rolls the
    /// membership write back with it, so the pool never saves half of what
    /// the user staged.
    ///
    /// - Parameters:
    ///   - existingId: The pool being edited; `nil` creates a new pool.
    ///   - userId: Owner uid (create mode).
    ///   - name: Trimmed pool name.
    ///   - taskIds: The pool's full ordered `taskIds` (unresolvable ids kept).
    ///   - stagedEdits: Inline edits keyed by task id.
    ///   - now: ISO8601 timestamp.
    /// - Returns: The persisted pool (nil only when `existingId` vanished).
    /// - Throws: `StagedTaskEditError` or a GRDB error; nothing is written.
    @discardableResult
    func savePoolWithStagedEdits(
        existingId: String?,
        userId: String,
        name: String,
        taskIds: [String],
        stagedEdits: [String: TaskEditPatch],
        now: String
    ) throws -> Pool? {
        try write { db in
            try Self.applyStagedTaskEdits(db: db, stagedEdits: stagedEdits, strict: true, now: now)
            if let existingId {
                return try Self.updatePool(db: db, id: existingId, name: name, taskIds: taskIds, now: now)
            }
            return try Self.insertPool(db: db, userId: userId, name: name, taskIds: taskIds, now: now)
        }
    }

    /// In-transaction pool insert + create-enqueue (shared by
    /// `createPoolAndEnqueue` and `savePoolWithStagedEdits`).
    static func insertPool(db: Database, userId: String, name: String, taskIds: [String], now: String) throws -> Pool {
        let pool = Pool(
            id: Self.generateUUID(),
            userId: userId,
            name: name,
            taskIds: taskIds,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil
        )
        try pool.insert(db)
        try SyncQueueBuilder.makeItem(
            entityType: "pools",
            entityId: pool.id,
            operationType: .create,
            payload: pool,
            now: now
        ).enqueue(db)
        return pool
    }

    /// In-transaction pool update + update-enqueue (shared by
    /// `updatePoolAndEnqueue` and `savePoolWithStagedEdits`).
    static func updatePool(db: Database, id: String, name: String?, taskIds: [String]?, now: String) throws -> Pool? {
        guard var pool = try Pool.fetchOne(db, key: id) else { return nil }
        if let name = name { pool.name = name }
        if let taskIds = taskIds { pool.taskIds = taskIds }
        pool.updatedAt = now
        pool.version += 1
        try pool.update(db)
        try SyncQueueBuilder.makeItem(
            entityType: "pools",
            entityId: pool.id,
            operationType: .update,
            payload: pool,
            now: now
        ).enqueue(db)
        return pool
    }

    /// Soft-delete a pool and enqueue the delete op atomically. Never
    /// cascades to the tasks it references, and never cascades to
    /// consumers (spawn records / core defaults) that pulled it in —
    /// detachment is derived at read time (source-supply resolution and
    /// core-defaults resolution skip `isDeleted` pools), matching `Pool`'s
    /// docstring.
    func softDeletePoolAndEnqueue(id: String, now: String) throws {
        try write { db in
            guard var pool = try Pool.fetchOne(db, key: id) else { return }
            pool.isDeleted = true
            pool.deletedAt = now
            pool.updatedAt = now
            pool.version += 1
            try pool.update(db)
            try SyncQueueBuilder.makeItem(
                entityType: "pools",
                entityId: pool.id,
                operationType: .delete,
                payload: pool,
                now: now
            ).enqueue(db)
        }
    }

    // MARK: - CoreBoardDefaults (Task Pools + Recurring Boards Rework, P1)
    //
    // Replaces `DefaultPool`. One row per `(userId, timeframe)`. CRUD
    // modeled on the retired DefaultPool upsert pattern (see
    // `OYBCTests/AppDatabase+DefaultPoolsTestSupport.swift`).

    /// Fetch all non-deleted CoreBoardDefault rows for a user. Used by the
    /// P7 Board-settings page's per-timeframe summary.
    func fetchCoreBoardDefaults(userId: String) throws -> [CoreBoardDefault] {
        return try read { db in
            try CoreBoardDefault
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .fetchAll(db)
        }
    }

    /// Fetch the (at-most-one) non-deleted CoreBoardDefault for
    /// `(userId, timeframe)`. Returns nil when the user hasn't set one up.
    /// Used by the core-board setup prefill path (P5).
    func fetchCoreBoardDefault(userId: String, timeframe: Timeframe) throws -> CoreBoardDefault? {
        return try read { db in
            try CoreBoardDefault
                .filter(
                    Column("userId") == userId
                        && Column("timeframe") == timeframe.rawValue
                        && Column("isDeleted") == false
                )
                .fetchOne(db)
        }
    }

    /// Atomic upsert by `(userId, timeframe)` + sync-enqueue. Preferred
    /// entry point — guarantees per-timeframe uniqueness AND that the
    /// change is queued for sync. NOT used by the P1 migration
    /// (`MigrationV25Helpers.migrateDefaultPools`) — that migration
    /// constructs + inserts `CoreBoardDefault` rows directly inside its own
    /// upgrade transaction (it needs a deterministic, uuidv5-derived id,
    /// not a fresh upsert), and enqueues sync via its own
    /// `enqueueMigrationSync` raw-SQL helper.
    ///
    /// **Per-timeframe size + centre** (docs/POOLS_RECURRING.md, 2026-09-29):
    /// `defaultBoardSize` / `defaultCenterType` are tri-state patches
    /// (`CoreBoardDefaultFieldPatch`) defaulting to `.keep`, so every
    /// pre-feature caller preserves whatever override is stored; the
    /// defaults sheet passes `.set(x)` to override or `.set(nil)` to clear
    /// back to inherit. A clear is stored NULL and pushed as a field delete.
    ///
    /// - Parameters:
    ///   - userId: Owner uid.
    ///   - timeframe: The core timeframe (never `.custom`).
    ///   - corePoolIds: Replaces the stored pool list.
    ///   - coreDefaultTaskIds: Replaces the stored individual-defaults list.
    ///   - defaultBoardSize: `.keep` / `.set(nil)` (clear) / `.set(size)`.
    ///   - defaultCenterType: `.keep` / `.set(nil)` (clear) / `.set(centre)`.
    ///   - now: ISO8601 stamp for `updatedAt` (and `createdAt` on insert).
    /// - Returns: The persisted row.
    @discardableResult
    func upsertCoreBoardDefaultAndEnqueue(
        userId: String,
        timeframe: Timeframe,
        corePoolIds: [String],
        coreDefaultTaskIds: [String],
        defaultBoardSize: CoreBoardDefaultFieldPatch<DefaultBoardSize> = .keep,
        defaultCenterType: CoreBoardDefaultFieldPatch<DefaultCenterSquareType> = .keep,
        now: String
    ) throws -> CoreBoardDefault {
        return try write { db in
            try Self.upsertCoreBoardDefault(
                db: db,
                userId: userId,
                timeframe: timeframe,
                corePoolIds: corePoolIds,
                coreDefaultTaskIds: coreDefaultTaskIds,
                defaultBoardSize: defaultBoardSize,
                defaultCenterType: defaultCenterType,
                now: now
            )
        }
    }

    /// Task Pools + Recurring Boards Rework (P5) — writes `corePoolIds`
    /// ONLY, preserving whatever `coreDefaultTaskIds` already exists.
    ///
    /// `upsertCoreBoardDefaultAndEnqueue` unconditionally overwrites BOTH
    /// fields on every call — there's no partial-update variant. But
    /// `coreDefaultTaskIds` is P7-authored-only (individual default tasks,
    /// set from the Board-settings defaults sheet); the core-setup
    /// checkbox (P5, docs/POOLS_RECURRING.md §Surfaces item 6) only ever
    /// persists `corePoolIds`. Calling the raw upsert directly from the
    /// checkbox path would silently zero out `coreDefaultTaskIds` the
    /// moment it exists — this wrapper reads the current row's
    /// `coreDefaultTaskIds` and passes it straight through unchanged.
    ///
    /// **Atomicity (P7 hardening)**: the fetch-existing-then-write used to
    /// be two separate GRDB transactions (a `read` here, then a nested
    /// `write` inside `upsertCoreBoardDefaultAndEnqueue`) — a concurrent
    /// sync pull landing between them could revert `coreDefaultTaskIds` to
    /// a value that was already stale by the time this write committed.
    /// The fetch now happens INSIDE the same `write` block as the upsert
    /// (via the shared `Self.upsertCoreBoardDefault` helper), so the whole
    /// read-merge-write is one transaction.
    @discardableResult
    func upsertCorePoolIdsAndEnqueue(
        userId: String,
        timeframe: Timeframe,
        corePoolIds: [String],
        now: String
    ) throws -> CoreBoardDefault {
        return try write { db in
            let existingTaskIds = try CoreBoardDefault
                .filter(
                    Column("userId") == userId
                        && Column("timeframe") == timeframe.rawValue
                        && Column("isDeleted") == false
                )
                .fetchOne(db)?.coreDefaultTaskIds ?? []
            // `.keep` on both overrides — the checkbox never touches size/centre.
            return try Self.upsertCoreBoardDefault(
                db: db,
                userId: userId,
                timeframe: timeframe,
                corePoolIds: corePoolIds,
                coreDefaultTaskIds: existingTaskIds,
                defaultBoardSize: .keep,
                defaultCenterType: .keep,
                now: now
            )
        }
    }

    /// Shared read-merge-write body for both `CoreBoardDefault` upsert
    /// entry points above — MUST be called from inside an existing `write`
    /// block (never opens its own transaction) so a caller that needs to
    /// read something else first (e.g. `upsertCorePoolIdsAndEnqueue`'s
    /// existing `coreDefaultTaskIds`) can do so in the SAME transaction as
    /// the write, closing the two-transaction race described above.
    private static func upsertCoreBoardDefault(
        db: Database,
        userId: String,
        timeframe: Timeframe,
        corePoolIds: [String],
        coreDefaultTaskIds: [String],
        defaultBoardSize: CoreBoardDefaultFieldPatch<DefaultBoardSize>,
        defaultCenterType: CoreBoardDefaultFieldPatch<DefaultCenterSquareType>,
        now: String
    ) throws -> CoreBoardDefault {
        let coreDefault: CoreBoardDefault
        let op: SyncOperationType
        if var existing = try CoreBoardDefault
            .filter(
                Column("userId") == userId
                    && Column("timeframe") == timeframe.rawValue
                    && Column("isDeleted") == false
            )
            .fetchOne(db)
        {
            existing.corePoolIds = corePoolIds
            existing.coreDefaultTaskIds = coreDefaultTaskIds
            defaultBoardSize.apply(to: &existing.defaultBoardSize)
            defaultCenterType.apply(to: &existing.defaultCenterType)
            existing.updatedAt = now
            existing.version += 1
            try existing.update(db)
            coreDefault = existing
            op = .update
        } else {
            var freshSize: DefaultBoardSize? = nil
            var freshCentre: DefaultCenterSquareType? = nil
            defaultBoardSize.apply(to: &freshSize)
            defaultCenterType.apply(to: &freshCentre)
            let fresh = CoreBoardDefault(
                id: Self.generateUUID(),
                userId: userId,
                timeframe: timeframe,
                corePoolIds: corePoolIds,
                coreDefaultTaskIds: coreDefaultTaskIds,
                defaultBoardSize: freshSize,
                defaultCenterType: freshCentre,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil,
                version: 1,
                isDeleted: false,
                deletedAt: nil
            )
            try fresh.insert(db)
            coreDefault = fresh
            op = .create
        }
        try SyncQueueBuilder.makeItem(
            entityType: "coreBoardDefaults",
            entityId: coreDefault.id,
            operationType: op,
            payload: coreDefault,
            now: now
        ).enqueue(db)
        return coreDefault
    }

    /// Soft-delete a CoreBoardDefault row and enqueue the delete op
    /// atomically.
    func softDeleteCoreBoardDefaultAndEnqueue(id: String, now: String) throws {
        try write { db in
            guard var coreDefault = try CoreBoardDefault.fetchOne(db, key: id) else { return }
            coreDefault.isDeleted = true
            coreDefault.deletedAt = now
            coreDefault.updatedAt = now
            coreDefault.version += 1
            try coreDefault.update(db)
            try SyncQueueBuilder.makeItem(
                entityType: "coreBoardDefaults",
                entityId: coreDefault.id,
                operationType: .delete,
                payload: coreDefault,
                now: now
            ).enqueue(db)
        }
    }
}
