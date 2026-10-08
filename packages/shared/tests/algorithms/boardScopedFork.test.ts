import * as fs from 'fs';
import * as path from 'path';
import {
  FORK_EVENT_NS,
  FORK_LINK_NS,
  FORK_TASK_NS,
  forkLinkId,
  forkTaskId,
  forkedEventId,
  planBoardScopedFork,
} from '../../src/algorithms/boardScopedFork';
import type { Board } from '../../src/types/board';
import type { BoardTask } from '../../src/types/boardTask';
import type { CompoundChild } from '../../src/types/compoundChild';
import type { Task } from '../../src/types/task';
import type { TaskEvent } from '../../src/types/taskEvent';
import { OperatorType, TaskType } from '../../src/constants/enums';

/**
 * Board-scoped task edits PR 1 (docs/BOARD_SCOPED_TASK_EDITS.md): pins the
 * deterministic fork ids and the pure `planBoardScopedFork` planner against
 * `tests/fixtures/boardScopedForkVectors.json` — the SAME fixture the iOS
 * `BoardScopedForkVectorTests` runs (byte-identical copy under
 * `apps/ios/OYBCTests/Fixtures/`). Expected ids are literal uuidv5 pins.
 */

interface FixBoard {
  id: string;
  startDate: string;
  endDate: string | null;
  sealedAt: string | null;
  isDeleted: boolean;
}
interface FixTask {
  id: string;
  type: string;
  title: string;
  action?: string;
  unit?: string;
  maxCount?: number;
  operator?: string;
  sharedCounterId?: string;
  forkedFromTaskId?: string;
  createdInWizard?: boolean;
}
interface FixEvent {
  id: string;
  taskId: string;
  kind: 'completion' | 'increment';
  occurredAt: string;
  delta?: number;
  boardId?: string;
  isDeleted?: boolean;
}
interface FixExpectedFork {
  mode: 'fork';
  forkId: string;
  repoint: { boardTaskId: string; newTaskId: string } | null;
  eventCopies: Array<{ id: string; sourceEventId: string; kind: string; occurredAt: string; delta?: number; boardId?: string }>;
  childLinksToCopy: Array<{ id: string; childTaskId: string; childIndex: number }>;
}
interface FixVector {
  name: string;
  task: FixTask;
  boardId: string;
  editedType: string;
  placements: Array<Pick<BoardTask, 'id' | 'boardId' | 'taskId' | 'isDeleted'>>;
  compoundChildren?: Array<Pick<CompoundChild, 'id' | 'compoundTaskId' | 'childTaskId' | 'childIndex' | 'isDeleted'>>;
  events?: FixEvent[];
  expected: { mode: 'inPlace' } | FixExpectedFork;
}
interface Fixture {
  ids: {
    forkTaskId: Array<{ boardId: string; taskId: string; expected: string }>;
    forkedEventId: Array<{ forkId: string; eventId: string; expected: string }>;
    forkLinkId: Array<{ forkId: string; childTaskId: string; expected: string }>;
  };
  planBoardScopedFork: { now: string; boards: FixBoard[]; vectors: FixVector[] };
}

const fixture: Fixture = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'boardScopedForkVectors.json'), 'utf8'),
);

const OLD = '2026-01-01T00:00:00.000Z';

function makeTask(raw: FixTask): Task {
  const counting = raw.type === TaskType.COUNTING;
  return {
    id: raw.id,
    userId: 'u1',
    title: raw.title,
    type: raw.type as TaskType,
    action: raw.action,
    unit: raw.unit,
    maxCount: raw.maxCount,
    operator: raw.operator as OperatorType | undefined,
    sharedCounterId: raw.sharedCounterId,
    forkedFromTaskId: raw.forkedFromTaskId,
    createdInWizard: raw.createdInWizard,
    isCounter: true,
    isCompleted: true,
    completedAt: '2026-10-06T10:00:00.000Z',
    currentCount: counting ? 5 : undefined,
    totalCompletions: 3,
    totalInstances: 2,
    createdAt: OLD,
    updatedAt: OLD,
    lastSyncedAt: OLD,
    version: 7,
    isDeleted: false,
  };
}

function makeEvent(raw: FixEvent): TaskEvent {
  const e: TaskEvent = {
    id: raw.id,
    userId: 'u1',
    taskId: raw.taskId,
    kind: raw.kind,
    occurredAt: raw.occurredAt,
    createdAt: OLD,
    updatedAt: OLD,
    lastSyncedAt: OLD,
    version: 3,
    isDeleted: raw.isDeleted ?? false,
  };
  if (raw.delta !== undefined) e.delta = raw.delta;
  if (raw.boardId !== undefined) e.boardId = raw.boardId;
  return e;
}

function makeLink(raw: NonNullable<FixVector['compoundChildren']>[number]): CompoundChild {
  return { ...raw, createdAt: OLD, updatedAt: OLD, lastSyncedAt: OLD, version: 4 };
}

describe('fork id namespaces', () => {
  it('uses fixed, distinct name prefixes', () => {
    expect([FORK_TASK_NS, FORK_EVENT_NS, FORK_LINK_NS]).toEqual(['fork:task', 'fork:event', 'fork:link']);
  });

  it.each(fixture.ids.forkTaskId)('forkTaskId($boardId, $taskId) = $expected', ({ boardId, taskId, expected }) => {
    expect(forkTaskId(boardId, taskId)).toBe(expected);
  });

  it.each(fixture.ids.forkedEventId)('forkedEventId(…, $eventId) = $expected', ({ forkId, eventId, expected }) => {
    expect(forkedEventId(forkId, eventId)).toBe(expected);
  });

  it.each(fixture.ids.forkLinkId)('forkLinkId(…, $childTaskId) = $expected', ({ forkId, childTaskId, expected }) => {
    expect(forkLinkId(forkId, childTaskId)).toBe(expected);
  });
});

