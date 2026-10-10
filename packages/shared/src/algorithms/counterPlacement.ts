/**
 * counterPlacement.ts — placing a shared counter on a board
 * (docs/SHARED_COUNTER_SETTINGS.md §2): which goal the per-board copy gets,
 * whether a hand-added ROOT needs a copy at all, and the search-match set the
 * wizard quick-add / library sheet / Board Edit picker share. Swift twin:
 * `Helpers/CounterPlacement.swift`; pinned by
 * `tests/fixtures/counterPlacementVectors.json`.
 *
 * Inert for a counter with no `timeframeGoals`: every helper then answers
 * exactly what placement did before (the root's own goal, no copy for a
 * hand-added root), so untouched counters place byte-for-byte as before.
 */

import { TaskType, type Timeframe } from '../constants/enums';
import {
  COUNTER_GOAL_TIMEFRAMES,
  counterDisplayName,
  derivedTimeframeGoals,
  effectiveTitleTemplates,
  COUNT_PLACEHOLDER,
  resolveCounterDefaultGoal,
  type CounterGoalTimeframe,
  type CounterSettingsFields,
} from './counterSettings';

/** The board fields placement reads. */
export interface PlacementBoard {
  timeframe: Timeframe | string;
}

/** An existing per-board copy (live or tombstoned) at the deterministic id. */
export interface PlacementExistingCopy {
  maxCount?: number | null;
}

/**
 * A usable positive goal, or null.
 *
 * @param v - A stored goal.
 */
function positive(v: number | null | undefined): number | null {
  return typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : null;
}

/**
 * The root's default for `timeframe` WITHOUT the root-goal fallback: the
 * stored default, else one D4 derives from the set defaults, else null (also
 * null for CUSTOM / INDEFINITE). This is what the member-rule auto-scaler
 * consults before its own pro-rating — {@link resolveCounterDefaultGoal}'s
 * root-goal fallback would stop it ever scaling.
 *
 * @param root - The counter root's fields.
 * @param timeframe - The board's timeframe.
 * @returns The timeframe default, or null.
 */
export function counterTimeframeDefault(root: CounterSettingsFields, timeframe: Timeframe | string): number | null {
  if (!(COUNTER_GOAL_TIMEFRAMES as readonly string[]).includes(timeframe)) return null;
  const t = timeframe as CounterGoalTimeframe;
  return positive(root.timeframeGoals?.[t]) ?? derivedTimeframeGoals(root)[t];
}

/**
 * The goal a per-board copy of a counter carries when it is placed on
 * `board` (spec §2): an EXISTING copy at the deterministic id keeps its own
 * goal; else {@link resolveCounterDefaultGoal} (stored → derived → the
 * root's goal); else — a CUSTOM / INDEFINITE board, which never matches a
 * default — the root's own goal; else null (goal-less, nothing to copy).
 *
 * @param root - The counter root's fields.
 * @param board - The board receiving the placement.
 * @param existingCopy - The row already holding the copy's id, if any.
 * @returns The copy's goal, or null.
 */
export function placementGoalForCounter(
  root: CounterSettingsFields,
  board: PlacementBoard,
  existingCopy?: PlacementExistingCopy | null
): number | null {
  return (
    positive(existingCopy?.maxCount) ??
    resolveCounterDefaultGoal(root, board.timeframe) ??
    positive(root.maxCount)
  );
}

/** Where a match row's goal comes from (the quick-add / picker row's goal slot). */
export interface PlacementGoalSource {
  /** The goal the per-board copy would carry. */
  goal: number;
  /** True when it is the board-timeframe default (stored or D4-derived) — the
   *  row prefixes the board's timeframe; false when it fell through to the
   *  root's own goal. */
  fromTimeframe: boolean;
}

/**
 * The goal a match row shows for placing a counter ROOT on `board`, and where
 * it came from: {@link placementGoalForCounter} with no existing copy, tagged
 * `fromTimeframe` when {@link counterTimeframeDefault} resolves. Null when no
 * goal resolves at all (a goal-less root on a board with no default) — the row
 * then offers a Goal entry instead.
 *
 * @param root - The counter root's fields.
 * @param board - The board receiving the placement.
 * @returns The goal and its source, or null.
 */
export function placementGoalSource(root: CounterSettingsFields, board: PlacementBoard): PlacementGoalSource | null {
  const goal = placementGoalForCounter(root, board);
  if (goal === null) return null;
  return { goal, fromTimeframe: counterTimeframeDefault(root, board.timeframe) !== null };
}

/**
 * Whether hand-adding the ROOT itself to `board` must mint a per-board copy
 * instead of placing the root: only when the root carries a timeframe default
 * for this board that differs from its own goal (or the root is goal-less and
 * the default gives it one). Otherwise the root is placed as-is, exactly as
 * before (the no-identical-clone rule).
 *
 * @param root - The counter root's fields.
 * @param board - The board receiving the placement.
 * @returns True when a copy must be minted.
 */
export function placementNeedsCopy(root: CounterSettingsFields, board: PlacementBoard): boolean {
  const dflt = counterTimeframeDefault(root, board.timeframe);
  return dflt !== null && dflt !== positive(root.maxCount);
}

/**
 * Search normaliser: diacritics folded (NFD, combining marks dropped),
 * lowercased, whitespace runs collapsed, trimmed — the existing quick-add
 * matcher's lowercase compare, made diacritic-insensitive.
 *
 * @param s - Any text.
 * @returns The normalised text.
 */
export function normalizeSearchText(s: string | null | undefined): string {
  return (s ?? '')
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * The texts a counter is found by: its display name, noun, verb, its
 * effective plural template with `#N` removed ("Read books"), and its stored
 * title.
 *
 * @param root - The counter's fields.
 * @returns The normalised, non-empty match texts.
 */
function counterSearchTexts(root: CounterSettingsFields): string[] {
  const plural = effectiveTitleTemplates(root).plural.split(COUNT_PLACEHOLDER).join(' ');
  return [counterDisplayName(root), root.unit, root.action, plural, root.title]
    .map(normalizeSearchText)
    .filter((t) => t.length > 0);
}

/**
 * Does `query` find this counter? Matches the name, noun, verb and rendered
 * plural title (spec §2), case- and diacritic-insensitively, as a substring
 * — the existing quick-add matcher's rule, so every prefix and word match.
 * An empty query matches.
 *
 * @param query - The typed search.
 * @param root - The counter's fields.
 * @returns True on a match.
 */
export function counterSearchMatches(query: string, root: CounterSettingsFields): boolean {
  const q = normalizeSearchText(query);
  if (q.length === 0) return true;
  return counterSearchTexts(root).some((t) => t.includes(q));
}

/**
 * The library / quick-add / picker task match: the title for every task,
 * plus {@link counterSearchMatches} for a COUNTING task.
 *
 * @param query - The typed search.
 * @param task - The task (type + title + counter fields).
 * @returns True on a match.
 */
export function taskSearchMatches(
  query: string,
  task: CounterSettingsFields & { type: TaskType | string; title: string }
): boolean {
  const q = normalizeSearchText(query);
  if (q.length === 0) return true;
  if (normalizeSearchText(task.title).includes(q)) return true;
  return task.type === TaskType.COUNTING && counterSearchMatches(q, task);
}
