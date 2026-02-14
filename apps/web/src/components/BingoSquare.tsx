import { useState, useCallback } from 'react';
import styles from './BingoSquare.module.css';

interface BingoSquareProps {
  /** Display text for the square */
  taskName?: string;
  /** Whether the square starts in a completed state */
  initialCompleted?: boolean;
  /** Size in pixels (width and height) */
  size?: number;
}

/**
 * BingoSquare Component
 *
 * A single bingo board square that toggles between incomplete and completed states.
 * Supports click, keyboard (Space/Enter), and full accessibility.
 *
 * @param taskName - Text displayed in the square (default: "Task Name")
 * @param initialCompleted - Whether the square starts completed (default: false)
 * @param size - Width and height in pixels (default: 100)
 */
export function BingoSquare({
  taskName = 'Task Name',
  initialCompleted = false,
  size = 100,
}: BingoSquareProps) {
  const [isCompleted, setIsCompleted] = useState(initialCompleted);

  const toggle = useCallback(() => {
    setIsCompleted((prev) => !prev);
  }, []);

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
