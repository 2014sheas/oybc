/**
 * memberRulesDisplay.ts — Board Sources "member rules" display + rule-editing
 * helpers (docs/BOARD_SOURCES.md §Member rules, B3).
 *
 * `memberRules.ts` (B1 + B2) is the planning/materialisation pipeline that
 * runs at spawn/persist time; this module is the UI-facing half that reads
 * and writes the *stored rule* a person edits in the Sources sheet — the
 * pro-rated target a rule-editing surface previews before it's saved
 * (`effectiveMemberTarget`), the human-readable vary range / split note
 * (`varyRangeLabel`, `splitSquaresNote`), the accessors that read a rule off
 * a `BoardSource` without a caller having to null-check three levels deep
 * (`memberRuleFor`, `partRuleFor`), and the immutable setters that write one
 * back with the same "omit when empty" serialisation `BoardSource.memberRules`
 * already promises (`withMemberRule`, `withPartRule`).
 *
 * Split out of `memberRules.ts` (rather than appended to it) to keep that
 * file under the 1000-line god-file guardrail; the public surface is the
 * `@oybc/shared` barrel either way.
 *
 * Has a Swift twin, pinned by the `display` section of the same vector
 * fixture (`tests/fixtures/memberRuleVectors.json`, copied byte-identically
 * to `apps/ios/OYBCTests/Fixtures/`). A change here is a change in two places.
 */

import type { BoardSource, BoardSourceMemberRule, BoardSourcePartRule, VaryLevel } from '../types/boardSource';
import { autoTarget, nominalWindowDays, varyRange } from './memberRules';
import type { BoardWindow, PlanMode } from './memberRules';

/**
 * The target a rule-editing surface previews for a counting member — the
 * same pro-rated math {@link planDerivedTasks} applies at mint time, without
 * requiring a full plan run.
 *
 * The auto-target gate is `fromBoard` ALONE: a board-pulled member pro-rates
 * on one-off and recurring boards alike (owner ruling 2026-09-21 — pulling
 * "Run 30 miles a month" onto a daily board must preview ~1, not 30), while
 * a pool-sourced or hand-added member always falls to `explicit ?? goal`
 * (those offer vary / split / part-exclusion, never a target). This mirrors
 * `resolveTarget`'s real gate in `planDerivedTasks` exactly. When the gate
 * is open the target pro-rates via {@link autoTarget} over the nominal
 * day-lengths of the source and target windows (`explicit ?? autoTarget(goal,
 * sourceDays, targetDays)`) — a missing `sourceWindow` behaves exactly like
 * `autoTarget` with a `null` source (falls back to `goal`), and a target
 * window at least as long as the source's also falls back to `goal`, so a
 * same-timeframe pull is unchanged. Either way the result is floored and
 * clamped to `1…goal`, mirroring `resolveTarget` in `memberRules.ts`.
 *
 * @param args.goal - The member's own `maxCount` (integer ≥ 1).
 * @param args.explicit - A stored member-/part-level `target` override, if any.
 * @param args.mode - Whether the board being assembled is one-off or recurring. **Not read** — see `PlanDerivedTasksArgs.mode`; accepted so this helper keeps one shape with the planner and the fixture can pin mode-independence.
 * @param args.fromBoard - Whether the member's supplying source is `kind: 'board'` — pool-sourced and hand-added members never auto-target, matching `resolveTarget`.
 * @param args.sourceWindow - The window the member was pulled from, if known.
 * @param args.targetWindow - The window of the board being assembled.
 * @returns The effective target (integer ≥ 1, ≤ `goal`).
 */
export function effectiveMemberTarget(args: {
  goal: number;
  explicit?: number;
  mode: PlanMode;
  fromBoard: boolean;
  sourceWindow?: BoardWindow;
  targetWindow: BoardWindow;
}): number {
  const { goal, explicit, fromBoard, sourceWindow, targetWindow } = args;
  const targetDays = nominalWindowDays(targetWindow.timeframe, targetWindow.startDate, targetWindow.endDate);
  const base =
    explicit ??
    (fromBoard
      ? autoTarget(
          goal,
          sourceWindow
            ? nominalWindowDays(sourceWindow.timeframe, sourceWindow.startDate, sourceWindow.endDate)
            : null,
          targetDays
        )
      : goal);
  return Math.min(Math.max(1, Math.floor(base)), goal);
}

