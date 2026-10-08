import Foundation
import FirebaseAuth
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

    /// Board Edit redesign slice 4 (D5): true once this session's FIRST
    /// `pullSync` call has returned (success or partial — see `pullSync`'s
    /// own doc comment). The lazy backstop auto-close pass
    /// (`BoardListView.onAppearLoad`) waits on this (with a timeout fallback)
    /// before sealing, so a device that hasn't yet pulled a peer's Reopen
    /// doesn't race it and re-seal the board under the OLD local snapshot.
    @Published var hasCompletedFirstPull: Bool = false

    /// `lastError` payload — message + timestamp as a value type so it
    /// stays SwiftUI-friendly.
    struct SyncErrorRecord: Equatable {
        let message: String
        let at: Date
    }

    // MARK: - Private

    /// Local database the push path and pull-apply seam use. Injected
    /// (defaulting to `.shared`) so tests can point them at an in-memory
    /// `AppDatabase.makeTestInstance()`; both `SyncService()` call sites keep
    /// working via the default.
    private let database: AppDatabase

    /// Remote store the push path reads/writes through (see FirestoreDocStore.swift).
    private let docStore: FirestoreDocStore

    /// Remote reads the pull path + listeners go through (PullDocumentSource.swift).
    private let pullSource: PullDocumentSource

    /// - Parameters:
    ///   - database: Local DB for push, pull and listeners. Defaults to
    ///     `.shared`; overridden only in tests.
    ///   - currentAuthUid: Returns the signed-in Firebase uid (or nil). Read
    ///     by the push-path uid guard; defaults to `Auth.auth()`.
    ///   - docStore: Remote store for the push path; defaults to Firestore.
    ///   - pullSource: Remote reads for the pull + listeners; defaults to Firestore.
    init(
        database: AppDatabase = .shared,
        currentAuthUid: @escaping () -> String? = { Auth.auth().currentUser?.uid },
        docStore: FirestoreDocStore = LiveFirestoreDocStore(),
        pullSource: PullDocumentSource = LiveFirestorePullSource()
    ) {
        self.database = database
        self.currentAuthUid = currentAuthUid
        self.docStore = docStore
        self.pullSource = pullSource
    }

    /// Reads the signed-in Firebase uid at call time. Injected (defaulting to
    /// `Auth.auth()`) so tests can drive the push-path uid guard without a
    /// Firebase session.
    private let currentAuthUid: () -> String?

    /// Safety-net interval for the periodic full sync. With push-on-enqueue
    /// + snapshot listeners doing the real-time work, this only needs to
    /// fire occasionally to retry FAILED items, recover stale IN_PROGRESS
    /// rows from a force-quit, and back-stop missed snapshot deliveries.
    ///
    /// DO NOT REMOVE this timer as an "optimization": the pull checkpoints
    /// are server `_syncedAt` instants, but their bootstrap fallback
    /// (`users.lastSyncedAt`) is a LOCAL-clock ISO string, so a clock-skew
    /// window remains for a device without checkpoints, and this periodic
    /// re-pull is also what recovers a skipped (missing-parent) row. Web twin: `SYNC_SAFETY_NET_MS` in
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
    private var listenerRegistrations: [PullListener] = []

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

        // Defense-in-depth: never push for a uid other than the signed-in
        // one (a loop outliving an account switch, or a stale debounced
        // push). Skips before touching the queue or Firestore. Web twin: the
        // `assertSyncUserMatches` guard at the top of `pushSync`/`pullSync`.
        guard currentAuthUid() == userId else {
            let msg = "Push skipped — sync userId does not match authenticated user"
            log(msg)
            result.details.append(msg)
            return result
        }

        // Reset stale IN_PROGRESS items (e.g. force-quit mid-push) and
        // promote FAILED items whose backoff window has elapsed back to
        // PENDING so this same push picks them up. Mirrors the web
        // `pushSync` preamble. Promotion also re-fires the GRDB
        // ValueObservation on PENDING count, which schedules the next
        // push-on-enqueue debounce.
        do {
            try database.resetStaleInProgressSyncItems()
            try database.promoteEligibleFailedSyncItems()
        } catch {
            log("Push warning: queue maintenance failed: \(error.localizedDescription)")
            // Non-fatal — fall through and try to push whatever's already pending.
        }

        let pendingItems: [SyncQueueItem]
        do {
            pendingItems = try database.dropForeignOwnedSyncItems(database.fetchPendingSyncItems(), userId: userId)
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

    /// Pulls remote changes, collection by collection in `pullApplyOrder`
    /// (dependency order), each resuming from its own checkpoint (or
    /// `lastSyncedAt` when it has none). Every collection applies in batches
    /// OFF the main actor (`AppDatabase.applyPullBatch`): one transaction +
    /// one cascade + one checkpoint per batch, so a killed pull resumes where
    /// it stopped instead of re-applying everything. The main actor only
    /// publishes each batch's outcome.
    ///
    /// The heal sweeps + the `users.lastSyncedAt` stamp run only when every
    /// collection applied cleanly in THIS pull.
    ///
    /// - Parameters:
    ///   - userId: The authenticated user's Firestore UID.
    ///   - lastSyncedAt: ISO8601 fallback watermark for collections with no
    ///     checkpoint yet, or `nil` for a first sync.
    /// - Returns: Pull result summary.
    func pullSync(userId: String, lastSyncedAt: String?) async -> PullResult {
        var result = PullResult()
        // Stamped as `lastSyncedAt` on a clean pull — the START, not the end:
        // it is the fallback watermark for collections with no checkpoint (and
        // the listeners' start), so a doc written remotely DURING this pull
        // must still be >= it. `>=` + the echo guard make the re-read free.
        let pullStartedAt = AppDatabase.currentTimestamp()

        // The parent user doc (`users/{userId}`) — synced profile fields like
        // `preferences` replicate back through it.
        await processPullUserDocument(userId: userId, result: &result)

        let fallback = lastSyncedAt.flatMap(DateFormatting.parseISO).map(PullWatermark.init(date:))
        let checkpoints = (try? await database.readAsync { db in
            try AppDatabase.fetchSyncWatermarks(db: db, userId: userId)
        }) ?? [:]
        for collection in pullApplyCollections {
            await processPullCollection(
                collection: collection, userId: userId,
                since: checkpoints[collection.firestoreName] ?? fallback, result: &result
            )
        }

        if !result.details.contains(where: { $0.contains("Pull failed") }) {
            await finishCleanPull(userId: userId, pullStartedAt: pullStartedAt, result: &result)
        }

        // Board-integrity PR-4 (Item 5): one signal per PULL, not per row.
        if result.pulled > 0 {
            postSyncDidApplyChanges()
        }

        hasCompletedFirstPull = true
        return result
    }

    /// Clean-pull tail: heal-on-pull (docs/WINDOWED_COMPLETION.md
    /// §Heal-on-pull) + the windowed-linked-counter sweep — idempotent, each
    /// in its own async write — then the `users.lastSyncedAt` stamp (the
    /// checkpoint fallback + web parity), stamped with the pull's START time.
    /// Heals never fail the pull.
    private func finishCleanPull(userId: String, pullStartedAt: String, result: inout PullResult) async {
        do {
            let healed = try await database.writeAsync { db in try AppDatabase.healMissingCompletionEventsTx(db: db, userId: userId) }
            if healed > 0 { result.pulled += healed; recordBatch(pulled: healed); result.details.append("Healed \(healed) missing completion event(s)") }
        } catch {
            log("Heal-on-pull skipped: \(error.localizedDescription)")
        }
        do {
            let windowed = try await database.writeAsync { db in
                try AppDatabase.healLinkedCounterWindowsTx(db: db, userId: userId, now: AppDatabase.currentTimestamp())
            }
            let total = windowed.stamped + windowed.copied
            if total > 0 { result.pulled += total; result.details.append("Windowed \(total) linked counter(s)") }
        } catch {
            log("Linked-counter window heal skipped: \(error.localizedDescription)")
        }
        do {
            let now = AppDatabase.currentTimestamp()
            try await database.writeAsync { db in
                guard var user = try User.fetchOne(db, key: userId) else { return }
                user.lastSyncedAt = pullStartedAt
                user.updatedAt = now
                try user.save(db)
            }
        } catch {
            log("Warning: could not update lastSyncedAt for user \(userId): \(error.localizedDescription)")
        }
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
            try database.saveSyncItem(inProgress)

            guard let payload = parsePayload(item.payload) else {
                throw SyncError.invalidPayload("Could not parse payload for \(item.entityType)/\(item.entityId)")
            }

            // The `users` entity is stored at `users/{userId}` (the scope root),
            // not in a subcollection, and it must never be DELETE-synced — that
            // would wipe the scope for every other collection.
            let isUserEntity = item.entityType == "users"
            let docPath = isUserEntity
                ? "users/\(item.entityId)"
                : "users/\(userId)/\(item.entityType)/\(item.entityId)"

            if isUserEntity && item.operationType == .delete {
                try markCompleted(item)
                let msg = "Skipped delete for users/\(item.entityId)"
                result.details.append(msg)
                log(msg)
                return
            }

            // DELETE operations: check conflict before overwriting.
            if item.operationType == .delete {
                if let remoteData = try await docStore.fetch(path: docPath) {
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
                try await writeFirestoreDoc(path: docPath, collection: item.entityType, data: payload)
                try markCompleted(item)
                result.pushed += 1
                recordEvent(.pushed)
                let msg = "Deleted \(item.entityType)/\(item.entityId)"
                result.details.append(msg)
                log(msg)
                return
            }

            // Fetch remote document to check for a conflict.
            guard let remoteData = try await docStore.fetch(path: docPath) else {
                // No remote document — push directly.
                try await writeFirestoreDoc(path: docPath, collection: item.entityType, data: payload)
                try markCompleted(item)
                result.pushed += 1
                recordEvent(.pushed)
                let msg = "Pushed \(item.entityType)/\(item.entityId) (new)"
                result.details.append(msg)
                log(msg)
                return
            }

            // Remote exists — resolve conflict.
            let winner = resolveConflict(local: payload, remote: remoteData)

            if winner == "local" {
                try await writeFirestoreDoc(path: docPath, collection: item.entityType, data: payload)
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
                try database.saveSyncItem(failed)
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

    // MARK: - Sync-applied live-update signal (Board-integrity PR-4, Item 5)

    /// Posts `.oybcSyncDidApplyChanges` once. `SyncService` is `@MainActor`, so
    /// every call site is already on the main queue/actor — this just makes
    /// the "on main" requirement explicit at the call site rather than
    /// implicit in the class-level `@MainActor`.
    private func postSyncDidApplyChanges() {
        NotificationCenter.default.post(name: .oybcSyncDidApplyChanges, object: nil)
    }

    // MARK: - Pull Helpers

    /// Pulls the parent user document at `users/{userId}` and LWW-merges it
    /// into the local `users` row (preserving the local `lastSyncedAt`).
    private func processPullUserDocument(userId: String, result: inout PullResult) async {
        do {
            guard let remoteData = try await pullSource.fetchUserDoc(userId: userId) else { return }
            let remote = PullDocs(docs: [remoteData])
            let outcome = try await database.writeAsync { db in
                try AppDatabase.applyPulledUserDocTx(db: db, userId: userId, remoteData: remote.docs[0])
            }
            if outcome.applied { result.pulled += 1; recordBatch(pulled: 1) } else { result.conflicts += 1 }
            result.details.append(outcome.detail)
            log(outcome.detail)
        } catch {
            let msg = "Pull failed for users/\(userId): \(error.localizedDescription)"
            result.details.append(msg)
            log(msg)
        }
    }

    /// Pulls one collection from its checkpoint and applies it in
    /// `_syncedAt`-ordered chunks, each its own off-main batch transaction
    /// with its own checkpoint. A throw stops the collection ("Pull failed")
    /// with every earlier chunk committed + checkpointed; the next pull
    /// resumes from there.
    private func processPullCollection(
        collection: PullCollection, userId: String, since: PullWatermark?, result: inout PullResult
    ) async {
        do {
            let fetched = try await pullSource.fetchCollection(userId: userId, collection: collection.firestoreName, since: since)
            for chunk in await Self.checkpointChunks(fetched) {
                // An account switch (`stop()`/`start()`) can land mid-pull now
                // that batches commit after an await — drop the rest.
                guard runningForUserId == nil || runningForUserId == userId else {
                    throw SyncError.invalidPayload("sync stopped for this user")
                }
                let outcome = try await database.applyPullBatch(collection: collection, docs: chunk, userId: userId, checkpoint: true)
                publish(outcome, collection: collection.firestoreName)
                result.pulled += outcome.pulled
                result.conflicts += outcome.conflicts
                result.details.append(contentsOf: outcome.details)
            }
        } catch {
            let msg = "Pull failed for \(collection.firestoreName): \(error.localizedDescription)"
            result.details.append(msg)
            log(msg)
        }
    }

    /// `AppDatabase.pullChunks`, run off the main actor (`nonisolated async`).
    nonisolated static func checkpointChunks(_ fetched: PullDocs) async -> [PullDocs] {
        AppDatabase.pullChunks(fetched)
    }

    /// Publishes one batch on the main actor: ONE counter mutation + log lines
    /// for skips / kept-local rows and a per-batch summary (no per-doc events).
    private func publish(_ outcome: PullBatchOutcome, collection: String) {
        recordBatch(pulled: outcome.pulled)
        for detail in outcome.details where !detail.hasPrefix("Pulled ") { log(detail) }
        if outcome.pulled > 0 { log("Pulled \(outcome.pulled) \(collection)") }
    }

    // MARK: - Firestore Write

    /// Writes a document to Firestore, stripping `nil`/`NSNull` values and
    /// attaching a server-side `_syncedAt` timestamp.
    ///
    /// Uses `merge: true` so that fields not present in `data` are preserved
    /// rather than deleted.
    ///
    /// - Parameters:
    ///   - path: Slash-joined document path, written through `docStore`.
    ///   - collection: The doc's collection (`"users"` for the user doc).
    ///   - data: The document data dictionary.
    private func writeFirestoreDoc(
        path: String,
        collection: String,
        data: [String: Any]
    ) async throws {
        var cleaned = SyncWirePayload.expandJSONStrings(data)
        cleaned["_syncedAt"] = FieldValue.serverTimestamp()

        // Board Edit redesign slice 4 (D2): clearable fields (`boards.endDate`
        // / `completedAt` / `sealedAt` / `sealedCompletedCells`, and a core
        // default's cleared size / centre override) must propagate their
        // ABSENCE, not just their presence — under `merge: true`, simply
        // omitting an absent field would PRESERVE a stale remote value (e.g.
        // a Reopen's cleared `sealedAt` never reaching Firestore, silently
        // re-closing the board on every other device). Per-collection map in
        // `SyncService+ClearableFields.swift`; no-op when never set.
        Self.applyClearableFieldDeletes(collection: collection, cleaned: &cleaned)

        try await docStore.write(path: path, data: cleaned)
    }

    // MARK: - Local DB Helpers

    /// Push-path remote-wins write-back: upserts a remote doc into `grdbTable`
    /// (no cascade — the push path never cascaded). The helper is shared with
    /// the pull engine (`AppDatabase.upsertPulledRecord`).
    private func upsertLocalRecord(grdbTable: String, data: [String: Any]) throws {
        try database.write { db in
            try AppDatabase.upsertPulledRecord(db: db, grdbTable: grdbTable, data: data)
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
        try database.saveSyncItem(completed)
    }

    // MARK: - User Helpers

    /// Fetches the current `lastSyncedAt` timestamp from the local user record.
    ///
    /// - Parameter userId: The user's ID.
    /// - Returns: The ISO8601 timestamp string, or `nil` if never synced.
    private func fetchLastSyncedAt(userId: String) async -> String? {
        do {
            return try await database.readAsync { db in try User.fetchOne(db, key: userId)?.lastSyncedAt }
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
    /// - After the initial catch-up pull completes, a Firestore snapshot
    ///   listener is opened on the parent `users/{userId}` doc and on each
    ///   pulled subcollection, from that collection's fresh checkpoint — not
    ///   before, or the first snapshot would re-deliver the very delta the
    ///   pull is applying (the launch double-apply). Listener snapshots go
    ///   through the same batch engine as the pull.
    /// - A safety-net timer fires `fullSync` every 5 minutes to recover
    ///   stuck queue items and back-stop any missed snapshot delivery.
    /// - An immediate `fullSync` runs once to handle anything queued
    ///   before this call (e.g. writes made while signed out).
    func start(userId: String) {
        if runningForUserId == userId { return }
        if runningForUserId != nil { stop() }
        runningForUserId = userId

        startQueueObservation(userId: userId)
        startSafetyNetTimer(userId: userId)

        // Initial sync covers anything queued before start, then attaches the
        // listeners (even when the pull failed — e.g. offline — so real-time
        // still works). Tracked and gated on `runningForUserId == userId` so a
        // rapid sign-out can cancel and short-circuit it.
        initialSyncTask?.cancel()
        initialSyncTask = _Concurrency.Task { [weak self] in
            guard let self, self.runningForUserId == userId else { return }
            // A push holding `isSyncing` makes `fullSync` skip the pull: wait
            // (≤ 30 s) and retry once, so listeners attach after a real pull.
            for _ in 0..<2 where !self.hasCompletedFirstPull {
                let deadline = Date().addingTimeInterval(30) // never wait forever on a stuck push
                while self.isSyncing, !_Concurrency.Task.isCancelled, Date() < deadline {
                    try? await _Concurrency.Task.sleep(nanoseconds: 50_000_000)
                }
                guard !_Concurrency.Task.isCancelled, self.runningForUserId == userId else { return }
                _ = await self.fullSync(userId: userId)
            }
            guard !_Concurrency.Task.isCancelled, self.runningForUserId == userId else { return }
            await self.attachPullListeners(userId: userId)
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
        hasCompletedFirstPull = false
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

    /// Record one applied pull/listener BATCH: a single mutation of the
    /// published counters per batch (each mutation invalidates every view
    /// observing `SyncService`), never one per doc.
    fileprivate func recordBatch(pulled: Int, at: Date = Date()) {
        guard pulled > 0 else { return }
        totalPulled += pulled
        lastEventAt = at
        lastError = nil
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
            exhaustedCount = try database.countExhaustedSyncItems()
        } catch {
            log("Warning: could not count exhausted sync items: \(error.localizedDescription)")
        }
    }

    /// Manually recover items stuck past the retry cap: reset them to a
    /// fresh PENDING state, refresh the count for immediate UI feedback,
    /// then run a full sync for an immediate push. Backs the network-regain
    /// auto-recovery (`MainTabView`); the sync sheet's manual "Retry" button
    /// was removed with the sync UI (2026-09-30). Mirrors the web
    /// `handleOnline` path (`retryExhaustedSyncItems` + `fullSync`).
    ///
    /// - Parameter userId: The authenticated user's Firestore UID.
    func retryExhaustedItems(userId: String) async {
        do {
            _ = try database.retryExhaustedSyncItems()
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
            in: database.dbQueue,
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

    /// Attaches the user-doc listener + one listener per pulled collection,
    /// each from its checkpoint (fallback `users.lastSyncedAt`, else epoch).
    /// Called only after the initial pull, so the first snapshot is just the
    /// boundary docs (`>=`), which the echo guard skips.
    private func attachPullListeners(userId: String) async {
        let marks = try? await database.readAsync { db in
            (try AppDatabase.fetchSyncWatermarks(db: db, userId: userId), try User.fetchOne(db, key: userId)?.lastSyncedAt)
        }
        guard runningForUserId == userId, listenerRegistrations.isEmpty else { return }
        let fallback = marks?.1.flatMap(DateFormatting.parseISO).map(PullWatermark.init(date:))
            ?? PullWatermark(seconds: 0, nanoseconds: 0)

        listenerRegistrations.append(pullSource.listenUserDoc(userId: userId) { [weak self] data in
            guard let self else { return }
            let doc = PullDocs(docs: [data])
            _Concurrency.Task { @MainActor in await self.applyListenerUserDoc(userId: userId, doc: doc) }
        })
        for collection in pullApplyCollections {
            let since = marks?.0[collection.firestoreName] ?? fallback
            listenerRegistrations.append(pullSource.listenCollection(
                userId: userId, collection: collection.firestoreName, since: since
            ) { [weak self] docs in
                guard let self else { return }
                _Concurrency.Task { @MainActor in await self.applyListenerBatch(collection: collection, docs: docs, userId: userId) }
            })
        }
    }

    /// One listener snapshot = batches through the pull engine (no checkpoint
    /// — a change set isn't a `_syncedAt`-ordered prefix), then at most ONE
    /// `.oybcSyncDidApplyChanges` for the snapshot (Board-integrity PR-4 Item 5).
    private func applyListenerBatch(collection: PullCollection, docs: PullDocs, userId: String) async {
        var pulled = 0
        for chunk in await Self.checkpointChunks(docs) {
            guard runningForUserId == userId else { return }
            do {
                let outcome = try await database.applyPullBatch(collection: collection, docs: chunk, userId: userId, checkpoint: false)
                publish(outcome, collection: collection.firestoreName)
                pulled += outcome.pulled
            } catch {
                log("Listener apply failed for \(collection.firestoreName): \(error.localizedDescription)")
            }
        }
        if pulled > 0 { postSyncDidApplyChanges() }
    }

    /// The user-doc listener: same LWW as the pull. Only a real local write
    /// posts `.oybcSyncDidApplyChanges` (a local-win re-assert changes nothing).
    private func applyListenerUserDoc(userId: String, doc: PullDocs) async {
        guard runningForUserId == userId else { return }
        do {
            let outcome = try await database.writeAsync { db in
                try AppDatabase.applyPulledUserDocTx(db: db, userId: userId, remoteData: doc.docs[0])
            }
            guard outcome.applied else { return }
            recordBatch(pulled: 1)
            log("\(outcome.detail), listener")
            postSyncDidApplyChanges()
        } catch {
            log("Listener apply failed for users/\(userId): \(error.localizedDescription)")
        }
    }

    // MARK: - Synchronous test seams (same engine as the pull)

    /// Applies ONE remote doc through the batch engine synchronously on the
    /// injected `database` — the seam `SyncPullApplyTests` & co. drive. Not
    /// used by production (the pull + listeners use `applyPullBatch`).
    ///
    /// - Returns: `true` if a remote value was written to local GRDB.
    @discardableResult
    func applyRemoteSubdoc(
        collection: (firestoreName: String, grdbTable: String),
        remoteData: [String: Any],
        authenticatedUserId: String
    ) -> Bool {
        do {
            let outcome = try database.write { db in
                try AppDatabase.applyPullBatchTx(db: db, collection: collection, docs: [remoteData], userId: authenticatedUserId)
            }
            publish(outcome, collection: collection.firestoreName)
            return outcome.pulled > 0
        } catch {
            log("Listener apply failed for \(collection.firestoreName): \(error.localizedDescription)")
            return false
        }
    }

    /// Batched `taskEvents` apply (`AppDatabase.applyTaskEventsBatchTx`),
    /// synchronous on the injected `database` — test seam.
    ///
    /// - Returns: Pulled-row count + per-row skip details.
    @discardableResult
    func applyTaskEventsBatch(userId: String, rawDocs: [[String: Any]]) -> (pulled: Int, details: [String]) {
        do {
            let batch = try database.write { db in try AppDatabase.applyTaskEventsBatchTx(db: db, userId: userId, rawDocs: rawDocs) }
            recordBatch(pulled: batch.pulled)
            return batch
        } catch {
            return (0, ["Pull failed for taskEvents: \(error.localizedDescription)"])
        }
    }

    /// Heal-on-pull (`AppDatabase.healMissingCompletionEventsTx`),
    /// synchronous on the injected `database` — test seam.
    ///
    /// - Returns: The number of events minted (0 on failure).
    func healMissingCompletionEvents(userId: String) -> Int {
        do {
            let minted = try database.write { db in try AppDatabase.healMissingCompletionEventsTx(db: db, userId: userId) }
            recordBatch(pulled: minted)
            return minted
        } catch {
            log("Heal-on-pull skipped: \(error.localizedDescription)")
            return 0
        }
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
