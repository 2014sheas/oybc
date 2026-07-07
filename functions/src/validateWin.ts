import { onCall, HttpsError } from 'firebase-functions/v2/https';
import { detectBingos, BOARD_SIZES, type BoardSize } from '@oybc/bingo-core';

/**
 * PoC: server-authoritative win validation running the SAME detection code
 * the clients run (see docs/PLAY_TRANSITION.md T6). Play's spike replaces
 * this with the real session-scoped endpoint; the point here is proving the
 * bundling path, not the API shape.
 */
export const validateWin = onCall((request) => {
  const { completionGrid, gridSize } = request.data as {
    completionGrid: unknown;
    gridSize: unknown;
  };
  if (
    !Array.isArray(completionGrid) ||
    !completionGrid.every((c) => typeof c === 'boolean') ||
    !BOARD_SIZES.includes(gridSize as BoardSize)
  ) {
    throw new HttpsError('invalid-argument', 'completionGrid: boolean[], gridSize: 3|4|5');
  }
  const result = detectBingos(completionGrid, gridSize as BoardSize);
  return { isWin: result.isGreenlog, completedLines: result.completedLines };
});