/**
 * Human-readable vary range for a rule-editing surface — the inclusive
 * `[lo, hi]` from {@link varyRange}, rendered as `"lo–hi unit"` (en dash;
 * `unit` omitted entirely when empty).
 *
 * @param t - The pre-vary target (see {@link effectiveMemberTarget}).
 * @param level - Vary level. `0` renders nothing — there is no range to show.
 * @param goal - The member's own `maxCount`, the hard ceiling.
 * @param unit - The counting member's unit, or `''` when it has none.
 * @returns The label, or `null` at vary level 0.
 */
export function varyRangeLabel(t: number, level: VaryLevel, goal: number, unit: string): string | null {
  if (level === 0) return null;
  const [lo, hi] = varyRange(t, level, goal);
  return `${lo}–${hi}${unit ? ` ${unit}` : ''}`;
}

/**
 * Human-readable "N squares" note for a split compound member — how many of
 * its parts a person actually contributes to the board.
 *
 * `excludedPartIds` is intersected against `partIds` — the member's own,
 * live part ids (from its `compound_children` rows) — rather than counted
 * on its own, so a stale excluded id that no longer names one of the
 * member's parts is silently inert — the same "stale rule does nothing"
 * idiom `applyMemberRules` uses. The result floors at 1: this is a display
 * note, not the expansion itself, so it never claims "0 squares" even when
 * every part is excluded.
 *
 * @param partIds - The member's own, live part ids.
 * @param excludedPartIds - Part ids excluded by this member's split rule.
 * @returns `"1 square"` or `"N squares"`.
 */
export function splitSquaresNote(partIds: readonly string[], excludedPartIds: ReadonlySet<string>): string {
  const included = Math.max(1, partIds.filter((id) => !excludedPartIds.has(id)).length);
  return included === 1 ? '1 square' : `${included} squares`;
}

/**
 * Read a member's rule off a source, never `undefined` — an absent rule
 * reads as `{}`, so a caller can destructure `.target` / `.vary` / `.split`
 * straight off the result without a null check.
 *
 * @param source - The `BoardSource` the member was pulled through.
 * @param taskId - The member's task id.
 * @returns The stored rule, or `{}` when there isn't one.
 */
export function memberRuleFor(source: BoardSource, taskId: string): BoardSourceMemberRule {
  return source.memberRules?.[taskId] ?? {};
}

/**
 * Read a part's rule off its parent member rule, never `undefined`.
 *
 * @param rule - The parent member's rule (from {@link memberRuleFor}).
 * @param childId - The part's `compound_children.childTaskId`.
 * @returns The stored part rule, or `{}` when there isn't one.
 */
export function partRuleFor(rule: BoardSourceMemberRule, childId: string): BoardSourcePartRule {
  return rule.parts?.[childId] ?? {};
}

/** `vary: 0` / `split: false` are the field defaults — pruned so a rule that only carries defaults serialises as absent. */
function pruneMemberRule(rule: BoardSourceMemberRule): BoardSourceMemberRule {
  const out: BoardSourceMemberRule = { ...rule };
  if (out.vary === 0) delete out.vary;
  if (out.split === false) delete out.split;
  return out;
}

/** `vary: 0` / `excluded: false` are the field defaults — pruned the same way as {@link pruneMemberRule}. */
function prunePartRule(rule: BoardSourcePartRule): BoardSourcePartRule {
  const out: BoardSourcePartRule = { ...rule };
  if (out.vary === 0) delete out.vary;
  if (out.excluded === false) delete out.excluded;
  return out;
}

/**
 * Merge `patch` onto `current`: a patch value of `undefined` deletes that
 * key (rather than storing an explicit `undefined`), any other value
 * overwrites it. Used by both {@link withMemberRule} and {@link withPartRule}
 * so the two setters share one merge rule.
 */
function applyPatch<T extends object>(current: T, patch: Partial<T>): T {
  const merged = { ...current } as Record<string, unknown>;
  for (const key of Object.keys(patch)) {
    const value = (patch as Record<string, unknown>)[key];
    if (value === undefined) delete merged[key];
    else merged[key] = value;
  }
  return merged as T;
}

/** Shallow-clone `source` without its `memberRules` key (never an explicit `undefined`). */
function withoutMemberRules(source: BoardSource): BoardSource {
  const clone: Partial<BoardSource> = { ...source };
  delete clone.memberRules;
  return clone as BoardSource;
}

