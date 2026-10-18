import {
  rekeyIds,
  rekeyRecordKeys,
  resolveCountKind,
  type BoardSource,
  type ManualTaskTarget,
  type Pool,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import { decodeRecurringDraftMix, encodeRecurringDraftMix } from '../recurringDraftMix';

/**
 * placementSweepRekey.ts — the pure half of the sweep's rule re-key (slice 4a):
 * stored rules keyed by a legacy derived row's id move onto its root's id.
 * Every helper returns `null` (or the same reference) when nothing changes, so
 * the applier authors a row only when it actually differs.
 */

type Rekey = Record<string, string>;

/** Re-key one source's exclusions, member rules and their per-part rules. */
function rekeySource(s: BoardSource, map: Rekey): BoardSource {
  const excludedTaskIds = rekeyIds(s.excludedTaskIds, map) as string[];
  let memberRules = s.memberRules;
  if (memberRules) {
    const keyed = rekeyRecordKeys(memberRules, map);
    let changed = keyed !== memberRules;
    const out: typeof keyed = {};
    for (const [id, rule] of Object.entries(keyed)) {
      const parts = rule.parts ? rekeyRecordKeys(rule.parts, map) : undefined;
      if (parts !== rule.parts) changed = true;
      out[id] = parts !== rule.parts ? { ...rule, parts } : rule;
    }
    if (changed) memberRules = out;
  }
  if (excludedTaskIds === s.excludedTaskIds && memberRules === s.memberRules) return s;
  return { ...s, excludedTaskIds, ...(memberRules ? { memberRules } : {}) };
}

/** Re-key a sources array; the SAME array when no source changed. */
export function rekeySources(sources: BoardSource[], map: Rekey): BoardSource[] {
  const next = sources.map((s) => rekeySource(s, map));
  return next.some((s, i) => s !== sources[i]) ? next : sources;
}

/**
 * The template fields a re-key changes, or `null` when it changes none.
 * A derived id in `manualTaskIds` that re-keys to a root carries its frozen
 * goal onto `manualTaskTargets[root]` when absent.
 */
export function rekeyTemplate(
  t: RecurringBoardTemplate,
  map: Rekey,
  tasksById: ReadonlyMap<string, Task>,
): Partial<RecurringBoardTemplate> | null {
  const patch: Partial<RecurringBoardTemplate> = {};
  const seed = rekeyIds(t.seedTaskIds, map) as string[];
  if (seed !== t.seedTaskIds) patch.seedTaskIds = seed;
  if (t.manualTaskIds) {
    const v = rekeyIds(t.manualTaskIds, map) as string[];
    if (v !== t.manualTaskIds) patch.manualTaskIds = v;
  }
  if (t.removedTaskIds) {
    const v = rekeyIds(t.removedTaskIds, map) as string[];
    if (v !== t.removedTaskIds) patch.removedTaskIds = v;
  }
  if (t.sources) {
    const v = rekeySources(t.sources, map);
    if (v !== t.sources) patch.sources = v;
  }
  if (t.manualTaskVary) {
    const v = rekeyRecordKeys(t.manualTaskVary, map);
    if (v !== t.manualTaskVary) patch.manualTaskVary = v;
  }
  let targets: Record<string, ManualTaskTarget> | undefined = t.manualTaskTargets;
  if (targets) {
    const v = rekeyRecordKeys(targets, map);
    if (v !== targets) {
      targets = v;
      patch.manualTaskTargets = v;
    }
  }
  for (const id of t.manualTaskIds ?? []) {
    const root = map[id];
    const row = tasksById.get(id);
    if (!root || !row || targets?.[root]) continue;
    if (typeof row.maxCount !== 'number' || row.maxCount <= 0) continue;
    targets = { ...(targets ?? {}), [root]: { target: row.maxCount, kind: resolveCountKind(row) } };
    patch.manualTaskTargets = targets;
  }
  return Object.keys(patch).length > 0 ? patch : null;
}

/** The pool fields a re-key changes, or `null`. */
export function rekeyPool(p: Pool, map: Rekey): Partial<Pool> | null {
  const patch: Partial<Pool> = {};
  const ids = rekeyIds(p.taskIds, map) as string[];
  if (ids !== p.taskIds) patch.taskIds = ids;
  if (p.memberVary) {
    const v = rekeyRecordKeys(p.memberVary, map);
    if (v !== p.memberVary) patch.memberVary = v;
  }
  return Object.keys(patch).length > 0 ? patch : null;
}

/** A draft's re-keyed `recurringDraftMix` blob, or `null` when unchanged / undecodable. */
export function rekeyDraftMix(blob: string | undefined, map: Rekey): string | null {
  if (!blob) return null;
  const mix = decodeRecurringDraftMix(blob);
  const sources = rekeySources(mix.sources, map);
  const manualTaskIds = rekeyIds(mix.manualTaskIds, map) as string[];
  const removedTaskIds = rekeyIds(mix.removedTaskIds, map) as string[];
  const manualTaskVary = rekeyRecordKeys(mix.manualTaskVary, map);
  const placementParams = rekeyRecordKeys(mix.placementParams, map);
  if (
    sources === mix.sources &&
    manualTaskIds === mix.manualTaskIds &&
    removedTaskIds === mix.removedTaskIds &&
    manualTaskVary === mix.manualTaskVary &&
    placementParams === mix.placementParams
  ) {
    return null;
  }
  return encodeRecurringDraftMix({
    poolIds: mix.poolIds,
    manualTaskIds,
    removedTaskIds,
    sources,
    manualTaskVary,
    placementParams,
  });
}
