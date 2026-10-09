import type { TaskType } from '@oybc/shared';
import { TypeBadge } from '../TypeBadge';
import { RisoSegmented } from '../riso';
import { TYPE_OPTIONS, typeLabel, type TypeControlMode } from './taskTypeRules';
import styles from './TaskTypeControl.module.css';

export interface TaskTypeControlProps {
  /** From `typeControlMode`; `'none'` renders nothing. */
  mode: TypeControlMode;
  /** The selected type (the switch's value). */
  selected: TaskType;
  /** The task's own type (shown when fixed). */
  storedType: TaskType;
  /** Called with the newly picked type. */
  onChange: (next: TaskType) => void;
}

/**
 * The "Type" row every task-row editor shows: the Simple / Counting /
 * Compound segmented switch, or the task's type fixed as a badge. Shared by
 * `BoardEditTaskSheet` and `TaskEditSheet` so both offer the same control.
 *
 * @param props - See {@link TaskTypeControlProps}.
 */
export function TaskTypeControl({ mode, selected, storedType, onChange }: TaskTypeControlProps): React.ReactElement | null {
  if (mode === 'none') return null;
  return (
    <div className={styles.typeRow}>
      <span className={styles.typeLabel}>Type</span>
      {mode === 'switch' ? (
        <div className={styles.typeSwitch}>
          <RisoSegmented
            aria-label="Task type"
            size="compact"
            fullWidth
            options={TYPE_OPTIONS}
            value={selected}
            onChange={onChange}
          />
        </div>
      ) : (
        <div className={styles.typeBadgeWrap}>
          <TypeBadge type={storedType} size="small" />
          <span className={styles.typeReadOnly}>{typeLabel(storedType)}</span>
        </div>
      )}
    </div>
  );
}
