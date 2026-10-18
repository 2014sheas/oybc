import type { BoardTask, PlacementChildTarget } from '../types/boardTask';
import { isQuantizedCount, isWholeCountKind } from './countValue';

/**
 * The per-placement parameter fields of a `BoardTask`
 * (docs/TASK_WINDOW_REWORK.md slice 1).
 */
export type PlacementFields = Pick<BoardTask, 'targetOverride' | 'targetKind' | 'childTargets' | 'titleOverride'>;

/** Upper bound on a per-board title, matching the task title limit. */
export const TITLE_OVERRIDE_MAX = 200;

/**
 * Normalise a placement's parameter fields to their canonical stored shape —
 * the one rule both platforms apply on decode (web: after the Zod pull
 * parse; iOS: `BoardTask.init(from:)`), so a malformed or partial value
 * falls back to "absent" (= the task's own default) instead of dropping the
 * placement, and two devices store byte-identical rows:
 *
 * - `targetOverride` must be finite, `> 0` and 2-dp quantized; for a whole
 *   `targetKind` (discrete / duration) it must also be whole. Otherwise both
 *   `targetOverride` and `targetKind` are dropped.
 * - `targetKind` is kept only alongside a kept `targetOverride`.
 * - `childTargets`: entries with a non-empty `childId` and a positive
 *   quantized `target`, first entry per `childId` wins, sorted by `childId`;
 *   an empty result is absent.
 * - `titleOverride`: trimmed; empty or over {@link TITLE_OVERRIDE_MAX} is absent.
 *
 * Swift twin: `BoardTask.normalizedPlacementFields` (vector-pinned by
 * `placementFieldsVectors.json`).
 *
 * @param fields - The raw fields (any of them may be missing or malformed).
 * @returns The canonical fields; a dropped field is `undefined`.
 */
export function normalizePlacementFields(fields: Partial<PlacementFields> | null | undefined): PlacementFields {
  const out: PlacementFields = {};
  if (!fields) return out;

  const kind = fields.targetKind === 'discrete' || fields.targetKind === 'continuous' || fields.targetKind === 'duration'
    ? fields.targetKind
    : undefined;
  const t = fields.targetOverride;
  if (typeof t === 'number' && t > 0 && isQuantizedCount(t) && !(kind != null && isWholeCountKind(kind) && !Number.isInteger(t))) {
    out.targetOverride = t;
    if (kind != null) out.targetKind = kind;
  }

  if (Array.isArray(fields.childTargets)) {
    const seen = new Set<string>();
    const kept: PlacementChildTarget[] = [];
    for (const entry of fields.childTargets) {
      if (!entry || typeof entry !== 'object') continue;
      const { childId, target } = entry as Partial<PlacementChildTarget>;
      if (typeof childId !== 'string' || childId.length === 0 || seen.has(childId)) continue;
      if (typeof target !== 'number' || !(target > 0) || !isQuantizedCount(target)) continue;
      seen.add(childId);
      kept.push({ childId, target });
    }
    kept.sort((a, b) => (a.childId < b.childId ? -1 : a.childId > b.childId ? 1 : 0));
    if (kept.length > 0) out.childTargets = kept;
  }

  if (typeof fields.titleOverride === 'string') {
    const title = fields.titleOverride.trim();
    if (title.length > 0 && title.length <= TITLE_OVERRIDE_MAX) out.titleOverride = title;
  }

  return out;
}

/**
 * A `BoardTask` with its placement fields normalised and every dropped
 * field REMOVED (not set to `undefined`), so a row's JSON / Dexie shape is
 * canonical. Non-placement fields pass through untouched.
 *
 * @param boardTask - The decoded row.
 * @returns The same row with canonical placement fields.
 */
export function withNormalizedPlacementFields<T extends Partial<PlacementFields>>(boardTask: T): T {
  const { targetOverride: _t, targetKind: _k, childTargets: _c, titleOverride: _o, ...rest } = boardTask;
  const norm = normalizePlacementFields(boardTask);
  const out = { ...rest } as T;
  if (norm.targetOverride !== undefined) out.targetOverride = norm.targetOverride;
  if (norm.targetKind !== undefined) out.targetKind = norm.targetKind;
  if (norm.childTargets !== undefined) out.childTargets = norm.childTargets;
  if (norm.titleOverride !== undefined) out.titleOverride = norm.titleOverride;
  return out;
}
