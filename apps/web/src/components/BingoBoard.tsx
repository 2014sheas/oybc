import { useState, useCallback } from 'react';
import { BingoSquare } from './BingoSquare';
import styles from './BingoBoard.module.css';

/** Number of rows/columns in the grid */
const GRID_SIZE = 5;

/** Total number of squares */
const TOTAL_SQUARES = GRID_SIZE * GRID_SIZE;

/** Index of the center square (0-based) */
const CENTER_INDEX = Math.floor(TOTAL_SQUARES / 2);

/**
 * Generate hardcoded task names for the board.
 *
 * @returns Array of 25 task name strings ("Task 1" through "Task 25")
 */
function generateTaskNames(): string[] {
  return Array.from({ length: TOTAL_SQUARES }, (_, i) => `Task ${i + 1}`);
}

interface BingoBoardProps {
  /** Size of each square in pixels (default: 80) */
  squareSize?: number;
}

/**
 * BingoBoard Component
 *
 * A 5x5 bingo board grid using CSS Grid layout and BingoSquare components.
 * All squares are toggleable. The center square (Task 13) has special styling
 * with a thicker border and star indicator.
 *
 * @param squareSize - Width and height of each square in pixels (default: 80)
 */
export function BingoBoard({ squareSize = 80 }: BingoBoardProps) {
  const taskNames = generateTaskNames();
  const [completedSquares, setCompletedSquares] = useState<Set<number>>(new Set());

  /**
   * Toggle a square's completed state by index.
   *
   * @param index - The 0-based index of the square to toggle
   */
  const handleToggle = useCallback((index: number) => {
    setCompletedSquares((prev) => {
      const next = new Set(prev);
      if (next.has(index)) {
        next.delete(index);
      } else {
        next.add(index);
      }
      return next;
    });
  }, []);

  /**
   * Reset all squares to incomplete state.
   */
  const handleReset = useCallback(() => {
    setCompletedSquares(new Set());
  }, []);

  /**
   * Set all squares to completed state (for testing).
   */
  const handleFillAll = useCallback(() => {
    setCompletedSquares(new Set(Array.from({ length: TOTAL_SQUARES }, (_, i) => i)));
  }, []);

  const completedCount = completedSquares.size;

  return (
    <div className={styles.boardContainer}>
      {/* Board grid */}
      <div
        className={styles.grid}
        style={{
          gridTemplateColumns: `repeat(${GRID_SIZE}, ${squareSize}px)`,
          gridTemplateRows: `repeat(${GRID_SIZE}, ${squareSize}px)`,
        }}
        role="grid"
        aria-label={`5 by 5 bingo board, ${completedCount} of ${TOTAL_SQUARES} completed`}
      >
        {taskNames.map((name, index) => {
          const isCenter = index === CENTER_INDEX;
          const row = Math.floor(index / GRID_SIZE);
          const col = index % GRID_SIZE;

          return (
            <div
              key={index}
              className={`${styles.cellWrapper} ${isCenter ? styles.centerCell : ''}`}
              role="gridcell"
              aria-rowindex={row + 1}
              aria-colindex={col + 1}
            >
              <BingoSquare
                taskName={isCenter ? `${name} *` : name}
                initialCompleted={completedSquares.has(index)}
                size={squareSize}
                onToggle={() => handleToggle(index)}
                isControlled
                controlledCompleted={completedSquares.has(index)}
              />
            </div>
          );
        })}
      </div>

      {/* Board info and controls */}
      <div className={styles.controls}>
        <span className={styles.progressText}>
          {completedCount} / {TOTAL_SQUARES} completed
        </span>
        <div className={styles.buttonGroup}>
          <button
            className={styles.resetButton}
            onClick={handleReset}
            aria-label="Reset all squares to incomplete"
          >
            Reset Board
          </button>
          <button
            className={styles.fillButton}
            onClick={handleFillAll}
            aria-label="Fill all squares as completed"
          >
            Fill All
          </button>
        </div>
      </div>
    </div>
  );
}
