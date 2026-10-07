import { useNavigate } from 'react-router-dom';
import { formatCountWithUnit, type CountKind, type SharedCounterMemberTask } from '@oybc/shared';
import { buildTaskCardCaption } from './counterDetailCaption';
import { memberValueParts } from './memberValueLabel';
import { timeframeDotColor } from './timeframeDotColor';
import styles from './CounterDetailTaskCard.module.css';

interface CounterDetailTaskCardProps {
  /** The member task to render. */
  task: SharedCounterMemberTask;
  /** The counter's unit string (e.g. "reps") for caption copy. */
  unit: string | null;
  /** The counter's kind (default Discrete). */
  kind?: CountKind;
  /** Whether this task is inactive ("Not counting now" section). */
  inactive?: boolean;
}

/**
 * CounterDetailTaskCard — one member task card in the Counter Detail screen.
 *
 * Active cards (inactive=false, default):
 *   - Tapping navigates to the task's board (/boards/:boardId).
 *   - Shows task name, logged/goal, board + dot, window progress bar,
 *     and a caption: "{window} · {remaining} to go" / "✓ Goal met" / "✓ Goal met · N over".
 *
 * Inactive cards (inactive=true, "Not counting now" section):
 *   - Greyed out, not clickable; name, Draft / Unplaced badge and board only.
 *
 * Matches the `cd-task` design from the shared-counters design handoff.
 */
export function CounterDetailTaskCard({
  task,
  unit,
  kind = 'discrete',
  inactive = false,
}: CounterDetailTaskCardProps): React.ReactElement {
  const navigate = useNavigate();
  const pct = task.goal > 0 ? Math.min(100, (task.logged / task.goal) * 100) : 0;
  const dotColor = timeframeDotColor(task.timeframe);
  const unitStr = unit ?? '';

  // Build caption copy
  const caption = buildTaskCardCaption(task, unitStr, kind);
  const value = memberValueParts(task.logged, task.goal, kind);

  const handleClick = () => {
    if (!inactive && task.boardId) {
      navigate(`/boards/${task.boardId}`);
    }
  };

  if (inactive) {
    return (
      <div className={`${styles.card} ${styles.cardInactive}`} aria-label={`${task.taskTitle} — inactive`}>
        <div className={styles.top}>
          <span className={styles.taskName}>{task.taskTitle}</span>
          <span className={styles.inactiveBadge}>
            {task.boardId ? 'Draft' : 'Unplaced'}
          </span>
        </div>
        {task.boardName && (
          <div className={styles.boardRow}>
            <span
              className={styles.dot}
              style={{ backgroundColor: dotColor }}
              aria-hidden="true"
            />
            <span>{task.boardName}</span>
          </div>
        )}
      </div>
    );
  }

  return (
    <button
      type="button"
      className={styles.card}
      onClick={handleClick}
      disabled={!task.boardId}
      aria-label={`${task.taskTitle}: ${formatCountWithUnit(task.logged, kind, unitStr)} of ${formatCountWithUnit(task.goal, kind, unitStr)}. ${task.boardName ?? ''}. ${caption}`}
    >
      {/* Top row: task name (left) + logged/goal (right) */}
      <div className={styles.top}>
        <span className={styles.taskName}>{task.taskTitle}</span>
        <span className={styles.progressVal} aria-hidden="true">
          {value.logged}
          <span className={styles.progressGoal}>/{value.goal}</span>
        </span>
      </div>

      {/* Board + timeframe dot */}
      {task.boardName && (
        <div className={styles.boardRow}>
          <span
            className={styles.dot}
            style={{ backgroundColor: dotColor }}
            aria-hidden="true"
          />
          <span>{task.boardName}</span>
        </div>
      )}

      {/* Window progress bar */}
      <div className={styles.barWrap} aria-hidden="true">
        <div
          className={`${styles.barFill} ${task.met ? styles.barFillMet : ''}`}
          style={{ width: `${pct}%` }}
        />
      </div>

      {/* Caption */}
      <div className={styles.caption} aria-hidden="true">
        {caption}
      </div>
    </button>
  );
}
