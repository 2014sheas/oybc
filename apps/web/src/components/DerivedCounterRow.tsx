import { TypeBadge } from './TypeBadge';
import styles from './DerivedCounterRow.module.css';

/**
 * Data required to render one derived-counter row.
 */
export interface DerivedCounterRowData {
  /** Stable identifier — used as React key by the parent list. */
  id: string;
  /** Auto-generated title from generateCounterTaskTitle(). */
  title: string;
  /** The derived task's personal threshold. */
  maxCount: number;
  /** The source count at the time this task was linked ("start from zero" offset). */
  baseline: number;
  /** Baseline mode label for display. */
  baselineMode: 'Inherit' | 'Start from zero';
}

export interface DerivedCounterRowResult {
  /** Count relative to baseline, clamped low at 0. Never high-clamped. */
  displayed: number;
  /** True when displayed >= maxCount. */
  isCompleted: boolean;
}

interface DerivedCounterRowProps {
  /** The derived task's display data. */
  data: DerivedCounterRowData;
  /** The live-computed derivation result from deriveDisplayedCount(). */
  result: DerivedCounterRowResult;
  /** Called when the remove button is clicked. */
  onRemove?: (id: string) => void;
}

/**
 * DerivedCounterRow — renders a single derived counting task's live progress.
 *
 * Designed for Phase 1 playground and reusable in Phase 2's CountingTemplatePicker
 * detail section. Shows the task title, baseline mode, progress fraction, and
 * a completion badge. No list-badge for the linked relationship (Decision 3:
 * detail-sheet only).
 *
 * @param data   - Static derived-task descriptor (title, maxCount, baseline, mode).
 * @param result - Live snapshot from deriveDisplayedCount() (displayed, isCompleted).
 * @param onRemove - Optional remove handler (playground use).
 */
export function DerivedCounterRow({
  data,
  result,
  onRemove,
}: DerivedCounterRowProps): React.ReactElement {
  const progressPercent =
    data.maxCount > 0
      ? Math.min(100, (result.displayed / data.maxCount) * 100)
      : 100;

  return (
    <div
      className={`${styles.row} ${result.isCompleted ? styles.rowCompleted : ''}`}
      aria-label={`Derived task: ${data.title}`}
    >
      {/* Left: type badge + title */}
      <div className={styles.titleBlock}>
        <TypeBadge type="counting" size="small" />
        <span className={styles.title}>{data.title}</span>
      </div>

      {/* Center: baseline mode + progress fraction */}
      <div className={styles.progressBlock}>
        <span className={styles.baselineLabel}>{data.baselineMode}</span>
        <span className={styles.fraction}>
          {result.displayed}
          <span className={styles.fractionSep}>/</span>
          {data.maxCount}
        </span>

        {/* Progress bar — percent-based ARIA so screen readers don't trip on
            overshoot (displayed can exceed maxCount intentionally). aria-valuetext
            carries the raw fraction for users who want the underlying numbers. */}
        <div
          className={styles.progressBar}
          role="progressbar"
          aria-valuenow={Math.min(100, Math.round(progressPercent))}
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuetext={`${result.displayed} of ${data.maxCount}`}
        >
          <div
            className={`${styles.progressFill} ${result.isCompleted ? styles.progressFillComplete : ''}`}
            style={{ width: `${progressPercent}%` }}
          />
        </div>
      </div>

      {/* Right: completion badge + optional remove */}
      <div className={styles.statusBlock}>
        {result.isCompleted ? (
          // Plain text status — no role="img" so assistive tech announces
          // the actual "Done" text rather than treating the span as an image.
          <span className={styles.completedBadge}>
            Done
          </span>
        ) : (
          <span className={styles.pendingBadge} aria-label="In progress">
            {progressPercent.toFixed(0)}%
          </span>
        )}
        {onRemove && (
          <button
            type="button"
            className={styles.removeButton}
            onClick={() => onRemove(data.id)}
            aria-label={`Remove ${data.title}`}
          >
            ×
          </button>
        )}
      </div>
    </div>
  );
}
