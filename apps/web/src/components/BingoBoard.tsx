import { useState, useCallback, useMemo } from 'react';
import { BingoSquare } from './BingoSquare';
import {
  detectBingos,
  formatBingoMessage,
  getHighlightedSquares,
  fisherYatesShuffle,
  getCenterSquareIndex,
  isCenterAutoCompleted,
  getCenterDisplayText,
  CenterSquareType,
} from '@oybc/shared';
import type { BoardSize } from '@oybc/shared';
import styles from './BingoBoard.module.css';

interface BingoBoardProps {
  /** Task names to display on the board squares */
  taskNames: string[];
  /** Number of rows/columns in the grid (default: 5) */
  gridSize?: number;
  /** Size of each square in pixels (default: 80) */
  squareSize?: number;
  /** Center square type (default: none) */
  centerSquareType?: CenterSquareType;
  /** Custom name for CUSTOM_FREE center square type */
  centerSquareCustomName?: string;
}

/**
 * BingoBoard Component
 *
 * A bingo board grid using CSS Grid layout and BingoSquare components.
 * Supports 3x3, 4x4, and 5x5 grid sizes. All squares are toggleable.
 * For odd-sized grids, the center square has special styling with a
 * thicker border and star indicator.
 *
 * Center square types:
 * - FREE: Auto-completed, shows "FREE SPACE", locked (cannot toggle off)
 * - CUSTOM_FREE: Auto-completed with custom text, locked
 * - CHOSEN: Fixed task name, NOT auto-completed, toggleable like any square
 * - NONE: Center is an ordinary square, no special treatment
 *
 * @param gridSize - Number of rows/columns (3, 4, or 5; default: 5)
 * @param squareSize - Width and height of each square in pixels (default: 80)
 * @param centerSquareType - Center square behavior type (default: NONE)
 * @param centerSquareCustomName - Custom name for CUSTOM_FREE type
 */
export function BingoBoard({
  taskNames,
  gridSize = 5,
  squareSize = 80,
  centerSquareType = CenterSquareType.NONE,
  centerSquareCustomName,
}: BingoBoardProps) {
  const totalSquares = gridSize * gridSize;
  const centerIndex = getCenterSquareIndex(gridSize);
  const autoCompleted = isCenterAutoCompleted(centerSquareType);
  const centerDisplayText = getCenterDisplayText(centerSquareType, centerSquareCustomName);

  const [taskLabels, setTaskLabels] = useState<string[]>(taskNames);
  const [completedSquares, setCompletedSquares] = useState<Set<number>>(() => {
    if (centerIndex >= 0 && autoCompleted) {
      return new Set([centerIndex]);
    }
    return new Set();
  });

  /**
   * Toggle a square's completed state by index.
   * Prevents toggling auto-completed center squares (FREE, CUSTOM_FREE).
   *
   * @param index - The 0-based index of the square to toggle
   */
  const handleToggle = useCallback((index: number) => {
    if (index === centerIndex && autoCompleted) {
      return;
    }
    setCompletedSquares((prev) => {
      const next = new Set(prev);
      if (next.has(index)) {
        next.delete(index);
      } else {
        next.add(index);
      }
      return next;
    });
  }, [centerIndex, autoCompleted]);

  /**
   * Reset all squares to incomplete state.
   * Preserves auto-completed center square if applicable.
   */
  const handleReset = useCallback(() => {
    if (centerIndex >= 0 && autoCompleted) {
      setCompletedSquares(new Set([centerIndex]));
    } else {
      setCompletedSquares(new Set());
    }
  }, [centerIndex, autoCompleted]);

  /**
   * Set all squares to completed state (for testing).
   */
  const handleFillAll = useCallback(() => {
    setCompletedSquares(new Set(Array.from({ length: totalSquares }, (_, i) => i)));
  }, [totalSquares]);

  /**
   * Shuffle task names using Fisher-Yates algorithm and reset completion state.
   * For any special center type (FREE, CUSTOM_FREE, CHOSEN), keeps the center
   * position fixed and only shuffles the other squares.
   * For NONE, shuffles all squares freely.
   */
  const handleShuffle = useCallback(() => {
    if (centerIndex >= 0 && centerSquareType !== CenterSquareType.NONE) {
      setTaskLabels((prev) => {
        const centerTask = prev[centerIndex];
        const otherTasks = prev.filter((_, i) => i !== centerIndex);
        const shuffled = fisherYatesShuffle(otherTasks);
        const newTasks = [...shuffled];
        newTasks.splice(centerIndex, 0, centerTask);
        return newTasks;
      });
    } else {
      setTaskLabels((prev) => fisherYatesShuffle(prev));
    }
    if (centerIndex >= 0 && autoCompleted) {
      setCompletedSquares(new Set([centerIndex]));
    } else {
      setCompletedSquares(new Set());
    }
  }, [centerIndex, autoCompleted, centerSquareType]);

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
        {taskLabels.map((name, index) => {
          const isCenter = index === centerIndex;
          const isHighlighted = highlightedSquares.has(index);
          const row = Math.floor(index / gridSize);
          const col = index % gridSize;

          let displayName = name;
          if (isCenter && centerDisplayText) {
            displayName = centerDisplayText;
          } else if (isCenter && centerSquareType === CenterSquareType.NONE) {
            displayName = name;
          } else if (isCenter) {
            displayName = `${name} *`;
          }

          return (
            <div
              key={index}
              className={`${styles.cellWrapper} ${isCenter && centerSquareType !== CenterSquareType.NONE ? styles.centerCell : ''} ${isHighlighted ? styles.highlightedCell : ''}`}
              role="gridcell"
              aria-rowindex={row + 1}
              aria-colindex={col + 1}
            >
              <BingoSquare
                taskName={displayName}
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
