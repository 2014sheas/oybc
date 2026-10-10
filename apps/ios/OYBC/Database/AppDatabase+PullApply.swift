import Foundation
import FirebaseFirestore
@preconcurrency import GRDB

// MARK: - Pull-apply engine (2026-10-07, the launch-watchdog fix)
//
// Every remote doc the pull or a listener delivers is applied here, in
// BATCHES: one write transaction per batch (≤ `pullChunkSize` docs of one
// collection) that LWW-applies every doc, then runs the collection's board
// cascade ONCE over the union of what changed, then (full pull only) writes
// that collection's checkpoint — all on one threaded `db: Database` (the
// atomic pull-path rule). `applyPullBatch` runs it on GRDB's writer queue
// with `async` access, so the main actor is suspended, never blocked.
//
// Before this, `SyncService` (`@MainActor`) applied one synchronous write +
// a full cascade (five whole-table loads + a derivation pass) PER DOC on the
// main thread — ~13.7 s for a fresh pull of the owner's data on a Mac
// simulator, past the iOS launch watchdog on the phone. Behaviour per doc is
// unchanged: validation, the compound-parent scope check, the echo guard,
// LWW, the local-win re-assert (owned by the PULL's uid) and the clearable-
// field NULLs all moved here verbatim from `SyncService.swift`.

/// Pull/listener collection: Firestore subcollection + its GRDB table.
typealias PullCollection = (firestoreName: String, grdbTable: String)

/// What one batch did — returned to the main actor, which only publishes it.
struct PullBatchOutcome: Sendable {
    var pulled = 0
    var conflicts = 0
    var details: [String] = []
    /// Highest server `_syncedAt` among the batch's docs (applied, echoed or
    /// skipped alike — every one was processed).
    var maxSyncedAt: PullWatermark?
}

/// Errors raised by the pull/push local-apply helpers.
enum SyncError: LocalizedError {
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case .invalidPayload(let msg): return msg
        }
    }
}

/// Whitelist of allowed GRDB table names — prevents SQL injection.
let allowedGRDBTables: Set<String> = Set(syncableCollections.map(\.grdbTable))

/// Safely extracts an integer from Any — handles Int, Int64, NSNumber.
func toInt(_ value: Any?) -> Int {
    if let i = value as? Int { return i }
    if let i64 = value as? Int64 { return Int(i64) }
    if let n = value as? NSNumber { return n.intValue }
    return 0
}

/// Validates the baseline sync-safety invariants every pulled document must
/// satisfy before reaching GRDB: a UUID `id`, `version >= 1`, `userId`
/// equality on user-scoped collections, and the board-task row/col bounds.
/// Not a mirror of the web Zod schemas.
///
/// - Returns: A reason string when the doc must be skipped, or nil to proceed.
///   Reason strings never interpolate a uid.
func validateRemotePullDocument(collection: String, data: [String: Any], authenticatedUserId: String) -> String? {
    guard let id = data["id"] as? String, !id.isEmpty else { return "missing or empty id" }
    guard UUID(uuidString: id) != nil else { return "invalid id format for \(collection)/\(id)" }
    guard toInt(data["version"]) >= 1 else { return "invalid version for \(collection)/\(id)" }
    if userScopedCollections.contains(collection), (data["userId"] as? String ?? "") != authenticatedUserId {
        return "userId mismatch for \(collection)/\(id)"
    }
    // Board-integrity PR-2 (Part 3): mirror `BoardTaskSchema`'s 0..24 bound.
    if collection == "boardTasks", !(0...24).contains(toInt(data["row"])) || !(0...24).contains(toInt(data["col"])) {
        return "row/col out of bounds for \(collection)/\(id)"
    }
    return nil
}

extension AppDatabase {

    /// Docs per batch transaction. `DatabaseQueue` makes every reader wait for
    /// the in-flight write, so a batch must stay short: a main-thread read
    /// waits at most one chunk.
    static let pullChunkSize = 250

    #if DEBUG
    /// Test hook — runs at the start of every `applyPullBatch` transaction.
    static var onPullBatchTransaction: ((Database) -> Void)?
    #endif

