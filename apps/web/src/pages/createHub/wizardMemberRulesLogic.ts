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
  prefilledOneOffTarget,
  withMemberRule,
  withPartRule,
  TaskType,
  type BoardSource,
  type BoardWindow,
  type BoardSourceMemberRule,
  type BoardSourcePartRule,
  type ExpandedSupply,
  type Task,
  type VaryLevel,
} from '@oybc/shared';
import type { SupplyChildrenMap, WizardSourceSupply } from './wizardSources';

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
 * Dice belong to counting rows only (spec §Member rules), and the STATE
 * layer is the guard — not just the UI: a level written for a normal,
 * compound or achievement task would serialise onto the record and read as
 * authored intent forever. A non-counting (or unknown) task is a no-op,
 * returning the SAME map. iOS mirrors this rule.
 *
 * @param manualTaskVary - The current map.
 * @param taskId - The hand-added task.
 * @param level - The new dice level.
 * @param task - That task, for the counting guard (`undefined` = unknown → no-op).
 * @returns A new map, or the input map when the write was refused.
 */
export function withManualVary(
  manualTaskVary: Record<string, VaryLevel>,
  taskId: string,
  level: VaryLevel,
  task: Pick<Task, 'type'> | undefined,
): Record<string, VaryLevel> {
  if (task?.type !== TaskType.COUNTING) return manualTaskVary;
  const next = { ...manualTaskVary };
  if (level === 0) delete next[taskId];
  else next[taskId] = level;
  return next;
}

/**
 * Drop a task's dice when it LEAVES the hand-added layer (deselect / remove).
 * Unguarded on purpose — this is the purge half, and a stale entry for a task
 * that is no longer counting (or no longer exists) is exactly what must go.
 * Without it the entry survives into the draft blob and onto
 * `RecurringBoardTemplate.manualTaskVary`, growing with every dice the person
 * ever set and then removed.
 *
 * @param manualTaskVary - The current map.
 * @param taskId - The task leaving the manual layer.
 * @returns A new map, or the input map when there was nothing to drop.
 */
export function pruneManualVary(
  manualTaskVary: Record<string, VaryLevel>,
  taskId: string,
): Record<string, VaryLevel> {
  if (!(taskId in manualTaskVary)) return manualTaskVary;
  const next = { ...manualTaskVary };
  delete next[taskId];
  return next;
}

/**
 * Whether a supplied task may be DESELECTED from the wizard's square list.
 *
 * Only one thing can refuse: a task that entered the supply as a Split-up
 * PART and is the last included part of its compound. A split member always
 * contributes at least one square, so excluding it would be ignored by
 * `applyMemberRules`' last-part guard and the square would come straight back
 * on the next selection recompute — a self-reverting control (the
 * late-mutation shape this codebase bans). The caller no-ops instead.
 *
 * @param supplies - The Split-up-expanded supplies (`controller.expandedSupplies`).
 * @param childrenByCompoundId - The live compound-children map.
 * @param taskId - The id being deselected.
 * @returns False when the deselect must be refused.
 */
export function canDeselectFromSources(
  supplies: readonly ExpandedSupply[],
  childrenByCompoundId: SupplyChildrenMap,
  taskId: string,
): boolean {
  for (const supply of supplies) {
    const parentId = supply.partOf[taskId];
    if (parentId === undefined) continue;
    const partIds = (childrenByCompoundId[parentId] ?? []).map((c) => c.childTaskId);
    if (!canSetPartExcluded(memberRuleFor(supply.source, parentId), partIds, taskId, true)) {
      return false;
    }
  }
  return true;
}

/**
 * Whether `toggleTaskSelection` may APPLY a toggle — the gate whose answer
 * the action now reports back to its caller (final review I1).
 *
 * A select is always applied; only a DESELECT can be refused, and only by
 * {@link canDeselectFromSources}. The wizard's row ✕ announces "Removed
 * …" with an Undo, and that Undo writes the id into `manualTaskIds` — so a
 * refusal the caller can't see produces a toast that contradicts the screen
 * AND silently re-provenances a source-supplied part as hand-added.
 *
 * Lives here, not inline in the hook, because this repo's Vitest harness is
 * `environment: 'node'` with no hook renderer (see `vitest.config.ts`): the
 * hook is a thin shell and the pure transitions in this module are where
 * behaviour is pinned. iOS keeps the same gate inline in the VM, which its
 * XCTest suite can construct directly.
 *
 * @param wasSelected - Whether the task is currently in the square list.
 * @param supplies - The Split-up-expanded supplies (`controller.expandedSupplies`).
 * @param childrenByCompoundId - The live compound-children map.
 * @param taskId - The id being toggled.
 * @returns False only for a deselect the expansion would undo.
 */
export function canApplyTaskToggle(
  wasSelected: boolean,
  supplies: readonly ExpandedSupply[],
  childrenByCompoundId: SupplyChildrenMap,
  taskId: string,
): boolean {
  if (!wasSelected) return true;
  return canDeselectFromSources(supplies, childrenByCompoundId, taskId);
}

