import { CountingStepFields } from './CountingStepFields';
import styles from './ProgressStepRow.module.css';

const DEFAULT_STEP_TITLE_MAX_LENGTH = 200;

/**
 * Generates a unique client-side ID for form step tracking.
 *
 * @returns A unique string ID
 */
export function generateFormId(): string {
  return crypto.randomUUID();
}

/**
 * Creates a new empty step form state.
 *
 * @returns A fresh StepFormState with default values
 */
export function createEmptyStep(): StepFormState {
  return {
    id: generateFormId(),
    title: '',
    type: 'normal',
    action: '',
    unit: '',
    maxCount: '',
  };
}

/**
 * Form state for a single step in a progress task creation form.
 * Exported so parent components (ProgressTaskCreationPlayground,
 * UnifiedTaskCreatorPlayground) share a single type definition.
 */
export interface StepFormState {
  id: string;
  title: string;
  type: 'normal' | 'counting';
  action: string;
  unit: string;
  maxCount: string;
}

/**
 * Validation error state for a single progress step.
 * Exported so parent FormErrors types can reference it.
 */
export interface StepFormErrors {
  title?: string;
  action?: string;
  unit?: string;
  maxCount?: string;
}

/**
 * Returns CSS class for character count based on proximity to limit.
 *
 * @param current - Current character count
 * @param max - Maximum allowed characters
 * @returns CSS class name string
 */
function getCharCountClass(current: number, max: number): string {
  if (current > max) return `${styles.charCount} ${styles.charCountError}`;
  if (current >= max * 0.9) return `${styles.charCount} ${styles.charCountWarning}`;
  return styles.charCount;
}

interface ProgressStepRowProps {
  index: number;
  /** Prefix for input element IDs to ensure uniqueness within the page (e.g. "step-abc123") */
  idPrefix: string;
  step: StepFormState;
  errors?: StepFormErrors;
  canRemove: boolean;
  /** Max length for step title display and input; defaults to 200 */
  stepTitleMaxLength?: number;
  /** Called when any field value changes */
  onFieldChange: (field: keyof StepFormState, value: string) => void;
  onRemove: () => void;
}

/**
 * ProgressStepRow - Reusable row for a single progress task step
 *
 * Renders the step header (number + remove button), step title field, type selector,
 * and the conditional CountingStepFields when type is "counting". Used in both
 * ProgressTaskCreationPlayground and UnifiedTaskCreatorPlayground to eliminate
 * duplicated step rendering logic.
 *
 * @param index - Zero-based step index (displays as "Step N+1")
 * @param idPrefix - Unique ID prefix for all inputs in this row
 * @param step - Current step form state
 * @param errors - Optional field-level errors
 * @param canRemove - Whether the Remove button is enabled
 * @param stepTitleMaxLength - Max character limit for step title (default: 200)
 * @param onFieldChange - Callback for any field value change
 * @param onRemove - Callback for the Remove button
 */
export function ProgressStepRow({
  index,
  idPrefix,
  step,
  errors,
  canRemove,
  stepTitleMaxLength = DEFAULT_STEP_TITLE_MAX_LENGTH,
  onFieldChange,
  onRemove,
}: ProgressStepRowProps): React.ReactElement {
  return (
    <div className={styles.stepRow}>
      <div className={styles.stepHeader}>
        <span className={styles.stepNumber}>Step {index + 1}</span>
        <button
          type="button"
          className={styles.removeStepButton}
          onClick={onRemove}
          disabled={!canRemove}
        >
          Remove
        </button>
      </div>

      <div className={styles.stepFields}>
        {/* Step Title */}
        <div className={styles.fieldGroup}>
          <label className={styles.label} htmlFor={`${idPrefix}-title`}>
            Step Title{step.type !== 'counting' && <span className={styles.required}>*</span>}
          </label>
          <input
            id={`${idPrefix}-title`}
            type="text"
            className={`${styles.input} ${errors?.title ? styles.inputError : ''}`}
            value={step.title}
            onChange={(e) => onFieldChange('title', e.target.value)}
            placeholder={step.type === 'counting' ? 'Auto-generated if blank' : 'Enter step title'}
            maxLength={stepTitleMaxLength + 1}
          />
          <span className={getCharCountClass(step.title.length, stepTitleMaxLength)}>
            {step.title.length}/{stepTitleMaxLength}
          </span>
          {errors?.title && (
            <span className={styles.fieldError}>{errors.title}</span>
          )}
        </div>

        {/* Step Type */}
        <div className={styles.fieldGroup}>
          <label className={styles.label} htmlFor={`${idPrefix}-type`}>
            Type
          </label>
          <select
            id={`${idPrefix}-type`}
            className={styles.stepTypeSelect}
            value={step.type}
            onChange={(e) =>
              onFieldChange('type', e.target.value as 'normal' | 'counting')
            }
          >
            <option value="normal">Normal</option>
            <option value="counting">Counting</option>
          </select>
        </div>

        {/* Counting Fields (conditional) */}
        {step.type === 'counting' && (
          <CountingStepFields
            idPrefix={idPrefix}
            action={step.action}
            maxCount={step.maxCount}
            unit={step.unit}
            errors={errors}
            onChange={(field, value) => onFieldChange(field, value)}
          />
        )}
      </div>
    </div>
  );
}
