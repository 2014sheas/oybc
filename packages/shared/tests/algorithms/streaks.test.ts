import * as fs from 'fs';
import * as path from 'path';
import {
  computeStreak,
  computeAllStreaks,
  computeLongestStreak,
  compactStreakLabel,
} from '../../src/algorithms/streaks';
import { AchievementTrigger, BoardStatus, CenterSquareType, Timeframe } from '../../src/constants/enums';
import type { Board } from '../../src/types/board';

/**
 * C1 (issue #267): fully fixture-driven from
 * `tests/fixtures/streaksVectors.json` — the SAME file
 * `apps/ios/OYBCTests/StreaksVectorTests.swift` runs through the Swift
 * mirrors in `Services/Streaks.swift`. Pre-C1: 12 computeStreak `it` blocks
 * (2 asserted 2 sub-cases each) + 1 computeAllStreaks + 6 computeLongestStreak
 * + 2 compactStreakLabel (asserting 4 + 2 sub-cases) = 27 total
 * input/output pairs. Post-C1: 14 + 1 + 6 + 6 = 27 fixture vectors — a 1:1
 * mapping, no case dropped.
 */

const FIXTURE_PATH = path.join(__dirname, '../fixtures/streaksVectors.json');

interface MiniBoard {
  timeframe: string;
  startDate: string;
  endDate: string;
  status: string;
  linesCompleted: number;
  isCore: boolean;
  isDeleted: boolean;
}

interface StreakVector {
  name: string;
  timeframe: string;
  criterion: string;
  boards: MiniBoard[];
  expected: number;
}

interface AllStreaksVector {
  name: string;
  boards: MiniBoard[];
  expected: Record<string, { bingo: number; greenlog: number }>;
}

interface LongestStreakVector {
  name: string;
  timeframe: string;
  boards: MiniBoard[];
  expected: number;
}

interface LabelVector {
  name: string;
  count: number;
  timeframe: string;
  expected: string;
}

interface Fixture {
  now: string;
  computeStreak: StreakVector[];
  computeAllStreaks: AllStreaksVector[];
  computeLongestStreak: LongestStreakVector[];
  compactStreakLabel: LabelVector[];
}

const fixture: Fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));
const NOW = new Date(fixture.now);

function toBoard(m: MiniBoard, i: number): Board {
  return {
    id: `b-${m.timeframe}-${m.startDate}-${i}`,
    userId: 'u1',
    name: 'core',
    status: m.status as BoardStatus,
    boardSize: 5,
    timeframe: m.timeframe as Timeframe,
    startDate: m.startDate,
    endDate: m.endDate,
    centerSquareType: CenterSquareType.FREE,
    isRandomized: true,
    totalTasks: 25,
    completedTasks: 0,
    linesCompleted: m.linesCompleted,
    createdAt: '2026-01-01T00:00:00.000',
    updatedAt: '2026-01-01T00:00:00.000',
    version: 1,
    isDeleted: m.isDeleted,
    isCore: m.isCore,
  };
}

describe('computeStreak (fixture-driven, tests/fixtures/streaksVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.computeStreak.length).toBeGreaterThan(0);
  });

  for (const v of fixture.computeStreak) {
    it(v.name, () => {
      const boards = v.boards.map(toBoard);
      const result = computeStreak(
        v.timeframe as Timeframe,
        v.criterion as AchievementTrigger,
        boards,
        'monday',
        NOW,
      );
      expect(result).toBe(v.expected);
    });
  }
});

describe('computeAllStreaks (fixture-driven, tests/fixtures/streaksVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.computeAllStreaks.length).toBeGreaterThan(0);
  });

  for (const v of fixture.computeAllStreaks) {
    it(v.name, () => {
      const boards = v.boards.map(toBoard);
      const all = computeAllStreaks(boards, 'monday', NOW);
      expect(all[Timeframe.DAILY]).toEqual(v.expected.daily);
      expect(all[Timeframe.WEEKLY]).toEqual(v.expected.weekly);
      expect(all[Timeframe.MONTHLY]).toEqual(v.expected.monthly);
      expect(all[Timeframe.YEARLY]).toEqual(v.expected.yearly);
    });
  }
});

describe('computeLongestStreak (fixture-driven, tests/fixtures/streaksVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.computeLongestStreak.length).toBeGreaterThan(0);
  });

  for (const v of fixture.computeLongestStreak) {
    it(v.name, () => {
      const boards = v.boards.map(toBoard);
      const result = computeLongestStreak(v.timeframe as Timeframe, boards, 'monday', NOW);
      expect(result).toBe(v.expected);
    });
  }
});

describe('compactStreakLabel (fixture-driven, tests/fixtures/streaksVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.compactStreakLabel.length).toBeGreaterThan(0);
  });

  for (const v of fixture.compactStreakLabel) {
    it(v.name, () => {
      expect(compactStreakLabel(v.count, v.timeframe as Timeframe)).toBe(v.expected);
    });
  }
});
