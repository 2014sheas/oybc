import { PULL_APPLY_ORDER } from '@oybc/shared';
import { applyRemoteSubdoc } from './pullApply';
import { applyTaskEventsBatch } from './taskEventPull';
import {
  currentAppBuild,
  fetchRetryableQuarantine,
  releaseQuarantinedDocs,
  stampQuarantineAttempt,
  QUARANTINE_RETRY_LIMIT,
} from './syncQuarantine';

/**
 * Re-fetches the docs a PREVIOUS build quarantined (issue #300; docs/
 * SYNC_STRATEGY.md §Forward-compatible pull). iOS twin:
 * `AppDatabase.retryQuarantinedPullDocs`.
 *
 * Runs at the start of every pull, but does anything only after the build
 * changed (`fetchRetryableQuarantine` selects rows recorded by another build),
 * so an unchanged build never re-reads a doc it already failed on. Each
 * retryable doc is fetched by id (collections in `PULL_APPLY_ORDER`, so a
 * compound's task lands before its children) and applied through the SAME
 * path as a normal pull — which releases it on success and re-ledgers it (with
 * this build) on another schema failure. A doc gone from the server is
 * released. Rows this pass could neither apply nor re-quarantine (rejected for a
 * permanent reason) are re-stamped so they wait for the next build too.
 *
 * Firebase-free on purpose: the remote read is injected.
 *
 * @param userId - The signed-in uid.
 * @param fetchDoc - Reads one remote doc by collection + id; null when absent.
 * @param appBuild - The running build (default: this build).
 * @param limit - Max rows per pass (default `QUARANTINE_RETRY_LIMIT`).
 * @returns Docs applied and per-doc status lines.
 * @throws Whatever `fetchDoc` throws (a transport error) — rows stay for the next pull.
 */
export async function retryQuarantinedDocs(
  userId: string,
  fetchDoc: (collection: string, docId: string) => Promise<Record<string, unknown> | null>,
  appBuild: string = currentAppBuild(),
  limit: number = QUARANTINE_RETRY_LIMIT,
): Promise<{ pulled: number; details: string[] }> {
  const rows = await fetchRetryableQuarantine(userId, appBuild, limit);
  const details: string[] = [];
  let pulled = 0;
  if (rows.length === 0) return { pulled, details };

  for (const collection of PULL_APPLY_ORDER) {
    const group = rows.filter((r) => r.collection === collection);
    if (group.length === 0) continue;
    const gone: string[] = [];
    const docs: Record<string, unknown>[] = [];
    for (const row of group) {
      const doc = await fetchDoc(collection, row.docId);
      if (doc) docs.push(doc);
      else gone.push(row.docId);
    }
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
  }
  await stampQuarantineAttempt(rows, appBuild);
  return { pulled, details };
}
