/**
 * Sync-queue ownership rules (docs/GUEST_MODE.md §Collision).
 *
 * Every queue item is stamped at enqueue with `ownerUid` — the Firebase uid
 * signed in at that moment (a LOCAL queue column, never on the wire). The
 * push path runs for exactly one uid; these two predicates decide which queue
 * rows it may touch. Pure so both platforms pin the same truth table — Swift
 * twins: `SyncQueueOwnership` in `Database/Models/SyncQueue.swift`.
 *
 * Why it exists: during a guest→account collision switch the new uid's sync
 * loop can start before the discarded guest's queue is cleared. `boardTasks`
 * and `compoundChildren` payloads carry no `userId`, so Firestore rules would
 * accept the guest's rows into the real account (orphan placements). A row
 * owned by another uid can never become valid for this one, so it is DROPPED,
 * never pushed.
 */

/**
 * True when a queue item belongs to a DIFFERENT account than the one being
 * pushed for, and must therefore be dropped rather than pushed.
 *
 * A null/absent owner is a legacy (pre-stamp) row, or one enqueued with no
 * signed-in user — it is NOT foreign and pushes as before.
 *
 * @param ownerUid - The item's enqueue-time owner stamp (may be null/absent).
 * @param userId - The uid the push is running for.
 * @returns Whether the item is owned by another uid.
 */
export function isForeignOwnedSyncItem(
  ownerUid: string | null | undefined,
  userId: string
): boolean {
  return ownerUid != null && ownerUid !== userId;
}

/**
 * True when an incoming enqueue (owned by `incomingOwnerUid`) may coalesce
 * into an existing PENDING row (owned by `existingOwnerUid`).
 *
 * Rows only coalesce within one owner, so a later account's edit is never
 * folded into (and dropped along with) another account's row. A legacy
 * null-owner row is adoptable by any incoming owner (it is then re-stamped
 * with the incoming owner); a stamped row never absorbs a differently-owned
 * (or unowned) incoming op — that op appends its own row instead.
 *
 * @param existingOwnerUid - Owner stamp of the existing PENDING row.
 * @param incomingOwnerUid - Owner stamp of the incoming enqueue.
 * @returns Whether the two may coalesce.
 */
export function canCoalesceSyncOwners(
  existingOwnerUid: string | null | undefined,
  incomingOwnerUid: string | null | undefined
): boolean {
  return existingOwnerUid == null || existingOwnerUid === (incomingOwnerUid ?? null);
}
