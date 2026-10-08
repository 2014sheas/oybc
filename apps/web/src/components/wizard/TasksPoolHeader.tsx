import styles from './TasksPoolHeader.module.css';

export interface TasksPoolHeaderProps {
  /**
   * Board Sources P4 — the sources CAPACITY: sum of every source's
   * effective max + hand-added, deduped (`useBoardWizard.capacity`).
   * Named `selectedCount` before P4.
   */
  capacity: number;
  tasksRequired: number;
  /** Kept for any future per-mode divergence — the copy no longer
   *  branches on it (no " min" suffix; docs/BOARD_SOURCES.md §Surfaces
   *  item 1). */
  isRecurring: boolean;
  /** True when a center square must be picked from the pool (CHOSEN). */
  centerTaskMode: boolean;
  /** True when a center task has been marked AND is still selected. */
  centerSatisfied: boolean;
  /** Replaces the pool-model note line (pool editor: the deck-preview text). */
  note?: string;
}

/**
 * TasksPoolHeader — pool-header card for the wizard Tasks step (Web
 * inline-editing port PR-1, porting iOS `RisoTasksPoolHeaderView`).
 *
 * "YOUR TASK POOL" kicker + N/required count, a blue→green progress bar,
 * an optional caller note, and — when `centerTaskMode` is
 * on — a center-task indicator line.
 *
 * Board Sources P4 (docs/BOARD_SOURCES.md §Surfaces item 1): the count is
 * the CAPACITY (`n/required`, green once satisfied). The advice sentences
 * ("N more to fill the board…", "✓ Fills your board…") were removed under
 * #548 — the count + bar carry the state; only a caller-supplied `note`
 * (the pool editor's deck preview) renders a line.
 *
 * Deliberate divergence from iOS (recorded in the handoff, §1): iOS colors
 * the whole satisfied center-task line gold, which is 1.33:1 contrast on
 * paper — unreadable. Here only the ★ glyph stays gold as the state cue;
 * the label text uses `--riso-ink` (satisfied) / `--riso-muted`
 * (unsatisfied) since gold is a fill color in this system, never a text
 * color on paper.
 */
export function TasksPoolHeader({
  capacity,
  tasksRequired,
  isRecurring: _isRecurring,
  centerTaskMode,
  centerSatisfied,
  note,
}: TasksPoolHeaderProps): React.ReactElement {
  const isSatisfied = capacity >= tasksRequired;
  const progress = tasksRequired > 0 ? Math.min(1, capacity / tasksRequired) : 0;

  return (
    <div className={styles.card}>
      <div className={styles.headRow}>
        <span className={styles.kicker}>Your task pool</span>
        <span
          className={styles.countBadge}
          aria-label={`Capacity ${capacity} of ${tasksRequired} tasks`}
        >
          <span className={isSatisfied ? styles.countOk : styles.countInk} aria-hidden="true">
            {capacity}
          </span>
          <span className={styles.countDenominator} aria-hidden="true">
            /{tasksRequired}
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

      {note !== undefined && (
        <p className={styles.note}>
          <span className={isSatisfied ? styles.noteOk : styles.noteShort}>{note}</span>
        </p>
      )}

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
