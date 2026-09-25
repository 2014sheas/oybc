import { describe, expect, it } from 'vitest';
import {
  TaskType,
  Timeframe,
  memberRuleFor,
  partRuleFor,
  type BoardSource,
  type BoardWindow,
  type Task,
} from '@oybc/shared';
import {
  canApplyTaskToggle,
  canDeselectFromSources,
  canSetPartExcluded,
  includedPartIds,
  initialPrefilledSourceIds,
  prefillRemainingTargets,
  pruneManualVary,
  pruneRulesForExcludedMember,
  withManualVary,
  withMemberRuleInSource,
  withPartRuleInSource,
} from '../wizardMemberRulesLogic';
import { algorithmSupplies, type SupplyInfoMap, type WizardSourceSupply } from '../wizardSources';

/**
 * §Member rules (docs/BOARD_SOURCES.md, B3 Task 3 commit 2) — the seven rule
 * actions' pure transitions plus the one-off remaining-target prefill. The
 * hook itself is a thin shell over these (no hook renderer in this repo's
 * node-env Vitest harness), so this is where the behaviour is pinned:
 * default-pruning, the last-part refusal, and the exclusivity rule that
 * drops a member's part rules once the member itself is excluded.
 */

const NOW = '2026-09-18T00:00:00.000Z';

function makeSource(overrides: Partial<BoardSource> & { sourceId: string }): BoardSource {
  return {
    kind: 'board',
    min: 0,
    max: null,
    excludedTaskIds: [],
    filter: 'all',
    ...overrides,
  };
}

function makeTask(id: string, overrides: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'user-1',
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function counter(id: string, goal: number): Task {
  return makeTask(id, { type: TaskType.COUNTING, maxCount: goal, unit: 'reps', action: 'Do' });
}

describe('withMemberRuleInSource (setMemberTarget / setMemberVary / setMemberSplit)', () => {
  it('writes the rule on the named source only', () => {
    const sources = [makeSource({ sourceId: 'b1' }), makeSource({ sourceId: 'b2' })];
    const next = withMemberRuleInSource(sources, 'b1', 't1', { target: 4 });
    expect(memberRuleFor(next[0], 't1').target).toBe(4);
    expect(next[1].memberRules).toBeUndefined();
  });

  it('clearing a target with `undefined` removes the rule entirely (and the key)', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    const withTarget = withMemberRuleInSource(sources, 'b1', 't1', { target: 4 });
    const cleared = withMemberRuleInSource(withTarget, 'b1', 't1', { target: undefined });
    expect(cleared[0].memberRules).toBeUndefined();
  });

  it('vary 0 is the default, so it is stored as an ABSENCE (pruned)', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    const varied = withMemberRuleInSource(sources, 'b1', 't1', { vary: 2 });
    expect(memberRuleFor(varied[0], 't1').vary).toBe(2);
    const off = withMemberRuleInSource(varied, 'b1', 't1', { vary: 0 });
    expect(off[0].memberRules).toBeUndefined();
  });

  it('split false is pruned too, but a target on the same member survives', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    let next = withMemberRuleInSource(sources, 'b1', 'c1', { split: true });
    next = withMemberRuleInSource(next, 'b1', 'c1', { target: 3 });
    next = withMemberRuleInSource(next, 'b1', 'c1', { split: false });
    expect(memberRuleFor(next[0], 'c1')).toEqual({ target: 3 });
  });

  it('never mutates the input sources', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    withMemberRuleInSource(sources, 'b1', 't1', { target: 9 });
    expect(sources[0].memberRules).toBeUndefined();
  });
});

