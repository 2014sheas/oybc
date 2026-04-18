import { OperatorType } from '@oybc/shared';
import type { SubtaskDraft } from './compositeSubtaskDraft';
import styles from './ReviewStep.module.css';

export interface ReviewStepProps {
  title: string;
  operator: OperatorType;
  threshold: number;
  subtasks: SubtaskDraft[];
  isSubmitting: boolean;
  errorMessage: string | null;
  onBack: () => void;
  onCreate: () => void;
}

/**
 * Step 3 of the composite mini-wizard. Minimal summary + Create button
 * for stage 2; fuller polish (summary card, library callout, retry UI)
 * lands in stage 4.
 */
export function ReviewStep({
  title,
  operator,
  threshold,
  subtasks,
  isSubmitting,
  errorMessage,
  onBack,
  onCreate,
}: ReviewStepProps): React.ReactElement {
  const inlineCount = subtasks.filter((s) => s.mode === 'inline').length;

  const operatorLabel =
    operator === OperatorType.AND
      ? 'All of'
      : operator === OperatorType.OR
        ? 'Any of'
        : `At least ${threshold} of`;

  return (
    <div className={styles.container}>
      <h3 className={styles.heading}>Review</h3>

      <dl className={styles.summary}>
        <div className={styles.row}>
          <dt>Title</dt>
          <dd>{title.trim() || <span className={styles.placeholder}>(unset)</span>}</dd>
        </div>
        <div className={styles.row}>
          <dt>Completion rule</dt>
          <dd>{operatorLabel}</dd>
        </div>
        <div className={styles.row}>
          <dt>Subtasks</dt>
          <dd>
            {subtasks.length} total
            {inlineCount > 0 && ` · ${inlineCount} will also be added to your library`}
          </dd>
        </div>
      </dl>

      {errorMessage && <div className={styles.errorBanner}>{errorMessage}</div>}

      <div className={styles.footer}>
        <button type="button" className={styles.backButton} onClick={onBack} disabled={isSubmitting}>
          ‹ Back
        </button>
        <button
          type="button"
          className={styles.createButton}
          onClick={onCreate}
          disabled={isSubmitting}
        >
          {isSubmitting ? 'Creating…' : 'Create Composite'}
        </button>
      </div>
    </div>
  );
}
