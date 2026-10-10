import * as fs from 'fs';
import * as path from 'path';
import { BoardStatus, TaskType, type OperatorType } from '../../src/constants/enums';
import type { Board } from '../../src/types/board';
import type { BoardTask } from '../../src/types/boardTask';
import type { CompoundChild } from '../../src/types/compoundChild';
import type { Task } from '../../src/types/task';
import type { TaskEvent } from '../../src/types/taskEvent';
import type { CountKind } from '../../src/algorithms/countValue';
import {
  COUNTS_TOWARD_NAMESPACE,
  candidateContributionIds,
  canonicalOccurrenceEventId,
  countsTowardAmountOf,
  countsTowardEventId,
  countsTowardProblem,
  isCountsTowardTarget,
  planCountsTowardActions,
  resolveContributionCredits,
  resolveContributionState,
  type ContributionInputs,
  type ContributionOccurrence,
} from '../../src/algorithms/countsToward';
import { forkedEventId } from '../../src/algorithms/boardScopedFork';
import { evaluateCompound } from '../../src/algorithms/compoundEvaluation';
import { TaskSchema } from '../../src/validation/schemas';

/**
 * Vector pins for `countsToward.ts` ↔ iOS `CountsToward.swift`
 * (`CountsTowardVectorTests`) — docs/SHARED_COUNTER_SETTINGS.md §3 (D10: one
 * credit per completion occurrence).
 */

const V = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'countsTowardVectors.json'), 'utf8'));

interface MiniTask {
  id: string;
  type?: string;
  operator?: string;
  threshold?: number;
  maxCount?: number;
  isCompleted?: boolean;
  completedAt?: string;
  isDeleted?: boolean;
  isCounter?: boolean;
  sharedCounterId?: string;
  createdInWizard?: boolean;
  startDate?: string;
  endDate?: string;
  countKind?: CountKind;
  createdAt?: string;
  countsTowardCounterId?: string;
  countsTowardAmount?: number;
  forkedFromTaskId?: string;
}

interface MiniEvent {
  id?: string;
  taskId: string;
  delta?: number;
  occurredAt: string;
  isDeleted?: boolean;
}

interface MiniBoard {
  id: string;
  startDate: string;
  endDate?: string;
  sealedAt?: string;
  status?: string;
  isDeleted?: boolean;
}

interface MiniPlacement {
  boardId: string;
  taskId: string;
  isDeleted?: boolean;
}

const T0 = '2026-01-01T00:00:00.000Z';

function toTask(m: MiniTask): Task {
  return {
    id: m.id,
    userId: 'u',
    title: m.id,
    type: (m.type as TaskType) ?? TaskType.NORMAL,
    operator: m.operator as OperatorType | undefined,
    threshold: m.threshold,
    maxCount: m.maxCount,
    isCompleted: m.isCompleted ?? false,
    completedAt: m.completedAt,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: m.createdAt ?? T0,
    updatedAt: T0,
    version: 1,
    isDeleted: m.isDeleted ?? false,
    isCounter: m.isCounter,
    sharedCounterId: m.sharedCounterId,
    createdInWizard: m.createdInWizard,
    startDate: m.startDate,
    endDate: m.endDate,
    countKind: m.countKind,
    countsTowardCounterId: m.countsTowardCounterId,
    countsTowardAmount: m.countsTowardAmount,
    forkedFromTaskId: m.forkedFromTaskId,
  };
}

function toEvent(m: MiniEvent, idx: number): TaskEvent {
  return {
    id: m.id ?? `e${idx}`,
    userId: 'u',
    taskId: m.taskId,
    kind: m.delta !== undefined ? 'increment' : 'completion',
    delta: m.delta,
    occurredAt: m.occurredAt,
    createdAt: m.occurredAt,
    updatedAt: m.occurredAt,
    version: 1,
    isDeleted: m.isDeleted ?? false,
  };
}

