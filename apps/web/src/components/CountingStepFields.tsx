import { generateCounterTaskTitle } from '@oybc/shared';
import { CountingSubConfigRow } from './wizard/CountingSubConfigRow';
import styles from './CountingStepFields.module.css';

/** Maximum action length matching the shared validation schema */
const ACTION_MAX_LENGTH = 50;

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
 * CountingStepFields - Reusable counting step sub-fields (Verb → Goal → Counting)
 *
 * Renders the three required fields for a counting task step in the canonical
 * order, using the shared (verb, noun) vocabulary — R1 counters refresh
 * ("Refining counters" design handoff §Creation Surfaces). `action` still
 * carries the verb and `unit` still carries the counted noun; only the
 * labels/placeholders changed. Used inside the compound builder's
 * `SubtaskCard` inline counting fields. The Goal + Counting pair is the
 * shared `CountingSubConfigRow` (also the compound edit editor's new-sub
 * config row).
 *
 * @param idPrefix - Unique prefix for input IDs (e.g., "step-abc123")
 * @param action - Current verb value (stored as `action`)
 * @param maxCount - Current goal value (as string from input)
 * @param unit - Current counted-noun value (stored as `unit`)
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
  const trimmedAction = action.trim();
  const trimmedUnit = unit.trim();
  const parsedMaxCount = parseInt(maxCount, 10);
  const goalValid = Number.isInteger(parsedMaxCount) && parsedMaxCount > 0;
  const titlePreview =
    trimmedAction && trimmedUnit && goalValid
      ? generateCounterTaskTitle(trimmedAction, parsedMaxCount, trimmedUnit)
      : '';

  return (
    <div className={styles.countingFields}>
      {/* Verb */}
      <div className={styles.fieldGroup}>
        <label className={styles.label} htmlFor={`${idPrefix}-action`}>
          Verb<span className={styles.required}>*</span>
        </label>
        <input
          id={`${idPrefix}-action`}
          type="text"
          className={`${styles.input} ${errors?.action ? styles.inputError : ''}`}
          value={action}
          onChange={(e) => onChange('action', e.target.value)}
          placeholder="Do"
          maxLength={ACTION_MAX_LENGTH}
        />
        {errors?.action && (
          <span className={styles.fieldError}>{errors.action}</span>
        )}
      </div>

      {/* Goal (drives completion threshold; user input may exceed it
          intentionally — see feedback_counter_overshoot_is_valid) +
          Counting — the shared pair the compound edit editor also uses. */}
      <CountingSubConfigRow
        idPrefix={idPrefix}
        goal={maxCount}
        unit={unit}
        onGoalChange={(value) => onChange('maxCount', value)}
        onUnitChange={(value) => onChange('unit', value)}
        goalError={errors?.maxCount}
        unitError={errors?.unit}
        stacked
      />

      {titlePreview && (
        <div className={styles.titlePreview}>
          Title: <strong>{titlePreview}</strong>
        </div>
      )}
    </div>
  );
}
