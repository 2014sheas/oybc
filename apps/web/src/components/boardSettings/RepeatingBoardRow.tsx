import { useState } from 'react';
import {
  Timeframe,
  type RecurringBoardTemplate,
  type SpawnPoolFailureReason,
  type WeekStartDay,
} from '@oybc/shared';
import { updateRecurringBoardTemplate } from '../../db/operations/recurringBoardTemplates';
import { formatRepeatingBoardMeta } from './repeatingBoardMeta';
import styles from './RepeatingBoardRow.module.css';

const TIMEFRAME_LABELS: Record<Timeframe, string> = {
  [Timeframe.DAILY]: 'DAILY',
  [Timeframe.WEEKLY]: 'WEEKLY',
  [Timeframe.MONTHLY]: 'MONTHLY',
  [Timeframe.YEARLY]: 'YEARLY',
  [Timeframe.CUSTOM]: 'CUSTOM', // unreachable — repeating boards exclude custom
  [Timeframe.INDEFINITE]: 'ONGOING', // unreachable
};

const ATTENTION_COPY: Record<
  SpawnPoolFailureReason | 'no_pool_tasks_resolved' | 'spawn_failed' | 'source_board_missing',
  string
> = {
  pool_too_small: 'Mix is too small for the current configuration. Edit tasks to add more.',
  has_deleted_tasks: 'A task in this mix was deleted. Edit tasks to refresh it.',
  unsupported_timeframe: "This board's timeframe is no longer supported.",
  unsupported_center: "This board's center cell is no longer supported.",
  no_pool_tasks_resolved: "None of this board's tasks could be loaded. Edit tasks to refresh it.",
  spawn_failed: "Couldn't make the next board. Try editing tasks to refresh it.",
  // Board Sources P3 — a pulled board-kind source's board is deleted or
  // archived; the next window waits until the source is removed (Edit
  // tasks) or the repeating board is paused.
  source_board_missing:
    'It pulls from a board that was deleted or archived. Edit tasks to remove that source.',
};

export interface RepeatingBoardRowProps {
  template: RecurringBoardTemplate;
  /** The board's CURRENT resolved mix size, for the meta line's "N-task
   *  pool" clause. Computed at the page level from `useTemplateRosterHealth`
   *  — NOT `template.seedTaskIds.length`, which goes stale after a
   *  Pool-linked write-through (docs/POOLS_RECURRING.md §Migration
   *  "seedTaskIds end state"). */
  taskCount: number;
  /** The user's week-start preference — feeds the meta line's "renews
   *  {day}" clause for a WEEKLY board. */
  weekStartDay: WeekStartDay;
  /** Set when this board's last spawn was skipped — surfaces a badge. */
  attentionReason?:
    | SpawnPoolFailureReason
    | 'no_pool_tasks_resolved'
    | 'spawn_failed'
    | 'source_board_missing';
  /** Row click (anywhere but the toggle) — opens the existing template
   *  editor (`RepeatingBoardWizardOverlay` wrapping `BoardWizardPage` in
   *  edit mode). */
  onOpen: (template: RecurringBoardTemplate) => void;
}

/**
 * RepeatingBoardRow — one compact row on the Board-settings repeating-boards
 * roster (Profile reorg PR3, `design_handoff_profile_reorg/README.md` §4 /
 * screenshot `4c-board-settings.png`). Replaces the earlier expanded row
 * (pool-preview chips, separate "Edit tasks"/"Delete" buttons) with: name
 * (muted when paused) + timeframe badge, one meta line, an optional
 * attention badge, a trailing Active/Paused toggle, and a chevron. The
 * whole row opens the template editor — pool-preview chips and the "Edit
 * tasks"/"Delete" buttons are dropped from this list per the
 * owner-decisions PR3 paragraph — they stay in the editor: Delete is the
 * "Delete repeating board" row on the editor's Setup step
 * (`BoardWizardSetupStep` → `DeleteRepeatingBoardConfirmDialog` →
 * `deleteEditedRecurringTemplate`, the same soft-delete op this row used to
 * call).
 *
 * The row is a `role="button"` DIV (not a literal `<button>`) because it
 * contains a real nested interactive control (the toggle's `<input
 * type="checkbox">`) — the HTML content model forbids interactive content
 * inside a `<button>`. `onKeyDown` restores button-equivalent Enter/Space
 * activation for keyboard + AT users.
 */
export function RepeatingBoardRow({
  template,
  taskCount,
  weekStartDay,
  attentionReason,
  onOpen,
}: RepeatingBoardRowProps): React.ReactElement {
  const [busy, setBusy] = useState(false);

  const toggleActive = async (e: React.MouseEvent | React.ChangeEvent) => {
    e.stopPropagation();
    if (busy) return;
    setBusy(true);
    try {
      await updateRecurringBoardTemplate(template.id, {
        isActive: !template.isActive,
      });
    } finally {
      setBusy(false);
    }
  };

  const meta = formatRepeatingBoardMeta(
    template.boardSize,
    taskCount,
    template.timeframe,
    weekStartDay,
    template.isActive,
  );

  const handleOpen = () => onOpen(template);

  return (
    <div
      role="button"
      tabIndex={0}
      className={`${styles.row} ${!template.isActive ? styles.rowInactive : ''}`}
      onClick={handleOpen}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          handleOpen();
        }
      }}
    >
      <div className={styles.rowMain}>
        <div className={styles.rowNameLine}>
          <span className={styles.rowName}>{template.name}</span>
          <span className={styles.timeframeBadge}>{TIMEFRAME_LABELS[template.timeframe]}</span>
        </div>
        <div className={styles.rowMeta}>{meta}</div>
        {attentionReason && (
          <div className={styles.attentionBadge} role="status">
            ⚠️ {ATTENTION_COPY[attentionReason]}
          </div>
        )}
      </div>
      <div className={styles.rowActions}>
        <label className={styles.toggleSwitch} onClick={(e) => e.stopPropagation()}>
          <input
            type="checkbox"
            checked={template.isActive}
            onChange={(e) => void toggleActive(e)}
            disabled={busy}
            aria-label={`${template.isActive ? 'Pause' : 'Resume'} ${template.name}`}
          />
          <span className={styles.toggleTrack} />
        </label>
        <span className={styles.rowArrow} aria-hidden="true">
          &rarr;
        </span>
      </div>
    </div>
  );
}
