import { BoardSize } from './constants';

/**
 * Result of bingo detection on a board.
 *
 * @property completedLines - Array of line IDs that are complete (e.g., 'row_0', 'col_2', 'diag_main')
 * @property isGreenlog - True when ALL squares on the board are completed
 * @property totalCompleted - Number of completed squares
 * @property totalSquares - Total squares on the board (gridSize * gridSize)
 */
export interface BingoDetectionResult {
  completedLines: string[];
  isGreenlog: boolean;
  totalCompleted: number;
  totalSquares: number;
}

/**
 * Detect all completed bingo lines on a board.
 *
 * Checks all rows, columns, and diagonals for completion.
 * Returns all simultaneously completed lines and whether the
 * entire board is complete (GREENLOG).
 *
 * The completion grid is a flat boolean array of length gridSize * gridSize,
 * indexed row-major: index = row * gridSize + col.
 *
 * Line ID format:
 * - Rows: 'row_0', 'row_1', ... 'row_{n-1}'
 * - Columns: 'col_0', 'col_1', ... 'col_{n-1}'
 * - Main diagonal (top-left to bottom-right): 'diag_main'
 * - Anti diagonal (top-right to bottom-left): 'diag_anti'
 *
 * @param completionGrid - Flat boolean array of completed states (row-major order)
 * @param gridSize - Board size (3, 4, or 5)
 * @returns BingoDetectionResult with all detected lines and greenlog status
 * @throws Error if completionGrid length does not match gridSize * gridSize
 */
export function detectBingos(
  completionGrid: boolean[],
  gridSize: BoardSize
): BingoDetectionResult {
  const totalSquares = gridSize * gridSize;

  if (completionGrid.length !== totalSquares) {
    throw new Error(
      `completionGrid length (${completionGrid.length}) does not match gridSize * gridSize (${totalSquares})`
    );
  }

  const completedLines: string[] = [];
  let totalCompleted = 0;

  // Count total completed squares
  for (let i = 0; i < totalSquares; i++) {
    if (completionGrid[i]) {
      totalCompleted++;
    }
  }

  // Check rows
  for (let row = 0; row < gridSize; row++) {
    let rowComplete = true;
    for (let col = 0; col < gridSize; col++) {
      if (!completionGrid[row * gridSize + col]) {
        rowComplete = false;
        break;
      }
    }
    if (rowComplete) {
      completedLines.push(`row_${row}`);
    }
  }

  // Check columns
  for (let col = 0; col < gridSize; col++) {
    let colComplete = true;
    for (let row = 0; row < gridSize; row++) {
      if (!completionGrid[row * gridSize + col]) {
        colComplete = false;
        break;
      }
    }
    if (colComplete) {
      completedLines.push(`col_${col}`);
    }
  }

  // Check main diagonal (top-left to bottom-right)
  let mainDiagComplete = true;
  for (let i = 0; i < gridSize; i++) {
    if (!completionGrid[i * gridSize + i]) {
      mainDiagComplete = false;
      break;
    }
  }
  if (mainDiagComplete) {
    completedLines.push('diag_main');
  }

  // Check anti diagonal (top-right to bottom-left)
  let antiDiagComplete = true;
  for (let i = 0; i < gridSize; i++) {
    if (!completionGrid[i * gridSize + (gridSize - 1 - i)]) {
      antiDiagComplete = false;
      break;
    }
  }
  if (antiDiagComplete) {
    completedLines.push('diag_anti');
  }

  const isGreenlog = totalCompleted === totalSquares;

  return {
    completedLines,
    isGreenlog,
    totalCompleted,
    totalSquares,
  };
}

/**
 * Total number of bingo lines on a `gridSize` board: every row, every column
 * and the two diagonals (`2 * gridSize + 2`). The denominator of the "LINE
 * COMPLETE - n OF {total}" kicker. Mirrors `BingoDetection.totalLineCount`
 * in `apps/ios/OYBC/Helpers/BingoDetection.swift`.
 *
 * @param gridSize - Board size (3, 4, or 5)
 * @returns The number of distinct line ids `detectBingos` can emit.
 */
export function totalLineCount(gridSize: BoardSize): number {
  return 2 * gridSize + 2;
}

/**
 * Format a bingo detection result into a display message.
 *
 * Returns a human-readable string describing the bingo state:
 * - "Greenlog!" when all squares are complete
 * - "Bingo! (row_0, col_2)" when one or more lines are complete
 * - null when no lines are complete
 *
 * @param result - BingoDetectionResult from detectBingos
 * @returns Display message string, or null if no bingos detected
 */
export function formatBingoMessage(
  result: BingoDetectionResult
): string | null {
  if (result.isGreenlog) {
    return 'Greenlog!';
  }

  if (result.completedLines.length === 0) {
    return null;
  }

  return `Bingo! (${result.completedLines.join(', ')})`;
}

/**
 * Strict-parse the numeric suffix of a `row_N` / `col_N` line id.
 *
 * `parseInt` prefix-parses (`"2x"` → 2), which would highlight a line for a
 * malformed id, and an out-of-range index (`col_7` on a 5×5) would silently
 * alias into wrong cells via `row * gridSize + col`. Both are rejected here —
 * the id must be all digits and resolve to `0 <= n < gridSize`. The Swift
 * mirror (`BingoDetection.swift`) applies the identical rule so malformed /
 * out-of-range ids are skipped byte-identically on both platforms.
 *
 * @param raw - The characters after the `row_` / `col_` prefix.
 * @param gridSize - Board size (3, 4, or 5).
 * @returns The parsed index, or `null` when malformed or out of range.
 */
function parseLineIndex(raw: string, gridSize: BoardSize): number | null {
  if (raw.length === 0 || !/^[0-9]+$/.test(raw)) return null;
  const n = Number(raw);
  return n < gridSize ? n : null;
}

/**
 * Get the set of square indices that belong to completed bingo lines.
 *
 * Used for visual highlighting of squares that are part of a winning line.
 *
 * @param completedLines - Array of line IDs (e.g., ['row_0', 'diag_main'])
 * @param gridSize - Board size (3, 4, or 5)
 * @returns Set of 0-based square indices that are part of completed lines
 */
export function getHighlightedSquares(
  completedLines: string[],
  gridSize: BoardSize
): Set<number> {
  const highlighted = new Set<number>();

  for (const lineId of completedLines) {
    if (lineId.startsWith('row_')) {
      const row = parseLineIndex(lineId.substring(4), gridSize);
      if (row === null) continue;
      for (let col = 0; col < gridSize; col++) {
        highlighted.add(row * gridSize + col);
      }
    } else if (lineId.startsWith('col_')) {
      const col = parseLineIndex(lineId.substring(4), gridSize);
      if (col === null) continue;
      for (let row = 0; row < gridSize; row++) {
        highlighted.add(row * gridSize + col);
      }
    } else if (lineId === 'diag_main') {
      for (let i = 0; i < gridSize; i++) {
        highlighted.add(i * gridSize + i);
      }
    } else if (lineId === 'diag_anti') {
      for (let i = 0; i < gridSize; i++) {
        highlighted.add(i * gridSize + (gridSize - 1 - i));
      }
    }
  }

  return highlighted;
}
