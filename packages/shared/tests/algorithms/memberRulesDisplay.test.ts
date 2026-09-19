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
  countingSummary,
  compoundSummary,
} from '../../src/algorithms/memberRulesDisplay';
import type { BoardWindow, PlanMode } from '../../src/algorithms/memberRules';
import type { VaryLevel, BoardSource, BoardSourceMemberRule, BoardSourcePartRule } from '../../src/types';

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
 * Builds the actual TS patch object from the fixture's `{ set, clear }` shape
 * (see the `patchShape` note): `set` fields overwrite, `clear` fields become
 * `undefined` (the TS API's own "delete this field" convention) — matching
 * exactly what the fixture note says the harness does.
 */
const buildPatch = <T extends object>(patch: { set?: Partial<T>; clear?: (keyof T)[] }): Partial<T> =>
  ({
    ...patch.set,
    ...Object.fromEntries((patch.clear ?? []).map((k) => [k, undefined])),
  }) as Partial<T>;

/** Recursively `Object.freeze`s `obj` and everything it references. */
function deepFreeze<T>(obj: T): T {
  if (obj !== null && typeof obj === 'object' && !Object.isFrozen(obj)) {
    for (const key of Object.getOwnPropertyNames(obj)) {
      deepFreeze((obj as Record<string, unknown>)[key]);
    }
    Object.freeze(obj);
  }
  return obj;
}

describe('effectiveMemberTarget', () => {
  it.each(V.effectiveMemberTarget as any[])('$name', (v: any) => {
    expect(
      effectiveMemberTarget({
        goal: v.goal,
        explicit: v.explicit,
        mode: v.mode as PlanMode,
        fromBoard: v.fromBoard,
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
    expect(splitSquaresNote(v.partIds, new Set<string>(v.excludedPartIds))).toBe(v.expected);
  });
});

describe('countingSummary (vectors)', () => {
  it.each(V.countingSummary as any[])('$name', (v: any) => {
    expect(countingSummary(v.target, v.level as VaryLevel, v.goal, v.unit)).toEqual(v.expected);
  });
});

describe('compoundSummary (vectors)', () => {
  it.each(V.compoundSummary as any[])('$name', (v: any) => {
    expect(
      compoundSummary(v.split, v.partIds, new Set<string>(v.excludedPartIds), v.level as VaryLevel)
    ).toEqual(v.expected);
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
      source = withMemberRule(source, step.taskId, buildPatch<BoardSourceMemberRule>(step.patch));
    }
    expectMemberRules(source, v.expectedMemberRules);
  });
});

describe('withPartRule', () => {
  it.each(V.withPartRule as any[])('$name', (v: any) => {
    let source = src(v.startMemberRules);
    for (const step of v.steps) {
      source = withPartRule(source, step.taskId, step.childId, buildPatch<BoardSourcePartRule>(step.patch));
    }
    expectMemberRules(source, v.expectedMemberRules);
  });
});

describe('withMemberRule / withPartRule immutability', () => {
  it.each(V.immutability as any[])('$name', (v: any) => {
    const original = deepFreeze(src(v.startMemberRules));
    const snapshot = JSON.parse(JSON.stringify(original));

    expect(() => {
      let current: BoardSource = original;
      for (const step of v.steps) {
        const next: BoardSource =
          v.kind === 'member'
            ? withMemberRule(current, step.taskId, buildPatch<BoardSourceMemberRule>(step.patch))
            : withPartRule(current, step.taskId, step.childId, buildPatch<BoardSourcePartRule>(step.patch));
        // Freeze every intermediate result too, so a later step in the chain
        // is proven not to mutate the PREVIOUS step's output either — not
        // just the very first frozen source.
        current = deepFreeze(next);
      }
    }).not.toThrow();

    expect(original).toEqual(snapshot);
  });
});
