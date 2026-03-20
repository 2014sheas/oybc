import styles from './CountingStepFields.module.css';

/** Maximum character lengths matching shared validation schemas */
const ACTION_MAX_LENGTH = 50;
const UNIT_MAX_LENGTH = 50;

/**
 * Validation error state for counting step fields.
 * Exported so parent components can reference it in their own error types.
 */
export interface CountingStepFieldErrors {
  action?: string;
  maxCount?: string;
  unit?: string;
}

interface CountingStepFieldsProps {
  /** Prefix for input element IDs to ensure uniqueness within the page */
  idPrefix: string;
  action: string;
  maxCount: string;
  unit: string;
  errors?: CountingStepFieldErrors;
  /** Called when any field value changes */
  onChange: (field: 'action' | 'maxCount' | 'unit', value: string) => void;
}

/**
 * CountingStepFields - Reusable counting step sub-fields (Action → Max Count → Unit)
 *
 * Renders the three required fields for a counting task step in the canonical order.
 * Used inside progress task step rows in both ProgressTaskCreationPlayground and
 * UnifiedTaskCreatorPlayground to ensure consistent field order and labels.
 *
 * @param idPrefix - Unique prefix for input IDs (e.g., "step-abc123")
 * @param action - Current action value
 * @param maxCount - Current max count value (as string from input)
 * @param unit - Current unit value
 * @param errors - Optional field-level error messages
 * @param onChange - Callback fired when any field changes
 */
export function CountingStepFields({
  idPrefix,
  action,
  maxCount,
  unit,
  errors,
  onChange,
}: CountingStepFieldsProps): React.ReactElement {
  return (
    <div className={styles.countingFields}>
      {/* Action */}
      <div className={styles.fieldGroup}>
        <label className={styles.label} htmlFor={`${idPrefix}-action`}>
          Action<span className={styles.required}>*</span>
        </label>
        <input
          id={`${idPrefix}-action`}
          type="text"
          className={`${styles.input} ${errors?.action ? styles.inputError : ''}`}
          value={action}
          onChange={(e) => onChange('action', e.target.value)}
          placeholder='e.g., "Read"'
          maxLength={ACTION_MAX_LENGTH}
        />
        {errors?.action && (
          <span className={styles.fieldError}>{errors.action}</span>
        )}
      </div>

      {/* Max Count */}
      <div className={styles.fieldGroup}>
        <label className={styles.label} htmlFor={`${idPrefix}-maxcount`}>
          Max Count<span className={styles.required}>*</span>
        </label>
        <input
          id={`${idPrefix}-maxcount`}
          type="number"
          className={`${styles.input} ${errors?.maxCount ? styles.inputError : ''}`}
          value={maxCount}
          onChange={(e) => onChange('maxCount', e.target.value)}
          placeholder="e.g., 100"
          min="1"
        />
        {errors?.maxCount && (
          <span className={styles.fieldError}>{errors.maxCount}</span>
        )}
      </div>

      {/* Unit */}
      <div className={styles.fieldGroup}>
        <label className={styles.label} htmlFor={`${idPrefix}-unit`}>
          Unit<span className={styles.required}>*</span>
        </label>
        <input
          id={`${idPrefix}-unit`}
          type="text"
          className={`${styles.input} ${errors?.unit ? styles.inputError : ''}`}
          value={unit}
          onChange={(e) => onChange('unit', e.target.value)}
          placeholder='e.g., "pages"'
          maxLength={UNIT_MAX_LENGTH}
        />
        {errors?.unit && (
          <span className={styles.fieldError}>{errors.unit}</span>
        )}
      </div>
    </div>
  );
}
