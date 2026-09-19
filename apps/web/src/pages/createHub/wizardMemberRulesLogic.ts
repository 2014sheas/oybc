/**
 * wizardMemberRulesLogic.ts — the pure transitions behind
 * `useWizardMemberRules` (docs/BOARD_SOURCES.md §Member rules, B3).
 *
 * Every rule edit a person can make in the Sources sheet — a counting
 * member's target or dice, a compound's Split up, a part's exclusion /
 * target / dice, a hand-added counter's dice — reduces to one of these
 * functions. They are pure, immutable, and go through the shared
 * `withMemberRule` / `withPartRule` setters, so the "omit when empty"
 * serialisation a rule-less source promises holds for free: patching a rule
 * back to its defaults leaves no entry behind.
 *
 * Split out from the hook for the same reason `wizardSourcesLogic.ts` is:
 * this repo's Vitest harness is `environment: 'node'` with no hook renderer,
 * so the behaviour has to live somewhere testable.
 *
 * iOS mirrors these with the same names (B3 Task 6).
 */

import {
  memberRuleFor,
  partRuleFor,
  remainingTarget,
  withMemberRule,
  withPartRule,
  TaskType,
  type BoardSource,
  type BoardSourceMemberRule,
  type BoardSourcePartRule,
  type Task,
  type VaryLevel,
} from '@oybc/shared';
import type { WizardSourceSupply } from './wizardSources';

/**
 * Apply a member-rule patch to ONE source row (other rows pass through
 * untouched). A rule for a source that isn't pulled is a no-op.
 *
 * @param sources - The current source rows.
 * @param sourceId - The row the member was pulled through.
 * @param taskId - The member's task id.
 * @param patch - Fields to set; a field set to `undefined` is cleared.
 * @returns The next rows.
 */
export function withMemberRuleInSource(
  sources: BoardSource[],
  sourceId: string,
  taskId: string,
  patch: Partial<BoardSourceMemberRule>,
): BoardSource[] {
  return sources.map((source) =>
    source.sourceId === sourceId ? withMemberRule(source, taskId, patch) : source,
  );
}

/**
 * Apply a PART-rule patch to ONE source row.
 *
 * @param sources - The current source rows.
 * @param sourceId - The row the parent member was pulled through.
 * @param taskId - The parent compound member's task id.
 * @param childId - The part's `compound_children.childTaskId`.
 * @param patch - Fields to set; a field set to `undefined` is cleared.
 * @returns The next rows.
 */
export function withPartRuleInSource(
  sources: BoardSource[],
  sourceId: string,
  taskId: string,
  childId: string,
  patch: Partial<BoardSourcePartRule>,
): BoardSource[] {
  return sources.map((source) =>
    source.sourceId === sourceId ? withPartRule(source, taskId, childId, patch) : source,
  );
}

/**
 * The parts of a split member that currently contribute a square — the
 * member's live part ids minus the ones its rule excludes. Stale excluded
 * ids (children the compound no longer has) subtract nothing, matching
 * `applyMemberRules`.
 *
 * @param rule - The member's rule.
 * @param partIds - The member's own, live part ids.
 * @returns The included part ids, in `partIds` order.
 */
export function includedPartIds(
  rule: BoardSourceMemberRule,
  partIds: readonly string[],
): string[] {
  return partIds.filter((id) => !partRuleFor(rule, id).excluded);
}

/**
 * Whether excluding `childId` is allowed — a split member must always
 * contribute at least one square, so the LAST included part can't be
 * excluded (the expansion's own last-part guard would silently ignore it,
 * which would read as a broken toggle).
 *
 * Un-excluding is always allowed.
 *
 * @param rule - The member's rule.
 * @param partIds - The member's own, live part ids.
 * @param childId - The part being toggled.
 * @param excluded - The requested state.
 * @returns True when the toggle may be applied.
 */
