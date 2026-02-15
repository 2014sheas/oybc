import {
  detectBingos,
  formatBingoMessage,
  getHighlightedSquares,
  BingoDetectionResult,
} from '../../src/algorithms/bingoDetection';

describe('detectBingos', () => {
  // ── 5x5 Board Tests ──────────────────────────────────────────────────

  describe('5x5 board', () => {
    const size = 5;
    const total = 25;

    /**
     * Helper: create a 5x5 grid with specific indices completed.
     */
    function makeGrid(completedIndices: number[]): boolean[] {
      const grid = new Array(total).fill(false);
      for (const i of completedIndices) {
        grid[i] = true;
      }
      return grid;
    }

    it('returns no bingos for an empty board', () => {
      const result = detectBingos(new Array(total).fill(false), size);
      expect(result.completedLines).toEqual([]);
      expect(result.isGreenlog).toBe(false);
      expect(result.totalCompleted).toBe(0);
      expect(result.totalSquares).toBe(25);
    });

    it('detects a completed first row', () => {
      const result = detectBingos(makeGrid([0, 1, 2, 3, 4]), size);
      expect(result.completedLines).toEqual(['row_0']);
      expect(result.isGreenlog).toBe(false);
      expect(result.totalCompleted).toBe(5);
    });

    it('detects a completed last row', () => {
      const result = detectBingos(makeGrid([20, 21, 22, 23, 24]), size);
      expect(result.completedLines).toEqual(['row_4']);
    });

    it('detects a completed middle row', () => {
      const result = detectBingos(makeGrid([10, 11, 12, 13, 14]), size);
      expect(result.completedLines).toEqual(['row_2']);
    });

    it('detects a completed first column', () => {
      const result = detectBingos(makeGrid([0, 5, 10, 15, 20]), size);
      expect(result.completedLines).toEqual(['col_0']);
    });

    it('detects a completed last column', () => {
      const result = detectBingos(makeGrid([4, 9, 14, 19, 24]), size);
      expect(result.completedLines).toEqual(['col_4']);
    });

    it('detects the main diagonal', () => {
      // Indices: 0, 6, 12, 18, 24
      const result = detectBingos(makeGrid([0, 6, 12, 18, 24]), size);
      expect(result.completedLines).toEqual(['diag_main']);
    });

    it('detects the anti diagonal', () => {
      // Indices: 4, 8, 12, 16, 20
      const result = detectBingos(makeGrid([4, 8, 12, 16, 20]), size);
      expect(result.completedLines).toEqual(['diag_anti']);
    });

    it('detects multiple simultaneous bingos', () => {
      // Row 0 (0-4) + col 0 (0,5,10,15,20) = shares index 0
      const result = detectBingos(
        makeGrid([0, 1, 2, 3, 4, 5, 10, 15, 20]),
        size
      );
      expect(result.completedLines).toContain('row_0');
      expect(result.completedLines).toContain('col_0');
      expect(result.completedLines.length).toBe(2);
    });

    it('detects both diagonals simultaneously', () => {
      // Main: 0,6,12,18,24  Anti: 4,8,12,16,20
      const result = detectBingos(
        makeGrid([0, 4, 6, 8, 12, 16, 18, 20, 24]),
        size
      );
      expect(result.completedLines).toContain('diag_main');
      expect(result.completedLines).toContain('diag_anti');
    });

    it('detects GREENLOG when all squares are complete', () => {
      const result = detectBingos(new Array(total).fill(true), size);
      expect(result.isGreenlog).toBe(true);
      expect(result.totalCompleted).toBe(25);
      // All lines should be detected
      expect(result.completedLines).toContain('row_0');
      expect(result.completedLines).toContain('row_4');
      expect(result.completedLines).toContain('col_0');
      expect(result.completedLines).toContain('col_4');
      expect(result.completedLines).toContain('diag_main');
      expect(result.completedLines).toContain('diag_anti');
      // 5 rows + 5 cols + 2 diags = 12 lines
      expect(result.completedLines.length).toBe(12);
    });

    it('does not detect incomplete rows', () => {
      // Row 0 missing one square
      const result = detectBingos(makeGrid([0, 1, 2, 3]), size);
      expect(result.completedLines).toEqual([]);
    });

    it('does not detect incomplete columns', () => {
      // Col 0 missing one square
      const result = detectBingos(makeGrid([0, 5, 10, 15]), size);
      expect(result.completedLines).toEqual([]);
    });

    it('does not detect incomplete diagonals', () => {
      // Main diagonal missing one
      const result = detectBingos(makeGrid([0, 6, 12, 18]), size);
      expect(result.completedLines).toEqual([]);
    });

    it('counts totalCompleted correctly with scattered squares', () => {
      const result = detectBingos(makeGrid([0, 7, 12, 19]), size);
      expect(result.totalCompleted).toBe(4);
    });
  });

  // ── 3x3 Board Tests ──────────────────────────────────────────────────

  describe('3x3 board', () => {
    const size = 3;
    const total = 9;

    function makeGrid(completedIndices: number[]): boolean[] {
      const grid = new Array(total).fill(false);
      for (const i of completedIndices) {
        grid[i] = true;
      }
      return grid;
    }

    it('returns no bingos for an empty board', () => {
      const result = detectBingos(new Array(total).fill(false), size);
      expect(result.completedLines).toEqual([]);
      expect(result.totalSquares).toBe(9);
    });

    it('detects a completed row', () => {
      const result = detectBingos(makeGrid([3, 4, 5]), size);
      expect(result.completedLines).toEqual(['row_1']);
    });

    it('detects a completed column', () => {
      const result = detectBingos(makeGrid([1, 4, 7]), size);
      expect(result.completedLines).toEqual(['col_1']);
    });

    it('detects main diagonal', () => {
      // 0, 4, 8
      const result = detectBingos(makeGrid([0, 4, 8]), size);
      expect(result.completedLines).toEqual(['diag_main']);
    });

    it('detects anti diagonal', () => {
      // 2, 4, 6
      const result = detectBingos(makeGrid([2, 4, 6]), size);
      expect(result.completedLines).toEqual(['diag_anti']);
    });

    it('detects GREENLOG', () => {
      const result = detectBingos(new Array(total).fill(true), size);
      expect(result.isGreenlog).toBe(true);
      // 3 rows + 3 cols + 2 diags = 8
      expect(result.completedLines.length).toBe(8);
    });

    it('detects row + column + diagonal intersection', () => {
      // Row 1: 3,4,5  Col 1: 1,4,7  Main diag: 0,4,8
      // Union: 0,1,3,4,5,7,8
      const result = detectBingos(makeGrid([0, 1, 3, 4, 5, 7, 8]), size);
      expect(result.completedLines).toContain('row_1');
      expect(result.completedLines).toContain('col_1');
      expect(result.completedLines).toContain('diag_main');
    });
  });

  // ── 4x4 Board Tests ──────────────────────────────────────────────────

  describe('4x4 board', () => {
    const size = 4;
    const total = 16;

    function makeGrid(completedIndices: number[]): boolean[] {
      const grid = new Array(total).fill(false);
      for (const i of completedIndices) {
        grid[i] = true;
      }
      return grid;
    }

    it('returns no bingos for an empty board', () => {
      const result = detectBingos(new Array(total).fill(false), size);
      expect(result.completedLines).toEqual([]);
      expect(result.totalSquares).toBe(16);
    });

    it('detects a completed row', () => {
      const result = detectBingos(makeGrid([8, 9, 10, 11]), size);
      expect(result.completedLines).toEqual(['row_2']);
    });

    it('detects a completed column', () => {
      const result = detectBingos(makeGrid([3, 7, 11, 15]), size);
      expect(result.completedLines).toEqual(['col_3']);
    });

    it('detects main diagonal', () => {
      // 0, 5, 10, 15
      const result = detectBingos(makeGrid([0, 5, 10, 15]), size);
      expect(result.completedLines).toEqual(['diag_main']);
    });

    it('detects anti diagonal', () => {
      // 3, 6, 9, 12
      const result = detectBingos(makeGrid([3, 6, 9, 12]), size);
      expect(result.completedLines).toEqual(['diag_anti']);
    });

    it('detects GREENLOG', () => {
      const result = detectBingos(new Array(total).fill(true), size);
      expect(result.isGreenlog).toBe(true);
      // 4 rows + 4 cols + 2 diags = 10
      expect(result.completedLines.length).toBe(10);
    });
  });

  // ── Error Handling ────────────────────────────────────────────────────

  describe('error handling', () => {
    it('throws when grid length does not match gridSize', () => {
      expect(() => detectBingos([true, false], 3)).toThrow(
        'completionGrid length (2) does not match gridSize * gridSize (9)'
      );
    });

    it('throws when grid is empty for non-zero gridSize', () => {
      expect(() => detectBingos([], 3)).toThrow(
        'completionGrid length (0) does not match gridSize * gridSize (9)'
      );
    });

    it('throws when grid is too large', () => {
      expect(() => detectBingos(new Array(30).fill(false), 5)).toThrow(
        'completionGrid length (30) does not match gridSize * gridSize (25)'
      );
    });
  });

  // ── Line ID format ────────────────────────────────────────────────────

  describe('line ID format', () => {
    it('uses correct row format', () => {
      const grid = new Array(9).fill(false);
      grid[6] = true; grid[7] = true; grid[8] = true; // row 2
      const result = detectBingos(grid, 3);
      expect(result.completedLines).toEqual(['row_2']);
    });

    it('uses correct column format', () => {
      const grid = new Array(9).fill(false);
      grid[2] = true; grid[5] = true; grid[8] = true; // col 2
      const result = detectBingos(grid, 3);
      expect(result.completedLines).toEqual(['col_2']);
    });

    it('returns lines in consistent order: rows, cols, diag_main, diag_anti', () => {
      const result = detectBingos(new Array(9).fill(true), 3);
      expect(result.completedLines).toEqual([
        'row_0', 'row_1', 'row_2',
        'col_0', 'col_1', 'col_2',
        'diag_main', 'diag_anti',
      ]);
    });
  });
});

