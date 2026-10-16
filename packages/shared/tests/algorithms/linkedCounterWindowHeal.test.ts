/**
 * linkedCounterWindowHeal.test.ts — windowed linked counters (owner rule
 * 2026-10-01).
 *
 * Vector-pinned suite for the pure heal planner, the placement gate and the
 * copy-draft builder. Every expectation lives in
 * `tests/fixtures/linkedCounterWindowHealVectors.json` (hand-computed, never
 * generated from the code under test) so the Swift twin
 * (`LinkedCounterWindowHealVectorTests`) asserts the identical plan against
 * the byte-identical iOS fixture copy.
 */
import fs from 'fs';
import path from 'path';
import { Timeframe } from '../../src/constants/enums';
import {
  sameWindowStart,
  isWindowStampedForBoard,
  planLinkedCounterWindowHeal,
  windowStampedCopyDraft,
} from '../../src/algorithms/linkedCounterWindowHeal';
import type {
  LinkedCounterWindowHealInput,
  LinkedCounterWindowHealPlan,
} from '../../src/algorithms/linkedCounterWindowHeal';
import { derivedTaskId } from '../../src/algorithms/memberRules';

const V: any = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'linkedCounterWindowHealVectors.json'), 'utf8')
);

/** Fixture `null` → the model's absent field. */
const orUndef = <T>(x: T | null): T | undefined => (x === null ? undefined : x);

type HealTask = LinkedCounterWindowHealInput['tasks'][number];
type HealBoard = LinkedCounterWindowHealInput['boards'][number];

const toTask = (t: any): HealTask => ({
  id: t.id,
  type: t.type,
  sharedCounterId: t.sharedCounterId,
  startDate: orUndef(t.startDate),
  endDate: orUndef(t.endDate),
  timeframe: orUndef(t.timeframe) as Timeframe | undefined,
  createdInWizard: t.createdInWizard,
  isDeleted: t.isDeleted,
  maxCount: orUndef(t.maxCount),
});
const toBoard = (b: any): HealBoard => ({
  id: b.id,
  timeframe: b.timeframe,
  startDate: b.startDate,
  endDate: orUndef(b.endDate),
  isDeleted: b.isDeleted,
});

const toInput = (v: any, sharedBoards: any[]): LinkedCounterWindowHealInput => ({
  tasks: v.tasks.map(toTask),
  boardTasks: v.boardTasks,
  boards: (v.boards ?? sharedBoards).map(toBoard),
  compoundChildren: v.compoundChildren,
});

describe('sameWindowStart', () => {
  it.each(V.sameWindowStart as any[])('$name', (v: any) => {
    expect(sameWindowStart(v.a, v.b)).toBe(v.expected);
  });
});

describe('isWindowStampedForBoard', () => {
  it.each(V.isWindowStampedForBoard as any[])('$name', (v: any) => {
    expect(
      isWindowStampedForBoard(
        { sharedCounterId: v.task.sharedCounterId, startDate: orUndef(v.task.startDate), createdInWizard: v.task.createdInWizard },
        { startDate: v.board.startDate }
      )
    ).toBe(v.expected);
  });
});

