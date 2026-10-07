import { countKindNeedsUnit, type CountKind } from '@oybc/shared';
import { GoalEntry } from '../counters/GoalEntry';
import { KindPicker } from '../counters/KindPicker';
import { KindTag } from '../counters/KindTag';
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
  /** The kind the Goal is entered at (the effective kind when linked). */
  kind: CountKind;
  onKindChange: (kind: CountKind) => void;
  /** Auto-linked: the family's kind tag replaces the picker (D5). */
  linkedTag?: { counterName: string; lifetime: number };
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
  kind,
  onKindChange,
  linkedTag,
  onGoalChange,
  onUnitChange,
  goalError,
  unitError,
  stacked = false,
}: CountingSubConfigRowProps): React.ReactElement {
  return (
    <div className={styles.stack}>
      {linkedTag ? (
        <KindTag kind={kind} counterName={linkedTag.counterName} lifetime={linkedTag.lifetime} />
      ) : (
        <KindPicker value={kind} lock="none" onChange={onKindChange} size="compact" />
      )}
      <div className={stacked ? styles.stack : styles.row}>
        <div className={`${fieldStyles.fieldGroup} ${stacked ? '' : styles.goalGroup}`}>
          <label className={fieldStyles.label} htmlFor={`${idPrefix}-maxcount`}>
            Goal<span className={fieldStyles.required}>*</span>
          </label>
          <GoalEntry
            id={`${idPrefix}-maxcount`}
            kind={kind}
            value={goal}
            onChange={onGoalChange}
            aria-label="Goal"
            dense
            invalid={Boolean(goalError)}
            placeholder={kind === 'duration' ? '0h 0m' : '100'}
          />
          {goalError && <span className={fieldStyles.fieldError}>{goalError}</span>}
        </div>
        {countKindNeedsUnit(kind) && (
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
        )}
      </div>
    </div>
  );
}
