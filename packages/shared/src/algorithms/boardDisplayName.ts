import { Timeframe } from '../constants/enums';
import { formatWindowLabel } from './calendarBoundaries';

/**
 * Heals board names that were frozen from a clock-relative label.
 *
 * ## Why this exists
 *
 * Core boards are auto-named — the wizard locks the name field for them
 * (`isCore`), so the user never gets a chance to change it before save.
 * That name came from `formatTimeframeLabel`, whose DAILY branch returns
 * the literal `"Today"` when the window is the current calendar date.
 * The string is correct for one day and then **persists**, so every daily
 * core board a user has ever created is stored as `"Today"` — making them
 * indistinguishable in lists, in search, and on share posters.
 *
 * The mint path now stores {@link formatWindowLabel}'s absolute label, so
 * no *new* board enters this state. This helper covers boards already in
 * the database. It deliberately derives rather than rewriting the rows:
 * past core boards are exactly the ones that get **sealed**, and sealed
 * boards must never mutate outside deterministic pull-path re-derivation
 * (see docs/WINDOWED_COMPLETION.md). A rename migration would have
 * written to precisely the rows that invariant protects.
 *
 * ## What counts as stale
 *
 * Only the two strings the auto-namers could actually produce, matched
 * exactly, and only on `isCore` boards:
 *
 * - `"Today"` — the bare window label (core-board wizard seed)
 * - `"<template name> — Today"` — `deriveSpawnedBoardName`'s composition
 *
 * Anything else is returned untouched, so a board the user renamed via
 * Board Edit keeps its name even if that name contains the word "today".
 */

/** The bare clock-relative label the DAILY branch could freeze into a name. */
const STALE_WINDOW_LABEL = 'Today';

/** Separator `deriveSpawnedBoardName` puts between template name and window label. */
const SPAWN_NAME_SEPARATOR = ' — ';

/** The minimum shape {@link boardDisplayName} needs. Accepts a full `Board`. */
export interface BoardNameFields {
  name: string;
  timeframe: Timeframe;
  startDate: string;
  isCore?: boolean;
}

/**
 * Returns the name to display for a board, healing a frozen "Today".
 *
 * Pure and clock-independent: the result depends only on the board's own
 * fields, so it can never change under an already-painted view.
 *
 * @param board - the board to name; only `name`, `timeframe`, `startDate`
 *   and `isCore` are read
 * @returns the stored name, or an absolute window label when the stored
 *   name is one of the known stale auto-generated forms
 */
export function boardDisplayName(board: BoardNameFields): string {
  // User-authored names are never rewritten. Only auto-named core boards
  // can hold a frozen label, so a non-core board is always its own name.
  if (!board.isCore) return board.name;

  // Fail safe on a malformed startDate: `formatWindowLabel` would render
  // "undefined NaN, NaN" rather than throw, which is worse than showing
  // the stale name. Mirrors the Swift twin's `parseISO8601Date` guard.
  if (Number.isNaN(new Date(board.startDate).getTime())) return board.name;

  if (board.name === STALE_WINDOW_LABEL) {
    return formatWindowLabel(board.timeframe, board.startDate);
  }

  // Spawned form: "<template name> — Today". Heal only the window half so
  // the template's own name (which the user did author) survives intact.
  const staleSuffix = `${SPAWN_NAME_SEPARATOR}${STALE_WINDOW_LABEL}`;
  if (board.name.endsWith(staleSuffix)) {
    const prefix = board.name.slice(0, -staleSuffix.length);
    const windowLabel = formatWindowLabel(board.timeframe, board.startDate);
    return `${prefix}${SPAWN_NAME_SEPARATOR}${windowLabel}`;
  }

  return board.name;
}
