import { nextPullWatermark, type PullWatermark } from '@oybc/shared';
import { db } from '../internal';

/**
 * Per-collection pull checkpoints (2026-10-07 — web parity with the iOS
 * launch-watchdog fix; iOS twin: `sync_watermarks` in
 * `AppDatabase+PullApply.swift`). Local-only Dexie store `syncWatermarks`
 * (v19): one row per (user, collection) holding the highest server
 * `_syncedAt` the pull has applied, so a pull interrupted after collection N
 * resumes at N+1 instead of re-reading everything from the old watermark.
 *
 * Firebase-free on purpose (same #280/#281 reason as `pullApply.ts`): a
 * Firestore `Timestamp` is read structurally (`seconds` / `nanoseconds`).
 */

/**
 * A doc's raw `_syncedAt` as a watermark: a Firestore `Timestamp` (or any
 * `{ seconds, nanoseconds }` value). A missing / pending (`null`) value is
 * null — it never moves a checkpoint.
 *
 * @param value - The raw `_syncedAt` field.
 * @returns The watermark, or null.
 */
export function pullWatermarkOf(value: unknown): PullWatermark | null {
  if (!value || typeof value !== 'object') return null;
  const { seconds, nanoseconds } = value as { seconds?: unknown; nanoseconds?: unknown };
  if (typeof seconds !== 'number' || typeof nanoseconds !== 'number') return null;
  return { seconds, nanoseconds };
}

/**
 * Every stored checkpoint for `userId`, keyed by collection.
 *
 * @param userId - The signed-in uid.
 * @returns collection → checkpoint.
 */
export async function fetchPullWatermarks(userId: string): Promise<Record<string, PullWatermark>> {
  const rows = await db.syncWatermarks.where('[userId+collection]').between([userId, ''], [userId, '￿']).toArray();
  return Object.fromEntries(rows.map((r) => [r.collection, { seconds: r.seconds, nanoseconds: r.nanoseconds }]));
}

/**
 * Raises `collection`'s checkpoint to the highest `_syncedAt` among `docs`
 * (never lowers it; a batch with no stamped doc is a no-op). Call only after
 * every doc in `docs` has been applied, so a checkpoint never gets ahead of
 * the rows it covers.
 *
 * @param userId - The signed-in uid.
 * @param collection - The pulled collection.
 * @param docs - The applied remote docs.
 */
export async function advancePullWatermark(
  userId: string,
  collection: string,
  docs: ReadonlyArray<Record<string, unknown>>,
): Promise<void> {
  await db.transaction('rw', db.syncWatermarks, async () => {
    const row = await db.syncWatermarks.get([userId, collection]);
    const prev = row ? { seconds: row.seconds, nanoseconds: row.nanoseconds } : null;
    const next = nextPullWatermark(prev, docs.map((d) => pullWatermarkOf(d._syncedAt)));
    if (!next || (prev && next.seconds === prev.seconds && next.nanoseconds === prev.nanoseconds)) return;
    await db.syncWatermarks.put({ userId, collection, ...next });
  });
}