describe('planLinkedCounterWindowHeal', () => {
  const P = V.planLinkedCounterWindowHeal;

  it('fixture section is non-trivial', () => {
    expect(P.vectors.length).toBeGreaterThanOrEqual(20);
    expect(P.vectors.some((v: any) => v.expected.copies.length > 0)).toBe(true);
    // The all-or-nothing veto: a PLACED unstamped row that is left alone.
    expect(
      P.vectors.some(
        (v: any) =>
          v.boardTasks.length > 0 &&
          v.tasks.some((t: any) => t.sharedCounterId && !t.createdInWizard) &&
          v.expected.stamps.length === 0 &&
          v.expected.copies.length === 0
      )
    ).toBe(true);
    // A mis-placed window-stamped row: copies with no stamp.
    expect(
      P.vectors.some((v: any) => v.expected.stamps.length === 0 && v.expected.copies.length > 0)
    ).toBe(true);
    // A stamped compound member: its stamp is cleared (2026-10-16).
    expect(P.vectors.some((v: any) => v.expected.unstamps.length > 0)).toBe(true);
  });

  it.each(P.vectors as any[])('$name', (v: any) => {
    const plan = planLinkedCounterWindowHeal(toInput(v, P.boards));
    expect(plan).toEqual(v.expected as LinkedCounterWindowHealPlan);
    // The pinned copy ids are literal uuidv5 outputs; they must also be the
    // id the wizard / spawn would mint for the same (board, root) pair.
    for (const c of plan.copies) {
      expect(c.id).toBe(derivedTaskId(c.boardId, c.rootTaskId));
    }
  });

  it('is idempotent once applied: stamping the first board and repointing the copied placements leaves nothing to plan', () => {
    const v = P.vectors.find((x: any) => x.name.startsWith('two direct placements'));
    expect(v).toBeDefined();
    const input = toInput(v, P.boards);
    const plan = planLinkedCounterWindowHeal(input);
    expect(plan.stamps).toHaveLength(1);
    expect(plan.copies).toHaveLength(1);

    // Simulate the platform apply: the stamp sets the window + createdInWizard
    // on the row; each copy becomes a window-stamped row and its placement is
    // repointed at it.
    const tasks: HealTask[] = input.tasks.map((t) => {
      const s = plan.stamps.find((x) => x.taskId === t.id);
      return s
        ? { ...t, timeframe: s.timeframe, startDate: s.startDate, endDate: orUndef(s.endDate), createdInWizard: true }
        : t;
    });
    for (const c of plan.copies) {
      tasks.push({
        id: c.id,
        type: 'counting' as HealTask['type'],
        sharedCounterId: c.rootTaskId,
        startDate: c.startDate,
        endDate: orUndef(c.endDate),
        timeframe: c.timeframe,
        createdInWizard: true,
        isDeleted: false,
        maxCount: 5,
      });
    }
    const boardTasks = input.boardTasks.map((bt) => {
      const c = plan.copies.find((x) => x.boardTaskId === bt.id);
      return c ? { ...bt, taskId: c.id } : bt;
    });
    expect(planLinkedCounterWindowHeal({ ...input, tasks, boardTasks })).toEqual({ stamps: [], copies: [], unstamps: [] });
  });

  it('is idempotent for a mis-placed window-stamped row: repointing the placement at the minted copy leaves nothing to plan', () => {
    const v = P.vectors.find((x: any) => x.name.startsWith('window-stamped for February placed on March only'));
    expect(v).toBeDefined();
    const input = toInput(v, P.boards);
    const plan = planLinkedCounterWindowHeal(input);
    expect(plan.stamps).toEqual([]);
    expect(plan.copies).toHaveLength(1);

    const tasks: HealTask[] = [...input.tasks];
    for (const c of plan.copies) {
      tasks.push({
        id: c.id,
        type: 'counting' as HealTask['type'],
        sharedCounterId: c.rootTaskId,
        startDate: c.startDate,
        endDate: orUndef(c.endDate),
        timeframe: c.timeframe,
        createdInWizard: true,
        isDeleted: false,
        maxCount: 5,
      });
    }
    const boardTasks = input.boardTasks.map((bt) => {
      const c = plan.copies.find((x) => x.boardTaskId === bt.id);
      return c ? { ...bt, taskId: c.id } : bt;
    });
    expect(planLinkedCounterWindowHeal({ ...input, tasks, boardTasks })).toEqual({ stamps: [], copies: [], unstamps: [] });
  });
});

describe('incident 2026-10-16: a linked sub-task of a compound on a daily series', () => {
  // The same compound (and the same hub-linked child) is placed on every
  // daily spawn. The old planner stamped the child with the FIRST day's
  // window ("reached-only single board → stamp"), so every later board read
  // it over Oct 13 — 0 of 10 after a 26-mile log on Oct 16 — and the
  // propagation freeze skipped it. A member is now never stamped, and the
  // kernel resolves it over each host board's own window.
  const oct13 = { id: 'd13', timeframe: 'daily', startDate: '2026-10-13T00:00:00', endDate: '2026-10-13T23:59:59.999', isDeleted: false };
  const oct16 = { id: 'd16', timeframe: 'daily', startDate: '2026-10-16T00:00:00', endDate: '2026-10-16T23:59:59.999', isDeleted: false };
  const child: HealTask = { id: 'bike', type: 'counting' as any, sharedCounterId: 'root', createdInWizard: true, isDeleted: false, maxCount: 10 };
  const compound: HealTask = { id: 'biking', type: 'compound' as any, sharedCounterId: undefined, createdInWizard: true, isDeleted: false };
  const root: HealTask = { id: 'root', type: 'counting' as any, sharedCounterId: undefined, createdInWizard: false, isDeleted: false };
  const input = (boards: HealBoard[]): LinkedCounterWindowHealInput => ({
    tasks: [child, compound, root],
    boards,
    boardTasks: boards.map((b) => ({ id: `bt-${b.id}`, boardId: b.id, taskId: 'biking', isDeleted: false })),
    compoundChildren: [{ compoundTaskId: 'biking', childTaskId: 'bike', isDeleted: false }],
  });

  it('leaves the child hub-linked on day 1 and on every later spawn', () => {
    expect(planLinkedCounterWindowHeal(input([oct13 as HealBoard]))).toEqual({ stamps: [], copies: [], unstamps: [] });
    expect(planLinkedCounterWindowHeal(input([oct13, oct16] as HealBoard[]))).toEqual({ stamps: [], copies: [], unstamps: [] });
  });

  it('un-stamps a child an earlier heal pinned to day 1', () => {
    const pinned: HealTask = { ...child, timeframe: Timeframe.DAILY, startDate: oct13.startDate, endDate: oct13.endDate };
    const plan = planLinkedCounterWindowHeal({ ...input([oct13, oct16] as HealBoard[]), tasks: [pinned, compound, root] });
    expect(plan).toEqual({ stamps: [], copies: [], unstamps: [{ taskId: 'bike' }] });
  });
});

describe('windowStampedCopyDraft', () => {
  it.each(V.windowStampedCopyDraft as any[])('$name', (v: any) => {
    const draft = windowStampedCopyDraft(
      v.copy,
      {
        title: v.sourceTask.title,
        action: orUndef(v.sourceTask.action),
        unit: orUndef(v.sourceTask.unit),
        maxCount: orUndef(v.sourceTask.maxCount),
        countKind: orUndef(v.sourceTask.countKind),
      },
      v.baseline
    );
    expect(draft).toEqual(v.expected);
  });
});