describe('formatBingoMessage', () => {
  it('returns null when no bingos detected', () => {
    const result: BingoDetectionResult = {
      completedLines: [],
      isGreenlog: false,
      totalCompleted: 3,
      totalSquares: 25,
    };
    expect(formatBingoMessage(result)).toBeNull();
  });

  it('returns "GREENLOG!" when board is fully complete', () => {
    const result: BingoDetectionResult = {
      completedLines: ['row_0', 'row_1', 'row_2', 'col_0', 'col_1', 'col_2', 'diag_main', 'diag_anti'],
      isGreenlog: true,
      totalCompleted: 9,
      totalSquares: 9,
    };
    expect(formatBingoMessage(result)).toBe('GREENLOG!');
  });

  it('returns single bingo message', () => {
    const result: BingoDetectionResult = {
      completedLines: ['row_0'],
      isGreenlog: false,
      totalCompleted: 5,
      totalSquares: 25,
    };
    expect(formatBingoMessage(result)).toBe('Bingo! (row_0)');
  });

  it('returns multiple bingo message with comma-separated line IDs', () => {
    const result: BingoDetectionResult = {
      completedLines: ['row_0', 'col_2', 'diag_main'],
      isGreenlog: false,
      totalCompleted: 11,
      totalSquares: 25,
    };
    expect(formatBingoMessage(result)).toBe('Bingo! (row_0, col_2, diag_main)');
  });

  it('prioritizes GREENLOG over listing individual lines', () => {
    const result: BingoDetectionResult = {
      completedLines: ['row_0', 'row_1', 'row_2', 'col_0', 'col_1', 'col_2', 'diag_main', 'diag_anti'],
      isGreenlog: true,
      totalCompleted: 9,
      totalSquares: 9,
    };
    expect(formatBingoMessage(result)).toBe('GREENLOG!');
  });
});

