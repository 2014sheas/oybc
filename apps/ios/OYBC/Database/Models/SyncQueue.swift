import Foundation
import GRDB

/// SyncQueue - Offline sync queue for tracking pending sync operations
///
/// Matches TypeScript SyncQueueItem interface from @oybc/shared
struct SyncQueueItem: Codable, FetchableRecord, PersistableRecord {
    // Identity
    var id: String
    var entityType: String
    var entityId: String

    // Operation details
    var operationType: SyncOperationType
    var payload: String // JSON string

    // Status tracking
    var status: SyncStatus
    var retryCount: Int
    var lastError: String?

    // Timestamps
    var createdAt: String // ISO8601
    var lastAttemptAt: String? // ISO8601
    var completedAt: String? // ISO8601

    // Priority (higher = more important)
    var priority: Int

    // Ownership — LOCAL queue column only, never on the wire (docs/GUEST_MODE.md
    // §Collision). The Firebase uid signed in when the item was built; the
    // default stamps it at every construction site automatically. The push
    // path DROPS an item whose owner is set and differs from the uid it pushes
    // for. nil = legacy (pre-v33) row or no signed-in user → pushes as before.
    // Mirrors `SyncQueueItem.ownerUid` in @oybc/shared.
    var ownerUid: String? = SyncQueueOwnership.currentUid()

    // MARK: - Database Configuration

    static let databaseTableName = "sync_queue"
}

// MARK: - Enums

enum SyncOperationType: String, Codable, DatabaseValueConvertible {
    case create
    case update
    case delete
}

enum SyncStatus: String, Codable, DatabaseValueConvertible {
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
}

// MARK: - Ownership

/// Sync-queue ownership rules (docs/GUEST_MODE.md §Collision). Swift twin of
/// `packages/shared/src/constants/syncQueueOwnership.ts` — keep the two
/// predicates in lockstep.
///
/// During a guest→account collision switch the new uid's sync loop can start
/// before the discarded guest's queue is cleared; `boardTasks` and
/// `compoundChildren` carry no `userId`, so Firestore rules would accept the
/// guest's rows into the real account. Every item is therefore stamped with
/// its enqueue-time owner, and a foreign-owned item is dropped, never pushed.
enum SyncQueueOwnership {
    private static let lock = NSLock()
    private static var _provider: () -> String? = { nil }

    /// Returns the uid signed in right now. Registered at launch by
    /// `OYBCApp.init` as `Auth.auth().currentUser?.uid` (read live, never
    /// cached) — the Database layer stays Firebase-free. Defaults to nil
    /// (tests, `-bypassAuth`), which yields legacy unstamped rows.
    static var provider: () -> String? {
        get { lock.lock(); defer { lock.unlock() }; return _provider }
        set { lock.lock(); defer { lock.unlock() }; _provider = newValue }
    }

    /// The enqueue-time owner stamp: the provider's current uid.
    static func currentUid() -> String? { provider() }

    /// True when an item belongs to a DIFFERENT account than `userId` and must
    /// be dropped rather than pushed. A nil owner (legacy row) is never foreign.
    static func isForeign(ownerUid: String?, userId: String) -> Bool {
        guard let ownerUid else { return false }
        return ownerUid != userId
    }

    /// True when an incoming enqueue owned by `incoming` may coalesce into an
    /// existing PENDING row owned by `existing`: same owner, or a legacy nil-
    /// owner row (which the incoming op then re-stamps). A stamped row never
    /// absorbs a differently-owned (or unowned) op — that op appends its own row.
    static func canCoalesce(existing: String?, incoming: String?) -> Bool {
        existing == nil || existing == incoming
    }
}

// MARK: - Retry Backoff

/// Mirror of `packages/shared/src/constants/syncRetry.ts`. Swift can't
/// import the TypeScript module, so the schedule is duplicated here —
/// keep the two in lockstep when changing.
enum SyncRetry {
    /// Maximum retry attempts for a sync operation (mirrors
    /// `MAX_SYNC_RETRIES` in @oybc/shared).
    static let maxRetries: Int = 5

    /// Exponential backoff schedule (milliseconds) indexed by
    /// retryCount - 1.
    static let backoffMs: [Int] = [
        30 * 1_000,         // first retry: 30s after failure
        2 * 60 * 1_000,     // second:      2 min
        10 * 60 * 1_000,    // third:       10 min
        30 * 60 * 1_000,    // fourth:      30 min
        60 * 60 * 1_000,    // fifth:       1 hour (cap)
    ]

    /// Returns true when a FAILED sync queue item has waited long
    /// enough since its last attempt to be re-promoted to PENDING.
    /// Mirrors `isFailedItemEligibleForRetry` in @oybc/shared.
    static func isFailedItemEligibleForRetry(
        retryCount: Int,
        lastAttemptAtMs: Int?,
        nowMs: Int
    ) -> Bool {
        let idx = max(0, min(retryCount - 1, backoffMs.count - 1))
        let backoff = backoffMs[idx]
        guard let lastAttemptAtMs else { return true }
        return nowMs - lastAttemptAtMs >= backoff
    }
}

// MARK: - Helpers

extension SyncQueueItem {
    /// Check if item is stale (created more than 24 hours ago)
    var isStale: Bool {
        guard let createdDate = ISO8601DateFormatter().date(from: createdAt) else {
            return false
        }
        let dayAgo = Date().addingTimeInterval(-24 * 60 * 60)
        return createdDate < dayAgo
    }
}
