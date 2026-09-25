import { useEffect, useState } from 'react';
import {
  poolSourceSupplyById,
  availableSupplyIds,
  sourcesForRecord,
  type BoardSourceSupply,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import { fetchBoardSourceSupplyForWindow } from '../db/operations/boardSources';

/** What {@link useSpawnNoteSupplies} resolves for the provenance note. */
export interface SpawnNoteSupplies {
  /** Every source's available supply, as the spawn dealt from it. */
  supplies: BoardSourceSupply[];
  /** Board sources with no board for the spawned window — they dealt
   *  nothing; the note ends "· No board for this window yet". */
  noBoardForWindowCount: number;
}

/**
 * Resolves a freshly-spawned board's source supplies for the
 * spawn-provenance note (loose-ends sweep 2026-09-09) — pool kinds sync
 * from the live lookups, board kinds through the shared (series-binding
 * aware) board-supply reader with the record's 'todo' filter applied,
 * exactly as the spawn resolved them. `undefined` template (note not
 * visible) short-circuits to `null`; the note renders once supplies
 * resolve. Extracted from `BoardPlaySurface` (file-size posture — a
 * self-contained async concern, not grid logic).
 *
 * Board sources resolve against the SPAWNED board's window start (owner
 * ruling 2026-09-24 — the same reference the spawn used), so a source that
 * had no board for that window reads as such here too.
 *
 * @param template - The record the board spawned from (undefined hides the note).
 * @param poolsById - Live pools.
 * @param taskMap - Live tasks.
 * @param windowStart - The spawned board's `startDate` (local ISO).
 * @returns The resolved supplies + windowless count, or `null` until resolved.
 */
export function useSpawnNoteSupplies(
  template: RecurringBoardTemplate | undefined,
  poolsById: Record<string, Pool>,
  taskMap: Record<string, Task>,
  windowStart: string,
): SpawnNoteSupplies | null {
  const [supplies, setSupplies] = useState<SpawnNoteSupplies | null>(null);
  useEffect(() => {
    if (template === undefined) {
      setSupplies(null);
      return;
    }
    let cancelled = false;
    void (async () => {
      const sources = sourcesForRecord(template);
      const resolved: BoardSourceSupply[] = [];
      let noBoardForWindowCount = 0;
      for (const source of sources) {
        if (source.kind === 'pool') {
          resolved.push({
            source,
            supplyTaskIds: poolSourceSupplyById(source.sourceId, poolsById, taskMap),
          });
          continue;
        }
        const resolution = await fetchBoardSourceSupplyForWindow(source.sourceId, windowStart);
        if (resolution.kind === 'noWindow') noBoardForWindowCount += 1;
        const info = resolution.kind === 'live' ? resolution.info : null;
        resolved.push({
          source,
          supplyTaskIds: availableSupplyIds(source, info?.supplyTaskIds ?? [], info?.doneTaskIds),
        });
      }
      if (!cancelled) setSupplies({ supplies: resolved, noBoardForWindowCount });
    })();
    return () => {
      cancelled = true;
    };
  }, [template, poolsById, taskMap, windowStart]);
  return supplies;
}
