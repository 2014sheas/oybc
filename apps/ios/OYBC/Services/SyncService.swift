import Foundation
import FirebaseFirestore
import GRDB

// MARK: - Types

/// Entity types that can be synced, mapped to their GRDB table names
/// and Firestore subcollection paths under `users/{userId}/`.
private let syncableCollections: [(firestoreName: String, grdbTable: String)] = [
    ("boards", "boards"),
    ("tasks", "tasks"),
    ("taskSteps", "task_steps"),
    ("boardTasks", "board_tasks"),
    ("compositeTasks", "composite_tasks"),
    ("compositeNodes", "composite_nodes"),
]

/// Whitelist of allowed GRDB table names — used to prevent SQL injection.
private let allowedGRDBTables: Set<String> = Set(syncableCollections.map(\.grdbTable))

/// Summary of a push sync operation.
public struct PushResult {
    /// Number of documents successfully pushed to Firestore.
    public var pushed: Int = 0
    /// Number of conflicts resolved in favour of the remote document.
    public var conflicts: Int = 0
    /// Number of items that failed to push.
    public var failed: Int = 0
    /// Human-readable log lines for each processed item.
    public var details: [String] = []
}

/// Summary of a pull sync operation.
public struct PullResult {
    /// Number of documents pulled from Firestore into local DB.
    public var pulled: Int = 0
    /// Number of conflicts resolved in favour of the local document.
    public var conflicts: Int = 0
    /// Human-readable log lines for each processed item.
    public var details: [String] = []
}

/// Combined result of a full push + pull sync cycle.
public struct SyncResult {
    public let push: PushResult
    public let pull: PullResult
}

/// A single event in the sync log, displayed in the playground dashboard.
public struct SyncEvent: Identifiable {
    public let id: UUID = UUID()
    public let timestamp: Date
    public let message: String
}

// MARK: - Conflict Resolution

/// Resolves a conflict between local and remote Firestore document dictionaries
/// using Last-Write-Wins (LWW) strategy.
///
/// Per SYNC_STRATEGY.md:
/// 1. Higher `version` wins.
/// 2. Same version → newer `updatedAt` wins.
/// 3. Exact tie → remote wins (server authority).
///
/// - Parameters:
///   - local: The local document as a `[String: Any]` dictionary.
///   - remote: The remote document from Firestore as a `[String: Any]` dictionary.
/// - Returns: `"local"` or `"remote"` indicating the winner.
private func resolveConflict(
    local: [String: Any],
    remote: [String: Any]
) -> String {
    let localVersion = (local["version"] as? Int) ?? 0
    let remoteVersion = (remote["version"] as? Int) ?? 0

    if localVersion > remoteVersion { return "local" }
    if remoteVersion > localVersion { return "remote" }

    // Same version — compare updatedAt timestamps via parsed Dates.
    // String comparison is unsafe across timezone formats (Z vs no Z).
    let localUpdatedAt = local["updatedAt"] as? String ?? ""
    let remoteUpdatedAt = remote["updatedAt"] as? String ?? ""
    if let localDate = parseISO8601Date(localUpdatedAt),
       let remoteDate = parseISO8601Date(remoteUpdatedAt) {
        if localDate > remoteDate { return "local" }
    } else if localUpdatedAt > remoteUpdatedAt {
        // Fallback to string comparison if parsing fails
        return "local"
    }

    // Tie or remote is newer — remote wins (server authority).
    return "remote"
}

// MARK: - SyncService

/// SyncService — mirrors the web `syncService.ts` for Firestore sync.
///
/// Implements the push/pull/fullSync cycle using local GRDB as the source of
/// truth and Firestore as the remote sync target.  Conflict resolution uses
/// Last-Write-Wins (LWW): higher version wins; same version → newer updatedAt
/// wins; tie → remote wins.
///
/// Use `AppDatabase.shared.saveSyncItem(_:)` after every local write to
/// enqueue the change for the next push.
///
/// - Note: All methods are `async` and run on the calling actor. UI-facing
///   published properties are always mutated on `@MainActor`.
@MainActor
final class SyncService: ObservableObject {

    // MARK: - Published State

    /// True while a sync cycle is in progress.
    @Published var isSyncing: Bool = false

    /// The result of the most recent full sync cycle.
    @Published var lastSyncResult: SyncResult?

    /// Ordered log of individual sync events, newest first.
    @Published var syncEvents: [SyncEvent] = []

    // MARK: - Private

    private let db = Firestore.firestore()

    // MARK: - Public API

