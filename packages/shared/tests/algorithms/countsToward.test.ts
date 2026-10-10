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
  canContribute,
  candidateContributionIds,
  countsTowardAmountOf,
  countsTowardEventId,
  isCountsTowardTarget,
  isCreditWriteSealSuppressed,
  isOccurrenceWanted,
  keptCreditIdsFor,
  lineageCreditDelta,
  planCountsTowardActions,
  resolveContributionCredits,
  resolveContributionState,
  type ContributionInputs,
  type ContributionOccurrence,
} from '../../src/algorithms/countsToward';
import {
  buildForkChildrenIndex,
  canonicalOccurrenceEventId,
  createForkEventResolver,
  forkLineageIds,
  isForkLineageLoaded,
  lineageRootId,
} from '../../src/algorithms/countsTowardLineage';
import { countsTowardProblem } from '../../src/algorithms/countsTowardValidation';
import { forkedEventId } from '../../src/algorithms/boardScopedFork';
import { evaluateCompound } from '../../src/algorithms/compoundEvaluation';
import { buildSealImmuneWindows } from '../../src/algorithms/taskEvents';
import { TaskSchema } from '../../src/validation/schemas';

/**
 * Vector pins for `countsToward.ts` (+ lineage / validation) ↔ iOS
 * `CountsToward.swift` (`CountsTowardVectorTests`) —
 * docs/SHARED_COUNTER_SETTINGS.md §3 (D10: one credit per completion
 * occurrence; D11: count from `countsTowardSince`, credits honour sealed
 * windows).
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
  countsTowardSince?: string;
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
    countsTowardSince: m.countsTowardSince,
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
  const children = toChildren(v.children ?? []);
  return {
    task: taskById[v.taskId],
    inputs: {
      taskById,
      childrenByCompound: group(children.filter((c) => !c.isDeleted), 'compoundTaskId'),
      allChildrenByCompound: group(children, 'compoundTaskId'),
      eventsByTaskId: group(events.filter((e) => !e.isDeleted), 'taskId'),
      allEventsByTaskId: group(events, 'taskId'),
      placements: (v.placements as MiniPlacement[]).map(toPlacement),
      boardById: Object.fromEntries((v.boards as MiniBoard[]).map((b) => [b.id, toBoard(b)])),
    },
  };
}

const byId = <T extends { eventId: string }>(rows: T[]): T[] => [...rows].sort((a, b) => (a.eventId < b.eventId ? -1 : a.eventId > b.eventId ? 1 : 0));

describe('countsTowardVectors — eventId', () => {
  it.each(V.eventId as any[])('$root $contributorId $occurrence.kind', (v: any) => {
    expect(countsTowardEventId(v.root, v.contributorId, v.occurrence)).toBe(v.expected);
  });

  it('every key carries the root; an own-event key ignores the scope, the other keys include it', () => {
    expect(COUNTS_TOWARD_NAMESPACE).toBe('counts-toward:event');
    const ev: ContributionOccurrence = { kind: 'event', eventId: 'x' };
    expect(countsTowardEventId('root', 'a', ev)).toBe(countsTowardEventId('root', 'b', ev));
    expect(countsTowardEventId('root', 'a', ev)).not.toBe(countsTowardEventId('root2', 'a', ev));
    expect(countsTowardEventId('root', 'a', { kind: 'lifetime' })).not.toBe(countsTowardEventId('root', 'b', { kind: 'lifetime' }));
    expect(countsTowardEventId('root', 'a', { kind: 'childEvent', eventId: 'x' })).not.toBe(countsTowardEventId('root', 'a', ev));
    expect(countsTowardEventId('root', 'a', { kind: 'board', boardId: 'b1' })).not.toBe(countsTowardEventId('root', 'a', { kind: 'lifetime' }));
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
    const scope = lineageRootId(task, inputs.taskById);
    const expected = byId(
      (v.expected as any[]).map((e) => {
        const rootId = e.root ?? 'root';
        return { eventId: countsTowardEventId(rootId, scope, e.occurrence), rootId, occurrence: e.occurrence, occurredAt: e.occurredAt };
      }),
    );
    expect(resolveContributionCredits(task, inputs)).toEqual(expected);
  });

  it('every wanted credit is among the candidates on its root', () => {
    for (const v of V.credits as any[]) {
      const { task, inputs } = toInputs(v);
      const credits = resolveContributionCredits(task, inputs);
      const candidates = new Set(candidateContributionIds(task, inputs, [...new Set(credits.map((c) => c.rootId))]));
      for (const c of credits) expect({ name: v.name, has: candidates.has(c.eventId) }).toEqual({ name: v.name, has: true });
    }
  });

  it('a shared resolver gives the same credits as an ad-hoc one; an explicit root re-keys them', () => {
    for (const v of V.credits as any[]) {
      const { task, inputs } = toInputs(v);
      const shared = { ...inputs, forkEvents: createForkEventResolver(inputs.taskById, inputs.allEventsByTaskId) };
      const credits = resolveContributionCredits(task, inputs);
      expect(resolveContributionCredits(task, shared)).toEqual(credits);
      expect(resolveContributionCredits(task, inputs, null)).toEqual([]);
      if (task.countsTowardCounterId == null) continue; // unflagged: nothing on its own root; an explicit root still keys its occurrences
      const onOther = resolveContributionCredits(task, inputs, 'root2');
      const occurrences = (rows: typeof credits): string[] => rows.map((c) => JSON.stringify([c.occurrence, c.occurredAt])).sort();
      expect(occurrences(onOther)).toEqual(occurrences(credits));
      for (const c of onOther) expect(c.rootId).toBe('root2');
    }
  });
});

describe('countsTowardVectors — candidateContributionIds', () => {
  it.each(V.candidates as any[])('$name', (v: any) => {
    const { task, inputs } = toInputs(v);
    const scope = lineageRootId(task, inputs.taskById);
    const expected = [...new Set((v.expected as any[]).map((e) => countsTowardEventId(e.root ?? 'root', scope, e.occurrence ?? e)))].sort();
    expect(candidateContributionIds(task, inputs, v.roots)).toEqual(expected);
  });
});

describe('countsTowardVectors — lineageCreditDelta', () => {
  it.each(V.lineageDelta as any[])('$name', (v: any) => {
    expect(lineageCreditDelta(v.root, (v.members as MiniTask[]).map(toTask), v.lineageRoot)).toBe(v.expected);
  });
});

describe('fork lineage', () => {
  const o = toTask({ id: 'o' });
  const f1 = toTask({ id: 'f1', forkedFromTaskId: 'o' });
  const f2 = toTask({ id: 'f2', forkedFromTaskId: 'f1' });
  const g1 = toTask({ id: 'g1', forkedFromTaskId: 'o' });
  const orphan = toTask({ id: 'orphan', forkedFromTaskId: 'missing' });
  const taskById = { o, f1, f2, g1, orphan };

  it('canonicalOccurrenceEventId walks a fork-of-a-fork back to the source event; an unknown ancestor or a non-copied event stays itself', () => {
    const e = toEvent({ id: 'e', taskId: 'o', occurredAt: T0 }, 0);
    const e1 = { ...e, id: forkedEventId('f1', 'e'), taskId: 'f1' };
    const e2 = { ...e, id: forkedEventId('f2', e1.id), taskId: 'f2' };
    const own = toEvent({ id: 'own', taskId: 'f1', occurredAt: T0 }, 1);
    const all = { o: [e], f1: [e1, own], f2: [e2] };
    expect(canonicalOccurrenceEventId(e2.id, f2, taskById, all)).toBe('e');
    expect(canonicalOccurrenceEventId(e1.id, f1, taskById, all)).toBe('e');
    expect(canonicalOccurrenceEventId('own', f1, taskById, all)).toBe('own');
    expect(canonicalOccurrenceEventId('e', o, taskById, all)).toBe('e');
    expect(canonicalOccurrenceEventId('x', orphan, taskById, all)).toBe('x');
  });

  it('lineageRootId is the top of the loaded chain; isForkLineageLoaded is false while an ancestor is missing', () => {
    expect(lineageRootId(f2, taskById)).toBe('o');
    expect(lineageRootId(g1, taskById)).toBe('o');
    expect(lineageRootId(o, taskById)).toBe('o');
    expect(lineageRootId(orphan, taskById)).toBe('orphan');
    expect(isForkLineageLoaded(f2, taskById)).toBe(true);
    expect(isForkLineageLoaded(o, taskById)).toBe(true);
    expect(isForkLineageLoaded(orphan, taskById)).toBe(false);
    expect(isForkLineageLoaded(f2, { f2, f1 })).toBe(false);
    const compoundKey: ContributionOccurrence = { kind: 'childEvent', eventId: 'e' };
    expect(countsTowardEventId('r', lineageRootId(f2, taskById), compoundKey)).toBe(countsTowardEventId('r', 'o', compoundKey));
    expect(countsTowardEventId('r', 'o', compoundKey)).not.toBe(countsTowardEventId('r', 'p', compoundKey));
  });

  it('forkLineageIds reaches ancestors, descendants and siblings, excluding the task itself', () => {
    const index = buildForkChildrenIndex(Object.values(taskById));
    expect(forkLineageIds('o', taskById, index)).toEqual(['f1', 'f2', 'g1']);
    expect(forkLineageIds('f2', taskById, index)).toEqual(['f1', 'g1', 'o']);
    expect(forkLineageIds('g1', taskById, index)).toEqual(['f1', 'f2', 'o']);
    expect(forkLineageIds('orphan', taskById, index)).toEqual([]);
    expect(forkLineageIds('lone', taskById, index)).toEqual([]);
  });
});

describe('countsTowardVectors — planCountsTowardActions', () => {
  it.each(V.planSet as any[])('$name', (v: any) => {
    const contributor = toTask(v.contributor);
    const tasks = (v.tasks as MiniTask[]).map(toTask);
    const taskById = Object.fromEntries([...tasks, contributor].map((t) => [t.id, t]));
    const idOf = (o: ContributionOccurrence, root = 'root'): string => countsTowardEventId(root, contributor.id, o);
    const wanted = (v.wanted as any[]).map((w) => ({ eventId: idOf(w.occurrence, w.root), rootId: w.root ?? 'root', occurrence: w.occurrence, occurredAt: w.occurredAt }));
    const candidates = (v.candidates as any[]).map((c) => idOf(c.occurrence, c.root));
    const storedById: Record<string, TaskEvent> = {};
    for (const s of v.stored as any[]) {
      const id = idOf(s.occurrence, s.taskId);
      storedById[id] = toEvent({ id, taskId: s.taskId, delta: s.delta, occurredAt: s.occurredAt, isDeleted: s.isDeleted }, 0);
    }
    const lineage = {
      wantedIds: new Set(((v.lineageWanted ?? []) as any[]).map((c) => idOf(c.occurrence, c.root))),
      ...(v.lineageDelta ? { deltaForRoot: (rootId: string) => v.lineageDelta[rootId] ?? countsTowardAmountOf(contributor) } : {}),
    };
    const expected = byId((v.expected as any[]).map(({ occurrence, root, ...rest }) => ({ eventId: idOf(occurrence, root), ...rest })));
    expect(planCountsTowardActions(contributor, taskById, wanted, candidates, storedById, lineage)).toEqual(expected);
  });
});

describe('isOccurrenceWanted / keptCreditIdsFor (D11)', () => {
  it('no since → every occurrence; a since bounds by parsed instant; unparseable since is no bound; unparseable instant is never wanted', () => {
    expect(isOccurrenceWanted({ countsTowardSince: undefined }, { occurredAt: T0 })).toBe(true);
    expect(isOccurrenceWanted({ countsTowardSince: '2026-10-10T00:00:00.000Z' }, { occurredAt: '2026-10-09T23:59:59.999Z' })).toBe(false);
    expect(isOccurrenceWanted({ countsTowardSince: '2026-10-10T00:00:00.000Z' }, { occurredAt: '2026-10-10T00:00:00.000Z' })).toBe(true);
    expect(isOccurrenceWanted({ countsTowardSince: 'garbage' }, { occurredAt: T0 })).toBe(true);
    expect(isOccurrenceWanted({ countsTowardSince: '2026-10-10T00:00:00.000Z' }, { occurredAt: 'garbage' })).toBe(false);
  });

  it('keptCreditIdsFor applies the flag, the target and since; a counter root / unflagged / deleted member keeps nothing', () => {
    const root = toTask({ id: 'root', type: 'counting', isCounter: true });
    const t = toTask({ id: 't', countsTowardCounterId: 'root', countsTowardSince: '2026-10-10T00:00:00.000Z' });
    const events = [toEvent({ id: 'c1', taskId: 't', occurredAt: '2026-10-07T00:00:00.000Z' }, 0), toEvent({ id: 'c2', taskId: 't', occurredAt: '2026-10-14T00:00:00.000Z' }, 1)];
    const base: ContributionInputs = {
      taskById: { root, t },
      childrenByCompound: {},
      eventsByTaskId: { t: events },
      allEventsByTaskId: { t: events },
      placements: [],
      boardById: {},
    };
    expect(keptCreditIdsFor(t, base)).toEqual([countsTowardEventId('root', 't', { kind: 'event', eventId: 'c2' })]);
    expect(keptCreditIdsFor({ ...t, countsTowardCounterId: undefined }, base)).toEqual([]);
    expect(keptCreditIdsFor({ ...t, isDeleted: true }, base)).toEqual([]);
    expect(keptCreditIdsFor({ ...t, countsTowardCounterId: 'missing' }, base)).toEqual([]);
    expect(keptCreditIdsFor(root, base)).toEqual([]);
  });
});

describe('canContribute', () => {
  it('counter roots, linked copies and achievements never contribute', () => {
    expect(canContribute(toTask({ id: 'a' }))).toBe(true);
    expect(canContribute(toTask({ id: 'a', type: 'counting' }))).toBe(true);
    expect(canContribute(toTask({ id: 'a', type: 'counting', isCounter: true }))).toBe(false);
    expect(canContribute(toTask({ id: 'a', type: 'counting', sharedCounterId: 'r' }))).toBe(false);
    expect(canContribute(toTask({ id: 'a', type: 'achievement' }))).toBe(false);
  });
});

describe('isCreditWriteSealSuppressed (D11)', () => {
  const windows = buildSealImmuneWindows([{ startDate: '2026-10-05T00:00:00.000Z', endDate: '2026-10-11T23:59:59.999Z', sealedAt: '2026-10-12T00:00:01.000Z' }]);
  const inside = '2026-10-07T09:00:00.000Z';
  const alsoInside = '2026-10-09T09:00:00.000Z';
  const outside = '2026-10-14T09:00:00.000Z';
  const now = '2026-10-20T00:00:00.000Z';

  it('skips an insert / tombstone whose instant sits in a sealed window of the root; only the late-logged instant itself is exempt', () => {
    const insert = { kind: 'insert' as const, eventId: 'x', rootId: 'root', delta: 1, occurredAt: inside };
    expect(isCreditWriteSealSuppressed(insert, { root: windows }, now, null)).toBe(true);
    expect(isCreditWriteSealSuppressed(insert, { root: windows }, now, inside)).toBe(false);
    expect(isCreditWriteSealSuppressed(insert, { root: windows }, now, alsoInside)).toBe(true);
    expect(isCreditWriteSealSuppressed({ ...insert, occurredAt: outside }, { root: windows }, now, null)).toBe(false);
    expect(isCreditWriteSealSuppressed(insert, { other: windows }, now, null)).toBe(false);
    expect(isCreditWriteSealSuppressed({ kind: 'tombstone', eventId: 'x', rootId: 'root', occurredAt: inside }, { root: windows }, now, null)).toBe(true);
  });

  it('a revise is skipped when EITHER its new instant on the new root or its previous instant on the previous root is sealed', () => {
    const revise = {
      kind: 'revise' as const,
      eventId: 'x',
      rootId: 'root2',
      delta: 1,
      occurredAt: outside,
      previousRootId: 'root',
      previousOccurredAt: inside,
      wasDeleted: false,
    };
    expect(isCreditWriteSealSuppressed(revise, { root: windows }, now, null)).toBe(true);
    expect(isCreditWriteSealSuppressed(revise, { root2: windows }, now, null)).toBe(false);
    expect(isCreditWriteSealSuppressed({ ...revise, occurredAt: inside }, { root2: windows }, now, null)).toBe(true);
    expect(isCreditWriteSealSuppressed(revise, { root: windows }, now, inside)).toBe(false);
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
  const SINCE = '2026-10-10T00:00:00.000Z';
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

  it('accepts a contributor with a counter, a since and an amount', () => {
    expect(TaskSchema.safeParse({ ...base, countsTowardCounterId: ROOT, countsTowardSince: SINCE, countsTowardAmount: 3 }).success).toBe(true);
    expect(TaskSchema.safeParse({ ...base, countsTowardCounterId: null }).success).toBe(true);
  });

  it('since travels with the flag (D11): neither without the other', () => {
    expect(TaskSchema.safeParse({ ...base, countsTowardCounterId: ROOT }).success).toBe(false);
    expect(TaskSchema.safeParse({ ...base, countsTowardSince: SINCE }).success).toBe(false);
    expect(TaskSchema.safeParse({ ...base, countsTowardCounterId: ROOT, countsTowardSince: 'not-a-date' }).success).toBe(false);
  });

  it('refuses counting toward itself', () => {
    expect(TaskSchema.safeParse({ ...base, countsTowardCounterId: base.id, countsTowardSince: SINCE }).success).toBe(false);
  });

  it('refuses a hub counter, a linked copy or an achievement as a contributor', () => {
    expect(TaskSchema.safeParse({ ...base, type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 3, isCounter: true, countsTowardCounterId: ROOT, countsTowardSince: SINCE }).success).toBe(false);
    expect(
      TaskSchema.safeParse({ ...base, type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 3, sharedCounterId: '00000000-0000-4000-8000-0000000000c2', baseline: 0, countsTowardCounterId: ROOT, countsTowardSince: SINCE }).success,
    ).toBe(false);
    expect(
      TaskSchema.safeParse({ ...base, type: TaskType.ACHIEVEMENT, referencedBoardId: '00000000-0000-4000-8000-0000000000b1', countsTowardCounterId: ROOT, countsTowardSince: SINCE }).success,
    ).toBe(false);
  });

  it('refuses a non-positive or fractional amount', () => {
    expect(TaskSchema.safeParse({ ...base, countsTowardCounterId: ROOT, countsTowardSince: SINCE, countsTowardAmount: 0 }).success).toBe(false);
    expect(TaskSchema.safeParse({ ...base, countsTowardCounterId: ROOT, countsTowardSince: SINCE, countsTowardAmount: 1.5 }).success).toBe(false);
  });
});
