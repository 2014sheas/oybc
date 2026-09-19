/**
 * memberRulesDisplay.test.ts — Board Sources §Member rules display +
 * rule-editing helpers (B3).
 *
 * Vector-pinned suite. Every expectation lives in the `display` section of
 * `tests/fixtures/memberRuleVectors.json` (hand-computed, never generated
 * from the code under test) so the Swift twin can assert the identical
 * numbers against the byte-identical iOS fixture copy.
 */
import fs from 'fs';
import path from 'path';
import { Timeframe } from '../../src/constants/enums';
import {
  effectiveMemberTarget,
  varyRangeLabel,
  splitSquaresNote,
  memberRuleFor,
  partRuleFor,
  withMemberRule,
  withPartRule,
  remainingTarget,
} from '../../src/algorithms/memberRulesDisplay';
import type { BoardWindow, PlanMode } from '../../src/algorithms/memberRules';
import type { VaryLevel, BoardSource, BoardSourceMemberRule } from '../../src/types';

const V: any = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'memberRuleVectors.json'), 'utf8')
).display;

/** Wraps a bare timeframe string into a `BoardWindow` — startDate/endDate null, per the fixture's `windows` note. */
const win = (tf: string): BoardWindow => ({ timeframe: tf as Timeframe, startDate: null, endDate: null });

/** A minimal `BoardSource`, with `memberRules` omitted unless the fixture supplies one. */
const src = (memberRules: Record<string, BoardSourceMemberRule> | null): BoardSource => ({
  sourceId: 's1',
  kind: 'board',
  min: 0,
  max: null,
  excludedTaskIds: [],
  filter: 'all',
  ...(memberRules ? { memberRules } : {}),
});

/**
 * Maps a fixture patch's `null` values to `undefined` (the fixture's "clear
 * this field" sentinel — see the `clearSentinel` note) and leaves every
 * other value untouched.
 */
const clearSentinel = <T extends Record<string, unknown>>(patch: T): T =>
  Object.fromEntries(Object.entries(patch).map(([k, v]) => [k, v === null ? undefined : v])) as T;

describe('effectiveMemberTarget', () => {
  it.each(V.effectiveMemberTarget as any[])('$name', (v: any) => {
    expect(
      effectiveMemberTarget({
        goal: v.goal,
        explicit: v.explicit,
        mode: v.mode as PlanMode,
        sourceWindow: v.sourceWindow ? win(v.sourceWindow) : undefined,
        targetWindow: win(v.targetWindow),
      })
    ).toBe(v.expected);
  });
});

describe('varyRangeLabel', () => {
  it.each(V.varyRangeLabel as any[])('$name', (v: any) => {
    expect(varyRangeLabel(v.t, v.level as VaryLevel, v.goal, v.unit)).toBe(v.expected);
  });
});

describe('splitSquaresNote', () => {
  it.each(V.splitSquaresNote as any[])('$name', (v: any) => {
    expect(splitSquaresNote(v.partCount, new Set<string>(v.excludedPartIds), v.partIds)).toBe(v.expected);
  });
});

describe('remainingTarget', () => {
  it.each(V.remainingTarget as any[])('$name', (v: any) => {
    expect(remainingTarget(v.goal, v.windowCount)).toBe(v.expected);
  });
});

describe('memberRuleFor', () => {
  it.each(V.memberRuleFor as any[])('$name', (v: any) => {
    expect(memberRuleFor(src(v.memberRules), v.taskId)).toEqual(v.expected);
  });
});

describe('partRuleFor', () => {
  it.each(V.partRuleFor as any[])('$name', (v: any) => {
    expect(partRuleFor(v.rule, v.childId)).toEqual(v.expected);
  });
});

/** Asserts the vector's `expectedMemberRules` against a source: `null` means NO `memberRules` key at all. */
const expectMemberRules = (source: BoardSource, expected: Record<string, BoardSourceMemberRule> | null) => {
  if (expected === null) {
    expect('memberRules' in source).toBe(false);
  } else {
    expect(source.memberRules).toEqual(expected);
  }
};

describe('withMemberRule', () => {
  it.each(V.withMemberRule as any[])('$name', (v: any) => {
    let source = src(v.startMemberRules);
    for (const step of v.steps) {
      source = withMemberRule(source, step.taskId, clearSentinel(step.patch));
    }
    expectMemberRules(source, v.expectedMemberRules);
  });
});

describe('withPartRule', () => {
  it.each(V.withPartRule as any[])('$name', (v: any) => {
    let source = src(v.startMemberRules);
    for (const step of v.steps) {
      source = withPartRule(source, step.taskId, step.childId, clearSentinel(step.patch));
    }
    expectMemberRules(source, v.expectedMemberRules);
  });
});