/**
 * The board sources whose RC4 prefill decision is already settled at mount:
 * every board source the wizard HYDRATED (a resumed draft / an edited
 * repeating record). Those were pulled in an earlier session and their saved
 * rules are the person's own state — silently rewriting them when the supply
 * resolves would be the "UI changes after first paint" shape this codebase
 * bans. Only a board pulled in THIS session is seeded.
 *
 * @param sources - The wizard's hydrated source rows.
 * @returns The board-kind source ids to treat as already decided.
 */
export function initialPrefilledSourceIds(sources: readonly BoardSource[]): Set<string> {
  return new Set(sources.filter((s) => s.kind === 'board').map((s) => s.sourceId));
}

/** Outcome of one {@link prefillRemainingTargets} pass. */
export interface PrefillRemainingTargetsResult {
  /** The next source rows (input array when nothing was written). */
  sources: BoardSource[];
  /**
   * Whether this source's prefill decision is SETTLED — i.e. every supplied
   * id resolved in `tasksById`, so each skip was deliberate (not counting /
   * goal-less / already targeted) rather than "the library hadn't loaded
   * yet". A caller marks the source as seeded only on `true`; `false` means
   * try again on the next resolve, so a slow live query can't permanently
   * lose the prefill for that board.
   */
  settled: boolean;
}

/**
 * RC4 — seed one BOARD source's counting members with their remaining
 * target for a ONE-OFF board, PRO-RATED to that board's window:
 * `prefilledOneOffTarget(goal, windowCount, sourceWindow, targetWindow)`,
 * where `windowCount` is the progress that member already has in the source
 * board's window. Pull a 3-of-10-done weekly counter onto a fresh one-off
 * weekly board and the rule is seeded at 7; pull an untouched
 * "Run 30 miles a month" onto a one-off DAILY board and it is seeded at
 * `ceil(30 × 1 / 30) = 1`, not 30 (owner ruling 2026-09-21 — the fix for
 * "defaults for Counter tasks pulled in from boards do not adjust with
 * timeframe"). Same-length windows are unaffected: `autoTarget` returns the
 * remaining amount verbatim when the target window is at least as long as
 * the source's.
 *
 * Writing an EXPLICIT target here is why the shared gate alone was not
 * enough: `resolveTarget` is `explicit ?? auto`, so a one-off board never
 * reaches the auto branch for a member this pass has seeded — the seeded
 * number has to be the pro-rated one.
 *
 * Only applies on one-off boards — a recurring board leaves `target` absent
 * so each spawned window auto-targets against its own window instead.
 *
 * Never overwrites an existing `target` (a rule the person authored, or one
 * a previous resolve already seeded), skips non-counting and goal-less
 * members, and returns the SAME array identity when nothing changed. A
 * supply with no board open (`noBoardForWindow`) is left UNSETTLED so the
 * source is seeded when it later resolves live. iOS twin: the
 * `pendingPrefillSourceIds` retry in `refreshSourceSupplies`.
 *
 * @param sources - The current source rows.
 * @param sourceId - The board source whose supply just resolved.
 * @param supply - That source's resolved supply entry (RC4 counts + RC5 window).
 * @param tasksById - Live id→Task lookup (`type` + `maxCount` are read).
 * @param targetWindow - The window of the board being assembled.
 * @returns The next rows plus whether the decision is settled — see
 *   {@link PrefillRemainingTargetsResult}.
 */
export function prefillRemainingTargets(
  sources: BoardSource[],
  sourceId: string,
  supply: WizardSourceSupply,
  tasksById: Record<string, Task>,
  targetWindow: BoardWindow,
): PrefillRemainingTargetsResult {
  const index = sources.findIndex((s) => s.sourceId === sourceId);
  // A source that isn't pulled has nothing to decide — settled, not retried.
  if (index === -1) return { sources, settled: true };
  // No board open for it yet (owner ruling 2026-09-24): there are no members
  // to seed, and the decision is NOT final — when the source later resolves
  // live, its counting members still get their remaining targets.
  if (supply.noBoardForWindow === true) return { sources, settled: false };
  let source = sources[index];
  const before = source;
  let settled = true;
  for (const id of supply.rawSupplyTaskIds) {
    const task = tasksById[id];
    if (task === undefined) {
      // The live task query hasn't caught up — this member's kind is unknown,
      // so the decision isn't final yet.
      settled = false;
      continue;
    }
    if (task.type !== TaskType.COUNTING) continue;
    const goal = task.maxCount;
    if (typeof goal !== 'number' || goal < 1) continue;
    if (memberRuleFor(source, id).target !== undefined) continue;
    const done = supply.windowCountByTaskId?.[id] ?? 0;
    source = withMemberRule(source, id, {
      target: prefilledOneOffTarget({
        goal,
        windowCount: done,
        sourceWindow: supply.sourceWindow,
        targetWindow,
      }),
    });
  }
  if (source === before) return { sources, settled };
  const next = [...sources];
  next[index] = source;
  return { sources: next, settled };
}
