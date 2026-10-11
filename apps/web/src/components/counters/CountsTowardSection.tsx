import { useEffect, useState } from 'react';
import type { ContributorRowStatus } from '@oybc/shared';
import type { CountsTowardSectionData } from '../../db/operations/countsTowardSection';
import { RisoButton } from '../riso/RisoButton';
import { RisoSectionLabel } from '../riso/RisoSectionLabel';
import { RisoTypeBadge } from '../riso/RisoTypeBadge';
import { COUNTS_TOWARD_STATUS_LABELS, StatusPill, type StatusPillStatus } from '../StatusPill';
import {
  UNIT_TASKS_EMPTY,
  creditCountText,
  removableRow,
  removeNeedsConfirm,
  removeSlotLabel,
  rowProgressText,
  unitTasksHeading,
} from './countsTowardLabels';
import { CounterWriteError } from './CounterWriteError';
import { RemoveUnitTaskConfirmDialog } from './RemoveUnitTaskConfirmDialog';
import { timeframeDotColor } from './timeframeDotColor';
import styles from './CountsTowardSection.module.css';

export interface CountsTowardSectionProps {
  data: CountsTowardSectionData;
  /** `counterDisplayName(root)` — names the remove slot and its confirm. */
  counterName: string;
  /** "+ New" — opens the task creator preset to this counter. */
  onNew: () => void;
  /** Row tap → Task Detail. */
  onOpenTask: (taskId: string) => void;
  /** Withdraws a unit task from the counter — clears every `memberIds` flag (`removeUnitTaskLineage`). */
  onRemove: (memberIds: string[]) => Promise<void>;
  /** A failed remove's line, shown under the list. */
  removeError?: string | null;
  /** The task "+ New" just created: its row wears the gold return ring until the next interaction. */
  arrivedTaskId?: string | null;
  /** The next interaction after an arrival — clears the ring. */
  onArrivalSeen?: () => void;
}

const PILL_STATUS: Record<ContributorRowStatus, StatusPillStatus> = {
  done: 'completed',
  inProgress: 'inProgress',
  notStarted: 'notStarted',
};

/**
 * Counter Detail's "Unit tasks" section (docs/SHARED_COUNTER_SETTINGS.md §3;
 * unit-tasks handoff §A): the tasks that credit one to a Discrete counter —
 * type badge · title (done = muted + strikethrough) · board line (timeframe
 * dot + board, then progress / "× N" credits) · StatusPill · a persistent ✕
 * remove slot — in In progress → Not started → Done order, or the empty
 * one-liner. A unit task with credits confirms before removal; one without
 * is removed at once.
 */
export function CountsTowardSection({ data, counterName, onNew, onOpenTask, onRemove, removeError = null, arrivedTaskId = null, onArrivalSeen }: CountsTowardSectionProps): React.ReactElement {
  const { rows, taskById, boardById } = data;
  const [confirmId, setConfirmId] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // The return ring stays until the next interaction.
  useEffect(() => {
    if (!arrivedTaskId || !onArrivalSeen) return undefined;
    const clear = (): void => onArrivalSeen();
    window.addEventListener('pointerdown', clear, { once: true });
    window.addEventListener('keydown', clear, { once: true });
    return () => {
      window.removeEventListener('pointerdown', clear);
      window.removeEventListener('keydown', clear);
    };
  }, [arrivedTaskId, onArrivalSeen]);

  async function remove(memberIds: string[]): Promise<void> {
    setBusy(true);
    try {
      await onRemove(memberIds);
    } finally {
      setBusy(false);
      setConfirmId(null);
    }
  }

  const confirmRow = confirmId ? rows.find((r) => r.taskId === confirmId) : undefined;
  const confirmTask = confirmRow ? taskById[confirmRow.taskId] : undefined;

  return (
    <section className={styles.section} aria-label="Unit tasks">
      <div className={styles.headRow}>
        <RisoSectionLabel>{unitTasksHeading(rows.length)}</RisoSectionLabel>
        <RisoButton kind="neutral" size="small" onClick={onNew}>
          + New
        </RisoButton>
      </div>
      {rows.length === 0 ? (
        <p className={styles.empty}>{UNIT_TASKS_EMPTY}</p>
      ) : (
        <ul className={styles.list} role="list" aria-label="Unit tasks of this counter">
          {rows.map((row) => {
            const task = taskById[row.taskId];
            const board = row.boardId ? boardById[row.boardId] : undefined;
            if (!task) return null;
            const credits = creditCountText(row);
            const progress = rowProgressText(row, task);
            const done = row.status === 'done';
            const arrived = row.taskId === arrivedTaskId;
            return (
              <li key={row.taskId} className={`${styles.item} ${arrived ? styles.arrived : ''}`}>
                <button type="button" className={styles.rowButton} onClick={() => onOpenTask(row.taskId)}>
                  <RisoTypeBadge type={task.type} />
                  <span className={styles.main}>
                    <span className={`${styles.title} ${done ? styles.titleDone : ''}`}>{task.title}</span>
                    {(board || progress || credits) && (
                      <span className={styles.boardLine}>
                        {board && (
                          <>
                            <i className={styles.dot} style={{ background: timeframeDotColor(board.timeframe) }} aria-hidden="true" />
                            <span className={styles.boardName}>{board.name}</span>
                          </>
                        )}
                        {progress && <span className={styles.progress}>{progress}</span>}
                        {credits && <span className={styles.credits}>{credits}</span>}
                      </span>
                    )}
                  </span>
                  <StatusPill status={PILL_STATUS[row.status]} labels={COUNTS_TOWARD_STATUS_LABELS} dense />
                </button>
                {removableRow(row) ? (
                  <button
                    type="button"
                    className={styles.removeButton}
                    aria-label={removeSlotLabel(counterName)}
                    disabled={busy}
                    onClick={() => (removeNeedsConfirm(row) ? setConfirmId(row.taskId) : void remove(row.memberIds))}
                  >
                    ✕
                  </button>
                ) : (
                  <span className={styles.removeSpacer} aria-hidden="true">✕</span>
                )}
              </li>
            );
          })}
        </ul>
      )}
      <CounterWriteError message={removeError} />
      {confirmRow && confirmTask && (
        <RemoveUnitTaskConfirmDialog
          counterName={counterName}
          taskTitle={confirmTask.title}
          credits={confirmRow.creditCount}
          busy={busy}
          onConfirm={() => void remove(confirmRow.memberIds)}
          onCancel={() => setConfirmId(null)}
        />
      )}
    </section>
  );
}