describe('getHighlightedSquares', () => {
  it('returns empty set for no completed lines', () => {
    const result = getHighlightedSquares([], 5);
    expect(result.size).toBe(0);
  });

  it('returns correct indices for a row on 5x5', () => {
    const result = getHighlightedSquares(['row_2'], 5);
    expect(result).toEqual(new Set([10, 11, 12, 13, 14]));
  });

  it('returns correct indices for a column on 5x5', () => {
    const result = getHighlightedSquares(['col_3'], 5);
    expect(result).toEqual(new Set([3, 8, 13, 18, 23]));
  });

  it('returns correct indices for main diagonal on 3x3', () => {
    const result = getHighlightedSquares(['diag_main'], 3);
    expect(result).toEqual(new Set([0, 4, 8]));
  });

  it('returns correct indices for anti diagonal on 3x3', () => {
    const result = getHighlightedSquares(['diag_anti'], 3);
    expect(result).toEqual(new Set([2, 4, 6]));
  });

  it('merges indices from multiple lines without duplicates', () => {
    // Row 0 on 3x3: [0, 1, 2]
    // Col 0 on 3x3: [0, 3, 6]
    // Shared: index 0
    const result = getHighlightedSquares(['row_0', 'col_0'], 3);
    expect(result).toEqual(new Set([0, 1, 2, 3, 6]));
  });

  it('handles all line types combined on 4x4', () => {
    const result = getHighlightedSquares(
      ['row_1', 'col_2', 'diag_main', 'diag_anti'],
      4
    );
    // row_1: 4,5,6,7
    // col_2: 2,6,10,14
    // diag_main: 0,5,10,15
    // diag_anti: 3,6,9,12
    expect(result).toEqual(new Set([0, 2, 3, 4, 5, 6, 7, 9, 10, 12, 14, 15]));
  });

  it('returns correct indices for first row on 3x3', () => {
    const result = getHighlightedSquares(['row_0'], 3);
    expect(result).toEqual(new Set([0, 1, 2]));
  });

  it('returns correct indices for last column on 4x4', () => {
    const result = getHighlightedSquares(['col_3'], 4);
    expect(result).toEqual(new Set([3, 7, 11, 15]));
  });
});