    /// Performs a full sync cycle: push local changes first, then pull remote.
    ///
    /// Fetches the user's `lastSyncedAt` timestamp before pushing so that any
    /// remote changes made during the push window are still caught by the pull.
    ///
    /// - Parameter userId: The authenticated user's Firestore UID.
    /// - Returns: Combined push and pull result summaries.
    func fullSync(userId: String) async -> SyncResult {
        guard !isSyncing else {
            log("Sync already in progress — skipped")
            return SyncResult(push: PushResult(), pull: PullResult())
        }

        isSyncing = true
        defer { isSyncing = false }

        log("Full sync started")

        // Capture lastSyncedAt before pushing so we don't miss remote changes
        // that arrive during the push window.
        let lastSyncedAt = await fetchLastSyncedAt(userId: userId)

        let push = await pushSync(userId: userId)
        let pull = await pullSync(userId: userId, lastSyncedAt: lastSyncedAt)

        let result = SyncResult(push: push, pull: pull)
        lastSyncResult = result

        log("Full sync complete — pushed: \(push.pushed), conflicts: \(push.conflicts + pull.conflicts), pulled: \(pull.pulled), failed: \(push.failed)")

        return result
    }

    /// Pushes all pending sync queue items to Firestore.
    ///
    /// For each pending item:
    /// 1. Marks it `inProgress` in the queue.
    /// 2. Reads the remote Firestore document (if it exists) for conflict checking.
    /// 3. Resolves conflicts using LWW.
    /// 4. Writes to Firestore if local wins (or remote doesn't exist).
    /// 5. Updates the local GRDB record if remote wins.
    /// 6. Marks the queue item `completed` or `failed`.
    ///
    /// - Parameter userId: The authenticated user's Firestore UID.
    /// - Returns: Push result summary.
    func pushSync(userId: String) async -> PushResult {
        var result = PushResult()

        let pendingItems: [SyncQueueItem]
        do {
            pendingItems = try AppDatabase.shared.fetchPendingSyncItems()
        } catch {
            let msg = "Push failed: could not read sync queue: \(error.localizedDescription)"
            log(msg)
            result.details.append(msg)
            result.failed += 1
            return result
        }

        guard !pendingItems.isEmpty else { return result }

        for item in pendingItems {
            await processPushItem(item, userId: userId, result: &result)
        }

        return result
    }

    /// Pulls remote changes from Firestore that are newer than `lastSyncedAt`.
    ///
    /// For each syncable collection:
    /// 1. Queries Firestore for documents updated after `lastSyncedAt` (all docs on first sync).
    /// 2. Compares each remote document with the local version.
    /// 3. Applies LWW conflict resolution.
    /// 4. Writes the winning document to the local GRDB table.
    ///
    /// Updates the user's `lastSyncedAt` in the local DB after all collections
    /// have been processed.
    ///
    /// - Parameters:
    ///   - userId: The authenticated user's Firestore UID.
    ///   - lastSyncedAt: ISO8601 timestamp of the last successful sync, or `nil` for first sync.
    /// - Returns: Pull result summary.
    func pullSync(userId: String, lastSyncedAt: String?) async -> PullResult {
        var result = PullResult()

        for collection in syncableCollections {
            await processPullCollection(
                collection: collection,
                userId: userId,
                lastSyncedAt: lastSyncedAt,
                result: &result
            )
        }

        // Update lastSyncedAt on the local user record.
        let now = AppDatabase.currentTimestamp()
        do {
            if var user = try AppDatabase.shared.fetchUser(id: userId) {
                user.lastSyncedAt = now
                user.updatedAt = now
                try AppDatabase.shared.saveUser(user)
            }
        } catch {
            log("Warning: could not update lastSyncedAt for user \(userId): \(error.localizedDescription)")
        }

        return result
    }

    // MARK: - Push Helpers

