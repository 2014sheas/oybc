import Foundation
import FirebaseFirestore
@preconcurrency import GRDB

// MARK: - Live-update signal (Board-integrity PR-4, Item 5)

extension Notification.Name {
    /// Posted by `SyncService`, on the main queue, once per pull/listener batch
    /// that applied ≥1 change to local GRDB — never per individual row.
    /// Foreground-only: only ever posted from an active push/pull cycle (never
    /// from a background task), so it carries no background-execution
    /// implications and does not relax the recurring-boards lazy-detection
    /// invariant (see CLAUDE.md §Recurring Boards).
    ///
    /// iOS had no live-update mechanism at all before this — a sync pull
    /// landing while a screen was open (e.g. another device completing a task)
    /// sat invisible until the user navigated away and back. Web is reactive
    /// via Dexie's `useLiveQuery`; this is the closest iOS equivalent without
    /// introducing a Combine/GRDB `ValueObservation` per screen.
    ///
    /// Observers: `BoardPlayViewModel`'s `syncObserver` (skips reload while an
    /// edit-save is in flight) and `BoardListView.onAppearLoad`'s
    /// `.onReceive`. Extend this pattern for future screens rather than
    /// inventing a parallel ad-hoc mechanism.
    static let oybcSyncDidApplyChanges = Notification.Name("oybcSyncDidApplyChanges")
}

// MARK: - Types

/// Entity types that can be synced, mapped to their GRDB table names
/// and Firestore subcollection paths under `users/{userId}/`.
///
/// The `firestoreName` half of each tuple (excluding the trailing `users`
/// entry, which is the parent doc, not a subcollection) must set-match
/// `@oybc/shared`'s `SYNC_COLLECTIONS` — enforced by
/// `OYBCTests/SyncContractTests.swift` against the generated
/// `syncContract.json` fixture (workstream C4 / issue #261). Not
/// `private` so that test can see it via `@testable import OYBC`.
let syncableCollections: [(firestoreName: String, grdbTable: String)] = [
    ("boards", "boards"),
    ("tasks", "tasks"),
    ("boardTasks", "board_tasks"),
    ("compoundChildren", "compound_children"),
    ("recurringBoardTemplates", "recurring_board_templates"), // Phase 6.2
    ("defaultPools", "default_pools"),                       // Phase 6.X — legacy, see legacyPullSkipCollections
    ("taskEvents", "task_events"),                           // Windowed Completion (docs/WINDOWED_COMPLETION.md §Sync)
    ("pools", "pools"),                                       // P1 — Task Pools + Recurring Boards Rework
    ("coreBoardDefaults", "core_board_defaults"),              // P1 — replaces defaultPools
    // `users` is handled as the parent doc at `users/{userId}` (not a
    // subcollection child), but the GRDB table it writes back into is still
    // `users`, so it participates in the allowedGRDBTables whitelist.
    ("users", "users"),
]

/// Whitelist of allowed GRDB table names — used to prevent SQL injection.
private let allowedGRDBTables: Set<String> = Set(syncableCollections.map(\.grdbTable))

/// Firestore subcollections whose documents carry a `userId` field.
/// The pull path rejects any document whose `userId` doesn't match the
/// authenticated user for these collections — defense-in-depth against
/// a compromised peer that spoofs `userId` in its own writes.
///
/// Must set-match `@oybc/shared`'s `USER_SCOPED_SYNC_COLLECTIONS` —
/// enforced by `OYBCTests/SyncContractTests.swift`. Not `private` so
/// that test can see it via `@testable import OYBC`.
let userScopedCollections: Set<String> = [
    "boards", "tasks", "recurringBoardTemplates",
    "defaultPools",
    // TaskEvent rows carry a top-level `userId` (Windowed Completion).
    "taskEvents",
    // P1 — Task Pools + Recurring Boards Rework. Both carry a top-level `userId`.
    "pools", "coreBoardDefaults",
]

/// Collections whose GRDB table is retired from live use by a
/// first-launch data migration but still receives sync tombstone drains.
/// `defaultPools` (P1 — Task Pools + Recurring Boards Rework) keeps its
/// `default_pools` table, but every row is soft-deleted by the v25
/// migration (docs/POOLS_RECURRING.md §Migration), so pulling a peer's
/// still-live `DefaultPool` doc (a mixed-version device that hasn't
/// migrated yet) would resurrect a row the local migration already
/// tombstoned. It stays in `syncableCollections` so the push path can
/// drain DELETE sync ops for pre-migration rows (cleaning up Firestore),
/// but the pull path must skip it so upserting doesn't fight the local
/// migration's tombstone. (The Compound-Tasks-Unification collections
/// `taskSteps`/`compositeTasks`/`compositeNodes` that used this same
/// pattern were removed from the sync contract entirely once their
/// tables were dropped.)
///
/// Must set-match `@oybc/shared`'s `LEGACY_PULL_SKIP_COLLECTIONS` —
/// enforced by `OYBCTests/SyncContractTests.swift`. Not `private` so
/// that test can see it via `@testable import OYBC`.
let legacyPullSkipCollections: Set<String> = [
    "defaultPools",
]

/// Validates the baseline sync-safety invariants that every pulled
/// document must satisfy before reaching GRDB. This helper enforces
/// the narrow subset it actually checks: a UUID `id`, `version >= 1`,
/// and (for user-scoped collections) `userId` equality. It does NOT
/// attempt to fully mirror the web Zod entity schemas — that would
/// require per-collection Codable decoding of every field; future
/// work if divergence becomes a problem.
///
/// - Parameters:
///   - collection: The Firestore subcollection name.
///   - data: The raw document data from Firestore.
///   - authenticatedUserId: The current user's uid.
/// - Returns: An error string if the document is invalid, or `nil` to
///   proceed with upsert. A returned string is logged and the document
///   is skipped.
private func validateRemotePullDocument(
    collection: String,
    data: [String: Any],
    authenticatedUserId: String
) -> String? {
    // Require an id string.
    guard let id = data["id"] as? String, !id.isEmpty else {
        return "missing or empty id"
    }

    // Require a UUID-format id to match the shared schemas. Prevents a
    // malformed identifier from entering GRDB as a string primary key
    // that later joins/queries against UUID-shaped ids won't match.
    guard UUID(uuidString: id) != nil else {
        return "invalid id format for \(collection)/\(id)"
    }

    // Require a positive integer version — a zero/negative version would
    // always lose LWW, but a non-numeric one could crash the resolver.
    // Reason strings omit the raw version value to stay consistent with
    // the userId-redaction rule below; collection + doc id is enough to
    // triage, and the raw value is one Firestore lookup away if needed.
    let version = toInt(data["version"])
    guard version >= 1 else {
        return "invalid version for \(collection)/\(id)"
    }

    // On user-scoped collections, the userId field must match the
    // authenticated user. Rejecting mismatches keeps a spoofed peer
    // write from corrupting our local row. Reason strings don't include
    // either uid — these messages flow into `syncEvents` (displayed in
    // the playground dashboard) and `log()` (printed to Xcode console),
    // so interpolating the authenticated uid here would leak a stable
    // identifier through any log-collection path.
    if userScopedCollections.contains(collection) {
        let userId = data["userId"] as? String ?? ""
        guard userId == authenticatedUserId else {
            return "userId mismatch for \(collection)/\(id)"
        }
    }

    // Board-integrity PR-2 (Part 3): mirror the shared `BoardTaskSchema`
    // row/col upper bound (0..24 — max grid is 5×5, so 24 is the highest
    // valid 0-based index). A malformed/out-of-range placement from a peer
    // must never reach GRDB — `PlacementIntegrity.resolvePlacements`'s
    // bounds-drop is defense-in-depth at READ time, but rejecting here
    // keeps corrupt rows out of local storage entirely.
    if collection == "boardTasks" {
        let row = toInt(data["row"])
        let col = toInt(data["col"])
        guard (0...24).contains(row), (0...24).contains(col) else {
            return "row/col out of bounds for \(collection)/\(id)"
        }
    }

    return nil
}

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
///
/// Not `private` so `OYBCTests/LwwVectorTests.swift` can run the shared
/// cross-platform vector fixture (`lwwVectors.json`) against it directly
/// via `@testable import OYBC` (workstream C4 / issue #261) — this is
/// the same comparison as `@oybc/shared`'s `resolveConflict`, hand-mirrored
/// here since iOS can't import TypeScript.
///
/// Canon (issue #263): at equal version, if EITHER `updatedAt` is empty or
/// unparseable, remote wins — the extension of the exact-tie→remote rule.
func resolveConflict(
    local: [String: Any],
    remote: [String: Any]
) -> String {
    // Normalize version — GRDB returns Int64, Firestore returns NSNumber or Int
    let localVersion = toInt(local["version"])
    let remoteVersion = toInt(remote["version"])

    if localVersion > remoteVersion { return "local" }
    if remoteVersion > localVersion { return "remote" }

    // Same version — compare updatedAt timestamps via parsed Dates.
    // String comparison is unsafe across timezone formats (Z vs no Z).
    let localUpdatedAt = local["updatedAt"] as? String ?? ""
    let remoteUpdatedAt = remote["updatedAt"] as? String ?? ""
    let localDate = parseISO8601Date(localUpdatedAt)
    let remoteDate = parseISO8601Date(remoteUpdatedAt)

    // Canon (issue #263): at equal version, if EITHER side's updatedAt is
    // unparseable/empty, remote wins (server authority) — an explicit guard,
    // not a string-comparison fallback. The old fallback compared the raw
    // strings when parsing failed, which could return "local" when only the
    // remote timestamp failed to parse (e.g. a real local ISO string sorts
    // lexicographically greater than ""). Production never emits unparseable
    // timestamps; this only pins defensive behavior.
    guard let localDate, let remoteDate else {
        return "remote"
    }

    if localDate > remoteDate { return "local" }

    // Tie or remote is newer — remote wins (server authority).
    return "remote"
}