function toChildren(rows: { compoundTaskId: string; childTaskId: string; isDeleted?: boolean }[]): CompoundChild[] {
  return rows.map((r, i) => ({
    id: `l${i}`,
    compoundTaskId: r.compoundTaskId,
    childTaskId: r.childTaskId,
    childIndex: i,
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: r.isDeleted ?? false,
  }));
}

function toBoard(m: MiniBoard): Pick<Board, 'id' | 'isDeleted' | 'status' | 'startDate' | 'endDate' | 'sealedAt'> {
  return {
    id: m.id,
    isDeleted: m.isDeleted ?? false,
    status: (m.status as BoardStatus) ?? BoardStatus.ACTIVE,
    startDate: m.startDate,
    endDate: m.endDate,
    sealedAt: m.sealedAt,
  };
}

function toPlacement(m: MiniPlacement, i: number): Pick<BoardTask, 'id' | 'boardId' | 'taskId' | 'isDeleted'> {
  return { id: `bt${i}`, boardId: m.boardId, taskId: m.taskId, isDeleted: m.isDeleted ?? false };
}

function group<T extends { compoundTaskId?: string; taskId?: string }>(rows: T[], key: 'compoundTaskId' | 'taskId'): Record<string, T[]> {
  const out: Record<string, T[]> = {};
  for (const r of rows) (out[r[key] as string] ??= []).push(r);
  return out;
}

/** The `ContributionInputs` a credits / candidates vector describes. */
function toInputs(v: any): { task: Task; inputs: ContributionInputs } {
  const tasks = (v.tasks as MiniTask[]).map(toTask);
  const taskById = Object.fromEntries(tasks.map((t) => [t.id, t]));
  const events = (v.events as MiniEvent[]).map(toEvent);
  return {
    task: taskById[v.taskId],
    inputs: {
      taskById,
      childrenByCompound: group(toChildren(v.children ?? []), 'compoundTaskId'),
      eventsByTaskId: group(events.filter((e) => !e.isDeleted), 'taskId'),
      allEventsByTaskId: group(events, 'taskId'),
      placements: (v.placements as MiniPlacement[]).map(toPlacement),
      boardById: Object.fromEntries((v.boards as MiniBoard[]).map((b) => [b.id, toBoard(b)])),
    },
  };
}

const byId = <T extends { eventId: string }>(rows: T[]): T[] => [...rows].sort((a, b) => (a.eventId < b.eventId ? -1 : a.eventId > b.eventId ? 1 : 0));

describe('countsTowardVectors — eventId', () => {
  it.each(V.eventId as any[])('$contributorId $occurrence.kind', (v: any) => {
    expect(countsTowardEventId(v.contributorId, v.occurrence)).toBe(v.expected);
  });

  it('uses the counts-toward name prefix; an event key ignores the contributor, the other keys include it', () => {
    expect(COUNTS_TOWARD_NAMESPACE).toBe('counts-toward:event');
    const ev: ContributionOccurrence = { kind: 'event', eventId: 'x' };
    expect(countsTowardEventId('a', ev)).toBe(countsTowardEventId('b', ev));
    expect(countsTowardEventId('a', { kind: 'lifetime' })).not.toBe(countsTowardEventId('b', { kind: 'lifetime' }));
    expect(countsTowardEventId('a', { kind: 'window', startDate: T0 })).not.toBe(countsTowardEventId('a', { kind: 'lifetime' }));
  });
});

describe('countsTowardVectors — amount', () => {
  it.each(V.amount as any[])('$name', (v: any) => {
    expect(countsTowardAmountOf({ countsTowardAmount: v.countsTowardAmount })).toBe(v.expected);
  });
});

