import { db } from '../internal';
import type { SyncQuarantineRow } from '../database';

/**
 * Forward-compat quarantine ledger (issue #300, ROADMAP Track L4; docs/
 * SYNC_STRATEGY.md §Forward-compatible pull). iOS twin: `sync_quarantine` in
 * `AppDatabase+PullQuarantine.swift`.
 *
 * A pulled doc this build cannot apply — an unknown enum value written by a
 * newer app version, or a schema-invalid doc — is SKIPPED so it never blocks the
 * rest of its batch. The pull checkpoint still moves past it, so without a
 * record it would never be re-read after an app update. This LOCAL-ONLY ledger
 * (Dexie `syncQuarantine`, v22; never synced) is that record: one row per
 * skipped doc, stamped with the build that failed to apply it, and a later
 * build re-fetches exactly those docs by id (`quarantineRetry.ts`).
 *
 * Firebase-free on purpose (same #280/#281 reason as `pullApply.ts`).
 */

/** Max ledger rows one retry pass re-fetches (the rest wait for the next pull). */
export const QUARANTINE_RETRY_LIMIT = 200;

/**
 * The identity of THIS build: a doc quarantined by build B is retried only by a
 * different build. Injected at build time (`__APP_BUILD__`, vite.config.ts =
 * package version + commit); `'dev'` where the define is absent (vitest).
 *
 * @returns The build identity string.
 */
export function currentAppBuild(): string {
  return typeof __APP_BUILD__ === 'string' ? __APP_BUILD__ : 'dev';
}

/**
 * The doc id of a raw remote doc, if it has a usable one.
 *
 * @param remoteData - The untrusted remote doc.
 * @returns Its `id`, or null when it has none (an unaddressable doc is never ledgered).
 */
function docIdOf(remoteData: unknown): string | null {
  const id = (remoteData as { id?: unknown } | null)?.id;
  return typeof id === 'string' && id.length > 0 ? id : null;
}

/**
 * Records `remoteData` as skipped by this build so a later build can re-fetch
 * it. Idempotent: re-quarantining an id updates its reason and build and keeps
 * its original `quarantinedAt`. A doc with no usable `id`, or whose own
 * `userId` is another account's, is not ledgered (nothing to re-fetch / not
 * ours).
 *
 * @param userId - The signed-in uid the pull runs for.
 * @param collection - The pulled subcollection.
 * @param remoteData - The raw remote doc.
 * @param reason - Why it was skipped (no uids).
 * @param appBuild - The build recording it (default: this build).
 * @returns True when a ledger row was written.
 */
export async function quarantinePulledDoc(
  userId: string,
  collection: string,
  remoteData: unknown,
  reason: string,
  appBuild: string = currentAppBuild(),
): Promise<boolean> {
  const docId = docIdOf(remoteData);
  if (!docId) return false;
  const owner = (remoteData as { userId?: unknown }).userId;
  if (typeof owner === 'string' && owner !== userId) return false;
  const existing = await db.syncQuarantine.get([userId, collection, docId]);
  await db.syncQuarantine.put({
    userId,
    collection,
    docId,
    reason,
    appBuild,
    quarantinedAt: existing?.quarantinedAt ?? new Date().toISOString(),
  });
  console.warn(`[sync] quarantined ${collection}/${docId}: ${reason}`);
  return true;
}

/**
 * Removes docs from the ledger — they applied (or no longer exist remotely).
 *
 * @param userId - The signed-in uid.
 * @param collection - The pulled subcollection.
 * @param docIds - The ids to release.
 */
export async function releaseQuarantinedDocs(
  userId: string,
  collection: string,
  docIds: readonly string[],
): Promise<void> {
  if (docIds.length === 0) return;
  await db.syncQuarantine.bulkDelete(docIds.map((id) => [userId, collection, id] as [string, string, string]));
}

/**
 * The ledger rows a build should re-fetch: those recorded by any OTHER build,
 * oldest first, capped at `limit`.
 *
 * @param userId - The signed-in uid.
 * @param appBuild - The running build.
 * @param limit - Max rows (default `QUARANTINE_RETRY_LIMIT`).
 * @returns The retryable rows.
 */
export async function fetchRetryableQuarantine(
  userId: string,
  appBuild: string = currentAppBuild(),
  limit: number = QUARANTINE_RETRY_LIMIT,
): Promise<SyncQuarantineRow[]> {
  const rows = await db.syncQuarantine.where('userId').equals(userId).toArray();
  return rows
    .filter((r) => r.appBuild !== appBuild)
    .sort((a, b) => a.quarantinedAt.localeCompare(b.quarantinedAt))
    .slice(0, limit);
}

/**
 * Whether any doc of `collection` is quarantined for `userId`.
 *
 * @param userId - The signed-in uid.
 * @param collection - The pulled subcollection.
 * @returns True when the ledger holds at least one such doc.
 */
export async function hasQuarantinedDocs(userId: string, collection: string): Promise<boolean> {
  return (await db.syncQuarantine.where('userId').equals(userId).filter((r) => r.collection === collection).count()) > 0;
}

/**
 * Every quarantined doc for `userId` (diagnostics and tests).
 *
 * @param userId - The signed-in uid.
 * @returns All ledger rows.
 */
export async function listQuarantinedDocs(userId: string): Promise<SyncQuarantineRow[]> {
  return db.syncQuarantine.where('userId').equals(userId).toArray();
}

/**
 * Re-stamps rows with `appBuild` so this build does not re-fetch them again
 * (used for rows a retry could neither apply nor re-quarantine, e.g. a doc
 * rejected for a permanent reason).
 *
 * @param rows - The rows to stamp.
 * @param appBuild - The running build.
 */
export async function stampQuarantineAttempt(
  rows: readonly SyncQuarantineRow[],
  appBuild: string = currentAppBuild(),
): Promise<void> {
  if (rows.length === 0) return;
  await db.transaction('rw', db.syncQuarantine, async () => {
    for (const row of rows) {
      const live = await db.syncQuarantine.get([row.userId, row.collection, row.docId]);
      if (live && live.appBuild !== appBuild) await db.syncQuarantine.put({ ...live, appBuild });
    }
  });
}