/// Safely extracts an integer from Any — handles Int, Int64, NSNumber.
private func toInt(_ value: Any?) -> Int {
    if let i = value as? Int { return i }
    if let i64 = value as? Int64 { return Int(i64) }
    if let n = value as? NSNumber { return n.intValue }
    return 0
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

    // MARK: - Published Counters (cumulative since last `start(userId:)`)

    /// Cumulative successful pushes.
    @Published var totalPushed: Int = 0
    /// Cumulative successful pulls (listener apply OR safety-net pull).
    @Published var totalPulled: Int = 0
    /// Cumulative LWW conflicts where remote won.
    @Published var totalConflicts: Int = 0
    /// Cumulative push failures.
    @Published var totalFailed: Int = 0
    /// Most recent successful sync activity (push or pull). `nil` until
    /// the first event of the session. Drives the production-Profile
    /// "Last synced" label via AuthService → @EnvironmentObject.
    @Published var lastEventAt: Date?
    /// Most recent error, if any. Cleared on the next successful event.
    @Published var lastError: SyncErrorRecord?
    /// FAILED items that exhausted their retry budget (`retryCount >=
    /// SyncRetry.maxRetries`). Refreshed after each push cycle via
    /// `refreshExhaustedCount()`; surfaced to the user as "N changes couldn't
    /// sync" with a Retry affordance. `0` means nothing is stuck. Mirrors web
    /// `SyncStatus.exhaustedCount`.
    @Published var exhaustedCount: Int = 0

    /// `lastError` payload — message + timestamp as a value type so it
    /// stays SwiftUI-friendly.
    struct SyncErrorRecord: Equatable {
        let message: String
        let at: Date
    }

    // MARK: - Private

    /// Firestore handle. `lazy` so merely *constructing* a `SyncService`
    /// doesn't touch Firebase — this lets the logic-test bundle (no
    /// `FirebaseApp.configure()` host) instantiate the service to exercise
    /// the GRDB-only pull-apply seam (`applyRemoteSubdoc`). Access stays
    /// serialized on `@MainActor`, so the non-thread-safe `lazy` is safe;
    /// production behaviour is unchanged (the handle is still created on
    /// first network use, before any real sync).
    private lazy var db = Firestore.firestore()

    /// Local database the pull-apply path writes into. Injected (defaulting
    /// to `.shared`) so tests can point the seam at an in-memory
    /// `AppDatabase.makeTestInstance()`. Mirrors the B3 ViewModel injection
    /// precedent; both `SyncService()` call sites keep working via the default.
    private let database: AppDatabase

    /// - Parameter database: Local DB the pull path writes into. Defaults to
    ///   `.shared`; overridden only in tests.
    ///
    /// SCOPE CAVEAT (E3): only `applyRemoteSubdoc` (and everything inside
    /// its transaction) reads this handle — push/fullSync/safety-net still
    /// use `AppDatabase.shared` directly. A test injecting
    /// `makeTestInstance()` may exercise the pull-apply seam ONLY; widening
    /// the injection is a deliberate future step, not an oversight.
    init(database: AppDatabase = .shared) {
        self.database = database
    }

    /// Safety-net interval for the periodic full sync. With push-on-enqueue
    /// + snapshot listeners doing the real-time work, this only needs to
    /// fire occasionally to retry FAILED items, recover stale IN_PROGRESS
    /// rows from a force-quit, and back-stop missed snapshot deliveries.
    ///
    /// DO NOT REMOVE this timer as an "optimization": the pull watermark is
    /// a LOCAL-clock ISO string compared against server `_syncedAt`, so a
    /// clock-skew window exists by design — a doc written during the skew
    /// can slip past the watermark, and this periodic re-pull is the only
    /// mechanism that recovers it. Web twin: `SYNC_SAFETY_NET_MS` in
    /// syncService.ts. See docs/SYNC_STRATEGY.md.
    static let safetyNetInterval: TimeInterval = 5 * 60

    /// Debounce window before a queue-driven push fires. Coalesces bursts
    /// of rapid local writes into a single push.
    private static let pushDebounceMs: UInt64 = 500

    /// Active GRDB observation on pending sync_queue count — drives
    /// push-on-enqueue. Retained for the lifetime of `start(userId:)`.
    private var pendingObservation: DatabaseCancellable?

    /// Active Firestore listener registrations — one per syncable
    /// subcollection plus the parent user doc. Detached on `stop()`.
    private var listenerRegistrations: [ListenerRegistration] = []

    /// Repeating safety-net timer.
    private var safetyNetTask: _Concurrency.Task<Void, Never>?

    /// Pending debounced-push task. Cancelled and replaced on every
    /// queue observation emission while the debounce window is open.
    private var pushDebounceTask: _Concurrency.Task<Void, Never>?

    /// The Task spawned at the end of `start(userId:)` to run the initial
    /// `fullSync`. Tracked so a rapid sign-out (or account switch)
    /// during the await window can cancel it instead of letting it
    /// continue syncing for the previous user.
    private var initialSyncTask: _Concurrency.Task<Void, Never>?

    /// The userId the orchestrator is currently bound to. `nil` means
    /// `start(userId:)` hasn't been called or `stop()` ran. Used for
    /// idempotency — repeat calls with the same userId are no-ops.
    private var runningForUserId: String?

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

        // Use the core (unguarded) push since fullSync already owns the
        // isSyncing flag — calling the public pushSync here would deadlock
        // on the guard.
        let push = await pushSyncCore(userId: userId)
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
    /// Public push entry point — guarded by `isSyncing` so a debounced
    /// second push can't start mid-flight. Mirrors the web sync loop's
    /// guard. `fullSync` (which already owns `isSyncing`) calls
    /// `pushSyncCore` directly to avoid double-locking the flag.
    ///
    /// Without this guard the queue maintenance below could re-queue
    /// items an in-flight push has already marked IN_PROGRESS, causing
    /// duplicate Firestore writes and conflict-handling churn.
    func pushSync(userId: String) async -> PushResult {
        guard !isSyncing else {
            log("Push skipped — another push is in flight")
            return PushResult()
        }
        isSyncing = true
        defer { isSyncing = false }
        return await pushSyncCore(userId: userId)
    }

    /// Inner push implementation. Runs queue maintenance + drains
    /// PENDING items. Caller is responsible for owning the `isSyncing`
    /// flag — both `pushSync` and `fullSync` do.
    private func pushSyncCore(userId: String) async -> PushResult {
        var result = PushResult()

        // Reset stale IN_PROGRESS items (e.g. force-quit mid-push) and
        // promote FAILED items whose backoff window has elapsed back to
        // PENDING so this same push picks them up. Mirrors the web
        // `pushSync` preamble. Promotion also re-fires the GRDB
        // ValueObservation on PENDING count, which schedules the next
        // push-on-enqueue debounce.
        do {
            try AppDatabase.shared.resetStaleInProgressSyncItems()
            try AppDatabase.shared.promoteEligibleFailedSyncItems()
        } catch {
            log("Push warning: queue maintenance failed: \(error.localizedDescription)")
            // Non-fatal — fall through and try to push whatever's already pending.
        }

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

        guard !pendingItems.isEmpty else {
            // Nothing pending, but exhausted FAILED items may still be
            // stranded — refresh so the count reflects reality even on a
            // no-op push.
            refreshExhaustedCount()
            return result
        }

        for item in pendingItems {
            await processPushItem(item, userId: userId, result: &result)
        }

        // pushSyncCore is the single choke point where items transition to
        // (and out of) the FAILED state, so recomputing the exhausted count
        // here covers every caller (fullSync, the debounced push, the manual
        // retry) without a separate poll loop.
        refreshExhaustedCount()

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

        // Pull the parent user doc (`users/{userId}`) so synced profile fields
        // like `preferences` replicate back to this device. Handled outside
        // the subcollection loop because it lives at a different path.
        await processPullUserDocument(userId: userId, result: &result)

        for collection in syncableCollections where collection.firestoreName != "users"
            && !legacyPullSkipCollections.contains(collection.firestoreName) {
            await processPullCollection(
                collection: collection,
                userId: userId,
                lastSyncedAt: lastSyncedAt,
                result: &result
            )
        }

        // Only advance watermark if no pull errors occurred
        let hadErrors = result.details.contains { $0.contains("Pull failed") }
        if !hadErrors {
            // Heal-on-pull (docs/WINDOWED_COMPLETION.md §Heal-on-pull): mint any
            // completion event a fresh install is missing so completed squares
            // don't render incomplete. Gated on a clean pull — a partial pull
            // could be missing a task's real events, and we must not mint over
            // that. Idempotent + self-limiting; before the watermark advances so
            // a mid-heal failure simply re-heals next pull. Counts toward
            // `result.pulled` so the changes-applied refresh fires.
            let healed = healMissingCompletionEvents(userId: userId)
            if healed > 0 {
                result.pulled += healed
                result.details.append("Healed \(healed) missing completion event(s)")
            }

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
        }

        // Board-integrity PR-4 (Item 5): one signal per PULL BATCH (this
        // whole `pullSync` call, covering the user doc + every subcollection),
        // not per row — `result.pulled` already aggregates every applied
        // write across both, including the batched `taskEvents` path.
        if result.pulled > 0 {
            postSyncDidApplyChanges()
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

            // The `users` entity is stored at `users/{userId}` (the scope root),
            // not in a subcollection, and it must never be DELETE-synced — that
            // would wipe the scope for every other collection.
            let isUserEntity = item.entityType == "users"
            let docRef: DocumentReference = isUserEntity
                ? db.collection("users").document(item.entityId)
                : db.collection("users")
                    .document(userId)
                    .collection(item.entityType)
                    .document(item.entityId)

            if isUserEntity && item.operationType == .delete {
                try markCompleted(item)
                let msg = "Skipped delete for users/\(item.entityId)"
                result.details.append(msg)
                log(msg)
                return
            }

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
                        recordEvent(.conflict)
                        let msg = "Delete conflict \(item.entityType)/\(item.entityId): remote wins"
                        result.details.append(msg)
                        log(msg)
                        return
                    }
                }
                try await writeFirestoreDoc(docRef: docRef, data: payload)
                try markCompleted(item)
                result.pushed += 1
                recordEvent(.pushed)
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
                recordEvent(.pushed)
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
                recordEvent(.pushed)
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
                recordEvent(.conflict)
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
            recordEvent(.failed)
            recordError(errorMsg)
            let msg = "Failed \(item.entityType)/\(item.entityId): \(errorMsg)"
            result.details.append(msg)
            log(msg)
        }
    }

    // MARK: - Local-wins re-assert (Board-integrity PR-4, Item 1)

    /// Push does getDoc → (later) setDoc, never a Firestore transaction — two
    /// devices racing the same doc can let a stale write land AFTER a fresher
    /// one. Historically, the next pull's LOCAL-wins resolution was a silent
    /// no-op: nothing ever re-asserted the fresher local version, so the
    /// devices + remote stayed divergent until some UNRELATED edit happened to
    /// bump the row's version again.
    ///
    /// Fix: whenever a pull resolves local-wins, enqueue an UPDATE push for the
    /// local row (the existing `SyncQueueBuilder` coalescer dedupes repeat
    /// enqueues into one PENDING row, so this is idempotent and cheap even on
    /// every 5-minute safety-net pull). This makes divergence self-healing
    /// regardless of push races, for every syncable collection (`taskEvents` is
    /// exempt — see below).
    ///
    /// Deliberately NOT doing: `runTransaction` on the push path — the
    /// offline-first queue + LWW + this re-assert makes a Firestore transaction
    /// redundant, and a transaction would serialize the push loop.
    ///
    /// Not applied to `taskEvents`: that collection's pull path
    /// (`applyTaskEventsBatch`) has its own append-only union-by-id semantics
    /// (docs/WINDOWED_COMPLETION.md §Sync) where a "local wins" outcome for one
    /// event id means this device's copy (create OR tombstone) is already the
    /// converged truth for that id — a stale delivery from before the
    /// tombstone, not a race this needs to correct. Scoped here to the generic
    /// per-collection pull path (`processPullCollection` / `applyRemoteSubdoc`)
    /// and the `users` parent-doc pull path (`processPullUserDocument` /
    /// `applyRemoteUserDoc`), mirroring web's `pullApply.ts` local-wins branch.
    ///
    /// - Parameters:
    ///   - db: GRDB transaction to enqueue into (caller's ongoing write block).
    ///   - entityType: The Firestore subcollection name (or `"users"`).
    ///   - entityId: The document/row id.
    ///   - localData: The LOCAL row that won the conflict (becomes the payload).
    ///   - remoteData: The remote row that lost, used only for the diff guard.
    private func reassertLocalWinIfNeeded(
        db: Database,
        entityType: String,
        entityId: String,
        localData: [String: Any],
        remoteData: [String: Any]
    ) throws {
        // Loop guard: a local-win under `resolveConflict`'s rules already
        // implies version or updatedAt genuinely differs (a byte-identical
        // row can only tie, which resolves to "remote"). This check is
        // defense-in-depth kept explicit so a future change to
        // `resolveConflict` can't silently reintroduce a re-enqueue loop —
        // it is also what the "no enqueue when rows are identical" test
        // pins.
        guard rowsGenuinelyDiffer(local: localData, remote: remoteData) else { return }

        // Build the payload from the TYPED model via the same
        // `SyncQueueBuilder.encodePayload` path every other enqueue uses —
        // NEVER from the raw GRDB row dict. GRDB's `DatabaseValue.storage`
        // has no `.bool` case, so a raw-dict payload serialises booleans as
        // 0/1 integers and leaves JSON-array columns as their stringified
        // column values; web's strict Zod (`z.boolean()`, `z.array`) then
        // rejects the whole doc — silently defeating the reassert (PR-4
        // review Critical C1). The models' custom `encode(to:)` produce
        // wire-correct types.
        guard let payloadStr = try Self.encodedLocalPayload(
            db: db, entityType: entityType, entityId: entityId
        ) else {
            // Drain-only legacy tables (e.g. defaultPools) have no live
            // model path and never need a reassert.
            log("No typed re-assert payload for \(entityType)/\(entityId) — skipped")
            return
        }

        // Always `.update`, even when the local winner is itself a tombstone
        // racing an older live remote: the push transport writes the FULL
        // payload (which carries isDeleted) regardless of the op-type label,
        // and the coalescer treats CREATE/UPDATE distinctions as cosmetic —
        // so a pending .delete coalescing to .update here is label-only, not
        // a resurrection (PR-4 review M2).
        let item = SyncQueueItem(
            id: AppDatabase.generateUUID(),
            entityType: entityType,
            entityId: entityId,
            operationType: .update,
            payload: payloadStr,
            status: .pending,
            retryCount: 0,
            lastError: nil,
            createdAt: AppDatabase.currentTimestamp(),
            lastAttemptAt: nil,
            completedAt: nil,
            priority: 1
        )
        try item.enqueue(db)
    }

    /// Fetch the local row AS ITS TYPED MODEL and encode it with
    /// `SyncQueueBuilder.encodePayload` — the wire-correct JSON every other
    /// enqueue site produces. Returns nil for tables with no live model
    /// (legacy drain-only collections).
    private static func encodedLocalPayload(
        db: Database,
        entityType: String,
        entityId: String
    ) throws -> String? {
        switch entityType {
        case "boards":
            return try Board.fetchOne(db, key: entityId).map(SyncQueueBuilder.encodePayload)
        case "tasks":
            return try Task.fetchOne(db, key: entityId).map(SyncQueueBuilder.encodePayload)
        case "boardTasks":
            return try BoardTask.fetchOne(db, key: entityId).map(SyncQueueBuilder.encodePayload)
        case "compoundChildren":
            return try CompoundChild.fetchOne(db, key: entityId).map(SyncQueueBuilder.encodePayload)
        case "recurringBoardTemplates":
            return try RecurringBoardTemplate.fetchOne(db, key: entityId).map(SyncQueueBuilder.encodePayload)
        case "pools":
            return try Pool.fetchOne(db, key: entityId).map(SyncQueueBuilder.encodePayload)
        case "coreBoardDefaults":
            return try CoreBoardDefault.fetchOne(db, key: entityId).map(SyncQueueBuilder.encodePayload)
        case "users":
            return try User.fetchOne(db, key: entityId).map(SyncQueueBuilder.encodePayload)
        default:
            return nil
        }
    }

    /// Non-transactional wrapper for the two `users` pull paths, which don't
    /// already hold an open `db: Database` (unlike the generic subcollection
    /// paths, which run their whole apply inside one `write { db in }` block).
    /// Opens its own small write — just a `sync_queue` insert/coalesce, no
    /// cascade dependency, so a separate transaction is safe here.
    private func reassertLocalWinIfNeeded(
        entityType: String,
        entityId: String,
        localData: [String: Any],
        remoteData: [String: Any]
    ) throws {
        try AppDatabase.shared.write { db in
            try reassertLocalWinIfNeeded(
                db: db, entityType: entityType, entityId: entityId,
                localData: localData, remoteData: remoteData
            )
        }
    }

    /// True when `local`/`remote` differ in `version` or `updatedAt` — the
    /// only two fields `resolveConflict` actually compares. See
    /// `reassertLocalWinIfNeeded`'s loop-guard comment for why a local-win
    /// already implies this is true; kept as an explicit, independently
    /// testable check rather than relying on that invariant implicitly.
    private func rowsGenuinelyDiffer(local: [String: Any], remote: [String: Any]) -> Bool {
        if toInt(local["version"]) != toInt(remote["version"]) { return true }
        let localUpdatedAt = local["updatedAt"] as? String ?? ""
        let remoteUpdatedAt = remote["updatedAt"] as? String ?? ""
        return localUpdatedAt != remoteUpdatedAt
    }

    // MARK: - Sync-applied live-update signal (Board-integrity PR-4, Item 5)

    /// Posts `.oybcSyncDidApplyChanges` once. `SyncService` is `@MainActor`, so
    /// every call site is already on the main queue/actor — this just makes
    /// the "on main" requirement explicit at the call site rather than
    /// implicit in the class-level `@MainActor`.
    private func postSyncDidApplyChanges() {
        NotificationCenter.default.post(name: .oybcSyncDidApplyChanges, object: nil)
    }

    // MARK: - Pull Helpers

    /// Pulls the parent user document at `users/{userId}` and merges any
    /// remote-wins changes back into the local `users` row. This is the
    /// replication path for synced profile fields such as `preferences`.
    private func processPullUserDocument(
        userId: String,
        result: inout PullResult
    ) async {
        do {
            let docRef = db.collection("users").document(userId)
            let snapshot = try await docRef.getDocument()
            guard snapshot.exists, let remoteData = snapshot.data() else { return }

            let localData = try fetchLocalRecord(grdbTable: "users", id: userId)

            if localData == nil {
                try upsertLocalRecord(grdbTable: "users", data: remoteData)
                result.pulled += 1
                recordEvent(.pulled)
                let msg = "Pulled users/\(userId) (new)"
                result.details.append(msg)
                log(msg)
                return
            }

            let winner = resolveConflict(local: localData!, remote: remoteData)
            if winner == "remote" {
                // Preserve the local `lastSyncedAt` watermark through a pull —
                // it's managed at the end of `pullSync` and shouldn't be
                // clobbered by a stale remote value.
                var merged = remoteData
                if let preservedWatermark = localData!["lastSyncedAt"] {
                    merged["lastSyncedAt"] = preservedWatermark
                }
                try upsertLocalRecord(grdbTable: "users", data: merged)
                result.pulled += 1
                recordEvent(.pulled)
                let remoteV = remoteData["version"] as? Int ?? 0
                let localV = localData!["version"] as? Int ?? 0
                let msg = "Pulled users/\(userId) (remote v\(remoteV) > local v\(localV))"
                result.details.append(msg)
                log(msg)
            } else {
                // Local-wins pull: no remote data was applied, so don't
                // record an observability event. `result.conflicts` still
                // tracks the for-the-cycle-summary count for log parity
                // with the web side; the cumulative counter only ticks
                // when a remote write actually lands.
                result.conflicts += 1
                let localV = localData!["version"] as? Int ?? 0
                let remoteV = remoteData["version"] as? Int ?? 0
                let msg = "Kept local users/\(userId) (local v\(localV) >= remote v\(remoteV))"
                result.details.append(msg)
                log(msg)
                // Board-integrity PR-4 (Item 1): re-assert the fresher local
                // row so a push race that let a stale remote write land
                // can't strand this device's newer data forever.
                try reassertLocalWinIfNeeded(
                    entityType: "users", entityId: userId,
                    localData: localData!, remoteData: remoteData
                )
            }
        } catch {
            let msg = "Pull failed for users/\(userId): \(error.localizedDescription)"
            result.details.append(msg)
            log(msg)
        }
    }

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
                // `_syncedAt` is written via `FieldValue.serverTimestamp()`
                // so it lives in Firestore as a `Timestamp`. The local
                // `lastSyncedAt` watermark is an ISO8601 String. Firestore
                // range queries require type-matched operands — comparing
                // Timestamp > String never matches because String ranks
                // above Timestamp in Firestore's canonical type ordering.
                // Convert to `Timestamp` here (and in the listener attach
                // below). Clock-skew between the local clock at watermark
                // write time and the server clock at doc write time is
                // bounded; the safety-net pull picks up anything missed.
                let formatter = ISO8601DateFormatter()
                let watermarkDate = formatter.date(from: lastSyncedAt) ?? Date(timeIntervalSince1970: 0)
                query = colRef.whereField("_syncedAt", isGreaterThan: Timestamp(date: watermarkDate))
            } else {
                query = colRef // First sync — pull everything.
            }

            let snapshot = try await query.getDocuments()
            guard !snapshot.isEmpty else { return }

            // Windowed Completion (docs §Sync): task events pull in a BATCH —
            // apply all rows, then one recompute per task + one cascade per board.
            if collection.firestoreName == "taskEvents" {
                let batch = applyTaskEventsBatch(
                    userId: userId,
                    rawDocs: snapshot.documents.map { $0.data() }
                )
                result.pulled += batch.pulled
                result.details.append(contentsOf: batch.details)
                for msg in batch.details { log(msg) }
                return
            }

            for docSnap in snapshot.documents {
                let remoteData = docSnap.data()

                // Validate before touching GRDB. A malformed payload (bad
                // version, mismatched userId, missing id) is logged and
                // skipped — the safety-net pull retries next cycle.
                if let reason = validateRemotePullDocument(
                    collection: collection.firestoreName,
                    data: remoteData,
                    authenticatedUserId: userId
                ) {
                    let msg = "Skipped \(collection.firestoreName): \(reason)"
                    result.details.append(msg)
                    log(msg)
                    continue
                }

                guard let remoteId = remoteData["id"] as? String else { continue }

                // Wrap fetch + upsert + cascade in one transaction so a cascade
                // failure rolls back the upsert. Mirrors the listener-path
                // applyRemoteSubdoc structure.
                var pullOutcome: (didWrite: Bool, kind: String)? = nil
                var skipReason: String? = nil
                try AppDatabase.shared.write { db in
                    // CompoundChild parent-userId check (mirrors web + listener).
                    if collection.firestoreName == "compoundChildren" {
                        guard let compoundTaskId = remoteData["compoundTaskId"] as? String, !compoundTaskId.isEmpty else {
                            skipReason = "missing compoundTaskId"
                            return
                        }
                        let parentRow = try Row.fetchOne(
                            db,
                            sql: "SELECT userId FROM tasks WHERE id = ?",
                            arguments: [compoundTaskId]
                        )
                        guard let parentRow = parentRow else {
                            skipReason = "parent compound not yet present locally"
                            return
                        }
                        let parentUserId: String? = parentRow["userId"]
                        guard parentUserId == userId else {
                            skipReason = "parent userId mismatch"
                            return
                        }
                    }

                    let localData = try fetchLocalRecord(db: db, grdbTable: collection.grdbTable, id: remoteId)

                    var didWrite = false
                    if localData == nil {
                        try upsertLocalRecord(db: db, grdbTable: collection.grdbTable, data: remoteData)
                        didWrite = true
                        pullOutcome = (true, "new")
                    } else {
                        // Windowed Completion (docs §Shared counters interaction):
                        // counting-task conflicts resolve by union-of-events (the
                        // batched taskEvents pull recompute), so a pulled Task just
                        // LWW-upserts like any other row. The Phase-4 additive-merge
                        // branch for shared-counter sources was retired (dead code
                        // deleted in WC PR D); `lastSyncedCount` is inert.
                        let winner = resolveConflict(local: localData!, remote: remoteData)
                        if winner == "remote" {
                            try upsertLocalRecord(db: db, grdbTable: collection.grdbTable, data: remoteData)
                            didWrite = true
                            let remoteV = remoteData["version"] as? Int ?? 0
                            let localV = localData!["version"] as? Int ?? 0
                            pullOutcome = (true, "remote v\(remoteV) > local v\(localV)")
                        } else {
                            let localV = localData!["version"] as? Int ?? 0
                            let remoteV = remoteData["version"] as? Int ?? 0
                            pullOutcome = (false, "local v\(localV) >= remote v\(remoteV)")
                            // Board-integrity PR-4 (Item 1): re-assert the
                            // fresher local row so a push race that let a
                            // stale remote write land can't strand this
                            // device's newer data forever. Same transaction
                            // as the (skipped) upsert.
                            try reassertLocalWinIfNeeded(
                                db: db, entityType: collection.firestoreName, entityId: remoteId,
                                localData: localData!, remoteData: remoteData
                            )
                        }
                    }

                    // Pull cascade — same transaction as the upsert so a
                    // cascade error rolls back the upsert.
                    if didWrite {
                        if collection.firestoreName == "tasks" {
                            try runPullCascade(db: db, changedTaskId: remoteId)
                        }
                        if collection.firestoreName == "compoundChildren",
                           let compoundTaskId = remoteData["compoundTaskId"] as? String {
                            try runPullCascade(db: db, changedTaskId: compoundTaskId)
                        }
                        // Board-integrity PR-1 (tombstones, docs/BOARD_INTEGRITY.md):
                        // a pulled `boardTasks` row — live re-placement OR
                        // tombstone — changes the affected board's grid
                        // geometry, so its stats must re-derive in the same
                        // transaction as the upsert. Without this, a pulled
                        // placement change left `completedTasks` /
                        // `completedLineIds` stale on the receiving device
                        // until the next unrelated cascade happened to touch
                        // that board.
                        if collection.firestoreName == "boardTasks",
                           let boardId = remoteData["boardId"] as? String {
                            try runPullCascadeForBoardTask(db: db, boardId: boardId)
                        }
                        // Sealed-board transport convergence: a pulled SEALED
                        // boards doc may carry a stale snapshot (sealed offline
                        // elsewhere with a partial event union). Re-derive THAT
                        // board from the local converged event union bounded at
                        // its own sealedAt — deterministic, local-only (no
                        // version bump / enqueue), inside this transaction.
                        if collection.firestoreName == "boards",
                           remoteData["sealedAt"] is String {
                            try AppDatabase.reDeriveSealedBoardSnapshots(db: db, boardIds: [remoteId])
                        }
                    }
                }

                if let skip = skipReason {
                    let msg = "Skipped \(collection.firestoreName)/\(remoteId): \(skip)"
                    result.details.append(msg)
                    log(msg)
                } else if let outcome = pullOutcome {
                    if outcome.didWrite {
                        result.pulled += 1
                        recordEvent(.pulled)
                        let msg = "Pulled \(collection.firestoreName)/\(remoteId) (\(outcome.kind))"
                        result.details.append(msg)
                        log(msg)
                    } else {
                        result.conflicts += 1
                        let msg = "Kept local \(collection.firestoreName)/\(remoteId) (\(outcome.kind))"
                        result.details.append(msg)
                        log(msg)
                    }
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

        // Indefinite boards carry no `endDate`. Because we write with
        // `merge: true`, simply omitting the field would PRESERVE a stale
        // deadline on Firestore from before a convert-to-indefinite edit —
        // which a second device would then pull, silently un-converting the
        // board. Explicitly delete the field so the remote doc matches the
        // local source of truth. (Harmless no-op on a fresh doc / a board
        // that never had an endDate.)
        if docRef.parent.collectionID == "boards", cleaned["endDate"] == nil {
            cleaned["endDate"] = FieldValue.delete()
        }

        // Same carve-out for `completedAt`: a COMPLETED → ACTIVE revert clears
        // the board's completedAt locally, but under `merge: true` simply
        // omitting the field would leave the stale completion timestamp on
        // Firestore — which a second device would then pull, resurrecting a
        // completedAt on an active board. Explicitly delete it so the remote
        // doc matches the local source of truth. (Harmless no-op on boards
        // that never completed.)
        if docRef.parent.collectionID == "boards", cleaned["completedAt"] == nil {
            cleaned["completedAt"] = FieldValue.delete()
        }

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
        return try AppDatabase.shared.read { db in
            try fetchLocalRecord(db: db, grdbTable: grdbTable, id: id)
        }
    }

    /// Reads against an existing GRDB transaction so callers can compose a
    /// fetch with subsequent writes (e.g. pull-path upsert + cascade) inside
    /// a single atomic block.
    private func fetchLocalRecord(db: Database, grdbTable: String, id: String) throws -> [String: Any]? {
        guard allowedGRDBTables.contains(grdbTable) else {
            throw SyncError.invalidPayload("Unknown table: \(grdbTable)")
        }
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
        try AppDatabase.shared.write { db in
            try upsertLocalRecord(db: db, grdbTable: grdbTable, data: data)
        }
    }

    /// Performs the upsert against an existing GRDB write transaction. Lets
    /// callers compose multiple writes (e.g. upsert + pull cascade) into a
    /// single atomic block so a downstream failure rolls back everything.
    private func upsertLocalRecord(db: Database, grdbTable: String, data: [String: Any]) throws {
        guard allowedGRDBTables.contains(grdbTable) else {
            throw SyncError.invalidPayload("Unknown table: \(grdbTable)")
        }
        // Filter out Firestore metadata fields that don't exist in GRDB.
        var cleaned = data
        cleaned.removeValue(forKey: "_syncedAt")

        guard !cleaned.isEmpty else { return }
        guard cleaned["id"] is String else {
            throw SyncError.invalidPayload("Document missing 'id' field for \(grdbTable) upsert")
        }

        // Validate all keys are safe SQL identifiers to prevent injection
        var keys = Array(cleaned.keys).filter { key in
            key.range(of: "^[a-zA-Z_][a-zA-Z0-9_]*$", options: .regularExpression) != nil
        }
        guard !keys.isEmpty else {
            throw SyncError.invalidPayload("No valid column names for \(grdbTable) upsert")
        }

        // Drop columns the local schema doesn't have. Firestore stores
        // documents as the schema was when they were written, so a
        // pre-Compound-Tasks-Unification BoardTask doc still carries
        // `isCompleted` / `completedAt` / `currentCount` even though
        // those columns were dropped from `board_tasks` in v7. A raw
        // INSERT against those columns crashes with "table X has no
        // column named Y". Web is unaffected because Zod's `safeParse`
        // strips unknown keys by default; iOS bypasses validation and
        // INSERTs raw, so we strip here for parity.
        let validColumns = try Self.columnNames(for: grdbTable, in: db)
        keys = keys.filter { validColumns.contains($0) }
        guard !keys.isEmpty else {
            throw SyncError.invalidPayload(
                "No columns match the local schema for \(grdbTable) upsert"
            )
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

        try db.execute(sql: sql, arguments: StatementArguments(values))

        // Pull is a full-entity replace: the remote doc is the source of truth.
        // The upsert above only SETs columns PRESENT in the remote doc, so an
        // indefinite board (whose endDate field was deleted on Firestore) would
        // leave a STALE endDate on an existing local row — making it
        // `timeframe = indefinite` yet still carrying a deadline. Explicitly
        // clear it so the local row matches the remote. Mirrors the push-side
        // FieldValue.delete(); harmless when the row already had no endDate.
        if grdbTable == "boards", cleaned["endDate"] == nil,
           let boardId = cleaned["id"] as? String {
            try db.execute(
                sql: "UPDATE \"boards\" SET endDate = NULL WHERE id = ?",
                arguments: [boardId]
            )
        }

        // Same replace semantics for `completedAt`: a remote boards doc whose
        // completedAt was FieldValue.delete()-ed (COMPLETED → ACTIVE revert on
        // the authoring device) must clear the stale local timestamp too —
        // otherwise the row reads `status = active` yet still carries a
        // completedAt. Mirrors the push-side carve-out above; harmless when
        // the local row never had one.
        if grdbTable == "boards", cleaned["completedAt"] == nil,
           let boardId = cleaned["id"] as? String {
            try db.execute(
                sql: "UPDATE \"boards\" SET completedAt = NULL WHERE id = ?",
                arguments: [boardId]
            )
        }
    }

    /// Cached per-table column names. Populated lazily on first lookup
    /// per table via `PRAGMA table_info`. Reads happen frequently
    /// (every pull / listener apply) so caching avoids hitting SQLite
    /// for the metadata over and over. Migrations don't run at runtime
    /// in production, so cache invalidation isn't needed; if a future
    /// dev flow ever mutates the schema mid-session, restart the app.
    private static let columnNameCache = NSCache<NSString, NSSet>()

    /// Returns the set of column names for `table` in the given GRDB
    /// `db`. Uses `PRAGMA table_info` so the result automatically
    /// tracks schema migrations — no hardcoded duplicate of the column
    /// list to keep in sync as columns are added or dropped.
    private static func columnNames(for table: String, in db: Database) throws -> Set<String> {
        let key = NSString(string: table)
        if let cached = columnNameCache.object(forKey: key) as? Set<String> {
            return cached
        }
        // PRAGMA table_info("name") returns one row per column.
        // Bind via the SQL string because PRAGMA doesn't accept ? bind
        // parameters for the table name. `table` is sourced from
        // `syncableCollections` (allowedGRDBTables) which is a closed
        // set of compile-time-known names — no injection risk.
        let rows = try Row.fetchAll(
            db,
            sql: "PRAGMA table_info(\"\(table)\")"
        )
        let names = Set(rows.compactMap { $0["name"] as String? })
        columnNameCache.setObject(NSSet(set: names), forKey: key)
        return names
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
        dlog("[SyncService] \(message)")
    }
}

// MARK: - Real-time orchestration

extension SyncService {

    /// Start the real-time sync orchestrator for the signed-in user.
    /// Idempotent — repeat calls with the same `userId` are no-ops, and a
    /// call with a different `userId` tears the previous instance down
    /// first (covers account-switching).
    ///
    /// On start:
    /// - A GRDB `ValueObservation` watches the count of PENDING sync queue
    ///   items and schedules a debounced push whenever it grows.
    /// - A Firestore snapshot listener is opened on the parent
    ///   `users/{userId}` doc and on each syncable subcollection. Each
    ///   listener feeds remote changes through the same apply helpers
    ///   that `pullSync` uses, so all incoming-write logic is unified.
    /// - A safety-net timer fires `fullSync` every 5 minutes to recover
    ///   stuck queue items and back-stop any missed snapshot delivery.
    /// - An immediate `fullSync` runs once to handle anything queued
    ///   before this call (e.g. writes made while signed out).
    func start(userId: String) {
        if runningForUserId == userId { return }
        if runningForUserId != nil { stop() }
        runningForUserId = userId

        startQueueObservation(userId: userId)
        attachPullListeners(userId: userId)
        startSafetyNetTimer(userId: userId)

        // Initial sync covers anything that was queued before start was
        // called, plus first-attach delivery from the listeners. Tracked
        // and gated on `runningForUserId == userId` so a rapid sign-out
        // can both cancel and short-circuit it before it touches Firestore
        // for the wrong user.
        initialSyncTask?.cancel()
        initialSyncTask = _Concurrency.Task { [weak self] in
            guard let self, self.runningForUserId == userId else { return }
            _ = await self.fullSync(userId: userId)
        }
    }

    /// Stop the orchestrator and tear down every registered observer /
    /// listener / timer. Safe to call when not running.
    func stop() {
        runningForUserId = nil

        pendingObservation?.cancel()
        pendingObservation = nil

        for reg in listenerRegistrations { reg.remove() }
        listenerRegistrations.removeAll()

        safetyNetTask?.cancel()
        safetyNetTask = nil

        pushDebounceTask?.cancel()
        pushDebounceTask = nil

        initialSyncTask?.cancel()
        initialSyncTask = nil

        // Counters are session-scoped — drop them so the next sign-in
        // starts from zero.
        totalPushed = 0
        totalPulled = 0
        totalConflicts = 0
        totalFailed = 0
        lastEventAt = nil
        lastError = nil
        exhaustedCount = 0
    }

    // MARK: - Observability helpers

    /// Record a successful sync event, incrementing the matching
    /// counter and advancing `lastEventAt`. Successful events also
    /// clear the `lastError` slot so the UI doesn't show a stale error
    /// after recovery. Mirrors web `recordSyncEvent`.
    fileprivate func recordEvent(_ kind: SyncEventKind, at: Date = Date()) {
        switch kind {
        case .pushed:   totalPushed += 1
        case .pulled:   totalPulled += 1
        case .conflict: totalConflicts += 1
        case .failed:   totalFailed += 1
        }
        if kind != .failed {
            lastEventAt = at
            lastError = nil
        }
    }

    /// Record an error message + timestamp. Doesn't increment any
    /// counter. Mirrors web `recordSyncError`.
    fileprivate func recordError(_ message: String, at: Date = Date()) {
        lastError = SyncErrorRecord(message: message, at: at)
    }

    /// Recompute `exhaustedCount` from the local DB. Called at the end of
    /// every push cycle (the choke point) so the UI stays fresh without a
    /// separate poll loop. Non-fatal on read failure — leaves the last
    /// known value rather than crashing the push. Mirrors web
    /// `setExhaustedCount(await countExhaustedSyncItems())`.
    fileprivate func refreshExhaustedCount() {
        do {
            exhaustedCount = try AppDatabase.shared.countExhaustedSyncItems()
        } catch {
            log("Warning: could not count exhausted sync items: \(error.localizedDescription)")
        }
    }

    /// Manually recover items stuck past the retry cap: reset them to a
    /// fresh PENDING state, refresh the count for immediate UI feedback,
    /// then run a full sync for an immediate push. Backs the sync sheet's
    /// "Retry" button AND the network-regain auto-recovery. Mirrors the web
    /// SyncStatusIndicator retry handler (`retryExhaustedSyncItems` +
    /// `fullSync`) and `handleOnline`.
    ///
    /// - Parameter userId: The authenticated user's Firestore UID.
    func retryExhaustedItems(userId: String) async {
        do {
            _ = try AppDatabase.shared.retryExhaustedSyncItems()
        } catch {
            log("Retry exhausted failed: \(error.localizedDescription)")
            return
        }
        // Immediate feedback: the reset cleared the exhausted rows.
        refreshExhaustedCount()
        // Push them now rather than waiting for the debounce/safety-net.
        _ = await fullSync(userId: userId)
    }
}

enum SyncEventKind {
    case pushed
    case pulled
    case conflict
    case failed
}

extension SyncService {

    // MARK: - Push-on-enqueue (queue observation)

    private func startQueueObservation(userId: String) {
        let observation = ValueObservation.tracking { db in
            try SyncQueueItem
                .filter(Column("status") == SyncStatus.pending.rawValue)
                .fetchCount(db)
        }
        pendingObservation = observation.start(
            in: AppDatabase.shared.dbQueue,
            onError: { [weak self] error in
                _Concurrency.Task { @MainActor in
                    self?.log("Queue observation error: \(error.localizedDescription)")
                }
            },
            onChange: { [weak self] count in
                guard let self else { return }
                _Concurrency.Task { @MainActor in
                    if count > 0 { self.scheduleDebouncedPush(userId: userId) }
                }
            }
        )
    }

    /// Cancel any pending debounce, then schedule a push after the
    /// debounce window. Repeated calls within the window collapse into a
    /// single push.
    private func scheduleDebouncedPush(userId: String) {
        pushDebounceTask?.cancel()
        pushDebounceTask = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(nanoseconds: Self.pushDebounceMs * 1_000_000)
            guard !_Concurrency.Task.isCancelled, let self else { return }
            _ = await self.pushSync(userId: userId)
        }
    }

    // MARK: - Pull listeners

    private func attachPullListeners(userId: String) {
        // Parent user doc — single document, no watermark filter.
        let userRef = db.collection("users").document(userId)
        let userListener = userRef.addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }
            if let error {
                _Concurrency.Task { @MainActor in
                    self.log("users/\(userId) listener error: \(error.localizedDescription)")
                }
                return
            }
            guard let snapshot, snapshot.exists, let data = snapshot.data() else { return }
            _Concurrency.Task { @MainActor in
                let applied = self.applyRemoteUserDoc(userId: userId, remoteData: data)
                // Board-integrity PR-4 (Item 5): only a real local write is
                // "applied" — a local-win re-assert enqueues a push but
                // changes nothing in local GRDB, so it shouldn't wake up a
                // reload with no new data to show.
                if applied { self.postSyncDidApplyChanges() }
            }
        }
        listenerRegistrations.append(userListener)

        // One listener per subcollection. Filter by `_syncedAt` so the
        // initial attach is bounded to deltas since the last safety-net
        // watermark advance. (Web mirror normalised on `_syncedAt`; iOS
        // historically used `updatedAt` — unifying here.)
        //
        // `_syncedAt` is a Firestore `Timestamp`; the local watermark is
        // an ISO8601 String. Comparing them directly in a range query
        // never matches (canonical type ordering). Convert to Timestamp.
        let formatter = ISO8601DateFormatter()
        let watermarkString = (try? AppDatabase.shared.fetchUser(id: userId)?.lastSyncedAt) ?? ""
        let watermarkDate = formatter.date(from: watermarkString) ?? Date(timeIntervalSince1970: 0)
        let watermarkTs = Timestamp(date: watermarkDate)

        for collection in syncableCollections where collection.firestoreName != "users"
            && !legacyPullSkipCollections.contains(collection.firestoreName) {
            let colRef = db.collection("users").document(userId).collection(collection.firestoreName)
            let q = colRef.whereField("_syncedAt", isGreaterThan: watermarkTs)
            let listener = q.addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    _Concurrency.Task { @MainActor in
                        self.log("\(collection.firestoreName) listener error: \(error.localizedDescription)")
                    }
                    return
                }
                guard let snapshot else { return }
                // Windowed Completion (docs §Sync): batch task-event deliveries
                // so the recompute + cascade runs once per snapshot, not once per
                // event row (and out-of-order events-before-task are skipped +
                // deferred to the safety-net pull).
                if collection.firestoreName == "taskEvents" {
                    let rows = snapshot.documentChanges
                        .filter { $0.type != .removed }
                        .map { $0.document.data() }
                    if !rows.isEmpty {
                        _Concurrency.Task { @MainActor in
                            let batch = self.applyTaskEventsBatch(userId: userId, rawDocs: rows)
                            for msg in batch.details { self.log(msg) }
                            // Board-integrity PR-4 (Item 5): one signal per
                            // batched delivery, not per event row.
                            if batch.pulled > 0 { self.postSyncDidApplyChanges() }
                        }
                    }
                    return
                }
                // Board-integrity PR-4 (Item 5): apply every changed doc in
                // THIS delivery inside one Task, then post at most once for
                // the whole batch — previously each changed doc spawned its
                // own independent `Task`, which would have meant one
                // notification per row instead of per snapshot.
                let changedDocs = snapshot.documentChanges
                    .filter { $0.type != .removed }
                    .map { $0.document.data() }
                guard !changedDocs.isEmpty else { return }
                _Concurrency.Task { @MainActor in
                    var appliedAny = false
                    for data in changedDocs {
                        let applied = self.applyRemoteSubdoc(
                            collection: collection,
                            remoteData: data,
                            authenticatedUserId: userId
                        )
                        if applied { appliedAny = true }
                    }
                    if appliedAny { self.postSyncDidApplyChanges() }
                }
            }
            listenerRegistrations.append(listener)
        }
    }

    /// Apply a remote `users/{userId}` payload to the local row, running
    /// the same LWW resolution as `processPullUserDocument` but invoked
    /// from a real-time snapshot rather than a scheduled poll.
    ///
    /// - Returns: `true` if a remote value was written to local GRDB (new or
    ///   remote-wins) — the signal callers use to decide whether to post
    ///   `.oybcSyncDidApplyChanges` (Board-integrity PR-4, Item 5). A
    ///   local-win re-assert enqueues a push but returns `false`: nothing in
    ///   local GRDB changed, so there is nothing new for a screen to reload.
    @discardableResult
    private func applyRemoteUserDoc(userId: String, remoteData: [String: Any]) -> Bool {
        do {
            let localData = try fetchLocalRecord(grdbTable: "users", id: userId)
            if localData == nil {
                try upsertLocalRecord(grdbTable: "users", data: remoteData)
                recordEvent(.pulled)
                log("Pulled users/\(userId) (new, listener)")
                return true
            }
            let winner = resolveConflict(local: localData!, remote: remoteData)
            if winner == "remote" {
                var merged = remoteData
                if let preservedWatermark = localData!["lastSyncedAt"] {
                    merged["lastSyncedAt"] = preservedWatermark
                }
                try upsertLocalRecord(grdbTable: "users", data: merged)
                recordEvent(.pulled)
                let remoteV = remoteData["version"] as? Int ?? 0
                let localV = localData!["version"] as? Int ?? 0
                log("Pulled users/\(userId) (remote v\(remoteV) > local v\(localV), listener)")
                return true
            }
            // local-wins is a silent no-op for listener traffic — would
            // otherwise spam the event log on every echo. Board-integrity
            // PR-4 (Item 1): still re-assert the fresher local row so a push
            // race can't strand it.
            try reassertLocalWinIfNeeded(
                entityType: "users", entityId: userId,
                localData: localData!, remoteData: remoteData
            )
            return false
        } catch {
            log("Listener apply failed for users/\(userId): \(error.localizedDescription)")
            return false
        }
    }

    /// Not `private` so `OYBCTests/SyncPullApplyTests.swift` can drive the
    /// pull-apply seam directly with crafted remote dicts (C4 widening
    /// precedent). Writes into the injected `database`.
    ///
    /// - Returns: `true` if a remote value was written to local GRDB (new or
    ///   remote-wins) — the signal callers use to decide whether to post
    ///   `.oybcSyncDidApplyChanges` (Board-integrity PR-4, Item 5). A
    ///   local-win re-assert enqueues a push but returns `false`: nothing in
    ///   local GRDB changed, so there is nothing new for a screen to reload.
    @discardableResult
    func applyRemoteSubdoc(
        collection: (firestoreName: String, grdbTable: String),
        remoteData: [String: Any],
        authenticatedUserId: String
    ) -> Bool {
        // Validate before touching GRDB. A malformed payload (bad version,
        // mismatched userId, missing id) is logged and dropped — the
        // safety-net pull will retry from Firestore on the next cycle.
        if let reason = validateRemotePullDocument(
            collection: collection.firestoreName,
            data: remoteData,
            authenticatedUserId: authenticatedUserId
        ) {
            log("Listener skipped \(collection.firestoreName): \(reason)")
            return false
        }

        guard let remoteId = remoteData["id"] as? String else { return false }
        do {
            // Wrap fetch + upsert + cascade in one transaction so a cascade
            // failure rolls back the upsert. Previously the cascade ran in a
            // separate write tx and its catch swallowed errors — leaving the
            // task applied locally but board stats stale forever, with no
            // safety net to reconcile.
            return try database.write { db -> Bool in
                // CompoundChild has no userId column — children scope through
                // their parent compound's userId. A crafted Firestore doc with
                // a compoundTaskId pointing at another user's compound would
                // land locally with no direct check. Resolve the parent and
                // skip on mismatch (mirrors web).
                if collection.firestoreName == "compoundChildren" {
                    guard let compoundTaskId = remoteData["compoundTaskId"] as? String, !compoundTaskId.isEmpty else {
                        log("Listener skipped compoundChildren/\(remoteId): missing compoundTaskId")
                        return false
                    }
                    let parentRow = try Row.fetchOne(
                        db,
                        sql: "SELECT userId FROM tasks WHERE id = ?",
                        arguments: [compoundTaskId]
                    )
                    guard let parentRow = parentRow else {
                        // No local parent yet — could be a cross-device race.
                        // Defer; safety-net pull retries.
                        log("Listener skipped compoundChildren/\(remoteId): parent compound not yet present locally")
                        return false
                    }
                    let parentUserId: String? = parentRow["userId"]
                    guard parentUserId == authenticatedUserId else {
                        log("Listener skipped compoundChildren/\(remoteId): parent userId mismatch")
                        return false
                    }
                }

                let localData = try fetchLocalRecord(db: db, grdbTable: collection.grdbTable, id: remoteId)
                var didWrite = false
                if localData == nil {
                    try upsertLocalRecord(db: db, grdbTable: collection.grdbTable, data: remoteData)
                    didWrite = true
                    log("Pulled \(collection.firestoreName)/\(remoteId) (new, listener)")
                } else {
                    // Windowed Completion (docs §Shared counters interaction):
                    // counting-task conflicts resolve by union-of-events, so a
                    // pulled Task just LWW-upserts. The Phase-4 additive-merge
                    // branch was retired (dead code deleted in WC PR D);
                    // `lastSyncedCount` is inert.
                    let winner = resolveConflict(local: localData!, remote: remoteData)
                    if winner == "remote" {
                        try upsertLocalRecord(db: db, grdbTable: collection.grdbTable, data: remoteData)
                        didWrite = true
                        let remoteV = remoteData["version"] as? Int ?? 0
                        let localV = localData!["version"] as? Int ?? 0
                        log("Pulled \(collection.firestoreName)/\(remoteId) (remote v\(remoteV) > local v\(localV), listener)")
                    } else {
                        // Board-integrity PR-4 (Item 1): re-assert the
                        // fresher local row so a push race that let a stale
                        // remote write land can't strand this device's newer
                        // data forever. Same transaction as the (skipped)
                        // upsert.
                        try reassertLocalWinIfNeeded(
                            db: db, entityType: collection.firestoreName, entityId: remoteId,
                            localData: localData!, remoteData: remoteData
                        )
                    }
                }
                // Pull cascade — runs in the same transaction as the upsert so
                // a cascade error rolls back the upsert. Task.version is NOT
                // bumped — the pulled value is authoritative (except additive merge
                // which writes a new local version above).
                if didWrite {
                    if collection.firestoreName == "tasks" {
                        try runPullCascade(db: db, changedTaskId: remoteId)
                    }
                    if collection.firestoreName == "compoundChildren",
                       let compoundTaskId = remoteData["compoundTaskId"] as? String {
                        try runPullCascade(db: db, changedTaskId: compoundTaskId)
                    }
                    // Board-integrity PR-1 (tombstones) — see the batch pull
                    // path (`processPullCollection`) for rationale. Same
                    // deterministic, same-transaction semantics.
                    if collection.firestoreName == "boardTasks",
                       let boardId = remoteData["boardId"] as? String {
                        try runPullCascadeForBoardTask(db: db, boardId: boardId)
                    }
                    // Sealed-board transport convergence — see the batch pull
                    // path (`processPullCollection`) for rationale. Same
                    // deterministic, local-only, same-transaction semantics.
                    if collection.firestoreName == "boards",
                       remoteData["sealedAt"] is String {
                        try AppDatabase.reDeriveSealedBoardSnapshots(db: db, boardIds: [remoteId])
                    }
                    recordEvent(.pulled)
                }
                return didWrite
            }
        } catch {
            log("Listener apply failed for \(collection.firestoreName)/\(remoteId): \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Pull Cascade

    /// Run the derivation pass for a Task whose state just changed via pull.
    ///
    /// Recomputes board stats + enqueues board sync for every board affected
    /// by this task (directly or via a compound). Does NOT bump Task.version —
    /// the pulled value is authoritative.
    ///
    /// **Throws** on any cascade failure so the caller's enclosing transaction
    /// rolls back the upserted row. Without this, a cascade failure would leave
    /// the task applied locally but board stats stale forever — a silent
    /// divergence with no safety net.
    ///
    /// - Parameters:
    ///   - db: GRDB transaction in which to perform the cascade. Caller is
    ///         responsible for the enclosing `write { db in ... }` block.
    ///   - changedTaskId: The id of the Task that was just upserted.
    private func runPullCascade(db: Database, changedTaskId: String) throws {
        // Fetch lookups needed by DerivationPass.
        let allChildren: [CompoundChild] = try CompoundChild
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allBoardTasks: [BoardTask] = try BoardTask
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allTasks: [Task] = try Task.fetchAll(db)
        // Phase 6.3 — same rationale as runBoardCascadeForTaskWithResults
        // (AppDatabase+Tasks): feed the workspace's boards into the
        // derivation pass so the specific-board / recurring-template
        // achievement branches evaluate against real cross-board state
        // rather than degrading to "incomplete".
        let allBoards: [Board] = try Board.fetchAll(db)
        // Windowed Completion — group events once so every board evaluates
        // windowed on the pull path too (docs §Sync).
        let windowContext = try AppDatabase.buildWindowContext(db: db)

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
            guard let board = try Board.fetchOne(db, key: boardId), !board.isDeleted, board.sealedAt == nil else { continue }
            // Board-integrity PR-2 (issue #375): resolve collisions/OOB before
            // deriving, so persisted stats can never disagree with the render.
            let boardTasksOnBoard = PlacementIntegrity.resolvedRows(
                boardId: boardId, in: allBoardTasks, boardSize: board.boardSize
            )
            let update = DerivationPass.computeBoardStatsUpdate(
                board: board,
                boardTasksOnBoard: boardTasksOnBoard,
                childrenByCompound: childrenByCompound,
                taskById: taskById,
                allBoards: allBoards,
                windowContext: windowContext
            )

            // Write board stats. Bump board.version (local write), NOT Task.version.
            let now = AppDatabase.currentTimestamp()
            let completedLineIdsJson = encodePullCascadeJSONArray(update.completedLineIds)
            try db.execute(sql: """
                UPDATE boards
                SET completedTasks = ?, linesCompleted = ?, completedLineIds = ?,
                    updatedAt = ?, version = version + 1
                WHERE id = ?
                """, arguments: [
                    update.completedTasks,
                    update.linesCompleted,
                    completedLineIdsJson,
                    now,
                    boardId
                ])

            // Enqueue board sync so the updated stats reach Firestore.
            if let updatedBoard = try Board.fetchOne(db, key: boardId) {
                let payload = try JSONEncoder().encode(updatedBoard)
                let payloadStr = String(data: payload, encoding: .utf8) ?? "{}"
                try db.execute(sql: """
                    INSERT INTO sync_queue
                        (id, entityType, entityId, operationType, payload, status, retryCount, createdAt, priority)
                    VALUES (?, 'boards', ?, 'update', ?, 'pending', 0, ?, 0)
                    """, arguments: [UUID().uuidString, boardId, payloadStr, now])
            }
        }
    }

    /// Board-integrity PR-1 (tombstones, docs/BOARD_INTEGRITY.md) — the
    /// `boardTasks`-pull cascade. A pulled `board_tasks` row — a LIVE
    /// re-placement or a tombstone — changes ONE board's grid geometry
    /// directly (unlike a `tasks` pull, which fans out via
    /// `findAffectedBoardIds`). Recomputes that board's stats + enqueues its
    /// sync, mirroring `runPullCascade`'s write shape exactly (same raw-SQL
    /// UPDATE + sync_queue INSERT, no GREENLOG status transition — the pull
    /// cascades never flip board status, consistent with `runPullCascade`/
    /// `runPullCascadeForTasks`).
    ///
    /// Sealed boards: `computeBoardStatsUpdate`'s live path is for ACTIVE
    /// boards only, so a sealed board takes the SAME sealed-transport-
    /// convergence branch the `boards`-collection pull uses
    /// (`reDeriveSealedBoardSnapshots`) instead of the live write below —
    /// keeping a sealed snapshot coherent when a late/offline placement
    /// change for a placed task arrives after the seal.
    ///
    /// **Throws** on any cascade failure so the caller's enclosing
    /// transaction rolls back the upserted row (same contract as
    /// `runPullCascade`).
    ///
    /// - Parameters:
    ///   - db: GRDB transaction in which to perform the cascade. Caller is
    ///         responsible for the enclosing `write { db in ... }` block.
    ///   - boardId: The `boardId` of the `BoardTask` row that was just upserted.
    private func runPullCascadeForBoardTask(db: Database, boardId: String) throws {
        guard let board = try Board.fetchOne(db, key: boardId), !board.isDeleted else { return }

        if board.sealedAt != nil {
            try AppDatabase.reDeriveSealedBoardSnapshots(db: db, boardIds: [boardId])
            return
        }

        let allChildren: [CompoundChild] = try CompoundChild
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allBoardTasks: [BoardTask] = try BoardTask
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allTasks: [Task] = try Task.fetchAll(db)
        let allBoards: [Board] = try Board.fetchAll(db)
        let windowContext = try AppDatabase.buildWindowContext(db: db)

        var taskById: [String: Task] = [:]
        for t in allTasks { taskById[t.id] = t }
        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in allChildren {
            childrenByCompound[c.compoundTaskId, default: []].append(c)
        }

        // Board-integrity PR-2 (issue #375): resolve collisions/OOB before
        // deriving, so persisted stats can never disagree with the render.
        let boardTasksOnBoard = PlacementIntegrity.resolvedRows(
            boardId: boardId, in: allBoardTasks, boardSize: board.boardSize
        )
        let update = DerivationPass.computeBoardStatsUpdate(
            board: board,
            boardTasksOnBoard: boardTasksOnBoard,
            childrenByCompound: childrenByCompound,
            taskById: taskById,
            allBoards: allBoards,
            windowContext: windowContext
        )

        let now = AppDatabase.currentTimestamp()
        let completedLineIdsJson = encodePullCascadeJSONArray(update.completedLineIds)
        try db.execute(sql: """
            UPDATE boards
            SET completedTasks = ?, linesCompleted = ?, completedLineIds = ?,
                updatedAt = ?, version = version + 1
            WHERE id = ?
            """, arguments: [
                update.completedTasks,
                update.linesCompleted,
                completedLineIdsJson,
                now,
                boardId
            ])

        if let updatedBoard = try Board.fetchOne(db, key: boardId) {
            let payload = try JSONEncoder().encode(updatedBoard)
            let payloadStr = String(data: payload, encoding: .utf8) ?? "{}"
            try db.execute(sql: """
                INSERT INTO sync_queue
                    (id, entityType, entityId, operationType, payload, status, retryCount, createdAt, priority)
                VALUES (?, 'boards', ?, 'update', ?, 'pending', 0, ?, 0)
                """, arguments: [UUID().uuidString, boardId, payloadStr, now])
        }
    }

    /// Batched multi-task pull cascade (Windowed Completion, docs §Sync —
    /// "recompute each affected task's caches once, then run ONE derivation pass
    /// per affected live board"). Unions the boards affected across every changed
    /// task and recomputes each exactly once, with the windowed event context
    /// built once. Same transaction contract + write shape as `runPullCascade`.
    ///
    /// - Parameters:
    ///   - db: GRDB write transaction.
    ///   - changedTaskIds: The tasks whose state changed (deduped internally).
    private func runPullCascadeForTasks(db: Database, changedTaskIds: Set<String>) throws {
        let allChildren: [CompoundChild] = try CompoundChild
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allBoardTasks: [BoardTask] = try BoardTask
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allTasks: [Task] = try Task.fetchAll(db)
        let allBoards: [Board] = try Board.fetchAll(db)
        let windowContext = try AppDatabase.buildWindowContext(db: db)

        var taskById: [String: Task] = [:]
        for t in allTasks { taskById[t.id] = t }
        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in allChildren { childrenByCompound[c.compoundTaskId, default: []].append(c) }

        // Union of affected boards across every changed task.
        var affectedBoardIds = Set<String>()
        for changedTaskId in changedTaskIds {
            let parentCompounds = DerivationPass.findTransitiveParentCompounds(
                changedTaskId: changedTaskId, children: allChildren
            )
            affectedBoardIds.formUnion(DerivationPass.findAffectedBoardIds(
                changedTaskId: changedTaskId, parentCompounds: parentCompounds, boardTasks: allBoardTasks
            ))
        }

        let now = AppDatabase.currentTimestamp()
        for boardId in affectedBoardIds {
            guard let board = try Board.fetchOne(db, key: boardId), !board.isDeleted, board.sealedAt == nil else { continue }
            // Board-integrity PR-2 (issue #375): resolve collisions/OOB before
            // deriving, so persisted stats can never disagree with the render.
            let boardTasksOnBoard = PlacementIntegrity.resolvedRows(
                boardId: boardId, in: allBoardTasks, boardSize: board.boardSize
            )
            let update = DerivationPass.computeBoardStatsUpdate(
                board: board,
                boardTasksOnBoard: boardTasksOnBoard,
                childrenByCompound: childrenByCompound,
                taskById: taskById,
                allBoards: allBoards,
                windowContext: windowContext
            )
            let completedLineIdsJson = encodePullCascadeJSONArray(update.completedLineIds)
            try db.execute(sql: """
                UPDATE boards
                SET completedTasks = ?, linesCompleted = ?, completedLineIds = ?,
                    updatedAt = ?, version = version + 1
                WHERE id = ?
                """, arguments: [update.completedTasks, update.linesCompleted, completedLineIdsJson, now, boardId])
            if let updatedBoard = try Board.fetchOne(db, key: boardId) {
                let payload = try JSONEncoder().encode(updatedBoard)
                let payloadStr = String(data: payload, encoding: .utf8) ?? "{}"
                try db.execute(sql: """
                    INSERT INTO sync_queue
                        (id, entityType, entityId, operationType, payload, status, retryCount, createdAt, priority)
                    VALUES (?, 'boards', ?, 'update', ?, 'pending', 0, ?, 0)
                    """, arguments: [UUID().uuidString, boardId, payloadStr, now])
            }
        }
    }

    /// Batched pull-path handler for the `taskEvents` collection (Windowed
    /// Completion, docs §Sync — "Batched pull-path recompute"). Twin of web's
    /// `applyTaskEventsBatch`: apply ALL pulled event rows first, then recompute
    /// each affected event-owning task's caches ONCE and run ONE derivation pass
    /// per affected board — all inside a single transaction (the atomic pull-path
    /// invariant).
    ///
    /// Pull ordering (docs §Sync): a `taskEvent` can arrive before its `Task`
    /// row. Such events are still upserted as rows but SKIPPED by the recompute
    /// (events-before-task) — the safety-net pull picks them up once the Task
    /// lands.
    ///
    /// - Parameters:
    ///   - userId: The authenticated user's uid (for the userId scope check).
    ///   - rawDocs: The untrusted raw event documents from Firestore.
    /// - Returns: Pulled-row count + per-row skip/status details.
    @discardableResult
    func applyTaskEventsBatch(userId: String, rawDocs: [[String: Any]]) -> (pulled: Int, details: [String]) {
        var details: [String] = []

        // 1. Validate + userId-scope every incoming row (no DB access yet).
        var valid: [[String: Any]] = []
        for raw in rawDocs {
            if let reason = validateRemotePullDocument(
                collection: "taskEvents", data: raw, authenticatedUserId: userId
            ) {
                let id = (raw["id"] as? String) ?? "?"
                details.append("Skipped taskEvents/\(id): \(reason)")
                continue
            }
            valid.append(raw)
        }
        if valid.isEmpty { return (0, details) }

        var pulled = 0
        do {
            try database.write { db in
                // 2. LWW-upsert each event row (union by id; tombstone = undo).
                var affectedTaskIds = Set<String>()
                for raw in valid {
                    guard let id = raw["id"] as? String else { continue }
                    let local = try fetchLocalRecord(db: db, grdbTable: "task_events", id: id)
                    let remoteWins = local == nil || resolveConflict(local: local!, remote: raw) == "remote"
                    if !remoteWins { continue }
                    try upsertLocalRecord(db: db, grdbTable: "task_events", data: raw)
                    if let taskId = raw["taskId"] as? String { affectedTaskIds.insert(taskId) }
                    pulled += 1
                }

                // 3. Recompute caches ONCE per affected event-owning task that
                //    exists locally (non-authored write — no version bump, no
                //    enqueue). Events whose task isn't local yet are skipped-and-
                //    deferred (safety-net retry).
                var cascadeTaskIds = Set<String>()
                for taskId in affectedTaskIds {
                    guard let task = try Task.fetchOne(db, key: taskId), isEventOwningTask(task) else { continue }
                    try AppDatabase.recomputeTaskCachesFromPull(db: db, taskId: taskId)
                    cascadeTaskIds.insert(taskId)
                }

                // 4. ONE batched derivation pass per affected LIVE board.
                //    Sealed boards are excluded here (fan-out exclusion).
                if !cascadeTaskIds.isEmpty {
                    try runPullCascadeForTasks(db: db, changedTaskIds: cascadeTaskIds)
                }

                // 5. Seal re-derivation (docs §Seal snapshots re-derive from the
                //    event union): late pre-seal events for a placed task
                //    deterministically re-derive any affected SEALED board's
                //    frozen snapshot — the only sanctioned mutation of a sealed
                //    record. Uses `affectedTaskIds` (not `cascadeTaskIds`) so a
                //    sealed board placing a task whose row isn't local yet still
                //    re-derives. Local-only, inside this txn.
                if !affectedTaskIds.isEmpty {
                    try AppDatabase.reDeriveSealedBoards(db: db, changedTaskIds: affectedTaskIds)
                }
            }
        } catch {
            details.append("Pull failed for taskEvents: \(error.localizedDescription)")
            return (0, details)
        }

        for _ in 0..<pulled { recordEvent(.pulled) }
        return (pulled, details)
    }

    /// Heal-on-pull (docs/WINDOWED_COMPLETION.md §Heal-on-pull). Repairs the
    /// fresh-install backfill gap: the v20 event backfill runs as a GRDB
    /// migration, so on a fresh DB it fires on empty data and mints nothing; the
    /// sync pull then brings tasks whose `isCompleted` is true but whose backing
    /// `task_event` isn't in Firestore. Those completions render incomplete on
    /// every windowed surface (the derivation never falls back to the lifetime
    /// cache when a window is present). `recomputeTaskCachesFromPull` only touches
    /// tasks whose *events* were in a pull, so a zero-event task KEEPS its pulled
    /// `isCompleted` cache — exactly the signal this sweep heals from.
    ///
    /// For every event-owning task (NORMAL / plain COUNTING) that is
    /// lifetime-complete (`isCompleted` or `currentCount > 0`) but has NO live
    /// event, it mints the event via the shared `buildBackfillTaskEvent`
    /// (deterministic id → converges with the migration + web + peers;
    /// idempotent), ENQUEUES a CREATE (so the repair propagates), then runs the
    /// same recompute + board cascade + sealed re-derive the event-pull path uses.
    /// Idempotent + self-limiting: once healed, a task HAS a live event and is
    /// skipped forever after. Swift twin of `healMissingCompletionEvents` in
    /// `apps/web/src/db/operations/taskEventPull.ts`.
    ///
    /// - Parameter userId: The authenticated user's uid (scope guard).
    /// - Returns: The number of completion/increment events minted this pass.
    func healMissingCompletionEvents(userId: String) -> Int {
        var minted = 0
        do {
            try database.write { db in
                let tasks = try Task.fetchAll(db)
                let allEvents = try TaskEvent.fetchAll(db)
                var hasLiveEvent = Set<String>()
                for e in allEvents where !e.isDeleted { hasLiveEvent.insert(e.taskId) }

                var toMint: [TaskEvent] = []
                for task in tasks {
                    if task.userId != userId { continue }
                    if task.isDeleted || !isEventOwningTask(task) { continue }
                    if hasLiveEvent.contains(task.id) { continue } // events are authoritative
                    let complete = task.isCompleted || (task.currentCount ?? 0) > 0
                    if !complete { continue }
                    if let ev = buildBackfillTaskEvent(task: task) { toMint.append(ev) }
                }
                if toMint.isEmpty { return }

                let now = AppDatabase.currentTimestamp()
                var healedTaskIds = Set<String>()
                for ev in toMint {
                    // Respect LWW against any existing local row with this
                    // deterministic id — in particular a TOMBSTONE from an explicit
                    // undo (not in `hasLiveEvent` because it's soft-deleted). Blind-
                    // overwriting it would resurrect undone state AND drive a wrong
                    // board cascade before self-correcting. Treat the mint as
                    // "remote" (same as applyTaskEventsBatch): skip unless it wins.
                    // Typed mirror of `resolveConflict` (lwwResolve.ts): higher
                    // version wins; equal version → strictly-newer updatedAt, tie /
                    // unparseable → remote(mint) wins.
                    if let existing = try TaskEvent.fetchOne(db, key: ev.id) {
                        let mintWins: Bool
                        if ev.version != existing.version {
                            mintWins = ev.version > existing.version
                        } else if let existingDate = DateFormatting.parseISO(existing.updatedAt),
                                  let mintDate = DateFormatting.parseISO(ev.updatedAt) {
                            mintWins = mintDate >= existingDate
                        } else {
                            mintWins = true // unparseable → remote authority (canon #263)
                        }
                        if !mintWins { continue }
                    }

                    // Deterministic id → save is an upsert; a concurrent real event
                    // with the same id just wins by LWW. Enqueue CREATE so the
                    // repair reaches Firestore and every peer converges.
                    try ev.save(db)
                    try SyncQueueBuilder.makeItem(
                        entityType: "taskEvents",
                        entityId: ev.id,
                        operationType: .create,
                        payload: ev,
                        now: now
                    ).enqueue(db)
                    healedTaskIds.insert(ev.taskId)
                    minted += 1
                }
                // Recompute caches from the now-present events, then one board
                // cascade + sealed re-derive over the healed set — same shape as
                // applyTaskEventsBatch.
                for taskId in healedTaskIds {
                    try AppDatabase.recomputeTaskCachesFromPull(db: db, taskId: taskId)
                }
                if !healedTaskIds.isEmpty {
                    try runPullCascadeForTasks(db: db, changedTaskIds: healedTaskIds)
                    try AppDatabase.reDeriveSealedBoards(db: db, changedTaskIds: healedTaskIds)
                }
            }
        } catch {
            // Never let the heal fail the pull — it retries next cycle.
            log("Heal-on-pull skipped: \(error.localizedDescription)")
            return 0
        }
        for _ in 0..<minted { recordEvent(.pulled) }
        return minted
    }

    /// JSON-encode a `[String]` array to a compact JSON string.
    /// Used exclusively by `runPullCascade` to serialise `completedLineIds`.
    private func encodePullCascadeJSONArray(_ arr: [String]) -> String {
        guard let data = try? JSONEncoder().encode(arr),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    // MARK: - Safety-net timer

    private func startSafetyNetTimer(userId: String) {
        safetyNetTask = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(nanoseconds: UInt64(Self.safetyNetInterval) * 1_000_000_000)
                guard !_Concurrency.Task.isCancelled, let self else { return }
                _ = await self.fullSync(userId: userId)
            }
        }
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