describe('planBoardScopedFork — vectors', () => {
  const { now, boards: rawBoards, vectors } = fixture.planBoardScopedFork;
  const boards = rawBoards.map(
    (b) => ({ ...b, endDate: b.endDate ?? undefined, sealedAt: b.sealedAt ?? undefined }) as unknown as Board,
  );

  it.each(vectors.map((v) => [v.name, v] as const))('%s', (_name, v) => {
    const task = makeTask(v.task);
    const board = boards.find((b) => b.id === v.boardId)!;
    const plan = planBoardScopedFork({
      task,
      board,
      editedType: v.editedType as TaskType,
      placements: v.placements,
      boards,
      compoundChildren: (v.compoundChildren ?? []).map(makeLink),
      events: (v.events ?? []).map(makeEvent),
      now,
    });

    if (v.expected.mode === 'inPlace') {
      expect(plan).toEqual({ mode: 'inPlace' });
      return;
    }
    const exp = v.expected;
    expect(plan.mode).toBe('fork');
    if (plan.mode !== 'fork') return;

    // The fork row.
    const f = plan.fork;
    expect(f.id).toBe(exp.forkId);
    expect(f.forkedFromTaskId).toBe(v.task.id);
    expect(f.createdInWizard).toBe(true);
    expect(f.isCounter).toBe(false);
    expect(f.version).toBe(1);
    expect(f.createdAt).toBe(now);
    expect(f.updatedAt).toBe(now);
    expect(f.isDeleted).toBe(false);
    expect(f.isCompleted).toBe(false);
    expect('completedAt' in f).toBe(false);
    expect('lastSyncedAt' in f).toBe(false);
    expect('deletedAt' in f).toBe(false);
    expect(f.currentCount).toBe(v.task.type === TaskType.COUNTING ? 0 : undefined);
    expect(f.totalCompletions).toBe(0);
    expect(f.totalInstances).toBe(1);
    expect(f.title).toBe(v.task.title);
    expect(f.type).toBe(v.task.type);
    expect(f.userId).toBe('u1');

    expect(plan.repoint).toEqual(exp.repoint);

    // Event copies (order is pinned: occurredAt instant asc, then source id).
    expect(
      plan.eventCopies.map((e) => {
        const o: Record<string, unknown> = { id: e.id, kind: e.kind, occurredAt: e.occurredAt };
        if (e.delta !== undefined) o.delta = e.delta;
        if (e.boardId !== undefined) o.boardId = e.boardId;
        return o;
      }),
    ).toEqual(exp.eventCopies.map(({ sourceEventId: _s, ...rest }) => rest));
    for (const e of plan.eventCopies) {
      expect(e.taskId).toBe(exp.forkId);
      expect(e.createdAt).toBe(now);
      expect(e.updatedAt).toBe(now);
      expect(e.version).toBe(1);
      expect(e.userId).toBe('u1');
      expect(e.isDeleted).toBe(false);
      expect('lastSyncedAt' in e).toBe(false);
    }

    // Compound child links.
    expect(plan.childLinksToCopy.map(({ id, childTaskId, childIndex }) => ({ id, childTaskId, childIndex }))).toEqual(
      exp.childLinksToCopy,
    );
    for (const l of plan.childLinksToCopy) {
      expect(l.compoundTaskId).toBe(exp.forkId);
      expect(l.version).toBe(1);
      expect(l.createdAt).toBe(now);
      expect(l.isDeleted).toBe(false);
      expect('lastSyncedAt' in l).toBe(false);
    }
  });

  it('is deterministic: a replay at a later instant yields the same ids', () => {
    const v = vectors.find((x) => x.name.startsWith('window: inclusive'))!;
    const args = {
      task: makeTask(v.task),
      board: boards.find((b) => b.id === v.boardId)!,
      editedType: v.editedType as TaskType,
      placements: v.placements,
      boards,
      compoundChildren: [],
      events: (v.events ?? []).map(makeEvent),
    };
    const a = planBoardScopedFork({ ...args, now });
    const b = planBoardScopedFork({ ...args, now: '2026-10-09T00:00:00.000Z' });
    if (a.mode !== 'fork' || b.mode !== 'fork') throw new Error('expected forks');
    expect(b.fork.id).toBe('bea9618c-f778-5782-a484-ee776d5704b8');
    expect(b.fork.id).toBe(a.fork.id);
    expect(b.eventCopies.map((e) => e.id)).toEqual(a.eventCopies.map((e) => e.id));
    expect(b.fork.createdAt).toBe('2026-10-09T00:00:00.000Z');
  });

  it('does not mutate its inputs', () => {
    const v = vectors.find((x) => x.name.startsWith('compound fork'))!;
    const task = makeTask(v.task);
    const links = (v.compoundChildren ?? []).map(makeLink);
    const snapshot = JSON.stringify({ task, links });
    planBoardScopedFork({
      task,
      board: boards.find((b) => b.id === v.boardId)!,
      editedType: TaskType.COMPOUND,
      placements: v.placements,
      boards,
      compoundChildren: links,
      events: [],
      now,
    });
    expect(JSON.stringify({ task, links })).toBe(snapshot);
  });
});
