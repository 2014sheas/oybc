/**
 * recurringDraftMix.ts — Board Creation Split (web PR D) + Board Sources
 * rework (P1, docs/BOARD_SOURCES.md).
 *
 * Pure encode/decode for `Board.recurringDraftMix`, the JSON payload
 * snapshotting a wizard draft's FULL pool selection so it survives a
 * save/resume round-trip. A pool can be larger than its grid (overfill is
 * the variety mechanism), so the placed `BoardTask` rows alone would
 * silently truncate the pool on resume — this payload is the source of
 * truth for resuming a draft's selection instead.
 *
 * **v2 (Board Sources P1):** the payload gains `v: 2` + `sources`
 * (`BoardSource[]` — the canonical shape) and is now written for ONE-OFF
 * drafts too (docs/BOARD_SOURCES.md §Data model item 2 — previously only
 * recurring drafts carried it, silently truncating an overfilled one-off
 * draft's pool on resume). The legacy trio (`poolIds` / `manualTaskIds` /
 * `removedTaskIds`) is still written alongside — an old client build
 * decodes it unchanged — and a v1 blob decodes forward by deriving
 * `sources` via `sourcesFromMixFields` (a `[0, all]` mapping, exactly the
 * template migration rule). The column name stays `recurringDraftMix` for
 * decode/sync compat; it is historical.
 *
 * No DB access, no React — a leaf module under `db/` (not `db/operations/`)
 * so the wizard's component-tree code (`components/wizard/wizardPersist.ts`,
 * `pages/createHub/useBoardWizard.ts`, `pages/createHub/resolveDraftCapacity.ts`)
 * can import it without crossing the `db/internal` access boundary.
 *
 * iOS twin: the top-level `RecurringDraftMixPayload` struct
 * (`apps/ios/OYBC/Views/CreateTab/RecurringDraftMixPayload.swift`).
 */

import { sourcesFromMixFields, type BoardSource, type VaryLevel } from '@oybc/shared';

export interface RecurringDraftMixPayload {
  poolIds: string[];
  manualTaskIds: string[];
  removedTaskIds: string[];
  /** Board Sources P1 — canonical sources shape. Always present on decode:
   *  derived from the trio for a v1 blob. */
  sources: BoardSource[];
  /** Member rules B1 (inert) — per-manual-task vary dice, keyed by task id.
   *  Always present on decode (`{}` default); omitted from the encoded
   *  blob when empty so an existing draft encodes byte-identically. */
  manualTaskVary: Record<string, VaryLevel>;
}

const EMPTY_MIX: RecurringDraftMixPayload = {
  poolIds: [],
  manualTaskIds: [],
  removedTaskIds: [],
  sources: [],
  manualTaskVary: {},
};

/**
 * Encodes a mix payload to the JSON string stored on
 * `Board.recurringDraftMix`. `sources` may be omitted — it is then derived
 * from the trio (`sourcesFromMixFields`), which is lossless only for
 * `[0, all]` pool pulls — the wizard always passes its native sources.
 */
export function encodeRecurringDraftMix(
  mix: Omit<RecurringDraftMixPayload, 'sources' | 'manualTaskVary'> & {
    sources?: BoardSource[];
    manualTaskVary?: Record<string, VaryLevel>;
  },
): string {
  return JSON.stringify({
    v: 2,
    poolIds: mix.poolIds,
    manualTaskIds: mix.manualTaskIds,
    removedTaskIds: mix.removedTaskIds,
    sources: mix.sources ?? sourcesFromMixFields(mix),
    ...(mix.manualTaskVary && Object.keys(mix.manualTaskVary).length
      ? { manualTaskVary: mix.manualTaskVary }
      : {}),
  });
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((v) => typeof v === 'string');
}

function isBoardSource(value: unknown): value is BoardSource {
  if (value === null || typeof value !== 'object') return false;
  const s = value as Record<string, unknown>;
  return (
    typeof s.sourceId === 'string' &&
    (s.kind === 'pool' || s.kind === 'board') &&
    typeof s.min === 'number' &&
    (s.max === null || typeof s.max === 'number') &&
    isStringArray(s.excludedTaskIds) &&
    (s.filter === 'all' || s.filter === 'todo')
  );
}

/**
 * Drops keys whose value isn't a valid {@link VaryLevel}; keeps the rest.
 * An array is rejected outright (`typeof [] === 'object'`, so it would
 * otherwise decode to index keys) — same "converge to no dice" intent.
 */
function sanitizeVary(v: unknown): Record<string, VaryLevel> {
  if (v === null || typeof v !== 'object' || Array.isArray(v)) return {};
  const out: Record<string, VaryLevel> = {};
  for (const [k, lvl] of Object.entries(v as Record<string, unknown>))
    if (lvl === 0 || lvl === 1 || lvl === 2) out[k] = lvl;
  return out;
}

/**
 * Decodes `Board.recurringDraftMix`. Returns an all-empty mix (never
 * throws) for a missing or malformed string so hydration always has a
 * well-formed shape to resolve against — an empty mix just means "no
 * tasks yet", not an error. Mirrors iOS
 * `RecurringDraftMixPayload.decoded(from:)`'s graceful-fallback posture.
 */
export function decodeRecurringDraftMix(json: string | undefined): RecurringDraftMixPayload {
  if (!json) return EMPTY_MIX;
  try {
    const parsed: unknown = JSON.parse(json);
    if (
      parsed !== null &&
      typeof parsed === 'object' &&
      isStringArray((parsed as Record<string, unknown>).poolIds) &&
      isStringArray((parsed as Record<string, unknown>).manualTaskIds) &&
      isStringArray((parsed as Record<string, unknown>).removedTaskIds)
    ) {
      const record = parsed as Record<string, unknown> & {
        poolIds: string[];
        manualTaskIds: string[];
        removedTaskIds: string[];
      };
      const trio = {
        poolIds: record.poolIds,
        manualTaskIds: record.manualTaskIds,
        removedTaskIds: record.removedTaskIds,
      };
      // v2 blob with a well-formed sources array → canonical. Anything
      // else (v1, or a corrupt sources value) → derive from the trio.
      const rawSources = record.sources;
      const sources =
        Array.isArray(rawSources) && rawSources.every(isBoardSource)
          ? (rawSources as BoardSource[])
          : sourcesFromMixFields(trio);
      return { ...trio, sources, manualTaskVary: sanitizeVary(record.manualTaskVary) };
    }
    return EMPTY_MIX;
  } catch {
    return EMPTY_MIX;
  }
}