/**
 * Immutably set (or clear) fields of one member's rule on `source`.
 *
 * A patch value of `undefined` deletes that field; the merged rule is then
 * pruned of default values (`vary: 0`, `split: false`) — so patching a rule
 * back to all-defaults, or explicitly clearing every field it had, leaves NO
 * entry for `taskId` in `memberRules`, and clearing the last rule on a
 * source drops the `memberRules` key entirely. This is what keeps a
 * rule-less source serialising byte-identically whether or not it was ever
 * touched by the rule editor.
 *
 * @param source - The source to update (not mutated).
 * @param taskId - The member's task id.
 * @param patch - Fields to set; a field set to `undefined` is cleared.
 * @returns A new `BoardSource` with the rule applied.
 */
export function withMemberRule(
  source: BoardSource,
  taskId: string,
  patch: Partial<BoardSourceMemberRule>
): BoardSource {
  const merged = pruneMemberRule(applyPatch(memberRuleFor(source, taskId), patch));
  const rules = { ...(source.memberRules ?? {}) };
  if (Object.keys(merged).length === 0) {
    delete rules[taskId];
  } else {
    rules[taskId] = merged;
  }
  if (Object.keys(rules).length === 0) {
    return withoutMemberRules(source);
  }
  return { ...source, memberRules: rules };
}

/**
 * Immutably set (or clear) fields of one part's rule, nested under its
 * parent member's rule on `source`. Same emptiness pruning as
 * {@link withMemberRule}, applied at both levels: a cleared part drops out
 * of `parts`, an empty `parts` drops out of the member rule, an
 * all-default-or-empty member rule drops out of `memberRules`, and an empty
 * `memberRules` drops out of `source` entirely.
 *
 * @param source - The source to update (not mutated).
 * @param taskId - The parent compound member's task id.
 * @param childId - The part's `compound_children.childTaskId`.
 * @param patch - Fields to set; a field set to `undefined` is cleared.
 * @returns A new `BoardSource` with the part rule applied.
 */
export function withPartRule(
  source: BoardSource,
  taskId: string,
  childId: string,
  patch: Partial<BoardSourcePartRule>
): BoardSource {
  const currentRule = memberRuleFor(source, taskId);
  const mergedPart = prunePartRule(applyPatch(partRuleFor(currentRule, childId), patch));

  const parts = { ...(currentRule.parts ?? {}) };
  if (Object.keys(mergedPart).length === 0) {
    delete parts[childId];
  } else {
    parts[childId] = mergedPart;
  }

  const mergedRule: BoardSourceMemberRule = { ...currentRule };
  if (Object.keys(parts).length > 0) {
    mergedRule.parts = parts;
  } else {
    delete mergedRule.parts;
  }
  const prunedRule = pruneMemberRule(mergedRule);

  const rules = { ...(source.memberRules ?? {}) };
  if (Object.keys(prunedRule).length === 0) {
    delete rules[taskId];
  } else {
    rules[taskId] = prunedRule;
  }
  if (Object.keys(rules).length === 0) {
    return withoutMemberRules(source);
  }
  return { ...source, memberRules: rules };
}

/**
 * How many more occurrences a counting member's goal needs this window,
 * given how many windows already ran — a simple countdown note for a
 * recurring-series preview. Floors at 1 so the note never reads "0 more".
 *
 * @param goal - The member's own `maxCount`.
 * @param windowCount - How many windows toward the goal have already run.
 * @returns The remaining target (integer ≥ 1).
 */
export function remainingTarget(goal: number, windowCount: number): number {
  return Math.max(1, goal - windowCount);
}

/**
 * The explicit `target` a ONE-OFF wizard prefills for a counting member
 * pulled from a BOARD source: the member's remaining amount in the source
 * board's window, then pro-rated to the window being assembled.
 *
 * `autoTarget(remainingTarget(goal, windowCount), sourceDays, targetDays)` —
 * the same window arithmetic {@link effectiveMemberTarget} previews and
 * `planDerivedTasks` mints with, over the same {@link nominalWindowDays}
 * inputs, so the prefilled number and the auto number can never disagree.
 *
 * Owner ruling 2026-09-21: one-off boards pro-rate too. Pulling a
 * "Run 30 miles a month" counter (nothing logged yet) onto a one-off DAILY
 * board seeds `autoTarget(30, 30, 1) = ceil(30 × 1 / 30) = 1`, not 30.
 *
 * **Same-length windows are unchanged**: `autoTarget`'s
 * `targetDays >= sourceDays` branch returns its `goal` argument verbatim, so
 * `autoTarget(remaining, d, d) === remaining` — a same-timeframe pull (and
 * any pull onto a LONGER window, and any pull whose source window length is
 * unknown) seeds exactly the remaining amount it seeded before this change.
 *
 * @param args.goal - The member's own `maxCount` (floored; integer ≥ 1).
 * @param args.windowCount - Its progress in the SOURCE board's window.
 * @param args.sourceWindow - The source board's own window, if known.
 * @param args.targetWindow - The window of the board being assembled.
 * @returns The target to seed (integer ≥ 1, ≤ the remaining amount).
 */
