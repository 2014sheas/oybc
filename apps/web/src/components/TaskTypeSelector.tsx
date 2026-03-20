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
  /** Accessible label for the radio group (e.g. "Task type") */
  label?: string;
}

/**
 * TaskTypeSelector — Mutually exclusive button group for selecting a task type.
 *
 * Used in the unified task creator to switch between Normal, Counting,
 * Progress, and Composite task creation forms.
 *
 * Renders as a `radiogroup` so assistive technologies understand only one
 * option may be selected at a time.
 *
 * @param types - Type option definitions
 * @param selectedType - Currently selected type value
 * @param onTypeChange - Called with the new type value on click
 * @param label - Accessible label announced for the radio group
 */
export function TaskTypeSelector({ types, selectedType, onTypeChange, label = 'Task type' }: TaskTypeSelectorProps): React.ReactElement {
  return (
    <div role="radiogroup" aria-label={label} className={styles.typeSelector}>
      {types.map((t) => (
        <button
          key={t.value}
          type="button"
          role="radio"
          aria-checked={selectedType === t.value}
          className={`${styles.typeButton} ${selectedType === t.value ? styles.typeButtonActive : ''}`}
          onClick={() => onTypeChange(t.value)}
        >
          {t.label}
        </button>
      ))}
    </div>
  );
}
