import Foundation
import GRDB

/// TaskEvent — a single completion / increment occurrence for an event-owning
/// Task (Windowed Completion, docs/WINDOWED_COMPLETION.md §New entity).
///
/// Swift mirror of the TypeScript `TaskEvent` interface from `@oybc/shared`
/// (`packages/shared/src/types/taskEvent.ts`), field-for-field.
///
/// One new synced collection (SQLite `task_events`, Dexie `taskEvents`,
/// Firestore `users/{uid}/taskEvents`). Per-row LWW + soft-delete tombstones,
/// exactly like `compound_children` — union by id, `isDeleted` tombstone = undo.
///
/// Events are only valid for tasks that **own their state**:
///   - `type == .normal`, or
///   - `type == .counting` with `sharedCounterId` nil (plain / source).
/// Compound / achievement / derived (shared-counter-linked) counting tasks do
/// NOT own events — their state is derived elsewhere (see the derived-task
/// carve-out in the design doc). `isEventOwningTask(_:)` is the shared predicate
/// the write choke points call to enforce this before appending an event.
///
/// `occurredAt` is the semantic timestamp — evaluation windows key on it
/// (`occurredAt >= board.startDate`, parsed compare; upper bound enforced by
/// sealing rather than filtering). `boardId` is provenance only (where the
/// event was logged) and is NEVER read during evaluation.
struct TaskEvent: Codable, FetchableRecord, PersistableRecord, Identifiable {
    // Identity
    var id: String
    var userId: String
    var taskId: String

    // Occurrence
    var kind: TaskEventKind
    /// Signed, non-zero integer delta. Present ONLY on `.increment` events;
    /// nil on `.completion` events. Enforced by the shared `TaskEventSchema`
    /// on the pull boundary.
    var delta: Int?
    /// ISO8601 — the semantic timestamp. Windows key on this. Set to `now` at
    /// write time; backfill rows derive it from the task snapshot.
    var occurredAt: String
    /// Provenance only (the board where the occurrence was logged). NEVER used
    /// in evaluation — attribution is by `occurredAt`, not board.
    var boardId: String?

    // Timestamps
    var createdAt: String // ISO8601
    var updatedAt: String // ISO8601

    // Sync metadata (identical shape to every other synced collection)
    var lastSyncedAt: String? // ISO8601
    var version: Int
    var isDeleted: Bool
    var deletedAt: String? // ISO8601

    // MARK: - Database Configuration

    static let databaseTableName = "task_events"

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, userId, taskId
        case kind, delta, occurredAt, boardId
        case createdAt, updatedAt
        case lastSyncedAt, version, isDeleted, deletedAt
    }
}

// MARK: - Supporting Types

/// The kind of a `TaskEvent`. Stored as the raw string `"completion"` /
/// `"increment"` to match the wire format (`TaskEventKind` in the TS twin).
enum TaskEventKind: String, Codable, DatabaseValueConvertible {
    case completion
    case increment
}
