import Foundation
@preconcurrency import GRDB

// MARK: - Forward-compatible pull (issue #300, ROADMAP Track L4)
//
// 1.0 is the OLDEST client that will ever exist, so whatever it does with a doc
// it cannot read is permanent. A doc written by a newer app version can carry an
// enum value this build's models cannot decode (`TaskType`, `BoardStatus`,
// `Timeframe`, `TaskEventKind`, …). Before this file the pull wrote such a doc
// as a raw column and let the board cascade's typed read trip over it: the
// whole batch (and its checkpoint) rolled back, the same batch re-failed every
// cycle, and nothing behind it was ever ingested; collections WITHOUT a cascade
// (`coreBoardDefaults`, `recurringBoardTemplates`) instead persisted the row and
// poisoned every later typed read of the table.
//
// The contract (docs/SYNC_STRATEGY.md §Forward-compatible pull):
//   1. Never wedge — each applied doc is upserted inside a SAVEPOINT and probed
//      with its typed model; a doc this build cannot decode is rolled back out
//      and the rest of the batch applies normally.
//   2. Never lose — the skipped doc goes into the LOCAL-ONLY `sync_quarantine`
//      ledger (GRDB v48). The checkpoint still moves past it, so the ledger is
//      what lets a LATER build re-fetch it by id (`retryQuarantinedPullDocs`).
//   3. Dependents follow — a placement / compound link whose task or board is
//      itself quarantined would trip the table's foreign key (board_tasks,
//      compound_children), so it is ledgered too and retried right after.
//
// Web twin: `db/operations/syncQuarantine.ts` + `quarantineRetry.ts`.

/// One row of the `sync_quarantine` ledger.
struct QuarantinedDoc: Equatable, Sendable {
    /// The Firestore subcollection (`pullApplyOrder` name).
    let collection: String
    /// The doc's entity id.
    let docId: String
    /// Why it was skipped (never contains a uid).
    let reason: String
    /// The build that last failed to apply it.
    let appBuild: String
}

extension AppDatabase {

    /// Max ledger rows one retry pass re-fetches (the rest wait for the next pull).
    static let quarantineRetryLimit = 200

    /// The reason a compound link is skipped when its parent compound is not
    /// local — the one pre-existing skip that is also ledgered.
    static let orphanedChildReason = "parent compound not yet present locally"

