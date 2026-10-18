import * as fs from 'fs';
import * as path from 'path';
import { planPlacementSweep, rekeyIds, rekeyRecordKeys } from '../../src/algorithms/placementSweep';
import type { Board, BoardTask, CompoundChild, Task, TaskEvent } from '../../src/types';

/**
 * Fixture-driven (tests/fixtures/placementSweepVectors.json — the SAME file
 * apps/ios/OYBCTests/PlacementSweepVectorTests.swift runs through the Swift
 * twin). Mini shapes are widened to full rows here exactly as the Swift
 * harness does; `expected` is the whole plan, compared deep-equal.
 */

const FIXTURE_PATH = path.join(__dirname, '../fixtures/placementSweepVectors.json');
const TS = '2026-10-01T00:00:00.000Z';

interface MiniWorkspace {
  tasks: Array<Partial<Task> & { id: string }>;
  boards: Array<Partial<Board> & { id: string }>;
  boardTasks: Array<Partial<BoardTask> & { id: string; boardId: string; taskId: string; row: number; col: number }>;
  compoundChildren: Array<{ compoundTaskId: string; childTaskId: string; isDeleted: boolean }>;
  events: Array<Partial<TaskEvent> & { taskId: string; kind: TaskEvent['kind']; occurredAt: string }>;
}
interface SweepVector {
  name: string;
  ws: MiniWorkspace;
  expected: ReturnType<typeof planPlacementSweep>;
}
interface IdsVector { name: string; ids: string[]; map: Record<string, string>; expected: string[]; identity: boolean }
interface RecordVector { name: string; record: Record<string, unknown>; map: Record<string, string>; expected: Record<string, unknown>; identity: boolean }

const fixture: { planPlacementSweep: SweepVector[]; rekeyIds: IdsVector[]; rekeyRecordKeys: RecordVector[] } = JSON.parse(
  fs.readFileSync(FIXTURE_PATH, 'utf8'),
);

function full(ws: MiniWorkspace) {
  return {
    tasks: ws.tasks.map((t) => ({ userId: 'u', totalCompletions: 0, totalInstances: 0, createdAt: TS, updatedAt: TS, version: 1, type: 'counting', title: `Task ${t.id}`, isCompleted: false, isDeleted: false, ...t }) as Task),
    boards: ws.boards.map((b) => ({ userId: 'u', isRandomized: false, totalTasks: 9, completedTasks: 0, linesCompleted: 0, completedLineIds: [], createdAt: TS, updatedAt: TS, version: 1, ...b }) as Board),
    boardTasks: ws.boardTasks.map((p) => ({ isCenter: false, createdAt: TS, updatedAt: TS, version: 1, isDeleted: false, ...p }) as BoardTask),
    compoundChildren: ws.compoundChildren.map((c, i) => ({ id: `${c.compoundTaskId}-${c.childTaskId}`, childIndex: i, createdAt: TS, updatedAt: TS, version: 1, ...c }) as CompoundChild),
    events: ws.events.map((e, i) => ({ id: `e${i}`, userId: 'u', createdAt: TS, updatedAt: TS, version: 1, isDeleted: false, ...e }) as TaskEvent),
  };
}

describe('planPlacementSweep (fixture-driven)', () => {
  it('fixture covers every outcome', () => {
    const outcomes = new Set(fixture.planPlacementSweep.flatMap((v) => v.expected.outcomes.map((o) => o.reason ?? o.outcome)));
    expect(outcomes).toEqual(new Set(['repointed', 'rootMissing', 'duplicateRoot', 'derivationChanged', 'compoundMismatch']));
    expect(fixture.planPlacementSweep.some((v) => v.expected.repoints.some((r) => r.childTargets !== undefined))).toBe(true);
    expect(fixture.planPlacementSweep.some((v) => v.expected.orphanTombstones.length > 0)).toBe(true);
    expect(fixture.planPlacementSweep.some((v) => v.expected.repoints.some((r) => r.sealed))).toBe(true);
  });

  for (const v of fixture.planPlacementSweep) {
    it(v.name, () => {
      expect(JSON.parse(JSON.stringify(planPlacementSweep(full(v.ws), TS)))).toEqual(v.expected);
    });
  }

  it('converges: applying each plan and re-planning reaches an empty plan within three runs, with no repoint after the first', () => {
    const apply = (ws: ReturnType<typeof full>, plan: ReturnType<typeof planPlacementSweep>): ReturnType<typeof full> => {
      const repointById = new Map(plan.repoints.map((r) => [r.boardTaskId, r]));
      const stripped = new Set(plan.strips);
      const tomb = new Set(plan.orphanTombstones);
      return {
        ...ws,
        boardTasks: ws.boardTasks.map((bt) => {
          const r = repointById.get(bt.id);
          if (!r) return bt;
          const next: BoardTask = { ...bt, taskId: r.toTaskId, targetOverride: r.targetOverride, targetKind: r.targetKind, titleOverride: r.titleOverride };
          return next;
        }),
        tasks: ws.tasks.map((t) => {
          if (tomb.has(t.id)) return { ...t, isDeleted: true };
          if (stripped.has(t.id)) {
            const { timeframe: _tf, startDate: _s, endDate: _e, ...rest } = t;
            return rest as Task;
          }
          return t;
        }),
      };
    };
    const isEmpty = (p: ReturnType<typeof planPlacementSweep>): boolean =>
      p.repoints.length === 0 && p.strips.length === 0 && p.orphanTombstones.length === 0 && p.outcomes.length === 0;
    for (const v of fixture.planPlacementSweep) {
      let ws = full(v.ws);
      let plan = planPlacementSweep(ws, TS);
      let runs = 0;
      while (!isEmpty(plan) && runs < 3) {
        ws = apply(ws, plan);
        plan = planPlacementSweep(ws, TS);
        runs += 1;
        // Repoints happen on the first run only; later runs retire orphans and settle refused rows.
        expect(plan.repoints).toEqual([]);
      }
      expect(isEmpty(plan)).toBe(true);
    }
  });
});

describe('rekeyIds / rekeyRecordKeys (fixture-driven)', () => {
  for (const v of fixture.rekeyIds) {
    it(`rekeyIds — ${v.name}`, () => {
      const out = rekeyIds(v.ids, v.map);
      expect([...out]).toEqual(v.expected);
      expect(out === v.ids).toBe(v.identity);
    });
  }
  for (const v of fixture.rekeyRecordKeys) {
    it(`rekeyRecordKeys — ${v.name}`, () => {
      const out = rekeyRecordKeys(v.record, v.map);
      expect(out).toEqual(v.expected);
      expect(out === v.record).toBe(v.identity);
    });
  }
});
