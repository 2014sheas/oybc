import { useState, useCallback, useMemo } from 'react';
import { BingoSquare } from './BingoSquare';
import { detectBingos, formatBingoMessage, getHighlightedSquares, fisherYatesShuffle } from '@oybc/shared';
import type { BoardSize } from '@oybc/shared';
import styles from './BingoBoard.module.css';

/**
 * Generate hardcoded task names for the board.
 *
 * @param count - Number of task names to generate
 * @returns Array of task name strings ("Task 1" through "Task N")
 */
function generateTaskNames(count: number): string[] {
  return Array.from({ length: count }, (_, i) => `Task ${i + 1}`);
}

interface BingoBoardProps {
  /** Number of rows/columns in the grid (default: 5) */
  gridSize?: number;
  /** Size of each square in pixels (default: 80) */
  squareSize?: number;
}

/**
 * BingoBoard Component
 *
 * A bingo board grid using CSS Grid layout and BingoSquare components.
 * Supports 3x3, 4x4, and 5x5 grid sizes. All squares are toggleable.
 * For odd-sized grids, the center square has special styling with a
 * thicker border and star indicator.
 *
 * @param gridSize - Number of rows/columns (3, 4, or 5; default: 5)
 * @param squareSize - Width and height of each square in pixels (default: 80)
 */
export function BingoBoard({ gridSize = 5, squareSize = 80 }: BingoBoardProps) {
  const totalSquares = gridSize * gridSize;
  const centerIndex = gridSize % 2 === 1 ? Math.floor(totalSquares / 2) : -1;
  const [taskNames, setTaskNames] = useState<string[]>(() => generateTaskNames(totalSquares));
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
    setCompletedSquares(new Set(Array.from({ length: totalSquares }, (_, i) => i)));
  }, [totalSquares]);

  /**
   * Shuffle task names using Fisher-Yates algorithm and reset completion state.
   */
  const handleShuffle = useCallback(() => {
    setTaskNames((prev) => fisherYatesShuffle(prev));
    setCompletedSquares(new Set());
  }, []);

  const completedCount = completedSquares.size;

  /** Build the flat boolean completion grid from the Set of completed indices. */
  const completionGrid = useMemo(() => {
    return Array.from({ length: totalSquares }, (_, i) => completedSquares.has(i));
  }, [completedSquares, totalSquares]);

  /** Run bingo detection on every state change. */
  const bingoResult = useMemo(
    () => detectBingos(completionGrid, gridSize as BoardSize),
    [completionGrid, gridSize]
  );

  /** Format the display message (null if no bingos). */
  const bingoMessage = useMemo(
    () => formatBingoMessage(bingoResult),
    [bingoResult]
  );

  /** Set of square indices that should be highlighted (part of a completed line). */
  const highlightedSquares = useMemo(
    () => getHighlightedSquares(bingoResult.completedLines, gridSize as BoardSize),
    [bingoResult.completedLines, gridSize]
  );

  return (
    <div className={styles.boardContainer}>
      {/* Board grid */}
      <div
        className={styles.grid}
        style={{
          gridTemplateColumns: `repeat(${gridSize}, ${squareSize}px)`,
          gridTemplateRows: `repeat(${gridSize}, ${squareSize}px)`,
        }}
        role="grid"
        aria-label={`${gridSize} by ${gridSize} bingo board, ${completedCount} of ${totalSquares} completed`}
      >
        {taskNames.map((name, index) => {
          const isCenter = index === centerIndex;
          const isHighlighted = highlightedSquares.has(index);
          const row = Math.floor(index / gridSize);
          const col = index % gridSize;

          return (
            <div
              key={index}
              className={`${styles.cellWrapper} ${isCenter ? styles.centerCell : ''} ${isHighlighted ? styles.highlightedCell : ''}`}
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

      {/* Bingo detection message */}
      {bingoMessage && (
        <div
          className={`${styles.bingoMessage} ${bingoResult.isGreenlog ? styles.greenlog : ''}`}
          role="status"
          aria-live="polite"
        >
          {bingoMessage}
        </div>
      )}

      {/* Board info and controls */}
      <div className={styles.controls}>
        <span className={styles.progressText}>
          {completedCount} / {totalSquares} completed
        </span>
        <div className={styles.buttonGroup}>
          <button
            className={styles.shuffleButton}
            onClick={handleShuffle}
            aria-label="Shuffle board task names and reset completion"
          >
            Shuffle Board
          </button>
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