describe('countsTowardVectors — resolveContributionState', () => {
  it.each(V.state as any[])('$name', (v: any) => {
    const tasks = (v.tasks as MiniTask[]).map(toTask);
    const taskById = Object.fromEntries(tasks.map((t) => [t.id, t]));
    const children = toChildren(v.children);
    const events = (v.events as MiniEvent[]).map(toEvent);
    const state = resolveContributionState(
      taskById[v.taskId],
      group(children, 'compoundTaskId'),
      taskById,
      group(events, 'taskId'),
      v.window ?? undefined,
    );
    expect(state).toEqual(v.expected);
  });

  it('agrees with evaluateCompound in the same window for every compound vector', () => {
    for (const v of V.state as any[]) {
      const tasks = (v.tasks as MiniTask[]).map(toTask);
      const root = tasks.find((t) => t.id === v.taskId)!;
      if (root.type !== TaskType.COMPOUND) continue;
      const taskById = Object.fromEntries(tasks.map((t) => [t.id, t]));
      const children = group(toChildren(v.children), 'compoundTaskId');
      const eventsByTaskId = group((v.events as MiniEvent[]).map(toEvent).filter((e) => !e.isDeleted), 'taskId');
      const window = v.window ?? { windowStart: null, windowEnd: null };
      const done = evaluateCompound(root, children, taskById, { ...window, eventsByTaskId });
      expect({ name: v.name, done }).toEqual({ name: v.name, done: v.expected.isCompleted });
    }
  });
});

describe('countsTowardVectors — resolveContributionCredits', () => {
  it.each(V.credits as any[])('$name', (v: any) => {
    const { task, inputs } = toInputs(v);
    const expected = byId(
      (v.expected as any[]).map((e) => ({ eventId: countsTowardEventId(task.id, e.occurrence), occurrence: e.occurrence, occurredAt: e.occurredAt })),
    );
    expect(resolveContributionCredits(task, inputs)).toEqual(expected);
  });

  it('every wanted credit is among the candidates', () => {
    for (const v of V.credits as any[]) {
      const { task, inputs } = toInputs(v);
      const candidates = new Set(candidateContributionIds(task, inputs));
      for (const c of resolveContributionCredits(task, inputs)) {
        expect({ name: v.name, has: candidates.has(c.eventId) }).toEqual({ name: v.name, has: true });
      }
    }
  });
});

describe('countsTowardVectors — candidateContributionIds', () => {
  it.each(V.candidates as any[])('$name', (v: any) => {
    const { task, inputs } = toInputs(v);
    const expected = [...new Set((v.expected as ContributionOccurrence[]).map((o) => countsTowardEventId(task.id, o)))].sort();
    expect(candidateContributionIds(task, inputs)).toEqual(expected);
  });
});

describe('canonicalOccurrenceEventId', () => {
  it('walks a fork-of-a-fork back to the source event; an unknown ancestor or a non-copied event stays itself', () => {
    const o = toTask({ id: 'o' });
    const f1 = toTask({ id: 'f1', forkedFromTaskId: 'o' });
    const f2 = toTask({ id: 'f2', forkedFromTaskId: 'f1' });
    const orphan = toTask({ id: 'orphan', forkedFromTaskId: 'missing' });
    const e = toEvent({ id: 'e', taskId: 'o', occurredAt: T0 }, 0);
    const e1 = { ...e, id: forkedEventId('f1', 'e'), taskId: 'f1' };
    const e2 = { ...e, id: forkedEventId('f2', e1.id), taskId: 'f2' };
    const own = toEvent({ id: 'own', taskId: 'f1', occurredAt: T0 }, 1);
    const taskById = { o, f1, f2, orphan };
    const all = { o: [e], f1: [e1, own], f2: [e2] };
    expect(canonicalOccurrenceEventId(e2.id, f2, taskById, all)).toBe('e');
    expect(canonicalOccurrenceEventId(e1.id, f1, taskById, all)).toBe('e');
    expect(canonicalOccurrenceEventId('own', f1, taskById, all)).toBe('own');
    expect(canonicalOccurrenceEventId('e', o, taskById, all)).toBe('e');
    expect(canonicalOccurrenceEventId('x', orphan, taskById, all)).toBe('x');
  });
});

