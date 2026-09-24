import { useState } from 'react';
import { searchCompoundChildCandidates, type Task } from '@oybc/shared';
import { useModalA11y } from '../../hooks/useModalA11y';
import { RisoButton } from '../riso';
import { TypeBadge } from '../TypeBadge';
import styles from './ExistingTaskPicker.module.css';

/** Whether the caller's candidate list has arrived (Task Detail loads it). */
export type PickerInputsState = 'loading' | 'loaded' | 'failed';

export interface ExistingTaskPickerProps {
  /**
   * The ELIGIBLE candidates, already filtered by the caller
   * (`compoundChildPickerCandidates`) — the picker only searches and lists.
   */
  tasks: Task[];
  /** A row was chosen; the caller appends it as a sub-task and closes. */
  onPick: (task: Task) => void;
  /** Backdrop click / Escape / Cancel. */
  onCancel: () => void;
  /** Candidate-list load state; the list shows only once `loaded`. Default `loaded`. */
  status?: PickerInputsState;
}

/**
 * ExistingTaskPicker — the compound editor's "+ Existing task…" dialog: a
 * title search over the eligible library tasks and one row per task
 * (`TypeBadge` + title). Picking a row hands the task to `onPick`.
 *
 * Opened from `CompoundFields`, so it serves both the wizard's inline
 * pool-row editor and the Task Detail edit sheet. It nests inside those
 * surfaces: `useModalA11y` consumes Escape (`preventDefault`) so the
 * enclosing sheet / row editor stays open, and clicks stop here so the
 * outer backdrop never sees them. iOS twin: `RisoExistingTaskPickerSheet`.
 */
export function ExistingTaskPicker({
  tasks,
  onPick,
  onCancel,
  status = 'loaded',
}: ExistingTaskPickerProps): React.ReactElement {
  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({
    open: true,
    onCancel,
  });
  const [query, setQuery] = useState('');
  const visible = searchCompoundChildCandidates(tasks, query);

  return (
    <div
      className={styles.backdrop}
      onClick={(e) => {
        e.stopPropagation();
        onCancel();
      }}
    >
      <div
        ref={modalRef}
        role="dialog"
        aria-label="Add an existing task"
        {...modalProps}
        className={styles.dialog}
        onClick={(e) => e.stopPropagation()}
      >
        <h3 className={styles.title}>Add an existing task</h3>
        <input
          type="search"
          autoFocus
          className={styles.search}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search your tasks"
          aria-label="Search tasks"
        />
        {status === 'loading' ? (
          <p className={styles.empty}>Loading your tasks…</p>
        ) : status === 'failed' ? (
          <p className={styles.empty} role="alert">
            Couldn&apos;t load your tasks. Close and reopen the editor to try again.
          </p>
        ) : visible.length === 0 ? (
          <p className={styles.empty}>
            {tasks.length === 0 ? 'No tasks can be added to this compound.' : 'No matching tasks.'}
          </p>
        ) : (
          <ul className={styles.list} aria-label="Tasks you can add">
            {visible.map((task) => (
              <li key={task.id}>
                <button
                  type="button"
                  className={styles.row}
                  onClick={() => onPick(task)}
                  aria-label={`Add ${task.title}`}
                >
                  <TypeBadge type={task.type} size="small" letterOnly />
                  <span className={styles.rowTitle}>{task.title}</span>
                </button>
              </li>
            ))}
          </ul>
        )}
        <div className={styles.actions}>
          <RisoButton kind="ghost" onClick={onCancel}>
            Cancel
          </RisoButton>
        </div>
      </div>
    </div>
  );
}
