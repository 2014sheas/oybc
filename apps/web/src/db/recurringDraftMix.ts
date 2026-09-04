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
 * so both the operations layer (`db/operations/recurringDraftMix.ts`) and
 * the wizard's component-tree code (`components/wizard/wizardPersist.ts`,
 * `pages/createHub/useBoardWizard.ts`) can import it without crossing the
 * `db/internal` access boundary unnecessarily.
 *
 * iOS twin: `BoardWizardViewModel.RecurringDraftMixPayload`
 * (`apps/ios/OYBC/Views/CreateTab/ViewModels/BoardWizardViewModel.swift`).
 */

import { sourcesFromMixFields, type BoardSource } from '@oybc/shared';

export interface RecurringDraftMixPayload {
  poolIds: string[];
  manualTaskIds: string[];
  removedTaskIds: string[];
  /** Board Sources P1 — canonical sources shape. Always present on decode:
   *  derived from the trio for a v1 blob. */
  sources: BoardSource[];
}

const EMPTY_MIX: RecurringDraftMixPayload = {
  poolIds: [],
  manualTaskIds: [],
  removedTaskIds: [],
  sources: [],
};

/**
 * Encodes a mix payload to the JSON string stored on
 * `Board.recurringDraftMix`. `sources` may be omitted — it is then derived
 * from the trio (`sourcesFromMixFields`), which is lossless for everything
 * the wizard can express until P2 ships ranges/board sources.
 */
export function encodeRecurringDraftMix(
  mix: Omit<RecurringDraftMixPayload, 'sources'> & { sources?: BoardSource[] },
): string {
  return JSON.stringify({
    v: 2,
    poolIds: mix.poolIds,
    manualTaskIds: mix.manualTaskIds,
    removedTaskIds: mix.removedTaskIds,
    sources: mix.sources ?? sourcesFromMixFields(mix),
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
      return { ...trio, sources };
    }
    return EMPTY_MIX;
  } catch {
    return EMPTY_MIX;
  }
}