describe('countsTowardVectors — planCountsTowardActions', () => {
  it.each(V.planSet as any[])('$name', (v: any) => {
    const contributor = toTask(v.contributor);
    const tasks = (v.tasks as MiniTask[]).map(toTask);
    const taskById = Object.fromEntries([...tasks, contributor].map((t) => [t.id, t]));
    const idOf = (o: ContributionOccurrence): string => countsTowardEventId(contributor.id, o);
    const wanted = (v.wanted as any[]).map((w) => ({ eventId: idOf(w.occurrence), occurrence: w.occurrence, occurredAt: w.occurredAt }));
    const candidates = (v.candidates as ContributionOccurrence[]).map(idOf);
    const storedById: Record<string, TaskEvent> = {};
    for (const s of v.stored as any[]) {
      storedById[idOf(s.occurrence)] = toEvent({ id: idOf(s.occurrence), taskId: s.taskId, delta: s.delta, occurredAt: s.occurredAt, isDeleted: s.isDeleted }, 0);
    }
    const expected = byId((v.expected as any[]).map(({ occurrence, ...rest }) => ({ eventId: idOf(occurrence), ...rest })));
    expect(planCountsTowardActions(contributor, taskById, wanted, candidates, storedById)).toEqual(expected);
  });
});

describe('countsTowardVectors — countsTowardProblem', () => {
  it.each(V.problem as any[])('$name', (v: any) => {
    const tasks = (v.tasks as MiniTask[]).map(toTask);
    const task = tasks.find((t) => t.id === v.taskId)!;
    expect(
      countsTowardProblem({ task, targetId: v.targetId, amount: v.amount, tasks, children: toChildren(v.children) }),
    ).toBe(v.expected);
  });
});

describe('isCountsTowardTarget', () => {
  it('needs a live, unlinked, Discrete counting row', () => {
    expect(isCountsTowardTarget(undefined)).toBe(false);
    expect(isCountsTowardTarget(toTask({ id: 'r', type: 'counting' }))).toBe(true);
    expect(isCountsTowardTarget(toTask({ id: 'r', type: 'counting', countKind: 'duration' }))).toBe(false);
    expect(isCountsTowardTarget(toTask({ id: 'r', type: 'counting', sharedCounterId: 'x' }))).toBe(false);
    expect(isCountsTowardTarget(toTask({ id: 'r', type: 'counting', isDeleted: true }))).toBe(false);
    expect(isCountsTowardTarget(toTask({ id: 'r' }))).toBe(false);
  });
});

describe('TaskSchema — countsToward shape rules', () => {
  const ROOT = '00000000-0000-4000-8000-0000000000c1';
  const base = {
    id: '00000000-0000-4000-8000-000000000001',
    userId: 'u',
    title: 'Read Dune',
    type: TaskType.NORMAL,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
  };

  it('accepts a contributor with a counter and an amount', () => {
    expect(TaskSchema.safeParse({ ...base, countsTowardCounterId: ROOT, countsTowardAmount: 3 }).success).toBe(true);
    expect(TaskSchema.safeParse({ ...base, countsTowardCounterId: null }).success).toBe(true);
  });

  it('refuses counting toward itself', () => {
    expect(TaskSchema.safeParse({ ...base, countsTowardCounterId: base.id }).success).toBe(false);
  });

  it('refuses a hub counter, a linked copy or an achievement as a contributor', () => {
    expect(TaskSchema.safeParse({ ...base, type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 3, isCounter: true, countsTowardCounterId: ROOT }).success).toBe(false);
    expect(
      TaskSchema.safeParse({ ...base, type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 3, sharedCounterId: '00000000-0000-4000-8000-0000000000c2', baseline: 0, countsTowardCounterId: ROOT }).success,
    ).toBe(false);
    expect(
      TaskSchema.safeParse({ ...base, type: TaskType.ACHIEVEMENT, referencedBoardId: '00000000-0000-4000-8000-0000000000b1', countsTowardCounterId: ROOT }).success,
    ).toBe(false);
  });

  it('refuses a non-positive or fractional amount', () => {
    expect(TaskSchema.safeParse({ ...base, countsTowardCounterId: ROOT, countsTowardAmount: 0 }).success).toBe(false);
    expect(TaskSchema.safeParse({ ...base, countsTowardCounterId: ROOT, countsTowardAmount: 1.5 }).success).toBe(false);
  });
});
