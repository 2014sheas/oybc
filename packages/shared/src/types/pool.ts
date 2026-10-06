/**
 * Pool — Task Pools + Recurring Boards Rework (P1)
 *
 * A user-named collection of task REFERENCES (never copies) that lives in
 * the Tasks tab as a first-class entity. Any board — one-off, core, or
 * repeating — may *draw from* a pool at creation; pools themselves carry
 * NO board actions (locked): no "use in board", no FEEDS control, no
 * default pinning (docs/POOLS_RECURRING.md §Surfaces item 1).
 *
 * - A task may belong to many pools. Deleting a pool never deletes its
 *   tasks. **Detachment is derived, not cascaded**: mix resolution
 *   (`resolveMix` in `../algorithms/poolMix`) and core-defaults resolution
 *   simply skip `isDeleted` pools at read time — no multi-record cascade
 *   write, no LWW race.
 * - **Health is derived, never stored**: resolvable non-deleted `taskIds`
 *   count vs a consumer's `fillableCellCount` (from `@oybc/bingo-core`).
 * - Replaces the un-shipped "starter packs" v1 idea — starter packs are
 *   explicitly deferred (locked 2026-07-19); this type carries no fields
 *   for them.
 *
 * Canonical design: docs/POOLS_RECURRING.md §Data model → New entity: Pool.
 */
import type { VaryLevel } from './boardSource';

export interface Pool {
  // Identity
  id: string;                // UUID (client-generated)
  userId: string;            // FK to users

  // Configuration
  name: string;               // User-named, e.g. "Morning Kickstart" (1-120 chars after trim)
  /**
   * Ordered task ID references into the task library — never copies.
   * Soft-deleted tasks are NOT auto-removed from this list; consumers
   * (`resolveMix`, core-defaults resolution) filter at read time so the
   * user's intent survives a temporary delete/undo.
   */
  taskIds: string[];
  /**
   * Pool-level default dice per member (docs/BOARD_SOURCES.md §Member
   * rules → *Pool-level defaults*, 2026-10-06): task id → `VaryLevel`.
   * Only levels `1 | 2` are stored (the ops prune a `0`, exactly as
   * `pruneMemberRule` does for a source rule); an id missing from the map
   * has no default. **Absent ≡ `{}`**: the ops always WRITE the map (`{}`
   * when empty, so a clear propagates as an overwrite, never a field
   * delete) and `PoolSchema` defaults a pulled doc to `{}`, but a local
   * row written before the field existed carries no key — readers go
   * through `pool.memberVary ?? {}` (the `BoardSource.memberRules` /
   * `RecurringBoardTemplate.manualTaskVary` posture). iOS decodes a
   * missing column to `[:]`.
   *
   * Consumed by `seedMemberRulesFromPool` (the Sources sheet copies the
   * defaults onto the pulled source's `memberRules`) and
   * `effectiveMemberRules` (spawn / prefill fallback for a member that
   * carries no stored `vary`).
   */
  memberVary?: Record<string, VaryLevel>;

  // Timestamps
  createdAt: string;          // ISO8601
  updatedAt: string;          // ISO8601

  // Sync metadata
  lastSyncedAt?: string;      // ISO8601
  version: number;            // Optimistic locking (incremented on each update)
  isDeleted: boolean;         // Soft delete
  deletedAt?: string;         // ISO8601
}

/**
 * Pool creation input. Fields not listed are computed client-side at
 * insert: `id` (UUID), `createdAt`/`updatedAt` (now), `version` (1),
 * `isDeleted` (false).
 */
export interface CreatePoolInput {
  name: string;
  taskIds: string[];
  /** Pool-level default dice; absent = none (stored as `{}`). `0` entries are pruned. */
  memberVary?: Record<string, VaryLevel>;
}

/**
 * Partial update input. `userId` is NOT mutable post-create.
 */
export interface UpdatePoolInput {
  name?: string;
  taskIds?: string[];
  /** Replaces the stored map when present (pruned of `0`s); absent = leave as is. */
  memberVary?: Record<string, VaryLevel>;
}