    /// The identity of THIS build — `<CFBundleShortVersionString>(<CFBundleVersion>)`.
    /// A doc quarantined by build B is retried only by a different build.
    static var currentAppBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version)(\(build))"
    }

    // MARK: - Ledger

    /// Records `docId` as skipped by this build. Idempotent: re-quarantining an
    /// id updates its reason + build and keeps its original `quarantinedAt`.
    ///
    /// - Parameters:
    ///   - db: The caller's open transaction.
    ///   - userId: The uid the pull runs for.
    ///   - collection: The Firestore subcollection.
    ///   - docId: The doc's entity id.
    ///   - reason: Why it was skipped.
    ///   - appBuild: The recording build (default: this build).
    /// - Throws: A GRDB error.
    static func quarantinePulledDoc(
        db: Database, userId: String, collection: String, docId: String, reason: String,
        appBuild: String = currentAppBuild
    ) throws {
        try db.execute(sql: """
            INSERT INTO sync_quarantine (userId, collection, docId, reason, appBuild, quarantinedAt)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (userId, collection, docId) DO UPDATE SET reason = excluded.reason, appBuild = excluded.appBuild
            """, arguments: [userId, collection, docId, reason, appBuild, currentTimestamp()])
        dlog("[SyncService] quarantined \(collection)/\(docId): \(reason)")
    }

    /// Removes docs from the ledger — they applied, or no longer exist remotely.
    ///
    /// - Throws: A GRDB error.
    static func releaseQuarantinedDocs(db: Database, userId: String, collection: String, ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        try db.execute(
            sql: "DELETE FROM sync_quarantine WHERE userId = ? AND collection = ? AND docId IN (\(marks))",
            arguments: StatementArguments([userId, collection] + ids)
        )
    }

    /// Marks `ids` as tried by `appBuild`, so this build does not re-fetch them
    /// again (a doc the retry can neither apply nor re-quarantine — rejected for
    /// a permanent reason — waits for the next build).
    ///
    /// - Throws: A GRDB error.
    static func stampQuarantineAttempt(db: Database, userId: String, collection: String, ids: [String], appBuild: String) throws {
        guard !ids.isEmpty else { return }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        try db.execute(
            sql: "UPDATE sync_quarantine SET appBuild = ? WHERE userId = ? AND collection = ? AND docId IN (\(marks))",
            arguments: StatementArguments([appBuild, userId, collection] + ids)
        )
    }

    /// The ledger rows a build should re-fetch: those recorded by any OTHER
    /// build, oldest first, capped at `limit`.
    ///
    /// - Throws: A GRDB error.
    static func retryableQuarantine(db: Database, userId: String, appBuild: String, limit: Int) throws -> [QuarantinedDoc] {
        try Row.fetchAll(db, sql: """
            SELECT collection, docId, reason, appBuild FROM sync_quarantine
            WHERE userId = ? AND appBuild != ? ORDER BY quarantinedAt, docId LIMIT ?
            """, arguments: [userId, appBuild, limit]).map {
            QuarantinedDoc(collection: $0["collection"], docId: $0["docId"], reason: $0["reason"], appBuild: $0["appBuild"])
        }
    }

    /// Every ledger row for `userId` (diagnostics and tests).
    ///
    /// - Throws: A GRDB error.
    static func fetchQuarantinedDocs(db: Database, userId: String) throws -> [QuarantinedDoc] {
        try Row.fetchAll(db, sql: """
            SELECT collection, docId, reason, appBuild FROM sync_quarantine WHERE userId = ? ORDER BY collection, docId
            """, arguments: [userId]).map {
            QuarantinedDoc(collection: $0["collection"], docId: $0["docId"], reason: $0["reason"], appBuild: $0["appBuild"])
        }
    }

    /// Whether any doc of `collection` is in the ledger for `userId`.
    static func hasQuarantinedDocs(db: Database, userId: String, collection: String) throws -> Bool {
        try Row.fetchOne(
            db, sql: "SELECT 1 FROM sync_quarantine WHERE userId = ? AND collection = ? LIMIT 1", arguments: [userId, collection]
        ) != nil
    }

    /// Whether `docId` is in the ledger.
    private static func isQuarantined(db: Database, userId: String, collection: String, docId: String) throws -> Bool {
        try Row.fetchOne(
            db, sql: "SELECT 1 FROM sync_quarantine WHERE userId = ? AND collection = ? AND docId = ?",
            arguments: [userId, collection, docId]
        ) != nil
    }

    // MARK: - Decodability probe

    /// Reads `id` back through the table's TYPED model — exactly the decode
    /// every reader of the table performs. A row this build cannot decode
    /// (an unknown enum value) throws; a table with no live model (the legacy
    /// pull-skip collections, `users`) probes nothing.
    ///
    /// - Throws: The model's decode error (not a `DatabaseError`), or a SQLite error.
    static func probeDecodable(db: Database, grdbTable: String, id: String) throws {
        switch grdbTable {
        case "boards": _ = try Board.fetchOne(db, key: id)
        case "tasks": _ = try Task.fetchOne(db, key: id)
        case "board_tasks": _ = try BoardTask.fetchOne(db, key: id)
        case "compound_children": _ = try CompoundChild.fetchOne(db, key: id)
        case "recurring_board_templates": _ = try RecurringBoardTemplate.fetchOne(db, key: id)
        case "default_pools": _ = try DefaultPool.fetchOne(db, key: id)
        case "task_events": _ = try TaskEvent.fetchOne(db, key: id)
        case "pools": _ = try Pool.fetchOne(db, key: id)
        case "core_board_defaults": _ = try CoreBoardDefault.fetchOne(db, key: id)
        default: break
        }
    }

    /// A one-line, row-free reason for a decode failure: GRDB's
    /// `RowDecodingError` text carries a dump of the whole row (title, userId, …)
    /// after ` - column`, which must not reach the ledger or the log.
    static func decodeFailureReason(_ error: Error) -> String {
        let text = String(describing: error)
        let head = text.components(separatedBy: " - column").first ?? text
        return "undecodable: \(String(head.prefix(200)))"
    }

    /// Upserts a pulled doc, keeping it ONLY if this build's typed model can read
    /// it back. The upsert + probe run in a savepoint: an undecodable doc is
    /// rolled out of the table (so no typed reader ever sees it) and ledgered.
    ///
    /// - Parameters:
    ///   - db: The caller's open transaction.
    ///   - collection: The doc's collection (a non-pull collection — `users`,
    ///     the legacy skip — is upserted without a probe or ledger row).
    ///   - id: The doc's entity id.
    ///   - data: The raw remote doc.
    ///   - userId: The uid the pull runs for.
    /// - Returns: nil when the doc was applied; else the quarantine reason.
    /// - Throws: A real DB error (SQLite failure, bad payload) — the caller's
    ///   transaction rolls back and the pull retries, as before.
    static func upsertDecodableOrQuarantine(
        db: Database, collection: PullCollection, id: String, data: [String: Any], userId: String
    ) throws -> String? {
        guard pullApplyOrder.contains(collection.firestoreName) else {
            try upsertPulledRecord(db: db, grdbTable: collection.grdbTable, data: data)
            return nil
        }
        var failure: String?
        try db.inSavepoint {
            try upsertPulledRecord(db: db, grdbTable: collection.grdbTable, data: data)
            do {
                try probeDecodable(db: db, grdbTable: collection.grdbTable, id: id)
            } catch let error where !(error is DatabaseError) {
                failure = decodeFailureReason(error)
                return .rollback
            }
            return .commit
        }
        guard let failure else { return nil }
        try quarantinePulledDoc(db: db, userId: userId, collection: collection.firestoreName, docId: id, reason: failure)
        return failure
    }

    // MARK: - Dependents

    /// Why a NEW placement / compound link cannot be applied because something it
    /// references is itself quarantined: `board_tasks` (board, task) and
    /// `compound_children` (child task) carry foreign keys, so inserting one
    /// whose referenced row was never stored would throw and roll back the batch.
    /// A missing reference that is NOT in the ledger returns nil — that is the
    /// ordinary cross-collection ordering race, which keeps its retry-next-pull
    /// behaviour.
    ///
    /// - Returns: The reason, or nil when the doc can be applied (or fails the
    ///   way it always did).
    /// - Throws: A GRDB error.
    static func quarantinedDependencyReason(db: Database, userId: String, collection: String, remote: [String: Any]) throws -> String? {
        let dependencies: [(collection: String, table: String, id: String?)]
        switch collection {
        case "boardTasks":
            dependencies = [("boards", "boards", remote["boardId"] as? String), ("tasks", "tasks", remote["taskId"] as? String)]
        case "compoundChildren":
            dependencies = [("tasks", "tasks", remote["childTaskId"] as? String)]
        default:
            return nil
        }
        for dependency in dependencies {
            guard let depId = dependency.id, !depId.isEmpty else { continue }
            let present = try Row.fetchOne(db, sql: "SELECT 1 FROM \(dependency.table) WHERE id = ?", arguments: [depId]) != nil
            if present { continue }
            if try isQuarantined(db: db, userId: userId, collection: dependency.collection, docId: depId) {
                return "depends on quarantined \(dependency.collection)/\(depId)"
            }
        }
        return nil
    }

    // MARK: - Retry on a new build

    /// Re-fetches the docs a PREVIOUS build quarantined and applies them through
    /// the normal batch path, collection by collection in `pullApplyOrder` (a
    /// compound's task before its children, a task before its placements).
    /// Does nothing until the build changed: only rows recorded by another build
    /// are selected. Per collection, ONE transaction releases the docs that no
    /// longer exist, stamps every fetched row as tried by this build, and applies
    /// the docs — which releases the ones that now decode and re-ledgers the rest.
    ///
    /// - Parameters:
    ///   - source: The remote reader (production: Firestore).
    ///   - userId: The signed-in uid.
    ///   - appBuild: The running build (default: this build).
    ///   - limit: Max rows per pass (default `quarantineRetryLimit`).
    /// - Returns: The aggregated outcome (`pulled` + per-doc details).
    /// - Throws: A transport error from `source` or a GRDB error — the rows stay
    ///   for the next pull.
    func retryQuarantinedPullDocs(
        source: PullDocumentSource, userId: String,
        appBuild: String = AppDatabase.currentAppBuild, limit: Int = AppDatabase.quarantineRetryLimit
    ) async throws -> PullBatchOutcome {
        var total = PullBatchOutcome()
        let rows = try await readAsync { db in
            try Self.retryableQuarantine(db: db, userId: userId, appBuild: appBuild, limit: limit)
        }
        for collection in pullApplyCollections {
            let ids = rows.filter { $0.collection == collection.firestoreName }.map(\.docId)
            if ids.isEmpty { continue }
            var docs: [[String: Any]] = []
            var gone: [String] = []
            for id in ids {
                if let doc = try await source.fetchDocument(userId: userId, collection: collection.firestoreName, id: id) {
                    docs.append(doc)
                } else {
                    gone.append(id)
                }
            }
            let fetched = PullDocs(docs: docs)
            let goneIds = gone
            let outcome = try await writeAsync { db in
                try Self.releaseQuarantinedDocs(db: db, userId: userId, collection: collection.firestoreName, ids: goneIds)
                try Self.stampQuarantineAttempt(db: db, userId: userId, collection: collection.firestoreName, ids: ids, appBuild: appBuild)
                return try Self.applyPullBatchTx(db: db, collection: collection, docs: fetched.docs, userId: userId)
            }
            total.pulled += outcome.pulled
            total.conflicts += outcome.conflicts
            total.details.append(contentsOf: goneIds.map { "Released quarantined \(collection.firestoreName)/\($0): no longer on the server" })
            total.details.append(contentsOf: outcome.details.map { "Retry \($0)" })
        }
        return total
    }
}