export function canSetPartExcluded(
  rule: BoardSourceMemberRule,
  partIds: readonly string[],
  childId: string,
  excluded: boolean,
): boolean {
  if (!excluded) return true;
  const included = includedPartIds(rule, partIds);
  if (!included.includes(childId)) return true; // already excluded — idempotent no-op
  return included.length > 1;
}

/**
 * RC14 exclusivity — drop a member's PART rules once the member itself is
 * excluded from a source. A member that supplies nothing must not keep
 * stale per-part state: re-including it later should start from a clean
 * split, not from whichever parts were suppressed in a previous session.
 * `split` itself is kept (it is the member's shape, not per-part state).
 *
 * A no-op when the member is NOT excluded in that source (same array
 * identity), so a caller can run it unconditionally after a toggle.
 *
 * @param sources - The current source rows (post-toggle).
 * @param sourceId - The row the member was pulled through.
 * @param taskId - The member just toggled.
 * @returns The next rows (input array when there was nothing to prune).
 */
export function pruneRulesForExcludedMember(
  sources: BoardSource[],
  sourceId: string,
  taskId: string,
): BoardSource[] {
  const index = sources.findIndex((s) => s.sourceId === sourceId);
  if (index === -1) return sources;
  const source = sources[index];
  if (!source.excludedTaskIds.includes(taskId)) return sources;
  if (memberRuleFor(source, taskId).parts === undefined) return sources;
  const next = [...sources];
  next[index] = withMemberRule(source, taskId, { parts: undefined });
  return next;
}

/**
 * Set a hand-added counter's dice level. Level `0` is the field default, so
 * it is stored as an ABSENCE — keeping the map byte-identical to one that
 * was never touched.
 *
 * @param manualTaskVary - The current map.
 * @param taskId - The hand-added task.
 * @param level - The new dice level.
 * @returns A new map.
 */
export function withManualVary(
  manualTaskVary: Record<string, VaryLevel>,
  taskId: string,
  level: VaryLevel,
): Record<string, VaryLevel> {
  const next = { ...manualTaskVary };
  if (level === 0) delete next[taskId];
  else next[taskId] = level;
  return next;
}

/**
 * RC4 — seed one BOARD source's counting members with their REMAINING
 * target for a ONE-OFF board: `remainingTarget(goal, windowCount)`, where
 * `windowCount` is the progress that member already has in the source
 * board's window. Pull a 3-of-10-done counter onto a fresh one-off board
 * and the rule is seeded at 7.
 *
 * Only applies on one-off boards — a recurring board leaves `target` absent
 * so every spawned window auto-targets against its own window instead.
 *
 * Never overwrites an existing `target` (a rule the person authored, or one
 * a previous resolve already seeded), skips non-counting and goal-less
 * members, and returns the SAME array identity when nothing changed.
 *
 * @param sources - The current source rows.
 * @param sourceId - The board source whose supply just resolved.
 * @param supply - That source's resolved supply entry.
 * @param tasksById - Live id→Task lookup (`type` + `maxCount` are read).
 * @returns The next rows (input array when nothing was seeded).
 */
export function prefillRemainingTargets(
  sources: BoardSource[],
  sourceId: string,
  supply: WizardSourceSupply,
  tasksById: Record<string, Task>,
): BoardSource[] {
  const index = sources.findIndex((s) => s.sourceId === sourceId);
  if (index === -1) return sources;
  let source = sources[index];
  const before = source;
  for (const id of supply.rawSupplyTaskIds) {
    const task = tasksById[id];
    if (task === undefined || task.type !== TaskType.COUNTING) continue;
    const goal = task.maxCount;
    if (typeof goal !== 'number' || goal < 1) continue;
    if (memberRuleFor(source, id).target !== undefined) continue;
    const done = supply.windowCountByTaskId?.[id] ?? 0;
    source = withMemberRule(source, id, { target: remainingTarget(Math.floor(goal), done) });
  }
  if (source === before) return sources;
  const next = [...sources];
  next[index] = source;
  return next;
}
