import Foundation

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
}