    /// Processes a single sync queue item during push.
    ///
    /// - Parameters:
    ///   - item: The `SyncQueueItem` to process.
    ///   - userId: The authenticated user's Firestore UID.
    ///   - result: The `PushResult` to mutate with this item's outcome.
    private func processPushItem(
        _ item: SyncQueueItem,
        userId: String,
        result: inout PushResult
    ) async {
        do {
            // Mark in-progress.
            var inProgress = item
            inProgress.status = .inProgress
            inProgress.lastAttemptAt = AppDatabase.currentTimestamp()
            try AppDatabase.shared.saveSyncItem(inProgress)

            guard let payload = parsePayload(item.payload) else {
                throw SyncError.invalidPayload("Could not parse payload for \(item.entityType)/\(item.entityId)")
            }

            let docRef = db.collection("users")
                .document(userId)
                .collection(item.entityType)
                .document(item.entityId)

            // DELETE operations: check conflict before overwriting.
            if item.operationType == .delete {
                let remoteDeleteSnap = try await docRef.getDocument()
                if remoteDeleteSnap.exists, let remoteData = remoteDeleteSnap.data() {
                    let winner = resolveConflict(local: payload, remote: remoteData)
                    if winner == "remote" {
                        // Remote is newer — don't delete, restore remote version locally
                        let grdbTable = collectionGRDBTable(item.entityType)
                        try upsertLocalRecord(grdbTable: grdbTable, data: remoteData)
                        try markCompleted(item)
                        result.conflicts += 1
                        let msg = "Delete conflict \(item.entityType)/\(item.entityId): remote wins"
                        result.details.append(msg)
                        log(msg)
                        return
                    }
                }
                try await writeFirestoreDoc(docRef: docRef, data: payload)
                try markCompleted(item)
                result.pushed += 1
                let msg = "Deleted \(item.entityType)/\(item.entityId)"
                result.details.append(msg)
                log(msg)
                return
            }

            // Fetch remote document to check for a conflict.
            let remoteSnap = try await docRef.getDocument()

            if !remoteSnap.exists {
                // No remote document — push directly.
                try await writeFirestoreDoc(docRef: docRef, data: payload)
                try markCompleted(item)
                result.pushed += 1
                let msg = "Pushed \(item.entityType)/\(item.entityId) (new)"
                result.details.append(msg)
                log(msg)
                return
            }

            // Remote exists — resolve conflict.
            guard let remoteData = remoteSnap.data() else {
                throw SyncError.invalidPayload("Empty remote document for \(item.entityType)/\(item.entityId)")
            }

            let winner = resolveConflict(local: payload, remote: remoteData)

            if winner == "local" {
                try await writeFirestoreDoc(docRef: docRef, data: payload)
                try markCompleted(item)
                result.pushed += 1
                let localV = payload["version"] as? Int ?? 0
                let remoteV = remoteData["version"] as? Int ?? 0
                let msg = "Pushed \(item.entityType)/\(item.entityId) (local v\(localV) > remote v\(remoteV))"
                result.details.append(msg)
                log(msg)
            } else {
                // Remote wins — update the local GRDB record with the remote data.
                try upsertLocalRecord(
                    grdbTable: collectionGRDBTable(item.entityType),
                    data: remoteData
                )
                try markCompleted(item)
                result.conflicts += 1
                let localV = payload["version"] as? Int ?? 0
                let remoteV = remoteData["version"] as? Int ?? 0
                let msg = "Conflict \(item.entityType)/\(item.entityId): remote wins (v\(remoteV) >= v\(localV))"
                result.details.append(msg)
                log(msg)
            }
        } catch {
            let errorMsg = error.localizedDescription
            do {
                var failed = item
                failed.status = .failed
                failed.lastError = errorMsg
                failed.retryCount += 1
                failed.lastAttemptAt = AppDatabase.currentTimestamp()
                try AppDatabase.shared.saveSyncItem(failed)
            } catch {
                log("Warning: could not update failed sync item \(item.id): \(error.localizedDescription)")
            }
            result.failed += 1
            let msg = "Failed \(item.entityType)/\(item.entityId): \(errorMsg)"
            result.details.append(msg)
            log(msg)
        }
    }

    // MARK: - Pull Helpers

