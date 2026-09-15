import { useMemo } from 'react';
import {
  CenterSquareType,
  Timeframe,
  formatCadenceAdverb,
  formatSpawnProvenanceNote,
  isFreshlyDealtBoard,
  summarizeSpawnProvenanceFromSupplies,
  type Board,
  type RecurringBoardTemplate,
  type Pool,
  type Task,
} from '@oybc/shared';
import { RisoSectionLabel, RisoSegmented, type RisoSegmentedOption } from '../riso';
import { usePools } from '../../hooks/usePools';
import { useSpawnNoteSupplies } from '../../hooks/useSpawnNoteSupplies';
import styles from './BoardEditPanel.module.css';

// ─── Staged repeat draft types ────────────────────────────────────────────────

/** Staged cadence choice for a one-off board — `'off'` (default) or a repeat cadence. */
export type RepeatCadenceChoice = Timeframe | 'off';

/**
 * The repeat mutation the Save button must run AFTER the board save commits
 * (repeat-in-edit rework — the play-surface repeat controls moved into Board
 * Edit as staged fields). `null` = nothing staged, Save is board-only.
 */
export type RepeatSavePlan =
  | { kind: 'startRepeating'; cadence: Timeframe }
  | { kind: 'setActive'; isActive: boolean };

/**
 * Pure decision core for the staged REPEATS section's Save contribution —
 * EXPORTED FOR TESTS (mirrors `buildEditDatesPatch`'s testable-core posture).
 *
 * Returns the repeat mutation to run after a successful board save, or
 * `null` when the staged state is a no-op:
 *  - One-off board (`spawnedFromTemplateId == null`): a staged cadence ≠ Off
 *    becomes `startRepeating` — but never for a CHOSEN center (a CHOSEN
 *    center can never validate a spawn pool — `validateSpawnPool` rejects it
 *    as `unsupportedCenter`) and never without a signed-in user id.
 *  - Repeating board with a resolved source record: a staged Active value
 *    differing from the record's current `isActive` becomes `setActive`.
 *    An unresolved (soft-deleted) record stages nothing.
 */
export function buildRepeatSavePlan(args: {
  spawnedFromTemplateId: string | null | undefined;
  /** The source record's live `isActive`; `undefined` = unresolved record. */
  sourceTemplateIsActive: boolean | undefined;
  stagedCadence: RepeatCadenceChoice;
  /** Staged Active value; `null` = the toggle was never touched. */
  stagedActive: boolean | null;
  centerType: CenterSquareType;
  hasUserId: boolean;
}): RepeatSavePlan | null {
  const {
    spawnedFromTemplateId,
    sourceTemplateIsActive,
    stagedCadence,
    stagedActive,
    centerType,
    hasUserId,
  } = args;

  if (spawnedFromTemplateId != null) {
    if (sourceTemplateIsActive === undefined) return null;
    if (stagedActive == null || stagedActive === sourceTemplateIsActive) return null;
    return { kind: 'setActive', isActive: stagedActive };
  }

  if (stagedCadence === 'off') return null;
  // CHOSEN-center boards can't start repeating (see docblock) — the section
  // is hidden for them, and this guard keeps a stale staged cadence inert
  // if the user picks a cadence and THEN flips the center to CHOSEN.
  if (centerType === CenterSquareType.CHOSEN) return null;
  if (!hasUserId) return null;
  return { kind: 'startRepeating', cadence: stagedCadence };
}

// ─── Options ──────────────────────────────────────────────────────────────────

/**
 * Staged cadence picker for a one-off board — Off (default) + the four
 * cadences from the retired play-surface "Repeat this board…" picker
 * (repeat-in-edit rework; labels unchanged).
 */
const REPEAT_CADENCE_OPTIONS: RisoSegmentedOption<RepeatCadenceChoice>[] = [
  { value: 'off', label: 'Off' },
  { value: Timeframe.DAILY, label: 'Daily' },
  { value: Timeframe.WEEKLY, label: 'Weekly' },
  { value: Timeframe.MONTHLY, label: 'Monthly' },
  { value: Timeframe.YEARLY, label: 'Yearly' },
];

/** Staged Active toggle values (RisoSegmented needs string values). */
type ActiveChoice = 'repeating' | 'paused';

const ACTIVE_OPTIONS: RisoSegmentedOption<ActiveChoice>[] = [
  { value: 'repeating', label: 'Repeating' },
  { value: 'paused', label: 'Paused' },
];

// ─── Component ────────────────────────────────────────────────────────────────

