import Foundation
import GRDB

/// Builds `SyncQueueItem` rows for local writes that should be pushed
/// to Firestore by `SyncService.pushSync`. Any write path that mutates
/// a user-visible entity (Board, BoardTask, Task, TaskStep, …) must
/// enqueue a matching sync item inside the same GRDB transaction,
/// otherwise the change stays local-only.
///
/// Previously this lived as `private` duplicates in
/// `BoardLifecyclePlayground.swift` and `BoardPlayView.swift`; lifted
/// out when a third caller (`BoardWizardPersist.swift`) appeared, per
/// the project's "extract at three" rule.
enum SyncQueueBuilder {
    /// Serialises a `Codable` value as a JSON string for
    /// `SyncQueueItem.payload`. Returns `"{}"` if serialisation fails
    /// — same fallback the legacy private helpers used.
    static func encodePayload<T: Codable>(_ value: T) -> String {
        guard
            let data = try? JSONEncoder().encode(value),
            let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    /// Constructs a `SyncQueueItem` with `status = .pending` for the
    /// given entity operation. The caller is responsible for saving
    /// the returned item inside the same transaction as the write it
    /// describes.
    static func makeItem<T: Codable>(
        entityType: String,
        entityId: String,
        operationType: SyncOperationType,
        payload: T,
        now: String
    ) -> SyncQueueItem {
        SyncQueueItem(
            id: AppDatabase.generateUUID(),
            entityType: entityType,
            entityId: entityId,
            operationType: operationType,
            payload: encodePayload(payload),
            status: .pending,
            retryCount: 0,
            lastError: nil,
            createdAt: now,
            lastAttemptAt: nil,
            completedAt: nil,
            priority: 1
        )
    }

    /// The outcome of coalescing an incoming enqueue against an existing
    /// PENDING row for the same `(entityType, entityId)` pair.
    enum CoalesceResult: Equatable {
        /// Keep the existing row's queue position, but set its operation type
        /// to the associated value and refresh its payload to the incoming
        /// snapshot.
        case replace(SyncOperationType)
        /// Discard the existing pending row entirely — a create that never
        /// reached the server is now deleted, so nothing needs to sync.
        case drop
    }

    /// D3 (issue #296) precedence — decide how an incoming sync op coalesces
    /// with an existing PENDING op for the *same entity*. Pure, so both the
    /// enqueue path and unit tests can call it. Mirrors the web
    /// `coalesceSyncOperation`.
    ///
    /// Precedence table (rows = existing PENDING op, cols = incoming op):
    ///
    /// ```
    ///              incoming create   incoming update   incoming delete
    /// create       create            create            DROP*/delete
    /// update       create            update            delete
    /// delete       create (resurr.)  update (resurr.)  delete
    /// ```
    /// *DROP only when the existing row was never attempted
    /// (`existingNeverAttempted`); otherwise delete.
    ///
    /// Reasoning:
    /// - **create + update → create**: the entity hasn't reached the server
    ///   yet, so it must still arrive as a create-equivalent. (The push path
    ///   treats create/update identically — both a `setDoc(merge)` after the
    ///   same version conflict-check — so the op type is cosmetic; keeping
    ///   create preserves the "not yet on server" semantic.)
    /// - **create + delete → DROP only if never attempted, else delete**:
    ///   dropping is safe only when the server provably never saw the entity.
    ///   PENDING alone doesn't prove that — a push whose `setDoc` landed but
    ///   whose completion write failed (or a force-quit mid-push) leaves the
    ///   row failed/inProgress and it is re-promoted/reset back to pending
    ///   with the doc already on the server; dropping the delete then would
    ///   orphan a live remote doc forever. Both platforms stamp
    ///   `lastAttemptAt` when claiming an item for push, so
    ///   `existingNeverAttempted` (`lastAttemptAt == nil`) proves no push was
    ///   ever attempted → ids are client-generated UUIDs, no other device
    ///   knows the entity, create-then-delete nets to nothing anywhere →
    ///   drop. Otherwise keep the row as delete — pushing a tombstone for a
    ///   doc that may not exist is harmless (it writes an inert
    ///   `isDeleted=true` doc), whereas an orphaned live doc is silent
    ///   divergence.
    /// - **update + delete → delete**: a standalone PENDING update means the
    ///   create already pushed (server has the doc), so the tombstone (a full
    ///   snapshot with `isDeleted=true`) must push to mark it deleted.
    /// - **delete + create/update → new op (resurrection)**: the un-pushed
    ///   tombstone is stale — the latest local snapshot (isDeleted=false,
    ///   higher version) is the truth. Pushing that one full snapshot under
    ///   LWW yields the correct server state in a single write, with no
    ///   ordering dependency (strictly better than a separate DELETE-then-
    ///   CREATE pair).
    static func coalesce(
        existing: SyncOperationType,
        incoming: SyncOperationType,
        existingNeverAttempted: Bool,
        entityType: String
    ) -> CoalesceResult {
        // Windowed Completion task events are append-only occurrence rows
        // (docs/WINDOWED_COMPLETION.md §Sync). Two DISTINCT events have distinct
        // ids, so they never meet in the coalescer (it keys on entityId) — that
        // distinctness IS the append-only guarantee: no event is ever collapsed
        // away by another. The coalescer only fires for the SAME event id, whose
        // only real sequence is create → tombstone (undo). Precedence:
        //
        //   - A tombstone SUPERSEDES a pending create — but is NEVER dropped.
        //     Backfill event ids are deterministic (uuidv5), so a peer may
        //     already hold the same id as a live row; only a pushed tombstone
        //     converges the undo. Dropping (as the generic create+delete path
        //     does) would strand the undo locally while the peer's copy stays
        //     live → silent divergence.
        //   - Undo is final for an id (a redo is a NEW id), so a tombstone is
        //     never resurrected by a later create/update.
        //   - Any other same-id op stays a create (not yet on the server).
        if entityType == Self.taskEventsEntityType {
            if incoming == .delete || existing == .delete {
                return .replace(.delete)
            }
            return .replace(.create)
        }

        if incoming == .delete {
            return existing == .create && existingNeverAttempted
                ? .drop
                : .replace(.delete)
        }
        if existing == .delete {
            // Resurrection: the incoming create/update supersedes the
            // un-pushed tombstone.
            return .replace(incoming)
        }
        return .replace(existing == .create ? .create : incoming)
    }

    /// The queue `entityType` for Windowed Completion task events
    /// (docs/WINDOWED_COMPLETION.md §Sync) — the Firestore subcollection name,
    /// same value the push path uses. Its coalescing precedence is append-only
    /// (see `coalesce`). Mirrors the web `TASK_EVENTS_ENTITY_TYPE`.
    static let taskEventsEntityType = "taskEvents"
}

extension SyncQueueItem {
    /// Enqueue this freshly-built (`status == .pending`) sync item into the
    /// queue, coalescing per entity, inside the caller's ongoing GRDB write
    /// transaction.
    ///
    /// D3 (issue #296): N edits to one entity used to enqueue N full-snapshot
    /// rows → N Firestore writes. Instead, if a PENDING row already exists for
    /// the same `(entityType, entityId)` we REPLACE its payload + operation
    /// type (per `SyncQueueBuilder.coalesce`) in place, keeping the original
    /// row's queue position, rather than appending a second snapshot. So an
    /// edit burst collapses to a single pending row carrying the LAST snapshot.
    ///
    /// Position-keeping: replacing preserves the original row's `createdAt`
    /// (queue position). That's correct under full-snapshot + LWW sync —
    /// conflict resolution is by the entity's `version`, not queue order, and
    /// Firestore docs carry no cross-doc referential constraints, so a
    /// coalesced row's position relative to *other* entities' rows is
    /// immaterial.
    ///
    /// IN_PROGRESS / FAILED rows are never coalesced into: an IN_PROGRESS row
    /// is mid-flight, and a FAILED row belongs to the retry/backoff machinery.
    /// When the only existing row for the entity is inProgress/failed we append
    /// a fresh PENDING row (which itself coalesces with subsequent edits).
    ///
    /// - Parameter db: The GRDB `Database` handle for the caller's transaction.
    func enqueue(_ db: Database) throws {
        // At most one PENDING row per entity post-coalescing; if legacy
        // duplicates exist, target the earliest (by createdAt) to preserve
        // queue position.
        let existing = try SyncQueueItem
            .filter(Column("entityType") == entityType)
            .filter(Column("entityId") == entityId)
            .filter(Column("status") == SyncStatus.pending.rawValue)
            .order(Column("createdAt"))
            .fetchOne(db)

        guard let existing else {
            try save(db)
            return
        }

        switch SyncQueueBuilder.coalesce(
            existing: existing.operationType,
            incoming: operationType,
            existingNeverAttempted: existing.lastAttemptAt == nil,
            entityType: entityType
        ) {
        case .drop:
            try SyncQueueItem.deleteOne(db, key: existing.id)
        case .replace(let op):
            var merged = existing // keep original id + createdAt (position)
            merged.operationType = op
            merged.payload = payload
            merged.priority = priority
            merged.status = .pending
            merged.retryCount = 0
            merged.lastError = nil
            // NOTE: lastAttemptAt is deliberately PRESERVED — it is the
            // evidence that a push was attempted for this row (its setDoc may
            // have landed), which the create+delete drop-vs-tombstone decision
            // above depends on. Clearing it here would let a later delete
            // wrongly drop a create whose doc already reached the server.
            try merged.save(db)
        }
    }
}
