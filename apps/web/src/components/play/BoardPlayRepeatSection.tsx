import { useCallback, useState } from 'react';
import {
  CenterSquareType,
  Timeframe,
  formatCadenceAdverb,
  type Board,
  type RecurringBoardTemplate,
  type WeekStartDay,
} from '@oybc/shared';
import { RisoSegmented, type RisoSegmentedOption } from '../riso';
import { updateRecurringBoardTemplate } from '../../db/operations/recurringBoardTemplates';
import { repeatBoardAsRecurring } from '../../db/operations/repeatBoard';
import styles from '../../pages/BoardPlayPage.module.css';

/**
 * P6 (Task Pools + Recurring Boards Rework) — "Repeat this board…" cadence
 * picker options. Same 4 options + labels as the wizard's Repeats segmented
 * (`BoardSetupForm.tsx`'s `REPEATS_OPTIONS`, minus "Once" — this picker only
 * ever turns recurrence ON). No option is pre-selected (picking a cadence
 * immediately writes and the picker is replaced by the manage row).
 */
const REPEAT_CADENCE_OPTIONS: RisoSegmentedOption<Timeframe>[] = [
  { value: Timeframe.DAILY, label: 'Daily' },
  { value: Timeframe.WEEKLY, label: 'Weekly' },
  { value: Timeframe.MONTHLY, label: 'Monthly' },
  { value: Timeframe.YEARLY, label: 'Yearly' },
];

export interface BoardPlayRepeatSectionProps {
  board: Board;
  userId: string | undefined;
  /** Resolved source template for a repeating board; undefined while
   *  loading, null for a one-off board. */
  sourceTemplate: RecurringBoardTemplate | null | undefined;
  isSealed: boolean;
  weekStartDay: WeekStartDay;
}

/**
 * BoardPlayRepeatSection — the play rail's recurring-management block:
 * the manage row (Pause/Resume) for a repeating board, or the "Repeat
 * this board…" CTA + cadence picker for a one-off board. Extracted from
 * `BoardPlaySurface` (core-board surface rework) — pure code motion;
 * owns its own busy/picker state and DB writes via `db/operations`.
 */
export function BoardPlayRepeatSection({
  board,
  userId,
  sourceTemplate,
  isSealed,
  weekStartDay,
}: BoardPlayRepeatSectionProps): React.ReactElement | null {
  const [repeatPickerOpen, setRepeatPickerOpen] = useState(false);
  const [repeatBusy, setRepeatBusy] = useState(false);
  const [manageBusy, setManageBusy] = useState(false);

  const handleToggleTemplateActive = useCallback(async (): Promise<void> => {
    if (!sourceTemplate || manageBusy) return;
    setManageBusy(true);
    try {
      await updateRecurringBoardTemplate(sourceTemplate.id, { isActive: !sourceTemplate.isActive });
    } finally {
      setManageBusy(false);
    }
  }, [sourceTemplate, manageBusy]);

  const handleRepeatThisBoard = useCallback(async (cadence: Timeframe): Promise<void> => {
    if (!userId || repeatBusy) return;
    setRepeatBusy(true);
    try {
      await repeatBoardAsRecurring(board, cadence, userId, weekStartDay);
      setRepeatPickerOpen(false);
    } finally {
      setRepeatBusy(false);
    }
  }, [board, userId, weekStartDay, repeatBusy]);

  if (board.spawnedFromTemplateId != null) {
    if (!sourceTemplate) return null;
    return (
      <div className={styles.repeatManageRow}>
        <span className={styles.repeatManageText}>
          ↻ Repeats {formatCadenceAdverb(sourceTemplate.timeframe)} · from "{sourceTemplate.name}"
        </span>
        <button
          type="button"
          className={styles.repeatManageBtn}
          disabled={manageBusy}
          onClick={() => void handleToggleTemplateActive()}
        >
          {sourceTemplate.isActive ? 'Pause' : 'Resume'}
        </button>
      </div>
    );
  }

  if (isSealed || board.centerSquareType === CenterSquareType.CHOSEN) return null;

  return (
    <div className={styles.repeatCta}>
      {!repeatPickerOpen ? (
        <button
          type="button"
          className={styles.repeatCtaBtn}
          onClick={() => setRepeatPickerOpen(true)}
        >
          ↻ Repeat this board…
        </button>
      ) : (
        <div className={styles.repeatPicker}>
          <span className={styles.repeatPickerLabel}>Repeat this board</span>
          <RisoSegmented
            aria-label="Repeat cadence"
            options={REPEAT_CADENCE_OPTIONS}
            value={'' as Timeframe}
            onChange={(cadence) => void handleRepeatThisBoard(cadence)}
          />
          <button
            type="button"
            className={styles.repeatPickerCancel}
            onClick={() => setRepeatPickerOpen(false)}
            disabled={repeatBusy}
          >
            Cancel
          </button>
        </div>
      )}
    </div>
  );
}
