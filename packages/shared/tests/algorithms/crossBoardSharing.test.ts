import { detectBingos } from '@oybc/bingo-core';

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
});