describe('withPartRuleInSource (setPartTarget / setPartVary / setPartExcluded)', () => {
  it('nests the part rule under its parent member', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    const next = withPartRuleInSource(sources, 'b1', 'c1', 'k1', { target: 5 });
    expect(partRuleFor(memberRuleFor(next[0], 'c1'), 'k1').target).toBe(5);
  });

  it('clearing the last part rule collapses `parts`, then the member rule, then `memberRules`', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    const set = withPartRuleInSource(sources, 'b1', 'c1', 'k1', { vary: 1 });
    const cleared = withPartRuleInSource(set, 'b1', 'c1', 'k1', { vary: 0 });
    expect(cleared[0].memberRules).toBeUndefined();
  });

  it('keeps a split parent when one of its parts is cleared', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    let next = withMemberRuleInSource(sources, 'b1', 'c1', { split: true });
    next = withPartRuleInSource(next, 'b1', 'c1', 'k1', { excluded: true });
    next = withPartRuleInSource(next, 'b1', 'c1', 'k1', { excluded: false });
    expect(memberRuleFor(next[0], 'c1')).toEqual({ split: true });
  });
});

describe('canSetPartExcluded (the last-part refusal)', () => {
  const partIds = ['k1', 'k2'];

  it('allows excluding while more than one part is still included', () => {
    expect(canSetPartExcluded({}, partIds, 'k1', true)).toBe(true);
  });

  it('REFUSES excluding the last included part', () => {
    const rule = { split: true, parts: { k1: { excluded: true } } };
    expect(canSetPartExcluded(rule, partIds, 'k2', true)).toBe(false);
  });

  it('always allows un-excluding', () => {
    const rule = { split: true, parts: { k1: { excluded: true }, k2: {} } };
    expect(canSetPartExcluded(rule, partIds, 'k1', false)).toBe(true);
  });

  it('is idempotent for a part that is already excluded', () => {
    const rule = { split: true, parts: { k1: { excluded: true } } };
    expect(canSetPartExcluded(rule, partIds, 'k1', true)).toBe(true);
  });

  it('includedPartIds ignores a stale excluded id the compound no longer has', () => {
    const rule = { split: true, parts: { gone: { excluded: true } } };
    expect(includedPartIds(rule, partIds)).toEqual(['k1', 'k2']);
  });
});

describe('pruneRulesForExcludedMember (RC14 exclusivity)', () => {
  it('drops a split compound’s part rules once the member itself is excluded', () => {
    let sources = [makeSource({ sourceId: 'b1' })];
    sources = withMemberRuleInSource(sources, 'b1', 'c1', { split: true });
    sources = withPartRuleInSource(sources, 'b1', 'c1', 'k1', { excluded: true, target: 2 });
    sources = sources.map((s) => ({ ...s, excludedTaskIds: ['c1'] }));
    const pruned = pruneRulesForExcludedMember(sources, 'b1', 'c1');
    expect(memberRuleFor(pruned[0], 'c1')).toEqual({ split: true });
  });

  it('is a no-op while the member is NOT excluded', () => {
    let sources = [makeSource({ sourceId: 'b1' })];
    sources = withPartRuleInSource(sources, 'b1', 'c1', 'k1', { excluded: true });
    expect(pruneRulesForExcludedMember(sources, 'b1', 'c1')).toBe(sources);
  });

  it('is a no-op for an excluded member that never had part rules', () => {
    const sources = [makeSource({ sourceId: 'b1', excludedTaskIds: ['t1'] })];
    expect(pruneRulesForExcludedMember(sources, 'b1', 't1')).toBe(sources);
  });
});

describe('withManualVary (setManualVary)', () => {
  const c1 = counter('t1', 10);

  it('stores a non-zero level and removes the key at level 0', () => {
    const one = withManualVary({}, 't1', 2, c1);
    expect(one).toEqual({ t1: 2 });
    expect(withManualVary(one, 't1', 0, c1)).toEqual({});
  });

  it('never mutates the input map', () => {
    const base = { t1: 1 as const };
    withManualVary(base, 't2', 2, counter('t2', 4));
    expect(base).toEqual({ t1: 1 });
  });

  it('REFUSES a non-counting task \u2014 the state layer is the guard, not just the UI', () => {
    const normal = makeTask('n1');
    const base = {};
    expect(withManualVary(base, 'n1', 2, normal)).toBe(base);
    expect(withManualVary(base, 'c1', 2, makeTask('c1', { type: TaskType.COMPOUND }))).toBe(base);
  });

  it('REFUSES an unknown task id (the library hasn\u2019t resolved it)', () => {
    const base = {};
    expect(withManualVary(base, 'ghost', 1, undefined)).toBe(base);
  });
});

