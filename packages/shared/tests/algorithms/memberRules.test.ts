/**
 * memberRules.test.ts — Board Sources §Member rules (B1).
 *
 * Vector-pinned suite for the pure member-rule helpers. Every expectation
 * lives in `tests/fixtures/memberRuleVectors.json` (hand-computed, never
 * generated from the code under test) so the Swift twin can assert the
 * identical numbers against the byte-identical iOS fixture copy.
 */
import fs from 'fs';
import path from 'path';
import { makeSeededRng } from '../../../bingo-core/tests/seededRng';
import { Timeframe, TaskType } from '../../src/constants/enums';
import {
  nominalWindowDays,
  autoTarget,
  varyRange,
  rollTarget,
  applyMemberRules,
  planDerivedTasks,
} from '../../src/algorithms/memberRules';
import type { VaryLevel, BoardSource } from '../../src/types';

const V: any = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'memberRuleVectors.json'), 'utf8')
);

type ChildRow = { childTaskId: string; childIndex: number };

/**
 * Fixture `children` entries are either a bare childTaskId (childIndex = its
 * array position) or an explicit `{ childTaskId, childIndex }` pair — the
 * object form lets a vector put childIndex deliberately out of array order.
 */
const buildChildren = (raw: Record<string, unknown>): Record<string, ChildRow[]> =>
  Object.fromEntries(
    Object.entries(raw).map(([compoundId, kids]) => [
      compoundId,
      (kids as unknown[]).map((k, i) =>
        typeof k === 'string' ? { childTaskId: k, childIndex: i } : (k as ChildRow)
      ),
    ])
  );

const src = (i: number, kind: 'pool' | 'board', memberRules: BoardSource['memberRules']): BoardSource => ({
  sourceId: `s${i}`,
  kind,
  min: 0,
  max: null,
  excludedTaskIds: [],
  filter: 'all',
  ...(memberRules && Object.keys(memberRules).length ? { memberRules } : {}),
});

describe('nominalWindowDays', () => {
  it.each(V.windowDays as any[])('$name', (v: any) => {
    expect(nominalWindowDays(v.timeframe as Timeframe, v.startDate ?? null, v.endDate ?? null)).toBe(
      v.expected
    );
  });
});

describe('autoTarget', () => {
  it.each(V.autoTarget as any[])('$name', (v: any) => {
    expect(autoTarget(v.goal, v.sourceDays, v.targetDays, v.countKind ?? 'discrete')).toBe(v.expected);
  });
});

describe('varyRange', () => {
  it.each(V.varyRange as any[])('$name', (v: any) => {
    expect(varyRange(v.t, v.level as VaryLevel, v.goal, v.countKind ?? 'discrete')).toEqual(v.expected);
  });
});

describe('rollTarget', () => {
  it.each(V.rollTarget as any[])('$name', (v: any) => {
    const rng =
      v.seed === null
        ? () => {
            throw new Error('rng must not be called');
          }
        : makeSeededRng(v.seed);
    let calls = 0;
    const counted = () => {
      calls += 1;
      return rng();
    };
    expect(rollTarget(v.t, v.level as VaryLevel, v.goal, counted, v.countKind ?? 'discrete')).toBe(
      v.expected
    );
    // Exactly one sample on a real roll, none on level 0 / a degenerate range.
    expect(calls).toBe(v.seed === null ? 0 : 1);
  });
});

describe('applyMemberRules', () => {
  const F = V.applyMemberRules;
  const tasksById: Record<string, { id: string; type: TaskType }> = Object.fromEntries(
    Object.entries(F.tasks).map(([id, t]) => [id, { id, type: t as TaskType }])
  );
  const childrenByCompoundId = buildChildren(F.children);

  it.each(F.vectors as any[])('$name', (v: any) => {
    const out = applyMemberRules(
      [{ source: src(1, 'board', v.memberRules), supplyTaskIds: v.supply }],
      childrenByCompoundId,
      tasksById
    );
    expect(out).toHaveLength(1);
    expect(out[0].supplyTaskIds).toEqual(v.expected);
    expect(out[0].partOf).toEqual(v.expectedPartOf);
    expect(out[0].source.sourceId).toBe('s1');
  });

  it('carries a board source\'s goalByTaskId through the expansion (slice 3a)', () => {
    const out = applyMemberRules(
      [{ source: src(1, 'board', {}), supplyTaskIds: ['r1'], goalByTaskId: { r1: 70 } }],
      {},
      { r1: { id: 'r1', type: TaskType.COUNTING } },
    );
    expect(out[0].goalByTaskId).toEqual({ r1: 70 });
    expect(out[0].supplyTaskIds).toEqual(['r1']);
  });
});

describe('planDerivedTasks', () => {
  const P = V.planDerivedTasks;
  const tasksById: Record<string, any> = Object.fromEntries(
    Object.entries(P.tasks).map(([id, t]: [string, any]) => [
      id,
      { id, ...t, sharedCounterId: t.sharedCounterId ?? null, startDate: t.startDate ?? undefined },
    ])
  );
  const childrenByCompoundId = buildChildren(P.children);
  const win = (tf: string) => ({ timeframe: tf as Timeframe, startDate: null, endDate: null });
  const sourceWindowByTaskId = Object.fromEntries(
    Object.entries(P.sourceWindows).map(([id, tf]) => [id, win(tf as string)])
  );

  it.each(P.vectors as any[])('$name', (v: any) => {
    const supplies = v.supplies.map((s: any, i: number) => ({
      source: src(i + 1, s.kind, s.memberRules),
      supplyTaskIds: s.supply,
      partOf: s.partOf ?? {},
      ...(s.goalByTaskId ? { goalByTaskId: s.goalByTaskId } : {}),
    }));
    const seeded = makeSeededRng(v.seed);
    let rngCalls = 0;
    const rng = () => {
      rngCalls += 1;
      return seeded();
    };
    const out = planDerivedTasks({
      selectedIds: v.selected,
      supplies,
      manualTaskIds: v.manual,
      manualTaskVary: v.manualTaskVary,
      window: v.window ?? P.window,
      mode: v.mode,
      tasksById,
      childrenByCompoundId,
      sourceWindowByTaskId,
      rng,
    });

    if (v.expectedRngCalls !== undefined) expect(rngCalls).toBe(v.expectedRngCalls);
    // Slice 3b: the planner emits one placement per selected id — compared whole.
    expect(out.placements).toHaveLength(v.selected.length);
    expect(JSON.parse(JSON.stringify(out.placements))).toEqual(v.expected.placements);
    // A placement's override always carries its kind, and never equals the placed task's own goal.
    for (const p of out.placements) {
      if (p.targetOverride !== undefined) {
        expect(p.targetKind).toBeDefined();
        expect(p.targetOverride).not.toBe(tasksById[p.taskId]?.maxCount);
      } else {
        expect(p.targetKind).toBeUndefined();
      }
    }
  });
});
