import { describe, expect, it } from 'vitest';
import {
  TaskType,
  Timeframe,
  memberRuleFor,
  partRuleFor,
  remainingTarget,
  type BoardSource,
  type Task,
} from '@oybc/shared';
import {
  canSetPartExcluded,
  includedPartIds,
  prefillRemainingTargets,
  pruneRulesForExcludedMember,
  withManualVary,
  withMemberRuleInSource,
  withPartRuleInSource,
} from '../wizardMemberRulesLogic';
import type { WizardSourceSupply } from '../wizardSources';

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
  it('stores a non-zero level and removes the key at level 0', () => {
    const one = withManualVary({}, 't1', 2);
    expect(one).toEqual({ t1: 2 });
    expect(withManualVary(one, 't1', 0)).toEqual({});
  });

  it('never mutates the input map', () => {
    const base = { t1: 1 as const };
    withManualVary(base, 't2', 2);
    expect(base).toEqual({ t1: 1 });
  });
});

describe('prefillRemainingTargets (RC4 — one-off remaining prefill)', () => {
  const tasksById: Record<string, Task> = {
    c10: counter('c10', 10),
    c5: counter('c5', 5),
    accumulator: makeTask('accumulator', { type: TaskType.COUNTING }),
    plain: makeTask('plain'),
  };

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

  it('seeds each counting member with goal − its progress in the source window', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    const next = prefillRemainingTargets(sources, 'b1', supply(), tasksById);
    expect(memberRuleFor(next[0], 'c10').target).toBe(remainingTarget(10, 3));
    expect(memberRuleFor(next[0], 'c10').target).toBe(7);
    // No recorded progress → the whole goal remains.
    expect(memberRuleFor(next[0], 'c5').target).toBe(5);
  });

  it('skips goal-less counters and non-counting members', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    const rules = prefillRemainingTargets(sources, 'b1', supply(), tasksById)[0].memberRules ?? {};
    expect(Object.keys(rules).sort()).toEqual(['c10', 'c5']);
  });

  it('floors at 1 when the member is already at (or past) its goal', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    const next = prefillRemainingTargets(
      sources,
      'b1',
      supply({ windowCountByTaskId: { c10: 12 } }),
      tasksById,
    );
    expect(memberRuleFor(next[0], 'c10').target).toBe(1);
  });

  it('never overwrites an edited target — a re-resolve is idempotent', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    const seeded = prefillRemainingTargets(sources, 'b1', supply(), tasksById);
    const edited = withMemberRuleInSource(seeded, 'b1', 'c10', { target: 2 });
    const again = prefillRemainingTargets(edited, 'b1', supply(), tasksById);
    expect(memberRuleFor(again[0], 'c10').target).toBe(2);
    expect(again).toBe(edited); // nothing left to seed → same identity
  });

  it('is a no-op for a source that is not pulled', () => {
    const sources = [makeSource({ sourceId: 'b1' })];
    expect(prefillRemainingTargets(sources, 'ghost', supply(), tasksById)).toBe(sources);
  });
});
