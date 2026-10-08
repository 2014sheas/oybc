import {
  Timeframe,
  type Board,
  type RecurringBoardTemplate,
} from '@oybc/shared';
import { RisoSectionLabel, RisoSegmented, type RisoSegmentedOption } from '../riso';
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
 *    becomes `startRepeating` — never without a signed-in user id. Any center
 *    type is eligible: a legacy CHOSEN board repeats with a NONE template
 *    (`buildRepeatBoardTemplateInput` reads `effectiveCenter` — Board Edit
 *    slice 3, D5).
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
  hasUserId: boolean;
}): RepeatSavePlan | null {
  const {
    spawnedFromTemplateId,
    sourceTemplateIsActive,
    stagedCadence,
    stagedActive,
    hasUserId,
  } = args;

  if (spawnedFromTemplateId != null) {
    if (sourceTemplateIsActive === undefined) return null;
    if (stagedActive == null || stagedActive === sourceTemplateIsActive) return null;
    return { kind: 'setActive', isActive: stagedActive };
  }

  if (stagedCadence === 'off') return null;
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
  /** Staged cadence for the one-off variant ('off' = no change). */
  stagedCadence: RepeatCadenceChoice;
  onStagedCadenceChange: (cadence: RepeatCadenceChoice) => void;
  /** Effective staged Active value for the repeating variant. */
  stagedActive: boolean;
  onStagedActiveChange: (active: boolean) => void;
}

/**
 * BoardEditRepeatSection — the Board Edit panel's staged REPEATS section
 * (repeat-in-edit rework; replaces the retired play-surface
 * `BoardPlayRepeatSection`). Two variants, both STAGED (nothing writes
 * until the panel's Save — docs/BOARD_EDIT.md staged-draft contract):
 *
 *  - One-off board (no source record), any center type: an
 *    Off · Daily · Weekly · Monthly · Yearly cadence segmented. On Save
 *    with cadence ≠ Off the panel runs `repeatBoardAsRecurring` AFTER the
 *    board save commits.
 *  - Repeating board with a resolved source record: a staged
 *    Repeating/Paused toggle.
 *
 * Presentational only — the staged values live on `BoardEditPanel`, which
 * also owns the Save-time mutations (via `buildRepeatSavePlan`).
 */
export function BoardEditRepeatSection({
  board,
  sourceTemplate,
  userId,
  stagedCadence,
  onStagedCadenceChange,
  stagedActive,
  onStagedActiveChange,
}: BoardEditRepeatSectionProps): React.ReactElement | null {
  if (board.spawnedFromTemplateId != null) {
    // A soft-deleted / unresolved source record hides the section entirely
    // (same rule as the retired play-surface manage row).
    if (!sourceTemplate) return null;
    return (
      <div className={styles.repeatsSection}>
        <RisoSectionLabel>Repeats</RisoSectionLabel>
        <RisoSegmented
          aria-label="Repeating status"
          options={ACTIVE_OPTIONS}
          value={stagedActive ? 'repeating' : 'paused'}
          onChange={(choice) => onStagedActiveChange(choice === 'repeating')}
          variant="pill"
        />
      </div>
    );
  }

  // One-off board. With no signed-in user id there's nothing to own the new
  // record. (A legacy CHOSEN center no longer hides this — slice 3, D5.)
  if (!userId) return null;

  return (
    <div className={styles.repeatsSection}>
      <RisoSectionLabel>Repeats</RisoSectionLabel>
      <RisoSegmented
        aria-label="Repeat cadence"
        options={REPEAT_CADENCE_OPTIONS}
        value={stagedCadence}
        onChange={onStagedCadenceChange}
      />
    </div>
  );
}
