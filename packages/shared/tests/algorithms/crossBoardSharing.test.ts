import {
  calculateCountingRollup,
} from '../../src/algorithms/rollup';
import { detectBingos } from '@oybc/bingo-core';

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Simulates a multi-board scenario by applying a rollup to each board's
 * parent state independently, returning updated states.
 */
function applyCountingRollupToBoards(
  boardStates: { currentCount: number }[],
  parentMaxCount: number,
  subtaskMaxCount: number
) {
  return boardStates.map((state) => {
    const result = calculateCountingRollup(
      state.currentCount,
      parentMaxCount,
      subtaskMaxCount
    );
    return { currentCount: result.newCount, isCompleted: result.isCompleted };
  });
}

// ─── Tests ────────────────────────────────────────────────────────────────────

describe('Cross-Board Task Sharing', () => {
  // ── 1. Same Task on Multiple Boards ──────────────────────────────────────

  describe('same task on multiple boards', () => {
    it('bingo detection runs independently per board with shared task', () => {
      // Board A: T1 completed, T2 completed, T3 completed → row_0 bingo
      const gridA: boolean[] = [
        true, true, true,
        false, true, false, // center (FREE) auto-completed
        false, false, false,
      ];

      // Board B: T1 completed, T4 NOT completed, T5 NOT completed → no row_0
      const gridB: boolean[] = [
        true, false, false,
        false, true, false,
        false, false, false,
      ];

      const resultA = detectBingos(gridA, 3);
      const resultB = detectBingos(gridB, 3);

      expect(resultA.completedLines).toContain('row_0');
      expect(resultB.completedLines).not.toContain('row_0');
    });

    it('completing a task on one board does not affect another board\'s grid', () => {
      // Simulate: T1 is on both boards
      // Board A marks T1 complete, Board B does not
      const gridA: boolean[] = [
        true, false, false,
        false, true, false,
        false, false, false,
      ];

      const gridB: boolean[] = [
        false, false, false, // T1 NOT completed on this board
        false, true, false,
        false, false, false,
      ];

      const resultA = detectBingos(gridA, 3);
      const resultB = detectBingos(gridB, 3);

      expect(resultA.totalCompleted).toBe(2); // T1 + FREE center
      expect(resultB.totalCompleted).toBe(1); // Only FREE center
    });

    it('each board can have different bingos despite shared tasks', () => {
      // Board A: column 0 complete (shared T1 at [0,0] + others at [1,0], [2,0])
      const gridA: boolean[] = [
        true, false, false,
        true, true, false,
        true, false, false,
      ];

      // Board B: row 0 complete (shared T1 at [0,0] + others at [0,1], [0,2])
      const gridB: boolean[] = [
        true, true, true,
        false, true, false,
        false, false, false,
      ];

      const resultA = detectBingos(gridA, 3);
      const resultB = detectBingos(gridB, 3);

      expect(resultA.completedLines).toContain('col_0');
      expect(resultA.completedLines).not.toContain('row_0');

      expect(resultB.completedLines).toContain('row_0');
      expect(resultB.completedLines).not.toContain('col_0');
    });
  });

  // ── 2. Counting Subtask Cross-Board Rollup ───────────────────────────────

  describe('counting subtask cross-board rollup', () => {
    it('rolls up single increment to parent on multiple boards', () => {
      // Parent "Read 100 pages" on Board A (count=0) and Board C (count=10)
      // Subtask increments +1
      const results = applyCountingRollupToBoards(
        [{ currentCount: 0 }, { currentCount: 10 }],
        100,
        1
      );

      expect(results[0]).toEqual({ currentCount: 1, isCompleted: false });
      expect(results[1]).toEqual({ currentCount: 11, isCompleted: false });
    });

    it('rolls up subtask maxCount when subtask completes', () => {
      // Subtask "Read 25 pages" completes → add 25 to each parent board
      const results = applyCountingRollupToBoards(
        [{ currentCount: 0 }, { currentCount: 10 }],
        100,
        25
      );

      expect(results[0]).toEqual({ currentCount: 25, isCompleted: false });
      expect(results[1]).toEqual({ currentCount: 35, isCompleted: false });
    });

    it('handles multiple subtasks completing sequentially', () => {
      // First subtask: +25
      const after25 = calculateCountingRollup(0, 100, 25);
      expect(after25).toEqual({ newCount: 25, isCompleted: false });

      // Second subtask: +30
      const after30 = calculateCountingRollup(after25.newCount, 100, 30);
      expect(after30).toEqual({ newCount: 55, isCompleted: false });
    });

    it('caps at maxCount and marks completed', () => {
      // Parent at 80/100, subtask adds 25 → capped at 100
      const result = calculateCountingRollup(80, 100, 25);
      expect(result).toEqual({ newCount: 100, isCompleted: true });
    });

    it('does not overflow when parent already complete', () => {
      // Parent at 100/100, subtask adds 25
      const result = calculateCountingRollup(100, 100, 25);
      expect(result).toEqual({ newCount: 100, isCompleted: true });
    });

    it('handles subtask with maxCount larger than remaining', () => {
      // Parent at 90/100, subtask adds 50
      const result = calculateCountingRollup(90, 100, 50);
      expect(result).toEqual({ newCount: 100, isCompleted: true });
    });

    it('each board gets independent rollup result', () => {
      // Board A: 80/100 → completes
      // Board C: 10/100 → does not complete
      const resultA = calculateCountingRollup(80, 100, 25);
      const resultC = calculateCountingRollup(10, 100, 25);

      expect(resultA.isCompleted).toBe(true);
      expect(resultC.isCompleted).toBe(false);
    });
  });

  // ── 5. Edge Cases ────────────────────────────────────────────────────────

  describe('cross-board edge cases', () => {
    it('counting rollup with maxCount=0 handles gracefully', () => {
      const result = calculateCountingRollup(0, 0, 5);
      // 0 + 5 = 5, but capped at max 0 → 0, isCompleted: true (0 >= 0)
      expect(result.newCount).toBe(0);
      expect(result.isCompleted).toBe(true);
    });

    it('counting rollup with subtaskMaxCount=0 is a no-op', () => {
      const result = calculateCountingRollup(50, 100, 0);
      expect(result).toEqual({ newCount: 50, isCompleted: false });
    });

    it('rollup-triggered completion creates bingo on receiving board', () => {
      // Board A: parent task at [2,2], row_2 almost complete
      // Before rollup: parent incomplete → no row_2 bingo
      const gridBefore: boolean[] = [
        true, false, false,
        false, true, false,
        true, true, false, // [2,2] = parent, incomplete
      ];

      // After rollup: parent completes at [2,2] → row_2 bingo + diag_main ([0,0],[1,1],[2,2])
      const gridAfter: boolean[] = [
        true, false, false,
        false, true, false,
        true, true, true, // [2,2] now complete
      ];

      const before = detectBingos(gridBefore, 3);
      const after = detectBingos(gridAfter, 3);

      expect(before.completedLines).not.toContain('row_2');
      expect(after.completedLines).toContain('row_2');
      expect(after.completedLines).toContain('diag_main'); // [0,0]=T [1,1]=T [2,2]=T
    });

    it('counting rollup with negative parentCurrentCount handled', () => {
      // Defensive: shouldn't happen, but function should not crash
      const result = calculateCountingRollup(-5, 100, 10);
      expect(result.newCount).toBe(5); // -5 + 10 = 5
      expect(result.isCompleted).toBe(false);
    });
  });
});
