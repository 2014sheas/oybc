import * as fs from 'fs';
import * as path from 'path';
import {
  counterSearchMatches,
  counterTimeframeDefault,
  normalizeSearchText,
  placementGoalForCounter,
  placementNeedsCopy,
  taskSearchMatches,
} from '../../src/algorithms/counterPlacement';
import { counterCopyTitle, generateCounterTaskTitle } from '../../src/algorithms/taskTitle';
import { derivedTaskId, planDerivedTasks } from '../../src/algorithms/memberRules';
import { windowStampedCopyDraft } from '../../src/algorithms/linkedCounterWindowHeal';
import { effectiveMemberTarget } from '../../src/algorithms/memberRulesDisplay';
import type { Timeframe } from '../../src/constants/enums';

const V = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'counterPlacementVectors.json'), 'utf8')
);

/**
 * Vector pins for `counterPlacement.ts` ↔ iOS `CounterPlacement.swift`
 * (`CounterPlacementVectorTests`) — docs/SHARED_COUNTER_SETTINGS.md §2.
 */

describe('counterPlacementVectors — counterTimeframeDefault', () => {
  it.each(V.counterTimeframeDefault as any[])('$name', (v: any) => {
    expect(counterTimeframeDefault(v.root, v.timeframe)).toBe(v.expected);
  });
});

describe('counterPlacementVectors — placementGoalForCounter', () => {
  it.each(V.placementGoalForCounter as any[])('$name', (v: any) => {
    expect(placementGoalForCounter(v.root, v.board, v.existingCopy)).toBe(v.expected);
  });
});

describe('counterPlacementVectors — placementNeedsCopy', () => {
  it('pins both outcomes', () => {
    expect(new Set((V.placementNeedsCopy as any[]).map((v) => v.expected))).toEqual(new Set([true, false]));
  });
  it.each(V.placementNeedsCopy as any[])('$name', (v: any) => {
    expect(placementNeedsCopy(v.root, v.board)).toBe(v.expected);
  });
});

describe('counterPlacementVectors — counterSearchMatches', () => {
  it('pins both outcomes', () => {
    expect(new Set((V.counterSearchMatches as any[]).map((v) => v.expected))).toEqual(new Set([true, false]));
  });
  it.each(V.counterSearchMatches as any[])('$name', (v: any) => {
    expect(counterSearchMatches(v.query, v.root)).toBe(v.expected);
  });
});

describe('counterPlacementVectors — taskSearchMatches', () => {
  it.each(V.taskSearchMatches as any[])('$name', (v: any) => {
    expect(taskSearchMatches(v.query, v.task)).toBe(v.expected);
  });
});

describe('counterPlacementVectors — counterCopyTitle with the root settings', () => {
  it.each(V.counterCopyTitleWithRoot as any[])('$name', (v: any) => {
    expect(counterCopyTitle(v.member, v.newMaxCount, v.root)).toBe(v.expected);
  });
});

describe('normalizeSearchText', () => {
  it('folds diacritics, case and whitespace', () => {
    expect(normalizeSearchText('  Crème   BRÛLÉE ')).toBe('creme brulee');
    expect(normalizeSearchText(null)).toBe('');
  });
});

describe('counterPlacementVectors — planDerivedTasks (placement defaults)', () => {
  const P = V.planDerivedTasks;
  const tasksById: Record<string, any> = Object.fromEntries(
    Object.entries(P.tasks).map(([id, t]: [string, any]) => [id, { id, sharedCounterId: null, ...t }])
  );
  const win = (tf: string) => ({ timeframe: tf as Timeframe, startDate: null, endDate: null });
  const resolve = (token: string): string =>
    token.startsWith('derived:') ? derivedTaskId(P.boardId, token.slice('derived:'.length)) : token;

  it.each(P.vectors as any[])('$name', (v: any) => {
    const out = planDerivedTasks({
      selectedIds: v.selected,
      supplies: v.supplies.map((s: any, i: number) => ({
        source: {
          sourceId: `s${i}`,
          kind: s.kind,
          min: 0,
          max: null,
          excludedTaskIds: [],
          filter: 'all',
          ...(s.memberRules ? { memberRules: s.memberRules } : {}),
        },
        supplyTaskIds: s.supply,
        partOf: {},
      })),
      manualTaskIds: v.manual,
      manualTaskVary: {},
      boardId: P.boardId,
      window: win(v.window),
      mode: 'oneOff',
      tasksById,
      childrenByCompoundId: {},
      sourceWindowByTaskId: Object.fromEntries(
        Object.entries(P.sourceWindows).map(([id, tf]) => [id, win(tf as string)])
      ),
      baselineByRootId: {},
      rootsById: tasksById,
      rng: () => {
        throw new Error('vary is off — no rng');
      },
    });
    expect(out.placementIds).toEqual(v.expected.placement.map(resolve));
    expect(out.derivedTasks.map((d) => ({ root: d.rootTaskId, maxCount: d.maxCount, title: d.title }))).toEqual(
      v.expected.drafts
    );
  });
});

describe('windowStampedCopyDraft — root settings + placement goal', () => {
  const copy = {
    id: 'cp',
    boardId: 'b',
    boardTaskId: '',
    sourceTaskId: 'L',
    rootTaskId: 'T',
    timeframe: 'weekly' as Timeframe,
    startDate: '2026-10-05T00:00:00',
    endDate: '2026-10-11T23:59:59',
  };
  const source = { title: 'Read 5 books', action: 'Read', unit: 'books', maxCount: 5 };

  it('renders the title through the root templates at the placement goal', () => {
    const d = windowStampedCopyDraft(copy, source, 0, {
      settings: { titleTemplatePlural: 'Finish #N novels' },
      maxCount: 3,
    });
    expect(d?.maxCount).toBe(3);
    expect(d?.title).toBe('Finish 3 novels');
  });

  it('without options behaves exactly as before', () => {
    const d = windowStampedCopyDraft(copy, source, 0);
    expect(d?.maxCount).toBe(5);
    expect(d?.title).toBe('Read 5 books');
  });

  it('a goal-less source takes the placement goal', () => {
    const d = windowStampedCopyDraft(copy, { ...source, maxCount: undefined, title: 'Read books' }, 0, { maxCount: 4 });
    expect(d?.maxCount).toBe(4);
    expect(d?.title).toBe('Read 4 books');
  });
});

describe('counterPlacementVectors — effectiveMemberTarget consults the default', () => {
  const win = (tf: string) => ({ timeframe: tf as Timeframe, startDate: null, endDate: null });
  it.each(V.effectiveMemberTarget as any[])('$name', (v: any) => {
    expect(
      effectiveMemberTarget({
        goal: v.goal,
        explicit: v.explicit,
        mode: 'recurring',
        fromBoard: v.fromBoard,
        sourceWindow: win(v.sourceWindow),
        targetWindow: win(v.targetWindow),
        timeframeDefault: v.timeframeDefault,
      })
    ).toBe(v.expected);
  });
});

describe('counterPlacementVectors — generateCounterTaskTitle with the root settings', () => {
  it.each(V.generateCounterTaskTitleWithSettings as any[])('$name', (v: any) => {
    expect(
      generateCounterTaskTitle(v.action, v.maxCount, v.unit, v.providedTitle, v.countKind ?? 'discrete', v.settings)
    ).toBe(v.expected);
  });
});