export function prefilledOneOffTarget(args: {
  goal: number;
  windowCount: number;
  sourceWindow?: BoardWindow | null;
  targetWindow: BoardWindow;
}): number {
  const { goal, windowCount, sourceWindow, targetWindow } = args;
  const remaining = remainingTarget(Math.floor(goal), windowCount);
  return autoTarget(
    remaining,
    sourceWindow
      ? nominalWindowDays(sourceWindow.timeframe, sourceWindow.startDate, sourceWindow.endDate)
      : null,
    nominalWindowDays(targetWindow.timeframe, targetWindow.startDate, targetWindow.endDate)
  );
}

/**
 * What a collapsed member row shows in place of its controls — the row's
 * current answer, never a second control.
 *
 * `varying` is what the row colours the chip by: `--riso-blue` when the
 * dice is lit, `--riso-muted` when it is not.
 */
export interface MemberSummary {
  /** The chip's text. */
  readonly text: string;
  /** True when this member's dice is lit. */
  readonly varying: boolean;
}

/**
 * Collapsed-row summary for a counting member: the vary range when the
 * dice is lit, otherwise the plain target (with its unit, when it has one)
 * — or NOTHING when the chip would only restate the row's own title.
 *
 * Counting titles are auto-generated from action + goal + unit
 * (`generateCounterTaskTitle`), so a member at its full goal with no vary
 * is a row reading "Run 35 mi" beside a chip reading "35 mi". The chip
 * earns its place exactly when it says something the title cannot: a
 * pro-rated or hand-set target (`target !== goal`), or a vary range.
 *
 * The suppression is a rule on the VALUES, never a comparison against the
 * title string: a member whose title the person has renamed by hand must
 * not start or stop showing a chip because of the rename, and this helper
 * is not given the title in the first place.
 *
 * Dispatches to {@link varyRangeLabel} rather than re-deriving the range,
 * so a collapsed row and the expanded row's blue range line can never
 * disagree.
 *
 * @param target - The pre-vary target (see {@link effectiveMemberTarget}).
 * @param level - The member's vary level.
 * @param goal - The member's own `maxCount`, the hard ceiling.
 * @param unit - The counting member's unit, or `''` when it has none.
 * @returns The chip, or null when it would only restate the title.
 */
export function countingSummary(
  target: number,
  level: VaryLevel,
  goal: number,
  unit: string
): MemberSummary | null {
  const range = varyRangeLabel(target, level, goal, unit);
  if (range !== null) return { text: range, varying: true };
  if (level === 0 && target === goal) return null;
  return { text: `${target}${unit ? ` ${unit}` : ''}`, varying: false };
}

/**
 * Collapsed-row summary for a compound member: how many squares it
 * contributes.
 *
 * While split, the dice lives on the individual parts, so the member-level
 * chip never reports varying however the parts are set — the parts' own
 * rows carry that. While One square, the member's dice rolls for the whole
 * square, so `level` governs.
 *
 * Unlike {@link countingSummary} this chip is NEVER suppressed: "1 square"
 * / "3 squares" is not implied by any title, so it always adds something.
 *
 * @param split - Whether the member is in Split up mode.
 * @param partIds - The member's own, live part ids.
 * @param excludedPartIds - Part ids excluded by this member's split rule.
 * @param level - The member's own vary level.
 * @returns The chip's text and whether the dice is lit.
 */
export function compoundSummary(
  split: boolean,
  partIds: readonly string[],
  excludedPartIds: ReadonlySet<string>,
  level: VaryLevel
): MemberSummary {
  if (split) return { text: splitSquaresNote(partIds, excludedPartIds), varying: false };
  return { text: '1 square', varying: level !== 0 };
}
