import styles from './TasksPoolHeader.module.css';

export interface TasksPoolHeaderProps {
  selectedCount: number;
  tasksRequired: number;
  /** Recurring mode appends " min" to the denominator + tweaks the
   *  satisfied/over copy — the spawn shuffles + slices from a loose-fit
   *  pool, so "extra" tasks become the random subset each window. */
  isRecurring: boolean;
  /** True when a center square must be picked from the pool (CHOSEN). */
  centerTaskMode: boolean;
  /** True when a center task has been marked AND is still selected. */
  centerSatisfied: boolean;
}

/**
 * TasksPoolHeader — pool-header card for the wizard Tasks step (Web
 * inline-editing port PR-1, porting iOS `RisoTasksPoolHeaderView`).
 *
 * "YOUR TASK POOL" kicker + N/required count, a blue→green progress bar,
 * pool-model copy (short / exact / over), and — when `centerTaskMode` is
 * on — a center-task indicator line.
 *
 * Deliberate divergence from iOS (recorded in the handoff, §1): iOS colors
 * the whole satisfied center-task line gold, which is 1.33:1 contrast on
 * paper — unreadable. Here only the ★ glyph stays gold as the state cue;
 * the label text uses `--riso-ink` (satisfied) / `--riso-muted`
 * (unsatisfied) since gold is a fill color in this system, never a text
 * color on paper.
 */
export function TasksPoolHeader({
  selectedCount,
  tasksRequired,
  isRecurring,
  centerTaskMode,
  centerSatisfied,
}: TasksPoolHeaderProps): React.ReactElement {
  const remaining = Math.max(0, tasksRequired - selectedCount);
  const extra = Math.max(0, selectedCount - tasksRequired);
  const isSatisfied = selectedCount >= tasksRequired;
  const progress = tasksRequired > 0 ? Math.min(1, selectedCount / tasksRequired) : 0;

  return (
    <div className={styles.card}>
      <div className={styles.headRow}>
        <span className={styles.kicker}>Your task pool</span>
        <span
          className={styles.countBadge}
          aria-label={`Selected ${selectedCount} of ${tasksRequired}${isRecurring ? ' minimum' : ''} tasks`}
        >
          <span className={isSatisfied ? styles.countOk : styles.countInk} aria-hidden="true">
            {selectedCount}
          </span>
          <span className={styles.countDenominator} aria-hidden="true">
            /{tasksRequired}
            {isRecurring ? ' min' : ''}
          </span>
        </span>
      </div>

      <div className={styles.progressTrack}>
        <div
          className={styles.progressFill}
          style={{
            width: `${progress * 100}%`,
            background: isSatisfied ? 'var(--riso-green)' : 'var(--riso-blue)',
          }}
        />
      </div>

      <p className={styles.note}>
        {isSatisfied ? (
          extra > 0 ? (
            <span className={styles.noteOk}>
              ✓ Fills your board · <strong>{extra} extra</strong>{' '}
              {isRecurring ? 'shuffle in each spawn' : 'shuffle into the mix'}
            </span>
          ) : (
            <span className={styles.noteOk}>✓ Fills your board exactly</span>
          )
        ) : (
          <span className={styles.noteShort}>
            Add <strong>{remaining}</strong> more — extras later just shuffle into the mix
          </span>
        )}
      </p>

      {centerTaskMode && (
        <div className={styles.centerLine}>
          <span aria-hidden="true" className={centerSatisfied ? styles.centerGlyphOn : styles.centerGlyphOff}>
            {centerSatisfied ? '★' : '☆'}
          </span>
          <span className={centerSatisfied ? styles.centerLabelOn : styles.centerLabelOff}>
            {centerSatisfied ? 'Center task chosen' : 'Tap ☆ on a pool task to set the center'}
          </span>
        </div>
      )}
    </div>
  );
}