    // MARK: - Async access

    /// Async write on GRDB's writer queue: the caller suspends, never blocks.
    func writeAsync<T>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await dbQueue.write(block)
    }

    /// Async read: the caller suspends, never blocks.
    func readAsync<T>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await dbQueue.read(block)
    }

    // MARK: - Batch apply

    /// Sorts docs by `_syncedAt` (docs without one first) and splits them into
    /// `pullChunkSize` batches, so each batch's max `_syncedAt` is
    /// a safe resume point: every older doc is in an earlier batch.
    static func pullChunks(_ fetched: PullDocs) -> [PullDocs] {
        let keyed = fetched.docs.map { (mark: PullWatermark(syncedAtValue: $0["_syncedAt"]), doc: $0) }
        let sorted = keyed.sorted { a, b in
            switch (a.mark, b.mark) {
            case (nil, .some): return true
            case let (.some(x), .some(y)): return x < y
            default: return false
            }
        }.map(\.doc)
        return stride(from: 0, to: sorted.count, by: pullChunkSize).map {
            PullDocs(docs: Array(sorted[$0..<min($0 + pullChunkSize, sorted.count)]))
        }
    }

    /// Applies one batch of one collection's remote docs in ONE write
    /// transaction off the calling actor, with one cascade, and (when
    /// `checkpoint`) advances that collection's watermark in the same
    /// transaction — so a checkpoint can never get ahead of applied rows.
    ///
    /// - Parameters:
    ///   - collection: The collection the docs belong to.
    ///   - docs: The raw remote docs (untrusted).
    ///   - userId: The uid this pull runs for (scope checks + owns enqueues).
    ///   - checkpoint: True for the full pull (docs are a `_syncedAt`-ordered
    ///     prefix); false for listener snapshots (a change set, not a prefix).
    /// - Returns: The batch outcome for the main actor to publish.
    /// - Throws: A GRDB error — the whole batch, checkpoint included, rolls back.
    func applyPullBatch(collection: PullCollection, docs: PullDocs, userId: String, checkpoint: Bool) async throws -> PullBatchOutcome {
        try await writeAsync { db in
            #if DEBUG
            Self.onPullBatchTransaction?(db)
            #endif
            let outcome = try Self.applyPullBatchTx(db: db, collection: collection, docs: docs.docs, userId: userId)
            if checkpoint, let mark = outcome.maxSyncedAt {
                try Self.advanceSyncWatermark(db: db, userId: userId, collection: collection.firestoreName, to: mark)
            }
            return outcome
        }
    }

    /// The batch body, inside the caller's transaction: LWW-apply every doc,
    /// collecting what changed, then ONE cascade over the union.
    ///
    /// - Throws: A GRDB / decode error from an upsert or the cascade.
    static func applyPullBatchTx(db: Database, collection: PullCollection, docs: [[String: Any]], userId: String) throws -> PullBatchOutcome {
        var outcome = PullBatchOutcome()
        outcome.maxSyncedAt = nextPullWatermark(nil, docs.map { PullWatermark(syncedAtValue: $0["_syncedAt"]) })
        let name = collection.firestoreName
        if name == "taskEvents" {
            let events = try applyTaskEventsBatchTx(db: db, userId: userId, rawDocs: docs)
            outcome.pulled = events.pulled
            outcome.details = events.details
            return outcome
        }

        var changedTaskIds = Set<String>()
        var previousCountsTowardRoots: [String: String] = [:]
        var changedBoardIds = Set<String>()
        var pulledBoards: [PulledBoard] = []
        for remote in docs {
            // Validate before touching GRDB — a malformed doc is skipped (the
            // safety-net pull retries); only real DB errors abort the batch.
            if let reason = validateRemotePullDocument(collection: name, data: remote, authenticatedUserId: userId) {
                outcome.details.append("Skipped \(name): \(reason)")
                continue
            }
            guard let id = remote["id"] as? String else { continue }
            if name == "compoundChildren", let skip = try compoundParentSkipReason(db: db, remote: remote, userId: userId) {
                outcome.details.append("Skipped \(name)/\(id): \(skip)")
                continue
            }
            let local = try fetchPullLocalRecord(db: db, grdbTable: collection.grdbTable, id: id)
            // Echo guard (sync-churn fix): same version + updatedAt = the same
            // authored write (usually our own push coming back) — no upsert,
            // no cascade.
            if let local, !pullRowsGenuinelyDiffer(local: local, remote: remote) { continue }
            let remoteV = toInt(remote["version"])
            if let local, resolveConflict(local: local, remote: remote) == "local" {
                outcome.conflicts += 1
                outcome.details.append("Kept local \(name)/\(id) (local v\(toInt(local["version"])) >= remote v\(remoteV))")
                // Board-integrity PR-4 (Item 1): re-assert the fresher local
                // row so a push race can't strand it. Same transaction.
                try reassertPullLocalWin(db: db, entityType: name, entityId: id, localData: local, remoteData: remote, ownerUid: userId)
                continue
            }
            // Windowed Completion: counting conflicts resolve by union-of-
            // events, so a pulled Task just LWW-upserts like any other row.
            try upsertPulledRecord(db: db, grdbTable: collection.grdbTable, data: remote)
            outcome.pulled += 1
            let kind = local.map { "remote v\(remoteV) > local v\(toInt($0["version"]))" } ?? "new"
            outcome.details.append("Pulled \(name)/\(id) (\(kind))")
            switch name {
            case "tasks":
                changedTaskIds.insert(id)
                // "Counts toward" (D11): a pulled row that was flagged here but
                // is now unflagged or re-pointed hands its previous root to the
                // cascade, so the credits keyed on that root are reconciled.
                if let previousRoot = local?["countsTowardCounterId"] as? String,
                   previousRoot != (remote["countsTowardCounterId"] as? String) {
                    previousCountsTowardRoots[id] = previousRoot
                }
            case "compoundChildren": if let parent = remote["compoundTaskId"] as? String { changedTaskIds.insert(parent) }
            // Board-integrity PR-1: a pulled placement (live OR tombstone)
            // changes its board's geometry.
            case "boardTasks": if let boardId = remote["boardId"] as? String { changedBoardIds.insert(boardId) }
            case "boards": pulledBoards.append(PulledBoard(id: id, remote: remote, local: local))
            default: break
            }
        }

        // ONE cascade per batch, same transaction — a cascade error rolls
        // back every upsert above.
        if !changedTaskIds.isEmpty {
            // B2 FI1: a pulled window-stamped derived counter's baseline is a
            // non-authored cache refreshed per task before the derivation.
            for taskId in changedTaskIds { _ = try refreshPulledDerivedBaseline(db: db, taskId: taskId) }
            try runPullCascadeForTasks(db: db, changedTaskIds: changedTaskIds, ownerUid: userId, previousCountsTowardRoots: previousCountsTowardRoots)
            // A new / changed sub-task link changes a compound's result on
            // SEALED boards too (the live cascade skips them): re-derive their
            // snapshots from the link set (non-authored, the sanctioned path).
            if name == "compoundChildren" { try reDeriveSealedBoards(db: db, changedTaskIds: changedTaskIds) }
        }
        try runPullCascadeForBoards(db: db, boardIds: changedBoardIds, ownerUid: userId)
        try applyPulledBoardsSideEffects(db: db, pulled: pulledBoards)
        return outcome
    }

    /// CompoundChild has no `userId` column — it scopes through its parent
    /// compound. Returns why the link must be skipped, or nil to apply it.
    private static func compoundParentSkipReason(db: Database, remote: [String: Any], userId: String) throws -> String? {
        guard let parentId = remote["compoundTaskId"] as? String, !parentId.isEmpty else { return "missing compoundTaskId" }
        guard let row = try Row.fetchOne(db, sql: "SELECT userId FROM tasks WHERE id = ?", arguments: [parentId]) else {
            return "parent compound not yet present locally"
        }
        let parentUserId: String? = row["userId"]
        return parentUserId == userId ? nil : "parent userId mismatch"
    }

    // MARK: - taskEvents batch (Windowed Completion, docs §Sync)

    /// Apply ALL pulled event rows (LWW, union by id; tombstone = undo), then
    /// recompute each affected event-owning task's caches ONCE and run ONE
    /// derivation pass per affected board — inside the caller's transaction.
    /// An event whose Task isn't local yet is upserted (shape only) and skipped
    /// by the recompute: `pullApplyOrder` pulls events before task rows, so the
    /// SAME pull's tasks batch brings that row (with its author's caches) and
    /// its cascade + derived-baseline refresh read these events.
    ///
    /// - Returns: Pulled-row count + per-row skip details.
    static func applyTaskEventsBatchTx(db: Database, userId: String, rawDocs: [[String: Any]]) throws -> (pulled: Int, details: [String]) {
        var details: [String] = []
        var pulled = 0
        var affectedTaskIds = Set<String>()
        for raw in rawDocs {
            if let reason = validateRemotePullDocument(collection: "taskEvents", data: raw, authenticatedUserId: userId) {
                details.append("Skipped taskEvents/\((raw["id"] as? String) ?? "?"): \(reason)")
                continue
            }
            guard let id = raw["id"] as? String else { continue }
            let local = try fetchPullLocalRecord(db: db, grdbTable: "task_events", id: id)
            // Echo guard: an identical row must not re-run the recompute + cascade.
            if let local, !pullRowsGenuinelyDiffer(local: local, remote: raw) { continue }
            if let local, resolveConflict(local: local, remote: raw) != "remote" { continue }
            try upsertPulledRecord(db: db, grdbTable: "task_events", data: raw)
            if let taskId = raw["taskId"] as? String { affectedTaskIds.insert(taskId) }
            pulled += 1
        }
        // Recompute caches once per affected local task + refresh the window-
        // stamped derived counters keyed off it (non-authored writes).
        let cascadeTaskIds = try recomputeTaskCachesAndRefreshDerived(db: db, taskIds: affectedTaskIds)
        // ONE derivation pass per affected LIVE board; roots expand to their
        // window-stamped derived rows.
        if !cascadeTaskIds.isEmpty {
            try runPullCascadeForTasks(db: db, changedTaskIds: withWindowStampedDerived(db: db, taskIds: cascadeTaskIds), ownerUid: userId)
        }
        // Sealed boards re-derive from the event union (the only sanctioned
        // mutation of a sealed record) — `affectedTaskIds`, so a sealed board
        // placing a not-yet-local task still re-derives; then the watchers of
        // every board reached refresh. Both non-authored.
        if !affectedTaskIds.isEmpty {
            try reDeriveSealedBoards(db: db, changedTaskIds: affectedTaskIds)
            try refreshWatchersAfterPull(db: db, boardIds: boardIdsReachedByTasks(db: db, taskIds: affectedTaskIds))
        }
        return (pulled, details)
    }

    // MARK: - Heal-on-pull (docs/WINDOWED_COMPLETION.md §Heal-on-pull)

    /// Repairs the fresh-install backfill gap: for every event-owning task
    /// (NORMAL / plain COUNTING) that is lifetime-complete but has NO live
    /// event, mint the event via `buildBackfillTaskEvent` (deterministic id;
    /// idempotent), ENQUEUE a CREATE owned by `userId`, then run the same
    /// recompute + board cascade + sealed re-derive the event pull uses.
    /// Respects LWW against an existing row with that id (an undo tombstone is
    /// never resurrected). Twin of web `healMissingCompletionEvents`.
    ///
    /// - Returns: The number of events minted.
    static func healMissingCompletionEventsTx(db: Database, userId: String) throws -> Int {
        let tasks = try Task.fetchAll(db)
        var hasLiveEvent = Set<String>()
        for e in try TaskEvent.fetchAll(db) where !e.isDeleted { hasLiveEvent.insert(e.taskId) }
        let toMint = tasks.compactMap { task -> TaskEvent? in
            guard task.userId == userId, !task.isDeleted, isEventOwningTask(task),
                  !hasLiveEvent.contains(task.id), // events are authoritative
                  task.isCompleted || (task.currentCount ?? 0) > 0 else { return nil }
            return buildBackfillTaskEvent(task: task)
        }
        if toMint.isEmpty { return 0 }

        let now = currentTimestamp()
        var healedTaskIds = Set<String>()
        var minted = 0
        for ev in toMint {
            // Typed mirror of `resolveConflict`: the mint is "remote" — higher
            // version wins; equal version → strictly-newer-or-equal updatedAt;
            // unparseable → remote (canon #263).
            if let existing = try TaskEvent.fetchOne(db, key: ev.id) {
                let mintWins: Bool
                if ev.version != existing.version {
                    mintWins = ev.version > existing.version
                } else if let existingDate = DateFormatting.parseISO(existing.updatedAt),
                          let mintDate = DateFormatting.parseISO(ev.updatedAt) {
                    mintWins = mintDate >= existingDate
                } else {
                    mintWins = true
                }
                if !mintWins { continue }
            }
            try ev.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "taskEvents", entityId: ev.id, operationType: .create,
                payload: ev, now: now, ownerUid: userId // the heal's uid, not the live one
            ).enqueue(db)
            healedTaskIds.insert(ev.taskId)
            minted += 1
        }
        _ = try recomputeTaskCachesAndRefreshDerived(db: db, taskIds: healedTaskIds)
        if !healedTaskIds.isEmpty {
            try runPullCascadeForTasks(db: db, changedTaskIds: withWindowStampedDerived(db: db, taskIds: healedTaskIds), ownerUid: userId)
            try reDeriveSealedBoards(db: db, changedTaskIds: healedTaskIds)
        }
        return minted
    }

    // MARK: - users doc

    /// LWW-applies the parent `users/{userId}` doc inside the caller's
    /// transaction, preserving the local `lastSyncedAt` through a remote win.
    ///
    /// - Returns: `applied` (a remote value was written) + a detail line.
    static func applyPulledUserDocTx(db: Database, userId: String, remoteData: [String: Any]) throws -> (applied: Bool, detail: String) {
        guard let local = try fetchPullLocalRecord(db: db, grdbTable: "users", id: userId) else {
            try upsertPulledRecord(db: db, grdbTable: "users", data: remoteData)
            return (true, "Pulled users/\(userId) (new)")
        }
        let remoteV = toInt(remoteData["version"]), localV = toInt(local["version"])
        if resolveConflict(local: local, remote: remoteData) == "remote" {
            var merged = remoteData
            if let watermark = local["lastSyncedAt"] { merged["lastSyncedAt"] = watermark }
            try upsertPulledRecord(db: db, grdbTable: "users", data: merged)
            return (true, "Pulled users/\(userId) (remote v\(remoteV) > local v\(localV))")
        }
        try reassertPullLocalWin(db: db, entityType: "users", entityId: userId, localData: local, remoteData: remoteData, ownerUid: userId)
        return (false, "Kept local users/\(userId) (local v\(localV) >= remote v\(remoteV))")
    }

    // MARK: - Per-collection checkpoints (`sync_watermarks`, GRDB v40)

    /// Every stored checkpoint for `userId`, keyed by collection.
    static func fetchSyncWatermarks(db: Database, userId: String) throws -> [String: PullWatermark] {
        var out: [String: PullWatermark] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT collection, seconds, nanoseconds FROM sync_watermarks WHERE userId = ?", arguments: [userId]) {
            let collection: String = row["collection"]
            out[collection] = PullWatermark(seconds: row["seconds"], nanoseconds: row["nanoseconds"])
        }
        return out
    }

    /// Raises `collection`'s checkpoint to `mark` (never lowers it).
    static func advanceSyncWatermark(db: Database, userId: String, collection: String, to mark: PullWatermark) throws {
        let next = nextPullWatermark(try fetchSyncWatermarks(db: db, userId: userId)[collection], [mark]) ?? mark
        try db.execute(sql: """
            INSERT INTO sync_watermarks (userId, collection, seconds, nanoseconds) VALUES (?, ?, ?, ?)
            ON CONFLICT (userId, collection) DO UPDATE SET seconds = excluded.seconds, nanoseconds = excluded.nanoseconds
            """, arguments: [userId, collection, next.seconds, next.nanoseconds])
    }

    // MARK: - Local record helpers (moved from SyncService.swift)

    /// The local row as a `[String: Any]` for LWW comparison, or nil.
    static func fetchPullLocalRecord(db: Database, grdbTable: String, id: String) throws -> [String: Any]? {
        guard allowedGRDBTables.contains(grdbTable) else { throw SyncError.invalidPayload("Unknown table: \(grdbTable)") }
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \"\(grdbTable)\" WHERE id = ?", arguments: [id]) else { return nil }
        var dict: [String: Any] = [:]
        for (column, dbValue) in zip(row.columnNames, row.databaseValues) {
            switch dbValue.storage {
            case .null: dict[column] = NSNull()
            case .int64(let i): dict[column] = i
            case .double(let d): dict[column] = d
            case .string(let s): dict[column] = s
            case .blob(let b): dict[column] = b.base64EncodedString()
            }
        }
        return dict
    }

    /// Upserts a remote doc into `grdbTable` inside the caller's transaction:
    /// every column present in `data` that the local schema has is written
    /// (arrays / dicts as JSON text, `Timestamp`s as ISO strings), then each
    /// clearable field absent from the doc is NULLed (Board Edit slice 4, D2).
    /// Columns the schema dropped (e.g. a pre-v7 BoardTask's `isCompleted`)
    /// are filtered out, matching web Zod's unknown-key strip.
    ///
    /// - Throws: `SyncError.invalidPayload` for an unknown table / missing id /
    ///   no matching columns; a GRDB error from the write.
    static func upsertPulledRecord(db: Database, grdbTable: String, data: [String: Any]) throws {
        guard allowedGRDBTables.contains(grdbTable) else { throw SyncError.invalidPayload("Unknown table: \(grdbTable)") }
        var cleaned = data
        cleaned.removeValue(forKey: "_syncedAt")
        guard !cleaned.isEmpty else { return }
        guard cleaned["id"] is String else {
            throw SyncError.invalidPayload("Document missing 'id' field for \(grdbTable) upsert")
        }
        let validColumns = try pullColumnNames(for: grdbTable, in: db)
        let keys = cleaned.keys.filter {
            $0.range(of: "^[a-zA-Z_][a-zA-Z0-9_]*$", options: .regularExpression) != nil && validColumns.contains($0)
        }
        guard !keys.isEmpty else {
            throw SyncError.invalidPayload("No columns match the local schema for \(grdbTable) upsert")
        }
        let columns = keys.map { "\"\($0)\"" }.joined(separator: ", ")
        let placeholders = keys.map { _ in "?" }.joined(separator: ", ")
        let updateClause = keys.map { "\"\($0)\" = excluded.\"\($0)\"" }.joined(separator: ", ")
        let values: [DatabaseValueConvertible?] = keys.map { pullDatabaseValue(cleaned[$0]) }
        try db.execute(
            sql: "INSERT INTO \"\(grdbTable)\" (\(columns)) VALUES (\(placeholders)) ON CONFLICT (id) DO UPDATE SET \(updateClause)",
            arguments: StatementArguments(values)
        )
        // Pull is a full-entity replace: NULL every clearable field of this
        // table's collection absent from the doc.
        try SyncService.applyClearableFieldNulls(db: db, grdbTable: grdbTable, cleaned: cleaned)
    }

    /// A remote field value as a GRDB-bindable value.
    private static func pullDatabaseValue(_ val: Any?) -> DatabaseValueConvertible? {
        guard let val, !(val is NSNull) else { return nil }
        if let s = val as? String { return s }
        if let i = val as? Int { return i }
        if let d = val as? Double { return d }
        if let b = val as? Bool { return b }
        if let ts = val as? Timestamp {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: ts.dateValue())
        }
        if val is [Any] || val is [String: Any] {
            guard let data = try? JSONSerialization.data(withJSONObject: val) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return "\(val)"
    }

    /// Per-table column names via `PRAGMA table_info`, cached (migrations
    /// never run mid-session in production).
    private static let pullColumnNameCache = NSCache<NSString, NSSet>()

    private static func pullColumnNames(for table: String, in db: Database) throws -> Set<String> {
        let key = NSString(string: table)
        if let cached = pullColumnNameCache.object(forKey: key) as? Set<String> { return cached }
        // `table` comes from the closed `allowedGRDBTables` set — no injection.
        let names = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")").compactMap { $0["name"] as String? })
        pullColumnNameCache.setObject(NSSet(set: names), forKey: key)
        return names
    }

    /// True when the rows differ in `version` or `updatedAt` — the only two
    /// fields `resolveConflict` compares. False = an identical echo.
    static func pullRowsGenuinelyDiffer(local: [String: Any], remote: [String: Any]) -> Bool {
        toInt(local["version"]) != toInt(remote["version"])
            || (local["updatedAt"] as? String ?? "") != (remote["updatedAt"] as? String ?? "")
    }

    /// Board-integrity PR-4 (Item 1): a pull that resolves LOCAL-wins enqueues
    /// an UPDATE for the local row so a push race that let a stale remote write
    /// land can't strand this device's fresher data. The payload is the TYPED
    /// model's `SyncQueueBuilder.encodePayload` (never the raw row dict, whose
    /// 0/1 booleans + stringified arrays web's Zod rejects — PR-4 C1); the
    /// coalescer dedupes repeats. Owned by the PULL's uid (GUEST_MODE
    /// §Collision). Not used for `taskEvents` (union-by-id: a local win is the
    /// converged truth for that id).
    static func reassertPullLocalWin(
        db: Database, entityType: String, entityId: String,
        localData: [String: Any], remoteData: [String: Any], ownerUid: String
    ) throws {
        // Loop guard: identical rows never re-enqueue.
        guard pullRowsGenuinelyDiffer(local: localData, remote: remoteData) else { return }
        // Drain-only legacy tables have no live model and never need a reassert.
        guard let payload = try encodedLocalPayload(db: db, entityType: entityType, entityId: entityId) else { return }
        // Always `.update`, even for a local tombstone: the transport writes the
        // full payload (with isDeleted) whatever the op label (PR-4 M2).
        try SyncQueueItem(
            id: generateUUID(), entityType: entityType, entityId: entityId,
            operationType: .update, payload: payload, status: .pending, retryCount: 0,
            lastError: nil, createdAt: currentTimestamp(), lastAttemptAt: nil, completedAt: nil,
            priority: 1, ownerUid: ownerUid
        ).enqueue(db)
    }

    /// The local row as its typed model, wire-encoded; nil for a table with
    /// no live model (legacy drain-only collections).
    private static func encodedLocalPayload(db: Database, entityType: String, entityId: String) throws -> String? {
        switch entityType {
        case "boards": return try Board.fetchOne(db, key: entityId).map(SyncQueueBuilder.encodePayload)
        case "tasks": return try Task.fetchOne(db, key: entityId).map(SyncQueueBuilder.encodePayload)
        case "boardTasks": return try BoardTask.fetchOne(db, key: entityId).map(SyncQueueBuilder.encodePayload)
        case "compoundChildren": return try CompoundChild.fetchOne(db, key: entityId).map(SyncQueueBuilder.encodePayload)
        case "recurringBoardTemplates": return try RecurringBoardTemplate.fetchOne(db, key: entityId).map(SyncQueueBuilder.encodePayload)
        case "pools": return try Pool.fetchOne(db, key: entityId).map(SyncQueueBuilder.encodePayload)
        case "coreBoardDefaults": return try CoreBoardDefault.fetchOne(db, key: entityId).map(SyncQueueBuilder.encodePayload)
        case "users": return try User.fetchOne(db, key: entityId).map(SyncQueueBuilder.encodePayload)
        default: return nil
        }
    }
}