export interface BoardEditRepeatSectionProps {
  board: Board;
  /** Resolved source record for a repeating board; `undefined` while
   *  loading, `null` for a one-off board. */
  sourceTemplate: RecurringBoardTemplate | null | undefined;
  userId: string | undefined;
  /** Staged draft centerSquareType (the panel's controlled value) — gates
   *  the one-off variant (CHOSEN hides it). */
  centerType: CenterSquareType;
  /** Staged cadence for the one-off variant ('off' = no change). */
  stagedCadence: RepeatCadenceChoice;
  onStagedCadenceChange: (cadence: RepeatCadenceChoice) => void;
  /** Effective staged Active value for the repeating variant. */
  stagedActive: boolean;
  onStagedActiveChange: (active: boolean) => void;
  /** Library tasks — feeds the spawn-provenance note's supply resolution. */
  taskMap: Record<string, Task>;
  /** Task ids currently dealt onto the board (grid order). */
  dealtTaskIds: string[];
  /** `buildCounterFamilyMap` over the library (computed by the surface). */
  counterFamilyByTaskId: Record<string, string>;
}

/**
 * BoardEditRepeatSection — the Board Edit panel's staged REPEATS section
 * (repeat-in-edit rework; replaces the retired play-surface
 * `BoardPlayRepeatSection`). Two variants, both STAGED (nothing writes
 * until the panel's Save — docs/BOARD_EDIT.md staged-draft contract):
 *
 *  - One-off board (no source record), non-CHOSEN center: an
 *    Off · Daily · Weekly · Monthly · Yearly cadence segmented. On Save
 *    with cadence ≠ Off the panel runs `repeatBoardAsRecurring` AFTER the
 *    board save commits.
 *  - Repeating board with a resolved source record: the
 *    "↻ Repeats {cadence} · from …" line + a staged Repeating/Paused
 *    toggle, plus the read-only spawn-provenance note while the board is
 *    still freshly dealt (moved here from the play surface — the supplies
 *    resolve only while the panel is open).
 *
 * Presentational only — the staged values live on `BoardEditPanel`, which
 * also owns the Save-time mutations (via `buildRepeatSavePlan`).
 */
export function BoardEditRepeatSection({
  board,
  sourceTemplate,
  userId,
  centerType,
  stagedCadence,
  onStagedCadenceChange,
  stagedActive,
  onStagedActiveChange,
  taskMap,
  dealtTaskIds,
  counterFamilyByTaskId,
}: BoardEditRepeatSectionProps): React.ReactElement | null {
  // Spawn-provenance note inputs (hooks must run unconditionally). Pools
  // are fetched here — only this note needs them (moved from the play
  // surface, which no longer resolves spawn-note supplies at all).
  const pools = usePools(userId);
  const poolsById = useMemo<Record<string, Pool>>(() => {
    const map: Record<string, Pool> = {};
    for (const p of pools) map[p.id] = p;
    return map;
  }, [pools]);
  const noteTemplate =
    board.spawnedFromTemplateId != null && sourceTemplate && isFreshlyDealtBoard(board)
      ? sourceTemplate
      : undefined;
  const spawnNoteSupplies = useSpawnNoteSupplies(noteTemplate, poolsById, taskMap);

  if (board.spawnedFromTemplateId != null) {
    // A soft-deleted / unresolved source record hides the section entirely
    // (same rule as the retired play-surface manage row).
    if (!sourceTemplate) return null;
    return (
      <div className={styles.repeatsSection}>
        <RisoSectionLabel>Repeats</RisoSectionLabel>
        <p className={styles.repeatRow}>
          ↻ Repeats {formatCadenceAdverb(sourceTemplate.timeframe)} · from &quot;
          {sourceTemplate.name}&quot;
        </p>
        <RisoSegmented
          aria-label="Repeating status"
          options={ACTIVE_OPTIONS}
          value={stagedActive ? 'repeating' : 'paused'}
          onChange={(choice) => onStagedActiveChange(choice === 'repeating')}
          variant="pill"
        />
        {noteTemplate && spawnNoteSupplies !== null && (
          <p className={styles.repeatNote}>
            {formatSpawnProvenanceNote(
              summarizeSpawnProvenanceFromSupplies(
                spawnNoteSupplies,
                noteTemplate.manualTaskIds ?? [],
                counterFamilyByTaskId,
                dealtTaskIds,
              ),
            )}
          </p>
        )}
      </div>
    );
  }

  // One-off board. CHOSEN-center boards can never start repeating (a CHOSEN
  // center can never validate a spawn pool — `validateSpawnPool` rejects it
  // as `unsupportedCenter`), so the section is hidden for them; likewise
  // with no signed-in user id there's nothing to own the new record.
  if (centerType === CenterSquareType.CHOSEN || !userId) return null;

  return (
    <div className={styles.repeatsSection}>
      <RisoSectionLabel>Repeats</RisoSectionLabel>
      <RisoSegmented
        aria-label="Repeat cadence"
        options={REPEAT_CADENCE_OPTIONS}
        value={stagedCadence}
        onChange={onStagedCadenceChange}
      />
      {stagedCadence !== 'off' && (
        <p className={styles.repeatHint}>
          This becomes a repeating board when you save.
        </p>
      )}
    </div>
  );
}
