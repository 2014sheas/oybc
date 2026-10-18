import { PULL_APPLY_ORDER } from '@oybc/shared';
import { applyRemoteSubdoc } from './pullApply';
import { applyTaskEventsBatch } from './taskEventPull';
import {
  currentAppBuild,
  fetchRetryableQuarantine,
  releaseQuarantinedDocs,
  stampQuarantineAttempt,
  QUARANTINE_FETCH_CONCURRENCY,
  QUARANTINE_RETRY_LIMIT,
} from './syncQuarantine';
import type { SyncQuarantineRow } from '../database';

/**
 * Maps `items` through `fn` with at most `limit` calls in flight, keeping the
 * input order. After the first rejection no further call starts and the
 * rejection is rethrown once the calls already in flight settle.
 *
 * @param items - The inputs.
 * @param limit - Max concurrent calls.
 * @param fn - The async mapper.
 * @returns The results, in input order.
 * @throws The first rejection of `fn`.
 */
async function mapWithConcurrency<T, R>(items: readonly T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  let failure: { error: unknown } | null = null;
  const worker = async (): Promise<void> => {
    while (!failure && next < items.length) {
      const index = next++;
      try {
        results[index] = await fn(items[index]);
      } catch (error) {
        failure ??= { error };
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  if (failure) throw (failure as { error: unknown }).error;
  return results;
}

/**
 * Re-fetches the docs a PREVIOUS build quarantined (issue #300; docs/
 * SYNC_STRATEGY.md §Forward-compatible pull). iOS twin:
 * `AppDatabase.retryQuarantinedPullDocs`.
 *
 * Runs at the start of every pull, but does anything only after the build
 * changed (`fetchRetryableQuarantine` selects rows recorded by another build),
 * so an unchanged build never re-reads a doc it already failed on. Each
 * collection's retryable docs are fetched by id (a few in flight at once; the
 * collections in `PULL_APPLY_ORDER`, so a compound's task lands before its
 * children) and applied through the SAME path as a normal pull — which releases
 * a doc on success and re-ledgers it (with this build) on another schema
 * failure. A doc gone from the server is released. Rows of a collection this
 * pass finished are re-stamped, so a doc rejected for a permanent reason waits
 * for the next build too.
 *
 * Never throws: a transport failure or an account change stops the pass and
 * returns what earlier collections already applied (their `pulled` count still
 * counts); the unfinished rows keep their old build and wait for the next pull.
 *
 * Firebase-free on purpose: the remote read is injected.
 *
 * @param userId - The signed-in uid.
 * @param fetchDoc - Reads one remote doc by collection + id; null when absent.
 * @param opts - `appBuild` (default: this build), `limit` (default
 *   `QUARANTINE_RETRY_LIMIT`) and `isActive` — false once the signed-in account
 *   is no longer `userId`, checked before every collection's apply.
 * @returns Docs applied and per-doc status lines.
 */
export async function retryQuarantinedDocs(
  userId: string,
  fetchDoc: (collection: string, docId: string) => Promise<Record<string, unknown> | null>,
  opts: { appBuild?: string; limit?: number; isActive?: () => boolean } = {},
): Promise<{ pulled: number; details: string[] }> {
  const { appBuild = currentAppBuild(), limit = QUARANTINE_RETRY_LIMIT, isActive = () => true } = opts;
  const details: string[] = [];
  const accountChanged = 'Quarantine retry stopped: the signed-in account changed';
  const finished: SyncQuarantineRow[] = [];
  let pulled = 0;
  try {
    const rows = await fetchRetryableQuarantine(userId, appBuild, limit);
    for (const collection of PULL_APPLY_ORDER) {
      const group = rows.filter((r) => r.collection === collection);
      if (group.length === 0) continue;
      if (!isActive()) {
        details.push(accountChanged);
        break;
      }
      const fetched = await mapWithConcurrency(group, QUARANTINE_FETCH_CONCURRENCY, (row) => fetchDoc(collection, row.docId));
      // The fetches took time: a sign-out / account switch may have landed.
      if (!isActive()) {
        details.push(accountChanged);
        break;
      }
      const docs = fetched.filter((d): d is Record<string, unknown> => d !== null);
      const gone = group.filter((_, i) => fetched[i] === null).map((r) => r.docId);
      await releaseQuarantinedDocs(userId, collection, gone);
      for (const id of gone) details.push(`Released quarantined ${collection}/${id}: no longer on the server`);

      if (collection === 'taskEvents') {
        const batch = await applyTaskEventsBatch(userId, docs);
        pulled += batch.pulled;
        details.push(...batch.details);
      } else {
        for (const doc of docs) {
          const status = await applyRemoteSubdoc(collection, doc, userId);
          if (status?.startsWith('Pulled')) pulled += 1;
          if (status) details.push(`Retry ${status}`);
        }
      }
      finished.push(...group);
    }
  } catch (err) {
    details.push(`Quarantine retry skipped: ${err instanceof Error ? err.message : String(err)}`);
  }
  try {
    await stampQuarantineAttempt(finished, appBuild);
  } catch (err) {
    details.push(`Quarantine retry could not re-stamp: ${err instanceof Error ? err.message : String(err)}`);
  }
  return { pulled, details };
}
