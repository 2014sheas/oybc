/**
 * sharedCounterMerge.ts — Phase 4 additive-merge conflict resolution.
 *
 * Implements the three-way merge for `Task.currentCount` on shared-counter
 * source tasks when two devices both increment the same counter while offline.
 *
 * ## Why additive merge is needed
 *
 * Plain LWW (last-write-wins) silently loses count increments:
 *
 *   Both devices start at currentCount: 10 (lastSyncedCount: 10)
 *   Device A increments +5 → currentCount: 15, version: N+1
 *   Device B increments +3 → currentCount: 13, version: N+1
 *   Both push. Higher-version/timestamp write wins. Result: 13 or 15.
 *   Expected: 18 (10 + 5 + 3). One device's increments vanish.
 *
 * Additive merge preserves both deltas by computing:
 *
 *   mergedCount = remote.currentCount + (local.currentCount - lastSyncedCount)
 *               = remote.currentCount + local_delta_since_last_sync
 *               = 13 + (15 - 10) = 18  ✓
 *
 * ## Design decisions (ARCHITECTURE.md §Shared counters, Decision 5 + Phase 4)
 *
 * - Additive merge fires ONLY for shared-counter sources (tasks that have at
 *   least one other Task with `sharedCounterId === thisTask.id`). Standalone
 *   counters keep plain LWW for v1.
 * - When `lastSyncedCount` is null/undefined (first sync, no common ancestor),
 *   the merge falls back to LWW — additive merge without a baseline is
 *   ambiguous.
 * - Plain LWW applies to ALL other Task fields (`maxCount`, `title`, etc.).
 *   Only `currentCount` uses additive merge.
 * - Overshoot invariant: the merged count is NEVER clamped to `maxCount`.
 *   If concurrent increments push the total above the threshold, the merged
 *   result reflects the full sum. No `Math.min(merged, maxCount)`.
 * - Negative deltas (decrements) are respected. A local decrement applied on
 *   top of a remote increment produces a smaller-than-remote result, which
 *   correctly reflects the user's intent ("I over-counted; back off by N").
 *
 * ## Cross-platform parity
 *
 * This TypeScript file is the source of truth. The manual Swift port lives in
 * `apps/ios/OYBC/Helpers/SharedCounterMerge.swift` and MUST be mirrored on
 * any math change to prevent cross-platform divergence.
 */

/**
 * Result of `additiveMergeCount`.
 */
export interface MergeCountResult {
  /**
   * The resolved `currentCount` to write to the local DB and push to Firestore.
   * Never negative (clamped to 0 on the low end). No high-end clamp.
   */
  merged: number;
  /**
   * Whether additive merge was applied (`true`) or plain LWW was used
   * (`false`). Callers can log this for debugging.
   */
  mergeApplied: boolean;
}

/**
 * Resolves a concurrent-increment conflict for a shared-counter source task
 * using three-way additive merge.
 *
 * Call this when:
 *   1. The task is a shared-counter source (other tasks reference it).
 *   2. Both local and remote `currentCount` differ from `lastSyncedCount`
 *      (both devices incremented since their common ancestor).
 *
 * Formula:
 *   mergedCount = remoteCount + (localCount - lastSyncedCount)
 *
 * The formula applies the local delta ("how much we added since last sync")
 * on top of the remote's current value. Both devices' contributions survive.
 *
 * @param localCount - The local device's current `Task.currentCount` (AFTER
 *   the local increments that haven't been pushed yet).
 * @param remoteCount - The remote Firestore document's `currentCount` (the
 *   value the other device pushed).
 * @param lastSyncedCount - The common-ancestor value: what `currentCount` was
 *   the last time this task was successfully synced (pushed or pulled) by
 *   THIS device. When null/undefined, LWW is used as a safe fallback.
 * @returns `{ merged, mergeApplied }`. If `mergeApplied` is false, `merged`
 *   equals the LWW winner (higher of local/remote, or remote on tie).
 *
 * @example
 * // Both devices start at 10.
 * // Device A increments to 15, Device B increments to 13.
 * additiveMergeCount(15, 13, 10)
 * // → { merged: 18, mergeApplied: true }
 *
 * @example
 * // Only Device A incremented (B didn't change since last sync).
 * additiveMergeCount(15, 10, 10)
 * // → { merged: 15, mergeApplied: true }
 * // (remote === lastSyncedCount → local delta = 5, remote delta = 0, merged = 10 + 5 = 15)
 *
 * @example
 * // No common ancestor known (first sync).
 * additiveMergeCount(15, 13, null)
 * // → { merged: 15, mergeApplied: false }  (LWW — local wins on higher value)
 */
export function additiveMergeCount(
  localCount: number,
  remoteCount: number,
  lastSyncedCount: number | null | undefined,
): MergeCountResult {
  // Null/undefined lastSyncedCount → no common ancestor → fall back to LWW.
  if (lastSyncedCount == null) {
    const lwwWinner = localCount >= remoteCount ? localCount : remoteCount;
    return { merged: Math.max(0, lwwWinner), mergeApplied: false };
  }

  // Three-way merge: apply local delta on top of remote.
  // localDelta may be negative (the user decremented to correct an over-count).
  const localDelta = localCount - lastSyncedCount;
  const raw = remoteCount + localDelta;

  // LOW-END CLAMP: merged count must not go below 0.
  // NO HIGH-END CLAMP: overshoot is intentional (feedback_counter_overshoot_is_valid).
  return { merged: Math.max(0, raw), mergeApplied: true };
}

/**
 * Detects whether an additive merge is needed given local, remote, and
 * last-synced counts.
 *
 * A merge is needed when BOTH devices have deviated from the common ancestor:
 *   - Local has changed:  `localCount !== lastSyncedCount`
 *   - Remote has changed: `remoteCount !== lastSyncedCount`
 *
 * If only one device changed, regular LWW already picks the right winner
 * (the changed value wins). Additive merge only matters when both changed.
 *
 * @returns `true` if concurrent edits exist and additive merge should fire.
 *   `false` if LWW is sufficient (one or both counts haven't changed, or
 *   `lastSyncedCount` is null).
 */
export function needsAdditiveMerge(
  localCount: number,
  remoteCount: number,
  lastSyncedCount: number | null | undefined,
): boolean {
  if (lastSyncedCount == null) return false;
  const localChanged = localCount !== lastSyncedCount;
  const remoteChanged = remoteCount !== lastSyncedCount;
  return localChanged && remoteChanged;
}
