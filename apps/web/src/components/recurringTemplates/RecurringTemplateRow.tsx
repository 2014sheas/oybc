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
import { POOL_PREVIEW_LIMIT } from './poolPreview';
import styles from '../../pages/RecurringTemplatesPage.module.css';

const TIMEFRAME_LABELS: Record<Timeframe, string> = {
  [Timeframe.DAILY]: 'Daily',
  [Timeframe.WEEKLY]: 'Weekly',
  [Timeframe.MONTHLY]: 'Monthly',
  [Timeframe.YEARLY]: 'Yearly',
  [Timeframe.CUSTOM]: 'Custom',
  [Timeframe.INDEFINITE]: 'Ongoing', // unreachable — templates exclude indefinite
};

const ATTENTION_COPY: Record<
  SpawnPoolFailureReason | 'no_pool_tasks_resolved' | 'spawn_failed',
  string
> = {
  pool_too_small: 'Pool is too small for the current configuration. Edit to add tasks.',
  has_deleted_tasks: 'A task in this template was deleted. Edit to refresh the pool.',
  unsupported_timeframe: "This template's timeframe is no longer supported.",
  unsupported_center: "This template's center cell is no longer supported.",
  no_pool_tasks_resolved: 'None of this template\'s tasks could be loaded. Edit to refresh the pool.',
  spawn_failed: 'Spawn failed unexpectedly. Try editing this template to refresh.',
};

export interface RecurringTemplateRowProps {
  template: RecurringBoardTemplate;
  /** The template's CURRENT resolved pool-mix size, for the "N-task
   *  pool" meta text. Computed at the page level from `useTemplateMixes`
   *  — NOT `template.seedTaskIds.length`, which goes stale after the P1
   *  legacy-editor write-through edits the linked Pool (see
   *  `computeTemplateAttention`'s docstring for the full story). */
  poolTaskCount: number;
  /** Set when this template's last spawn was skipped — surfaces a badge. */
  attentionReason?: SpawnPoolFailureReason | 'no_pool_tasks_resolved' | 'spawn_failed';
  /** First few resolved pool task titles (≤ POOL_PREVIEW_LIMIT, in mix
   *  order); the page resolves ids against the library. Empty/omitted
   *  renders no chip row. */
  poolPreview?: string[];
  /** Count of additional resolved titles beyond `poolPreview` (0 ⇒ no
   *  "+k more" chip). See `computePoolPreview`. */
  poolPreviewOverflow?: number;
  onEdit: (template: RecurringBoardTemplate) => void;
  /** "Add tasks" — deep-links into the wizard's Tasks step for this
   *  template. Adds-only in framing; the wizard's existing min-count
   *  validation still guards removals below the floor. */
  onAddTasks: (template: RecurringBoardTemplate) => void;
}

export function RecurringTemplateRow({
  template,
  poolTaskCount,
  attentionReason,
  poolPreview = [],
  poolPreviewOverflow = 0,
  onEdit,
  onAddTasks,
}: RecurringTemplateRowProps): React.ReactElement {
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
      `Delete "${template.name}"? Boards spawned from this template will not be deleted.`,
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
          {`${poolTaskCount}-task pool`}
        </div>
        {poolPreview.length > 0 && (
          <div className={styles.poolPreview} aria-label="Pool preview">
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
            aria-label={`${template.isActive ? 'Pause' : 'Activate'} ${template.name}`}
          />
          <span>{template.isActive ? 'Active' : 'Paused'}</span>
        </label>
        <button
          type="button"
          className={styles.editButton}
          onClick={() => onAddTasks(template)}
          disabled={busy}
          aria-label={`Add tasks to ${template.name}`}
        >
          Add tasks
        </button>
        <button
          type="button"
          className={styles.editButton}
          onClick={() => onEdit(template)}
          disabled={busy}
        >
          Edit
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
