import styles from './TaskTypeSelector.module.css';

interface TypeOption {
  value: string;
  label: string;
}

interface TaskTypeSelectorProps {
  /** Available type options */
  types: TypeOption[];
  /** Currently selected type value */
  selectedType: string;
  /** Callback when a type button is clicked */
  onTypeChange: (value: string) => void;
}

/**
 * TaskTypeSelector — Mutually exclusive button group for selecting a task type.
 *
 * Used in the unified task creator to switch between Normal, Counting,
 * Progress, and Composite task creation forms.
 *
 * @param types - Type option definitions
 * @param selectedType - Currently selected type value
 * @param onTypeChange - Called with the new type value on click
 */
export function TaskTypeSelector({ types, selectedType, onTypeChange }: TaskTypeSelectorProps): React.ReactElement {
  return (
    <div className={styles.typeSelector}>
      {types.map((t) => (
        <button
          key={t.value}
          type="button"
          className={`${styles.typeButton} ${selectedType === t.value ? styles.typeButtonActive : ''}`}
          onClick={() => onTypeChange(t.value)}
        >
          {t.label}
        </button>
      ))}
    </div>
  );
}
