import { OperatorType } from '@oybc/shared';
import { OperatorSelector } from '../OperatorSelector';
import { CounterStepper } from '../CounterStepper';
import { getCharCountClass } from '../playground/playgroundUtils';
import styles from './SetupStep.module.css';

const TITLE_MAX_LENGTH = 200;

export interface SetupStepProps {
  title: string;
  onTitleChange: (next: string) => void;
  operator: OperatorType;
  onOperatorChange: (next: OperatorType) => void;
  threshold: number;
  onThresholdChange: (next: number) => void;
  /** Needed to scope the threshold stepper's max. Zero during setup is
   *  fine — the stepper falls back to 1 to avoid a disabled min == max
   *  trap when the user hasn't built any subtasks yet. */
  subtaskCount: number;
  onCancel: () => void;
  onNext: () => void;
}

/**
 * Step 1 of the composite mini-wizard. Title + operator + (conditional)
 * threshold. Next is blocked until the title is non-empty; validation
 * is live, not deferred to submit.
 */
export function SetupStep({
  title,
  onTitleChange,
  operator,
  onOperatorChange,
  threshold,
  onThresholdChange,
  subtaskCount,
  onCancel,
  onNext,
}: SetupStepProps): React.ReactElement {
  const trimmedTitle = title.trim();
  const titleError =
    trimmedTitle.length === 0
      ? null // Don't nag empty-and-never-touched state
      : trimmedTitle.length > TITLE_MAX_LENGTH
        ? `Title must be ${TITLE_MAX_LENGTH} characters or less.`
        : null;

  const canAdvance = trimmedTitle.length > 0 && titleError === null;

  // Stepper max: subtask count, falling back to 1 so the stepper
  // renders meaningfully even when the user hasn't built the list yet.
  const thresholdMax = Math.max(1, subtaskCount);

  return (
    <div className={styles.container}>
      <div className={styles.fieldGroup}>
        <label className={styles.label} htmlFor="composite-wizard-title">
          Title<span className={styles.required}>*</span>
        </label>
        <input
          id="composite-wizard-title"
          type="text"
          className={styles.titleInput}
          value={title}
          onChange={(e) => onTitleChange(e.target.value)}
          placeholder="Enter composite task title"
          maxLength={TITLE_MAX_LENGTH + 1}
        />
        <span className={getCharCountClass(title.length, TITLE_MAX_LENGTH, styles)}>
          {title.length}/{TITLE_MAX_LENGTH}
        </span>
        {titleError !== null && <span className={styles.fieldError}>{titleError}</span>}
      </div>

      <div className={styles.fieldGroup}>
        <span className={styles.label}>Completion rule</span>
        <OperatorSelector selectedOperator={operator} onOperatorChange={onOperatorChange} />
        {operator === OperatorType.M_OF_N && (
          <div className={styles.thresholdRow}>
            <CounterStepper
              value={threshold}
              min={1}
              max={thresholdMax}
              onChange={onThresholdChange}
              label={
                subtaskCount > 0
                  ? `of ${subtaskCount} subtask${subtaskCount !== 1 ? 's' : ''}`
                  : 'of your subtasks (add them in the next step)'
              }
            />
          </div>
        )}
      </div>

      <div className={styles.footer}>
        <button type="button" className={styles.cancelButton} onClick={onCancel}>
          Cancel
        </button>
        <button
          type="button"
          className={styles.nextButton}
          onClick={onNext}
          disabled={!canAdvance}
          title={canAdvance ? undefined : 'Add a title to continue.'}
        >
          Next ›
        </button>
      </div>
    </div>
  );
}
