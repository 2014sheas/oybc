import { useRef, useCallback } from 'react';
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
 * option may be selected at a time. Implements the ARIA radio keyboard pattern:
 * - Only the selected button is in the tab order (roving tabIndex).
 * - Arrow keys (Left/Up and Right/Down) move focus and selection between options.
 * - Home/End jump to the first/last option.
 *
 * @param types - Type option definitions
 * @param selectedType - Currently selected type value
 * @param onTypeChange - Called with the new type value on click
 * @param label - Accessible label announced for the radio group
 */
export function TaskTypeSelector({ types, selectedType, onTypeChange, label = 'Task type' }: TaskTypeSelectorProps): React.ReactElement {
  const buttonRefs = useRef<(HTMLButtonElement | null)[]>([]);

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLButtonElement>, index: number) => {
      let nextIndex: number | null = null;

      if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
        nextIndex = (index + 1) % types.length;
      } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
        nextIndex = (index - 1 + types.length) % types.length;
      } else if (e.key === 'Home') {
        nextIndex = 0;
      } else if (e.key === 'End') {
        nextIndex = types.length - 1;
      }

      if (nextIndex !== null) {
        e.preventDefault();
        onTypeChange(types[nextIndex].value);
        buttonRefs.current[nextIndex]?.focus();
      }
    },
    [types, onTypeChange],
  );

  return (
    <div role="radiogroup" aria-label={label} className={styles.typeSelector}>
      {types.map((t, index) => {
        const isSelected = selectedType === t.value;
        return (
          <button
            key={t.value}
            ref={(el) => { buttonRefs.current[index] = el; }}
            type="button"
            role="radio"
            aria-checked={isSelected}
            tabIndex={isSelected ? 0 : -1}
            className={`${styles.typeButton} ${isSelected ? styles.typeButtonActive : ''}`}
            onClick={() => onTypeChange(t.value)}
            onKeyDown={(e) => handleKeyDown(e, index)}
          >
            {t.label}
          </button>
        );
      })}
    </div>
  );
}