    /// Processes all documents in a single Firestore collection during pull.
    ///
    /// - Parameters:
    ///   - collection: The collection name pair (Firestore name + GRDB table name).
    ///   - userId: The authenticated user's Firestore UID.
    ///   - lastSyncedAt: ISO8601 timestamp for incremental pulls, or `nil` for first sync.
    ///   - result: The `PullResult` to mutate with this collection's outcomes.
    private func processPullCollection(
        collection: (firestoreName: String, grdbTable: String),
        userId: String,
        lastSyncedAt: String?,
        result: inout PullResult
    ) async {
        do {
            let colRef = db.collection("users")
                .document(userId)
                .collection(collection.firestoreName)

            let query: Query
            if let lastSyncedAt {
                query = colRef.whereField("updatedAt", isGreaterThan: lastSyncedAt)
            } else {
                query = colRef // First sync — pull everything.
            }

            let snapshot = try await query.getDocuments()
            guard !snapshot.isEmpty else { return }

            for docSnap in snapshot.documents {
                let remoteData = docSnap.data()
                guard let remoteId = remoteData["id"] as? String else { continue }

                // Look up the local record for conflict resolution.
                let localData = try fetchLocalRecord(grdbTable: collection.grdbTable, id: remoteId)

                if localData == nil {
                    // New remote document — insert locally.
                    try upsertLocalRecord(grdbTable: collection.grdbTable, data: remoteData)
                    result.pulled += 1
                    let msg = "Pulled \(collection.firestoreName)/\(remoteId) (new)"
                    result.details.append(msg)
                    log(msg)
                    continue
                }

                // Both exist — resolve conflict.
                let winner = resolveConflict(local: localData!, remote: remoteData)

                if winner == "remote" {
                    try upsertLocalRecord(grdbTable: collection.grdbTable, data: remoteData)
                    result.pulled += 1
                    let remoteV = remoteData["version"] as? Int ?? 0
                    let localV = localData!["version"] as? Int ?? 0
                    let msg = "Pulled \(collection.firestoreName)/\(remoteId) (remote v\(remoteV) > local v\(localV))"
                    result.details.append(msg)
                    log(msg)
                } else {
                    result.conflicts += 1
                    let localV = localData!["version"] as? Int ?? 0
                    let remoteV = remoteData["version"] as? Int ?? 0
                    let msg = "Kept local \(collection.firestoreName)/\(remoteId) (local v\(localV) >= remote v\(remoteV))"
                    result.details.append(msg)
                    log(msg)
                }
            }
        } catch {
            let msg = "Pull failed for \(collection.firestoreName): \(error.localizedDescription)"
            result.details.append(msg)
            log(msg)
        }
    }

    // MARK: - Firestore Write

    /// Writes a document to Firestore, stripping `nil`/`NSNull` values and
    /// attaching a server-side `_syncedAt` timestamp.
    ///
    /// Uses `merge: true` so that fields not present in `data` are preserved
    /// rather than deleted.
    ///
    /// - Parameters:
    ///   - docRef: The Firestore `DocumentReference` to write to.
    ///   - data: The document data dictionary.
    private func writeFirestoreDoc(
        docRef: DocumentReference,
        data: [String: Any]
    ) async throws {
        var cleaned: [String: Any] = [:]
        for (key, value) in data {
            if value is NSNull { continue }
            // Expand JSON-encoded strings back to native arrays/dicts for Firestore.
            // GRDB stores arrays as JSON strings (e.g. completedLineIds: "[\"row_0\"]"),
            // but Firestore should receive native arrays so web can read them correctly.
            if let str = value as? String, str.hasPrefix("[") || str.hasPrefix("{") {
                if let jsonData = str.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: jsonData) {
                    cleaned[key] = parsed
                    continue
                }
            }
            cleaned[key] = value
        }
        cleaned["_syncedAt"] = FieldValue.serverTimestamp()

