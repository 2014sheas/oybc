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
import styles from './RecurringTemplatesSection.module.css';

const TIMEFRAME_LABELS: Record<Timeframe, string> = {
  [Timeframe.DAILY]: 'Daily',
  [Timeframe.WEEKLY]: 'Weekly',
  [Timeframe.MONTHLY]: 'Monthly',
  [Timeframe.YEARLY]: 'Yearly',
  [Timeframe.CUSTOM]: 'Custom',
};

const ATTENTION_COPY: Record<SpawnPoolFailureReason | 'no_pool_tasks_resolved', string> = {
  pool_too_small: 'Pool is too small for the current configuration. Edit to add tasks.',
  pool_wrong_size: "Pool doesn't fit the board size. Edit to adjust the task list.",
  has_deleted_tasks: 'A task in this template was deleted. Edit to refresh the pool.',
  invalid_strategy: 'Pool strategy needs attention. Try editing this template.',
  unsupported_timeframe: "This template's timeframe is no longer supported.",
  unsupported_center: "This template's center cell is no longer supported.",
  no_pool_tasks_resolved: 'None of this template\'s tasks could be loaded. Edit to refresh the pool.',
};

export interface RecurringTemplateRowProps {
  template: RecurringBoardTemplate;
  /** Set when this template's last spawn was skipped — surfaces a badge. */
  attentionReason?: SpawnPoolFailureReason | 'no_pool_tasks_resolved';
  onEdit: (template: RecurringBoardTemplate) => void;
}

export function RecurringTemplateRow({
  template,
  attentionReason,
  onEdit,
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
          {template.poolStrategy === 'all'
            ? `${template.seedTaskIds.length} tasks`
            : `${template.seedTaskIds.length}-task pool`}
        </div>
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
