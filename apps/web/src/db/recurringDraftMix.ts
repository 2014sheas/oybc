/**
 * recurringDraftMix.ts — Board Creation Split (web PR D).
 *
 * Pure encode/decode for `Board.recurringDraftMix`, the JSON payload
 * snapshotting a recurring wizard's FULL pool-mix selection
 * (`poolIds` / `manualTaskIds` / `removedTaskIds`) so it survives a
 * save/resume round-trip. A recurring pool can be larger than its grid
 * (overfill is the variety mechanism, per docs/POOLS_RECURRING.md
 * §Behavior invariants), so the placed `BoardTask` rows alone would
 * silently truncate the pool on resume — this payload is the source of
 * truth for resuming a recurring draft's selection instead.
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

export interface RecurringDraftMixPayload {
  poolIds: string[];
  manualTaskIds: string[];
  removedTaskIds: string[];
}

const EMPTY_MIX: RecurringDraftMixPayload = {
  poolIds: [],
  manualTaskIds: [],
  removedTaskIds: [],
};

/** Encodes a mix payload to the JSON string stored on `Board.recurringDraftMix`. */
export function encodeRecurringDraftMix(mix: RecurringDraftMixPayload): string {
  return JSON.stringify(mix);
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((v) => typeof v === 'string');
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
      const record = parsed as RecurringDraftMixPayload;
      return {
        poolIds: record.poolIds,
        manualTaskIds: record.manualTaskIds,
        removedTaskIds: record.removedTaskIds,
      };
    }
    return EMPTY_MIX;
  } catch {
    return EMPTY_MIX;
  }
}
