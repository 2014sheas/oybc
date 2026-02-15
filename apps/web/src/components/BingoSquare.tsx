import { useState, useCallback } from 'react';
import styles from './BingoSquare.module.css';

interface BingoSquareProps {
  /** Display text for the square */
  taskName?: string;
  /** Whether the square starts in a completed state */
  initialCompleted?: boolean;
  /** Size in pixels (width and height) */
  size?: number;
  /** Callback when the square is toggled (for controlled mode) */
  onToggle?: () => void;
  /** Whether the component is controlled externally */
  isControlled?: boolean;
  /** Controlled completed state (used when isControlled is true) */
  controlledCompleted?: boolean;
}

/**
 * BingoSquare Component
 *
 * A single bingo board square that toggles between incomplete and completed states.
 * Supports click, keyboard (Space/Enter), and full accessibility.
 * Can be used in uncontrolled mode (manages own state) or controlled mode
 * (parent manages state via onToggle and controlledCompleted).
 *
 * @param taskName - Text displayed in the square (default: "Task Name")
 * @param initialCompleted - Whether the square starts completed (default: false)
 * @param size - Width and height in pixels (default: 100)
 * @param onToggle - Callback when the square is toggled
 * @param isControlled - Whether the component is controlled externally
 * @param controlledCompleted - Controlled completed state
 */
export function BingoSquare({
  taskName = 'Task Name',
  initialCompleted = false,
  size = 100,
  onToggle,
  isControlled = false,
  controlledCompleted = false,
}: BingoSquareProps) {
  const [internalCompleted, setInternalCompleted] = useState(initialCompleted);

  const isCompleted = isControlled ? controlledCompleted : internalCompleted;

  const toggle = useCallback(() => {
    if (onToggle) {
      onToggle();
    }
    if (!isControlled) {
      setInternalCompleted((prev) => !prev);
    }
  }, [onToggle, isControlled]);

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === ' ' || e.key === 'Enter') {
        e.preventDefault();
        toggle();
      }
    },
    [toggle]
  );

  return (
    <div
      className={`${styles.square} ${isCompleted ? styles.completed : styles.incomplete}`}
      style={{ width: size, height: size }}
      role="button"
      tabIndex={0}
      aria-pressed={isCompleted}
      aria-label={`${taskName} - ${isCompleted ? 'completed' : 'incomplete'}`}
      onClick={toggle}
      onKeyDown={handleKeyDown}
    >
      <span className={styles.taskName}>{taskName}</span>
    </div>
  );
}