describe('pruneManualVary (a task leaving the hand-added layer)', () => {
  it('drops the entry \u2014 unguarded, so a stale non-counting entry goes too', () => {
    expect(pruneManualVary({ t1: 2, t2: 1 }, 't1')).toEqual({ t2: 1 });
  });

  it('returns the SAME map when there is nothing to drop', () => {
    const base = { t1: 2 as const };
    expect(pruneManualVary(base, 'other')).toBe(base);
  });
});

describe('canDeselectFromSources (review Important #2 \u2014 the deselect guard)', () => {
  const compoundTask = makeTask('c1', { type: TaskType.COMPOUND });
  const children = {
    c1: [
      { childTaskId: 'k1', childIndex: 0 },
      { childTaskId: 'k2', childIndex: 1 },
    ],
  };
  const info: SupplyInfoMap = {
    b1: { displayName: 'Board', rawSupplyTaskIds: ['c1', 'x'], doneTaskIds: new Set() },
  };

  function suppliesFor(parts?: Record<string, { excluded?: boolean }>) {
    const source = makeSource({
      sourceId: 'b1',
      memberRules: { c1: { split: true, ...(parts ? { parts } : {}) } },
    });
    return algorithmSupplies([source], info, children, { c1: compoundTask });
  }

  it('allows deselecting a plain member', () => {
    expect(canDeselectFromSources(suppliesFor(), children, 'x')).toBe(true);
  });

  it('allows deselecting a part while another part is still included', () => {
    expect(canDeselectFromSources(suppliesFor(), children, 'k1')).toBe(true);
  });

  it('REFUSES the last included part \u2014 consistent with setPartExcluded', () => {
    const supplies = suppliesFor({ k1: { excluded: true } });
    expect(canDeselectFromSources(supplies, children, 'k2')).toBe(false);
  });
});

/**
 * Final review I1 — `toggleTaskSelection` now REPORTS the refusal (it
 * returns `false`, exactly like `setPartExcluded`) so the Tasks step can
 * skip its "Removed \u2026" toast: the toast's Undo calls `restoreToPool`,
 * which writes the id into `manualTaskIds` and would re-provenance a
 * source-supplied part as hand-added. This is the gate the action reports.
 */
describe('canApplyTaskToggle (the reported half of toggleTaskSelection)', () => {
  const compoundTask = makeTask('c1', { type: TaskType.COMPOUND });
  const children = {
    c1: [
      { childTaskId: 'k1', childIndex: 0 },
      { childTaskId: 'k2', childIndex: 1 },
    ],
  };
  const info: SupplyInfoMap = {
    b1: { displayName: 'Board', rawSupplyTaskIds: ['c1', 'x'], doneTaskIds: new Set() },
  };
  const suppliesWithK1Excluded = algorithmSupplies(
    [
      makeSource({
        sourceId: 'b1',
        memberRules: { c1: { split: true, parts: { k1: { excluded: true } } } },
      }),
    ],
    info,
    children,
    { c1: compoundTask },
  );

  it('REFUSES deselecting the last included part', () => {
    expect(canApplyTaskToggle(true, suppliesWithK1Excluded, children, 'k2')).toBe(false);
  });

  it('allows deselecting a plain member', () => {
    expect(canApplyTaskToggle(true, suppliesWithK1Excluded, children, 'x')).toBe(true);
  });

  it('never refuses a SELECT \u2014 only a deselect can self-revert', () => {
    expect(canApplyTaskToggle(false, suppliesWithK1Excluded, children, 'k2')).toBe(true);
  });
});