        try await docRef.setData(cleaned, merge: true)
    }

    // MARK: - Local DB Helpers

    /// Fetches the local GRDB record for the given table and primary key,
    /// returning it as a `[String: Any]` dictionary suitable for conflict comparison.
    ///
    /// - Parameters:
    ///   - grdbTable: The GRDB table name (e.g. `"boards"`).
    ///   - id: The primary key of the record.
    /// - Returns: The record as a dictionary, or `nil` if not found.
    private func fetchLocalRecord(grdbTable: String, id: String) throws -> [String: Any]? {
        guard allowedGRDBTables.contains(grdbTable) else {
            throw SyncError.invalidPayload("Unknown table: \(grdbTable)")
        }
        return try AppDatabase.shared.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \"\(grdbTable)\" WHERE id = ?", arguments: [id]) else {
                return nil
            }
            var dict: [String: Any] = [:]
            for (column, dbValue) in zip(row.columnNames, row.databaseValues) {
                switch dbValue.storage {
                case .null:             dict[column] = NSNull()
                case .int64(let i):     dict[column] = i
                case .double(let d):    dict[column] = d
                case .string(let s):    dict[column] = s
                case .blob(let b):      dict[column] = b.base64EncodedString()
                }
            }
            return dict
        }
    }

    /// Upserts a remote Firestore document into a local GRDB table.
    ///
    /// Converts the `[String: Any]` dictionary to JSON data, then uses
    /// `JSONSerialization` to round-trip through the generic SQL upsert
    /// path.  All columns present in `data` are written; missing columns
    /// retain their existing values.
    ///
    /// - Parameters:
    ///   - grdbTable: The GRDB table name (e.g. `"tasks"`).
    ///   - data: The Firestore document dictionary.
    private func upsertLocalRecord(grdbTable: String, data: [String: Any]) throws {
        guard allowedGRDBTables.contains(grdbTable) else {
            throw SyncError.invalidPayload("Unknown table: \(grdbTable)")
        }
        // Filter out Firestore metadata fields that don't exist in GRDB.
        var cleaned = data
        cleaned.removeValue(forKey: "_syncedAt")

        guard !cleaned.isEmpty else { return }

        // Validate all keys are safe SQL identifiers to prevent injection
        let keys = Array(cleaned.keys).filter { key in
            key.range(of: "^[a-zA-Z_][a-zA-Z0-9_]*$", options: .regularExpression) != nil
        }
        guard !keys.isEmpty else {
            throw SyncError.invalidPayload("No valid column names for \(grdbTable) upsert")
        }

        let columns = keys.map { "\"\($0)\"" }.joined(separator: ", ")
        let placeholders = keys.map { _ in "?" }.joined(separator: ", ")
        let updateClause = keys.map { "\"\($0)\" = excluded.\"\($0)\"" }.joined(separator: ", ")

        let sql = """
            INSERT INTO "\(grdbTable)" (\(columns))
            VALUES (\(placeholders))
            ON CONFLICT (id) DO UPDATE SET \(updateClause)
            """

        // Convert values to GRDB-compatible DatabaseValue types.
        // Arrays and dictionaries are JSON-encoded (GRDB stores them as TEXT).
        // Firestore Timestamps are converted to ISO8601 strings.
        let values: [DatabaseValueConvertible?] = keys.map { key in
            let val = cleaned[key]
            if val == nil || val is NSNull { return nil }
            if let s = val as? String { return s }
            if let i = val as? Int { return i }
            if let d = val as? Double { return d }
            if let b = val as? Bool { return b }
            if let ts = val as? Timestamp {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.string(from: ts.dateValue())
            }
            // Arrays and dictionaries → JSON string
            if let arr = val as? [Any] {
                if let jsonData = try? JSONSerialization.data(withJSONObject: arr),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    return jsonStr
                }
                return nil
            }
            if let dict = val as? [String: Any] {
                if let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    return jsonStr
                }
                return nil
            }
            // Fallback: try String description
            return "\(val!)"
        }

        try AppDatabase.shared.write { db in
            try db.execute(sql: sql, arguments: StatementArguments(values))
        }
    }

    // MARK: - Sync Queue Helpers

    /// Marks a sync queue item as completed and records the completion timestamp.
    ///
    /// - Parameter item: The `SyncQueueItem` to mark completed.
    private func markCompleted(_ item: SyncQueueItem) throws {
        var completed = item
        completed.status = .completed
        completed.completedAt = AppDatabase.currentTimestamp()
        try AppDatabase.shared.saveSyncItem(completed)
    }

    // MARK: - User Helpers

    /// Fetches the current `lastSyncedAt` timestamp from the local user record.
    ///
    /// - Parameter userId: The user's ID.
    /// - Returns: The ISO8601 timestamp string, or `nil` if never synced.
    private func fetchLastSyncedAt(userId: String) async -> String? {
        do {
            return try AppDatabase.shared.fetchUser(id: userId)?.lastSyncedAt
        } catch {
            log("Warning: could not fetch user for lastSyncedAt: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Utilities

    /// Maps a Firestore collection name to its GRDB table name.
    ///
    /// - Parameter firestoreName: The Firestore subcollection name.
    /// - Returns: The corresponding GRDB table name.
    private func collectionGRDBTable(_ firestoreName: String) -> String {
        syncableCollections
            .first(where: { $0.firestoreName == firestoreName })?
            .grdbTable ?? firestoreName
    }

    /// Parses a JSON string payload from the sync queue into a `[String: Any]` dictionary.
    ///
    /// - Parameter jsonString: The JSON payload string stored on a `SyncQueueItem`.
    /// - Returns: The parsed dictionary, or `nil` on failure.
    private func parsePayload(_ jsonString: String) -> [String: Any]? {
        guard
            let data = jsonString.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }

    /// Appends a new event to `syncEvents` and prints to the console.
    ///
    /// - Parameter message: The event message.
    private func log(_ message: String) {
        let event = SyncEvent(timestamp: Date(), message: message)
        syncEvents.insert(event, at: 0)
        // Cap the log at 100 entries to prevent unbounded growth.
        if syncEvents.count > 100 {
            syncEvents = Array(syncEvents.prefix(100))
        }
        print("[SyncService] \(message)")
    }
}

// MARK: - Errors

private enum SyncError: LocalizedError {
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case .invalidPayload(let msg): return msg
        }
    }
}
