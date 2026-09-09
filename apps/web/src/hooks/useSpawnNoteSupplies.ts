import { useEffect, useState } from 'react';
import {
  poolSourceSupplyById,
  sourcesForRecord,
  type BoardSourceSupply,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import { fetchBoardSourceSupply } from '../db/operations/boardSources';

/**
 * Resolves a freshly-spawned board's source supplies for the
 * spawn-provenance note (loose-ends sweep 2026-09-09) — pool kinds sync
 * from the live lookups, board kinds through the shared (series-binding
 * aware) board-supply reader with the record's 'todo' filter applied,
 * exactly as the spawn resolved them. `undefined` template (note not
 * visible) short-circuits to `null`; the note renders once supplies
 * resolve. Extracted from `BoardPlaySurface` (file-size posture — a
 * self-contained async concern, not grid logic).
 */
export function useSpawnNoteSupplies(
  template: RecurringBoardTemplate | undefined,
  poolsById: Record<string, Pool>,
  taskMap: Record<string, Task>,
): BoardSourceSupply[] | null {
  const [supplies, setSupplies] = useState<BoardSourceSupply[] | null>(null);
  useEffect(() => {
    if (template === undefined) {
      setSupplies(null);
      return;
    }
    let cancelled = false;
    void (async () => {
      const sources = sourcesForRecord(template);
      const resolved: BoardSourceSupply[] = [];
      for (const source of sources) {
        if (source.kind === 'pool') {
          resolved.push({
            source,
            supplyTaskIds: poolSourceSupplyById(source.sourceId, poolsById, taskMap),
          });
          continue;
        }
        const info = await fetchBoardSourceSupply(source.sourceId);
        const raw = info?.supplyTaskIds ?? [];
        resolved.push({
          source,
          supplyTaskIds:
            source.filter === 'todo' && info
              ? raw.filter((id) => !info.doneTaskIds.has(id))
              : raw,
        });
      }
      if (!cancelled) setSupplies(resolved);
    })();
    return () => {
      cancelled = true;
    };
  }, [template, poolsById, taskMap]);
  return supplies;
}
