import styles from './CountingSubConfigRow.module.css';
import fieldStyles from '../CountingStepFields.module.css';

/** Maximum unit length matching the shared validation schema. */
const UNIT_MAX_LENGTH = 50;

export interface CountingSubConfigRowProps {
  /** Prefix for the input ids (unique within the page). */
  idPrefix: string;
  /** The Goal field's text (the counting child's `maxCount`). */
  goal: string;
  /** The Counting field's text (the counted noun, stored as `unit`). */
  unit: string;
  onGoalChange: (value: string) => void;
  onUnitChange: (value: string) => void;
  /** Optional field-level errors (the create wizard's validation). */
  goalError?: string;
  unitError?: string;
  /** Stack the two fields vertically (the create wizard's `CountingStepFields`)
   *  instead of the default side-by-side row. */
  stacked?: boolean;
}

/**
 * CountingSubConfigRow — the Goal + Counting pair every new counting
 * sub-task is configured with: required-starred labels, a numeric Goal and
 * the counted noun. One component for the compound CREATE wizard
 * (`CountingStepFields`, stacked under its Verb field) and the compound
 * EDIT editor (`CompoundFields`, a row under the quick-add row whose text
 * is the action). iOS twin: `RisoCountingSubConfigRow`.
 */
export function CountingSubConfigRow({
  idPrefix,
  goal,
  unit,
  onGoalChange,
  onUnitChange,
  goalError,
  unitError,
  stacked = false,
}: CountingSubConfigRowProps): React.ReactElement {
  return (
    <div className={stacked ? styles.stack : styles.row}>
      <div className={`${fieldStyles.fieldGroup} ${stacked ? '' : styles.goalGroup}`}>
        <label className={fieldStyles.label} htmlFor={`${idPrefix}-maxcount`}>
          Goal<span className={fieldStyles.required}>*</span>
        </label>
        <input
          id={`${idPrefix}-maxcount`}
          type="number"
          className={`${fieldStyles.input} ${goalError ? fieldStyles.inputError : ''}`}
          value={goal}
          onChange={(e) => onGoalChange(e.target.value)}
          placeholder="100"
          min="1"
        />
        {goalError && <span className={fieldStyles.fieldError}>{goalError}</span>}
      </div>
      <div className={`${fieldStyles.fieldGroup} ${stacked ? '' : styles.unitGroup}`}>
        <label className={fieldStyles.label} htmlFor={`${idPrefix}-unit`}>
          Counting<span className={fieldStyles.required}>*</span>
        </label>
        <input
          id={`${idPrefix}-unit`}
          type="text"
          className={`${fieldStyles.input} ${unitError ? fieldStyles.inputError : ''}`}
          value={unit}
          onChange={(e) => onUnitChange(e.target.value)}
          placeholder="push-ups"
          maxLength={UNIT_MAX_LENGTH}
        />
        {unitError && <span className={fieldStyles.fieldError}>{unitError}</span>}
      </div>
    </div>
  );
}
