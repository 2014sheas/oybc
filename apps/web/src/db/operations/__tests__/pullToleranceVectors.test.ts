import * as fs from 'fs';
import * as path from 'path';
import { afterEach, describe, expect, it } from 'vitest';
import { SYNC_COLLECTIONS, type SyncCollection } from '@oybc/shared';
import { db } from '../../internal';
import { applyRemoteSubdoc } from '../pullApply';
import { applyTaskEventsBatch } from '../taskEventPull';
import { listQuarantinedDocs } from '../syncQuarantine';

/**
 * Cross-platform pull-tolerance vectors (issue #300; docs/SYNC_STRATEGY.md
 * §Forward-compatible pull) run END TO END through web's pull-apply. The same
 * fixture runs through iOS's `applyPullBatch` in `PullToleranceVectorTests.swift`:
 * both suites passing is what proves a pulled doc is applied (with the same
 * fallback values) or quarantined IDENTICALLY on the two platforms.
 */

interface Vector {
  name: string;
  collection: SyncCollection;
  set: Record<string, unknown>;
  disposition: 'applied' | 'quarantined';
  expect?: Record<string, unknown>;
}

const USER = 'user-1';
const fixture = JSON.parse(
  fs.readFileSync(path.join(__dirname, '../../../../../../packages/shared/tests/fixtures/pullToleranceVectors.json'), 'utf8'),
) as { bases: Record<string, Record<string, unknown>>; cases: Vector[] };

/** The case's doc: its collection's base with `$USER` resolved, then `set` overlaid. */
function docFor(vector: Vector): Record<string, unknown> {
  const base = JSON.parse(JSON.stringify(fixture.bases[vector.collection]).split('$USER').join(USER)) as Record<string, unknown>;
  return { ...base, ...vector.set };
}

/** Applies one doc through the same entry point the pull uses; true when it was stored. */
async function pull(collection: SyncCollection, doc: Record<string, unknown>): Promise<boolean> {
  if (collection === 'taskEvents') return (await applyTaskEventsBatch(USER, [doc])).pulled === 1;
  return (await applyRemoteSubdoc(collection, doc, USER))?.startsWith('Pulled') ?? false;
}

afterEach(async () => {
  await Promise.all([...SYNC_COLLECTIONS.map((c) => db.table(c).clear()), db.syncQueue.clear(), db.syncQuarantine.clear()]);
});

describe('pull tolerance vectors — web end to end', () => {
  it.each(fixture.cases.map((c) => [c.name, c] as const))('%s', async (_name, vector) => {
    if (vector.collection === 'boardTasks') {
      // iOS needs the board + task for the placement's foreign keys; seed the same here.
      await pull('boards', docFor({ ...vector, collection: 'boards', set: {} }));
      await pull('tasks', docFor({ ...vector, collection: 'tasks', set: {} }));
    }
    const doc = docFor(vector);

    const stored = await pull(vector.collection, doc);

    const row = (await db.table(vector.collection).get(doc.id as string)) as Record<string, unknown> | undefined;
    const ledger = (await listQuarantinedDocs(USER)).filter((r) => r.collection === vector.collection);
    if (vector.disposition === 'applied') {
      expect(stored).toBe(true);
      expect(ledger).toEqual([]);
      for (const [field, want] of Object.entries(vector.expect ?? {})) {
        expect({ [field]: row?.[field] ?? null }).toEqual({ [field]: want });
      }
    } else {
      expect(stored).toBe(false);
      expect(row).toBeUndefined();
      expect(ledger.map((r) => r.docId)).toEqual([doc.id]);
    }
  });
});
