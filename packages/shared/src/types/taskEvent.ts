/**
 * TaskEvent — a single completion / increment occurrence for an event-owning
 * Task (Windowed Completion, docs/WINDOWED_COMPLETION.md §New entity).
 *
 * One new synced collection (SQLite `task_events`, Dexie `taskEvents`,
 * Firestore `users/{uid}/taskEvents`). Per-row LWW + soft-delete tombstones,
 * exactly like `compound_children` — union by id, `isDeleted` tombstone = undo.
 *
 * Events are only valid for tasks that **own their state**:
 *   - `type === NORMAL`, or
 *   - `type === COUNTING` with `sharedCounterId` null/undefined (plain / source).
 * Compound / achievement / derived (shared-counter-linked) counting tasks do
 * NOT own events — their state is derived elsewhere (see the derived-task
 * carve-out in the design doc). `isEventOwningTask()` is the shared predicate
 * the write choke points call to enforce this before appending an event.
 *
 * `occurredAt` is the semantic timestamp — evaluation windows key on it
 * (`occurredAt >= board.startDate`, parsed compare, upper bound enforced by
 * sealing rather than filtering). `boardId` is provenance only (where the
 * event was logged) and is NEVER read during evaluation.
 */
export type TaskEventKind = 'completion' | 'increment';

export interface TaskEvent {
  // Identity
  id: string; // UUID (client-generated; deterministic for backfill rows)
  userId: string; // FK users
  taskId: string; // FK tasks (must be an event-owning task — see isEventOwningTask)

  // Occurrence
  kind: TaskEventKind;
  /**
   * Signed, non-zero integer delta. Present ONLY on `increment` events;
   * forbidden on `completion` events. Enforced by `TaskEventSchema`.
   */
  delta?: number;
  /**
   * ISO8601 — the semantic timestamp. Windows key on this. Set to `now` at
   * write time; backfill rows derive it from the task snapshot.
   */
  occurredAt: string;
  /**
   * Provenance only (the board where the occurrence was logged). NEVER used
   * in evaluation — attribution is by `occurredAt`, not board.
   */
  boardId?: string;

  // Timestamps
  createdAt: string; // ISO8601
  updatedAt: string; // ISO8601

  // Sync metadata (identical shape to every other synced collection)
  lastSyncedAt?: string; // ISO8601
  version: number; // per-row LWW
  isDeleted: boolean; // tombstone = undo
  deletedAt?: string; // ISO8601
}
