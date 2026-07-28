import * as fs from 'fs';
import * as path from 'path';
import { hasCycle } from '../../src/algorithms/cycleDetection';
import { BoardStatus, CenterSquareType, TaskType, Timeframe } from '../../src/constants/enums';
import type { Board, BoardTask, Task } from '../../src';

/**
 * C1 (issue #267): fully fixture-driven from
 * `tests/fixtures/cycleDetectionVectors.json` — the SAME file
 * `apps/ios/OYBCTests/CycleDetectionVectorTests.swift` runs through the
 * Swift mirror `CycleDetection.hasCycle`. Pre-C1: 23 `it` blocks across the
 * referencedBoardId / referencedTemplateId / live-edit-retarget describe
 * blocks. Post-C1: 23 fixture vectors — a 1:1 mapping, no case dropped.
 */

const FIXTURE_PATH = path.join(__dirname, '../fixtures/cycleDetectionVectors.json');
const BASE_TS = '2026-04-23T00:00:00.000Z';

interface MiniBoard {
  id: string;
  startDate: string;
  endDate: string;
  spawnedFromTemplateId?: string;
  isDeleted?: boolean;
}

interface MiniTask {
  id: string;
  type?: string;
  referencedBoardId?: string;
  referencedTemplateId?: string;
  isDeleted?: boolean;
}

interface MiniBoardTask {
  boardId: string;
  taskId: string;
}

interface Vector {
  name: string;
  boards: MiniBoard[];
  tasks: MiniTask[];
  boardTasks: MiniBoardTask[];
  candidate: { parentBoardIds: string[]; referencedBoardId?: string; referencedTemplateId?: string };
  expected: {
    ok: boolean;
    cyclePathEquals?: string[];
    cyclePathContains?: string[];
    cyclePathFirst?: string;
    cyclePathLast?: string;
  };
}

interface Fixture {
  vectors: Vector[];
}

const fixture: Fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));

function toBoard(m: MiniBoard): Board {
  return {
    id: m.id,
    userId: 'u',
    name: m.id,
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.MONTHLY,
    startDate: m.startDate,
    endDate: m.endDate,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: BASE_TS,
    updatedAt: BASE_TS,
    version: 1,
    isDeleted: m.isDeleted ?? false,
    spawnedFromTemplateId: m.spawnedFromTemplateId,
  };
}

function toTask(m: MiniTask): Task {
  return {
    id: m.id,
    userId: 'u',
    title: m.id,
    type: (m.type as TaskType) ?? TaskType.ACHIEVEMENT,
    referencedBoardId: m.referencedBoardId,
    referencedTemplateId: m.referencedTemplateId,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: BASE_TS,
    updatedAt: BASE_TS,
    version: 1,
    isDeleted: m.isDeleted ?? false,
  };
}

function toBoardTask(m: MiniBoardTask, idx: number): BoardTask {
  return {
    id: `bt-${m.boardId}-${m.taskId}-${idx}`,
    boardId: m.boardId,
    taskId: m.taskId,
    row: 0,
    col: idx,
    isCenter: false,
    createdAt: BASE_TS,
    updatedAt: BASE_TS,
    version: 1,
    isDeleted: false,
  };
}

describe('hasCycle (fixture-driven, tests/fixtures/cycleDetectionVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.vectors.length).toBeGreaterThan(0);
  });

  for (const v of fixture.vectors) {
    it(v.name, () => {
      const allBoards = v.boards.map(toBoard);
      const allTasks = v.tasks.map(toTask);
      const allBoardTasks = v.boardTasks.map(toBoardTask);

      const result = hasCycle(v.candidate, { allBoardTasks, allTasks, allBoards });

      expect(result.ok).toBe(v.expected.ok);
      if (!result.ok) {
        if (v.expected.cyclePathEquals) {
          expect(result.cyclePath).toEqual(v.expected.cyclePathEquals);
        }
        if (v.expected.cyclePathFirst) {
          expect(result.cyclePath[0]).toBe(v.expected.cyclePathFirst);
        }
        if (v.expected.cyclePathLast) {
          expect(result.cyclePath[result.cyclePath.length - 1]).toBe(v.expected.cyclePathLast);
        }
        if (v.expected.cyclePathContains) {
          for (const id of v.expected.cyclePathContains) {
            expect(result.cyclePath).toContain(id);
          }
        }
      }
    });
  }
});
