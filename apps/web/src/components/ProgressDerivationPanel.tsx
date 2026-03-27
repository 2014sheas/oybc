import { TaskType } from '@oybc/shared';
import type { TaskStep } from '@oybc/shared';
import { useTaskSteps } from '../hooks';
import { TypeBadge } from './TypeBadge';
import styles from './ProgressDerivationPanel.module.css';

/**
 * Props for ProgressDerivationPanel.
 */
export interface ProgressDerivationPanelProps {
  taskId: string;
  onExtractStep: (step: TaskStep) => Promise<void>;
  onAddStepToPool: (step: TaskStep) => void;
  isCreating: boolean;
  isInPool: (taskId: string) => boolean;
}

/**
 * ProgressDerivationPanel — shown when the selected parent is a progress task.
 *
 * Reactively fetches and displays all steps, including type metadata and whether
 * each step already has a linked task. Unlinked steps show an "Extract & Add to Pool"
 * button to create a task record and link it. Steps with linked tasks show
 * "Add to Pool" or an "In Pool" badge.
 *
 * @param taskId - The ID of the selected progress task
 * @param onExtractStep - Async callback invoked to extract a step as a task
 * @param onAddStepToPool - Callback to add an already-linked step's task to the pool
 * @param isCreating - Whether a creation operation is in progress
 * @param isInPool - Function to check whether a task ID is already in the pool
 */
export function ProgressDerivationPanel({
  taskId,
  onExtractStep,
  onAddStepToPool,
  isCreating,
  isInPool,
}: ProgressDerivationPanelProps): React.ReactElement {
  const steps = useTaskSteps(taskId) ?? [];

  if (steps.length === 0) {
    return <p className={styles.emptyState}>No steps defined for this progress task.</p>;
  }

  return (
    <ol className={styles.stepList} style={{ listStyle: 'none', padding: 0, margin: 0 }}>
      {steps.map((step: TaskStep, index: number) => (
        <li key={step.id} className={styles.stepItem}>
          <span className={styles.stepIndex}>{index + 1}</span>

          <div className={styles.stepInfo}>
            <span className={styles.stepTitle}>{step.title}</span>
            {step.type === TaskType.COUNTING &&
              step.action &&
              step.unit &&
              step.maxCount !== undefined && (
                <span className={styles.stepMeta}>
                  {step.action} {step.maxCount} {step.unit}
                </span>
              )}
          </div>

          <div className={styles.stepBadges}>
            {/* Step type badge */}
            <TypeBadge type={step.type} size="small" />

            {/* Action: add to pool or extract first */}
            {step.linkedTaskId ? (
              isInPool(step.linkedTaskId) ? (
                <span className={styles.linkedBadge}>In Pool ✓</span>
              ) : (
                <button
                  type="button"
                  className={styles.actionButton}
                  onClick={() => onAddStepToPool(step)}
                >
                  Add to Pool
                </button>
              )
            ) : (
              <button
                type="button"
                className={styles.actionButton}
                disabled={isCreating}
                onClick={() => void onExtractStep(step)}
              >
                Extract & Add to Pool
              </button>
            )}
          </div>
        </li>
      ))}
    </ol>
  );
}
