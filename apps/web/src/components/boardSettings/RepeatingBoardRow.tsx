import { useState } from 'react';
import {
  Timeframe,
  type RecurringBoardTemplate,
  type SpawnPoolFailureReason,
} from '@oybc/shared';
import {
  softDeleteRecurringBoardTemplate,
  updateRecurringBoardTemplate,
} from '../../db/operations/recurringBoardTemplates';
import { POOL_PREVIEW_LIMIT } from '../recurringTemplates/poolPreview';
import styles from './RepeatingBoardRow.module.css';

const TIMEFRAME_LABELS: Record<Timeframe, string> = {
  [Timeframe.DAILY]: 'Daily',
  [Timeframe.WEEKLY]: 'Weekly',
  [Timeframe.MONTHLY]: 'Monthly',
  [Timeframe.YEARLY]: 'Yearly',
  [Timeframe.CUSTOM]: 'Custom',
  [Timeframe.INDEFINITE]: 'Ongoing', // unreachable — repeating boards exclude indefinite
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
  spawn_failed: 'Spawn failed unexpectedly. Try editing tasks to refresh it.',
  // Board Sources P3 — a pulled board-kind source's board is deleted or
  // archived; the next window waits until the source is removed (Edit
  // tasks) or the repeating board is paused.
  source_board_missing:
    'It pulls from a board that was deleted or archived. Edit tasks to remove that source.',
};

export interface RepeatingBoardRowProps {
  template: RecurringBoardTemplate;
  /** The board's CURRENT resolved mix size, for the "N-task mix" meta
   *  text. Computed at the page level from `useTemplateMixes` — NOT
   *  `template.seedTaskIds.length`, which goes stale after a Pool-linked
   *  write-through (docs/POOLS_RECURRING.md §Migration "seedTaskIds end
   *  state"). */
  taskCount: number;
  /** Set when this board's last spawn was skipped — surfaces a badge. */
  attentionReason?:
    | SpawnPoolFailureReason
    | 'no_pool_tasks_resolved'
    | 'spawn_failed'
    | 'source_board_missing';
  /** First few resolved mix task titles (≤ POOL_PREVIEW_LIMIT, in mix
   *  order); the page resolves ids against the library. Empty/omitted
   *  renders no chip row. */
  poolPreview?: string[];
  /** Count of additional resolved titles beyond `poolPreview` (0 ⇒ no
   *  "+k more" chip). See `computePoolPreview`. */
  poolPreviewOverflow?: number;
  /** "Edit tasks" — opens the roster edit sheet for this board. */
  onEditTasks: (template: RecurringBoardTemplate) => void;
}

/**
 * RepeatingBoardRow — one row on the Board-settings repeating-boards
 * roster (Task Pools + Recurring Boards Rework, P7,
 * docs/POOLS_RECURRING.md §Surfaces item 9). Adapted from the retired
 * `RecurringTemplateRow` (Profile → Recurring templates, deleted in P7):
 * same Pause/Resume toggle + Delete + attention badge + pool-preview
 * chips, but "Edit"/"Add tasks" collapse into ONE "Edit tasks" button that
 * opens the roster edit sheet in place — no more cross-tab navigation into
 * the wizard's template-edit mode (that deep link retired with the old
 * templates page; see docs/POOLS_RECURRING.md §Migration).
 */
export function RepeatingBoardRow({
  template,
  taskCount,
  attentionReason,
  poolPreview = [],
  poolPreviewOverflow = 0,
  onEditTasks,
}: RepeatingBoardRowProps): React.ReactElement {
  const [busy, setBusy] = useState(false);

  const toggleActive = async () => {
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

  const handleDelete = async () => {
    if (busy) return;
    const ok = window.confirm(
      `Delete "${template.name}"? Boards already spawned from it will not be deleted.`,
    );
    if (!ok) return;
    setBusy(true);
    try {
      await softDeleteRecurringBoardTemplate(template.id);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className={`${styles.row} ${!template.isActive ? styles.rowInactive : ''}`}>
      <div className={styles.rowMain}>
        <div className={styles.rowName}>{template.name}</div>
        <div className={styles.rowMeta}>
          {TIMEFRAME_LABELS[template.timeframe]} ·{' '}
          {template.boardSize}×{template.boardSize} ·{' '}
          {`${taskCount}-task mix`}
        </div>
        {poolPreview.length > 0 && (
          <div className={styles.poolPreview} aria-label="Mix preview">
            {poolPreview.slice(0, POOL_PREVIEW_LIMIT).map((title, i) => (
              <span key={`${title}-${i}`} className={styles.poolChip}>
                {title}
              </span>
            ))}
            {poolPreviewOverflow > 0 && (
              <span className={`${styles.poolChip} ${styles.poolChipMore}`}>
                +{poolPreviewOverflow} more
              </span>
            )}
          </div>
        )}
        {attentionReason && (
          <div className={styles.attentionBadge} role="status">
            ⚠️ {ATTENTION_COPY[attentionReason]}
          </div>
        )}
      </div>
      <div className={styles.rowActions}>
        <label className={styles.activeToggle}>
          <input
            type="checkbox"
            checked={template.isActive}
            onChange={() => void toggleActive()}
            disabled={busy}
            aria-label={`${template.isActive ? 'Pause' : 'Resume'} ${template.name}`}
          />
          <span>{template.isActive ? 'Active' : 'Paused'}</span>
        </label>
        <button
          type="button"
          className={styles.editButton}
          onClick={() => onEditTasks(template)}
          disabled={busy}
        >
          Edit tasks
        </button>
        <button
          type="button"
          className={styles.deleteButton}
          onClick={() => void handleDelete()}
          disabled={busy}
          aria-label={`Delete ${template.name}`}
        >
          Delete
        </button>
      </div>
    </div>
  );
}
