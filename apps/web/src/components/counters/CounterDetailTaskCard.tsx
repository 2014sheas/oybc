import { useNavigate } from 'react-router-dom';
import type { SharedCounterMemberTask } from '@oybc/shared';
import { timeframeDotColor } from './timeframeDotColor';
import styles from './CounterDetailTaskCard.module.css';

interface CounterDetailTaskCardProps {
  /** The member task to render. */
  task: SharedCounterMemberTask;
  /** The counter's unit string (e.g. "reps") for caption copy. */
  unit: string | null;
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
 *   - Greyed out, not clickable.
 *   - Shows "Starts counting when this board goes live."
 *
 * Matches the `cd-task` design from the shared-counters design handoff.
 */
export function CounterDetailTaskCard({
  task,
  unit,
  inactive = false,
}: CounterDetailTaskCardProps): React.ReactElement {
  const navigate = useNavigate();
  const pct = task.goal > 0 ? Math.min(100, (task.logged / task.goal) * 100) : 0;
  const dotColor = timeframeDotColor(task.timeframe);
  const unitStr = unit ?? '';

  // Build caption copy
  const caption = buildCaption(task, unitStr);

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
        <div className={styles.caption}>Starts counting when this board goes live.</div>
      </div>
    );
  }

  return (
    <button
      type="button"
      className={styles.card}
      onClick={handleClick}
      disabled={!task.boardId}
      aria-label={`${task.taskTitle}: ${task.logged} of ${task.goal} ${unitStr}. ${task.boardName ?? ''}. ${caption}`}
    >
      {/* Top row: task name (left) + logged/goal (right) */}
      <div className={styles.top}>
        <span className={styles.taskName}>{task.taskTitle}</span>
        <span className={styles.progressVal} aria-hidden="true">
          {task.logged.toLocaleString()}
          <span className={styles.progressGoal}>/{task.goal.toLocaleString()}</span>
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

/**
 * Derives the window caption from the task's progress state.
 * Priority: over-goal → met → in progress (with remaining count).
 */
function buildCaption(task: SharedCounterMemberTask, unit: string): string {
  if (task.met && task.over > 0) {
    return `✓ Goal met · ${task.over.toLocaleString()} over`;
  }
  if (task.met) {
    return '✓ Goal met this window';
  }
  const remaining = Math.max(0, task.goal - task.logged);
  const windowPrefix = task.window ? `${task.window} · ` : '';
  return `${windowPrefix}${remaining.toLocaleString()} ${unit} to go`;
}
