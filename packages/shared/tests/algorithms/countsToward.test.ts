import * as fs from 'fs';
import * as path from 'path';
import { TaskType, type OperatorType } from '../../src/constants/enums';
import type { CompoundChild } from '../../src/types/compoundChild';
import type { Task } from '../../src/types/task';
import type { TaskEvent } from '../../src/types/taskEvent';
import type { CountKind } from '../../src/algorithms/countValue';
import {
  COUNTS_TOWARD_NAMESPACE,
  countsTowardAmountOf,
  countsTowardEventId,
  countsTowardProblem,
  isCountsTowardTarget,
  planCountsTowardAction,
  resolveContributionState,
} from '../../src/algorithms/countsToward';
import { evaluateCompound } from '../../src/algorithms/compoundEvaluation';
import { TaskSchema } from '../../src/validation/schemas';

/**
 * Vector pins for `countsToward.ts` ↔ iOS `CountsToward.swift`
 * (`CountsTowardVectorTests`) — docs/SHARED_COUNTER_SETTINGS.md §3.
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
}

interface MiniEvent {
  id?: string;
  taskId: string;
  delta?: number;
  occurredAt: string;
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

function group<T extends { compoundTaskId?: string; taskId?: string }>(rows: T[], key: 'compoundTaskId' | 'taskId'): Record<string, T[]> {
  const out: Record<string, T[]> = {};
  for (const r of rows) (out[r[key] as string] ??= []).push(r);
  return out;
}

describe('countsTowardVectors — eventId', () => {
  it.each(V.eventId as any[])('$taskId', (v: any) => {
    expect(countsTowardEventId(v.taskId)).toBe(v.expected);
  });

  it('uses the counts-toward name prefix, distinct per task', () => {
    expect(COUNTS_TOWARD_NAMESPACE).toBe('counts-toward:event');
    expect(countsTowardEventId('a')).not.toBe(countsTowardEventId('b'));
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
    );
    expect(state).toEqual(v.expected);
  });

  it('agrees with evaluateCompound in a lifetime window context for every compound vector', () => {
    for (const v of V.state as any[]) {
      const tasks = (v.tasks as MiniTask[]).map(toTask);
      const root = tasks.find((t) => t.id === v.taskId)!;
      if (root.type !== TaskType.COMPOUND) continue;
      const taskById = Object.fromEntries(tasks.map((t) => [t.id, t]));
      const children = group(toChildren(v.children), 'compoundTaskId');
      const eventsByTaskId = group((v.events as MiniEvent[]).map(toEvent).filter((e) => !e.isDeleted), 'taskId');
      const lifetime = evaluateCompound(root, children, taskById, { windowStart: null, windowEnd: null, eventsByTaskId });
      expect({ name: v.name, done: lifetime }).toEqual({ name: v.name, done: v.expected.isCompleted });
    }
  });
});

describe('countsTowardVectors — planCountsTowardAction', () => {
  it.each(V.plan as any[])('$name', (v: any) => {
    const contributor = toTask(v.contributor);
    const tasks = (v.tasks as MiniTask[]).map(toTask);
    const taskById = Object.fromEntries([...tasks, contributor].map((t) => [t.id, t]));
    const existing = v.existing
      ? { ...toEvent({ ...v.existing, id: countsTowardEventId(contributor.id) }, 0) }
      : undefined;
    const action = planCountsTowardAction(contributor, taskById, v.state, existing);
    if (v.expected === null) {
      expect(action).toBeNull();
    } else {
      expect(action).toEqual({ eventId: countsTowardEventId(contributor.id), ...v.expected });
    }
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
