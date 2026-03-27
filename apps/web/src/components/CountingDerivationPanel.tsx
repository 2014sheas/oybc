import { generateCounterTaskTitle } from '@oybc/shared';
import type { Task } from '@oybc/shared';
import styles from './CountingDerivationPanel.module.css';

/**
 * Props for CountingDerivationPanel.
 */
export interface CountingDerivationPanelProps {
  task: Task;
  partialCount: string;
  onPartialCountChange: (value: string) => void;
  onCreateSubtask: (task: Task, count: number) => Promise<void>;
  isCreating: boolean;
}

/**
 * CountingDerivationPanel — shown when the selected parent is a counting task.
 *
 * Displays parent counting metadata and allows the user to enter a partial count
 * allocation, with a live preview of the derived subtask title. Provides a
 * "Add to Board Pool" button to persist the derived task to the task library.
 *
 * @param task - The selected counting task
 * @param partialCount - Current partial count input value (as string)
 * @param onPartialCountChange - Callback when the partial count field changes
 * @param onCreateSubtask - Async callback invoked when the user clicks "Add to Board Pool"
 * @param isCreating - Whether a creation operation is in progress
 */
export function CountingDerivationPanel({
  task,
  partialCount,
  onPartialCountChange,
  onCreateSubtask,
  isCreating,
}: CountingDerivationPanelProps): React.ReactElement {
  const action = task.action ?? '';
  const unit = task.unit ?? '';
  const maxCount = task.maxCount ?? 0;

  const parsedCount = parseInt(partialCount, 10);
  const isValid =
    partialCount !== '' && !isNaN(parsedCount) && parsedCount >= 1 && parsedCount <= maxCount;
  const isOutOfRange =
    partialCount !== '' && !isNaN(parsedCount) && (parsedCount < 1 || parsedCount > maxCount);
  const previewTitle = isValid ? generateCounterTaskTitle(action, parsedCount, unit) : null;

  return (
    <>
      {/* Parent counting metadata */}
      <div className={styles.countingMeta}>
        <div className={styles.countingMetaRow}>
          <span className={styles.metaLabel}>Action:</span>
          <span>{action || '—'}</span>
        </div>
        <div className={styles.countingMetaRow}>
          <span className={styles.metaLabel}>Unit:</span>
          <span>{unit || '—'}</span>
        </div>
        <div className={styles.countingMetaRow}>
          <span className={styles.metaLabel}>Parent total:</span>
          <span>{maxCount}</span>
        </div>
      </div>

      {/* Partial count allocation input */}
      <div className={styles.allocationField}>
        <label className={styles.allocationLabel} htmlFor="subtask-partial-count">
          Allocate count:
        </label>
        <input
          id="subtask-partial-count"
          type="number"
          className={`${styles.allocationInput} ${isOutOfRange ? styles.allocationInputError : ''}`}
          value={partialCount}
          min={1}
          max={maxCount}
          onChange={(e) => onPartialCountChange(e.target.value)}
          placeholder={`1 – ${maxCount}`}
        />
        {isOutOfRange && (
          <span className={styles.validationError}>Count must be between 1 and {maxCount}.</span>
        )}
      </div>

      {/* Live preview */}
      {isValid && previewTitle !== null && (
        <div className={styles.previewBox}>
          <span className={styles.previewLabel}>Derived subtask title preview</span>
          <span className={styles.previewTitle}>{previewTitle}</span>
        </div>
      )}

      {/* Create subtask action */}
      <button
        type="button"
        className={styles.actionButton}
        disabled={!isValid || isCreating}
        onClick={() => {
          if (isValid) {
            void onCreateSubtask(task, parsedCount);
          }
        }}
      >
        {isCreating ? 'Adding...' : 'Add to Board Pool'}
      </button>
    </>
  );
}