describe('initialPrefilledSourceIds (RC4 hydration exemption)', () => {
  it('pre-marks every HYDRATED board source, and no pool source', () => {
    const ids = initialPrefilledSourceIds([
      makeSource({ sourceId: 'b1' }),
      makeSource({ sourceId: 'p1', kind: 'pool' }),
      makeSource({ sourceId: 'b2' }),
    ]);
    expect([...ids].sort()).toEqual(['b1', 'b2']);
  });

  it('a fresh wizard pre-marks nothing \u2014 every board pulled this session seeds', () => {
    expect(initialPrefilledSourceIds([]).size).toBe(0);
  });
});
describe('prefillRemainingTargets (RC4 — one-off remaining prefill)', () => {
  const tasksById: Record<string, Task> = {
    c10: counter('c10', 10),
    c5: counter('c5', 5),
    c30: counter('c30', 30),
    accumulator: makeTask('accumulator', { type: TaskType.COUNTING }),
    plain: makeTask('plain'),
  };

  /** The board being assembled. WEEKLY, matching the default supply's source
   *  window, so every pre-existing expectation below is also the safety
   *  assertion: a same-length window pro-rates by a ratio of 1. */
  const weeklyTarget: BoardWindow = {
    timeframe: Timeframe.WEEKLY,
    startDate: null,
    endDate: null,
  };
  const dailyTarget: BoardWindow = { timeframe: Timeframe.DAILY, startDate: null, endDate: null };

  function supply(overrides: Partial<WizardSourceSupply> = {}): WizardSourceSupply {
    return {
      displayName: 'Last week',
      rawSupplyTaskIds: ['c10', 'c5', 'accumulator', 'plain'],
      doneTaskIds: new Set(),
      windowCountByTaskId: { c10: 3 },
      sourceWindow: { timeframe: Timeframe.WEEKLY, startDate: '2026-09-07', endDate: null },
      ...overrides,
    };
  }

  it('seeds each counting member with goal minus its progress in the source window (same-length window: ratio 1, so NOT pro-rated)', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    const { sources: next, settled } = prefillRemainingTargets(
      sources,
      'b1',
      supply(),
      tasksById,
      weeklyTarget,
    );
    // 10 − 3 = 7, and a weekly→weekly pull must not scale it.
    expect(memberRuleFor(next[0], 'c10').target).toBe(7);
    // No recorded progress -> the whole goal remains.
    expect(memberRuleFor(next[0], 'c5').target).toBe(5);
    expect(settled).toBe(true);
  });

  // Owner ruling 2026-09-24 — a source with no board open resolves empty; it
  // must NOT be marked seeded, so it still prefills once it resolves live.
  it('a no-board-for-window supply is left UNSETTLED, then seeds when it resolves live', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    const pending = prefillRemainingTargets(
      sources,
      'b1',
      {
        displayName: 'Weekly',
        rawSupplyTaskIds: [],
        doneTaskIds: new Set(),
        noBoardForWindow: true,
      },
      tasksById,
      weeklyTarget,
    );
    expect(pending.settled).toBe(false);
    expect(pending.sources).toBe(sources);

    const live = prefillRemainingTargets(pending.sources, 'b1', supply(), tasksById, weeklyTarget);
    expect(live.settled).toBe(true);
    expect(memberRuleFor(live.sources[0], 'c10').target).toBe(7);
  });

  it('pro-rates onto a SHORTER window (owner ruling 2026-09-21) — the reported bug', () => {
    // "Run 30 Miles a Month" pulled from a monthly board onto a ONE-OFF daily
    // board: remaining 30, then ceil(30 × 1 / 30) = 1. Before the ruling this
    // seeded the full 30, and the explicit seed then beat the auto branch.
    const sources = [makeSource({ sourceId: 'b1' })];
    const { sources: next } = prefillRemainingTargets(
      sources,
      'b1',
      supply({
        rawSupplyTaskIds: ['c30'],
        windowCountByTaskId: {},
        sourceWindow: { timeframe: Timeframe.MONTHLY, startDate: '2026-09-01', endDate: null },
      }),
      tasksById,
      dailyTarget,
    );
    expect(memberRuleFor(next[0], 'c30').target).toBe(1);
  });

  it('leaves the remaining amount alone when the source window never resolved', () => {
    // No `sourceWindow` -> unknowable source length -> autoTarget's null-source
    // branch -> the plain remaining amount (10 − 3 = 7), even onto a daily board.
    const sources = [makeSource({ sourceId: 'b1' })];
    const { sources: next } = prefillRemainingTargets(
      sources,
      'b1',
      supply({ sourceWindow: undefined }),
      tasksById,
      dailyTarget,
    );
    expect(memberRuleFor(next[0], 'c10').target).toBe(7);
  });

  it('skips goal-less counters and non-counting members', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    const rules =
      prefillRemainingTargets(sources, 'b1', supply(), tasksById, weeklyTarget).sources[0]
        .memberRules ?? {};
    expect(Object.keys(rules).sort()).toEqual(['c10', 'c5']);
  });

  it('floors at 1 when the member is already at (or past) its goal', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    const { sources: next } = prefillRemainingTargets(
      sources,
      'b1',
      supply({ windowCountByTaskId: { c10: 12 } }),
      tasksById,
      weeklyTarget,
    );
    expect(memberRuleFor(next[0], 'c10').target).toBe(1);
  });

  it('never overwrites an edited target — a re-resolve is idempotent', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    const { sources: seeded } = prefillRemainingTargets(
      sources,
      'b1',
      supply(),
      tasksById,
      weeklyTarget,
    );
    const edited = withMemberRuleInSource(seeded, 'b1', 'c10', { target: 2 });
    const again = prefillRemainingTargets(edited, 'b1', supply(), tasksById, weeklyTarget);
    expect(memberRuleFor(again.sources[0], 'c10').target).toBe(2);
    expect(again.sources).toBe(edited); // nothing left to seed -> same identity
    expect(again.settled).toBe(true);
  });

  it('is a no-op for a source that is not pulled (and counts as settled)', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    const result = prefillRemainingTargets(sources, 'ghost', supply(), tasksById, weeklyTarget);
    expect(result.sources).toBe(sources);
    expect(result.settled).toBe(true);
  });

  it('a supply with NO counting members is settled too — nothing written, never retried', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    const result = prefillRemainingTargets(
      sources,
      'b1',
      supply({ rawSupplyTaskIds: ['plain'], windowCountByTaskId: {} }),
      tasksById,
      weeklyTarget,
    );
    expect(result.sources).toBe(sources);
    expect(result.settled).toBe(true);
  });

  it('is NOT settled while a supplied member is unknown to the task map — a slow live query is retried, not lost', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    const result = prefillRemainingTargets(sources, 'b1', supply(), {}, weeklyTarget);
    expect(result.sources).toBe(sources);
    expect(result.settled).toBe(false);

    // The retry (library now loaded) seeds as usual.
    const retry = prefillRemainingTargets(
      result.sources,
      'b1',
      supply(),
      tasksById,
      weeklyTarget,
    );
    expect(retry.settled).toBe(true);
    expect(memberRuleFor(retry.sources[0], 'c10').target).toBe(7);
  });

  it('a HYDRATED board source is pre-marked, so its saved target is never re-seeded', () => {
    // The hook skips any source in `initialPrefilledSourceIds(...)`; this pins
    // that a resumed draft's board source IS in that set, and that even a
    // resolve that slipped through leaves the saved target alone.
    const saved = withMemberRuleInSource([makeSource({ sourceId: 'b1' })], 'b1', 'c10', {
      target: 2,
    });
    expect(initialPrefilledSourceIds(saved).has('b1')).toBe(true);
    const anyway = prefillRemainingTargets(saved, 'b1', supply(), tasksById, weeklyTarget);
    expect(memberRuleFor(anyway.sources[0], 'c10').target).toBe(2);
  });
});
