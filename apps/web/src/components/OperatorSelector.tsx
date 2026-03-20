import { OperatorType } from '@oybc/shared';
import styles from './OperatorSelector.module.css';

interface OperatorSelectorProps {
  /** Currently selected operator */
  selectedOperator: OperatorType;
  /** Callback when an operator button is clicked */
  onOperatorChange: (operator: OperatorType) => void;
}

/**
 * OperatorSelector — Three-button group for selecting a composite operator.
 *
 * Provides mutually exclusive selection between AND ("All of"),
 * OR ("Any of"), and M_OF_N ("At least N of") composite operators.
 *
 * @param selectedOperator - Currently selected OperatorType
 * @param onOperatorChange - Called with the new OperatorType on click
 */
export function OperatorSelector({ selectedOperator, onOperatorChange }: OperatorSelectorProps): React.ReactElement {
  return (
    <div className={styles.operatorPicker}>
      <button
        type="button"
        className={`${styles.operatorButton} ${selectedOperator === OperatorType.AND ? styles.operatorButtonActive : ''}`}
        onClick={() => onOperatorChange(OperatorType.AND)}
      >
        All of
      </button>
      <button
        type="button"
        className={`${styles.operatorButton} ${selectedOperator === OperatorType.OR ? styles.operatorButtonActive : ''}`}
        onClick={() => onOperatorChange(OperatorType.OR)}
      >
        Any of
      </button>
      <button
        type="button"
        className={`${styles.operatorButton} ${selectedOperator === OperatorType.M_OF_N ? styles.operatorButtonActive : ''}`}
        onClick={() => onOperatorChange(OperatorType.M_OF_N)}
      >
        At least N of
      </button>
    </div>
  );
}
