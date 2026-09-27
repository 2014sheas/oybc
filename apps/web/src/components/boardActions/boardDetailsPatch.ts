import {
  Timeframe,
  toLocalISO,
  getTimeframeBoundaries,
  type Board,
  type WeekStartDay,
} from '@oybc/shared';
import type { UpdateActiveBoardPatch } from '../../db/operations/boards';

/**
 * Board Edit redesign slice 2 — the pure core of the "Board details" sheet
 * (plan D4 / D5 / D12): the draft shape, its edit count, validation, and the
 * metadata patch it saves. The iOS twin is `BoardDetailsDraft` in
 * `Views/BoardsTab/BoardActions/BoardDetailsDraft.swift`, pinned by mirrored
 * case tables (`boardDetailsPatch.test.ts` ↔ `BoardDetailsDraftTests`).
 */

// ─── Shared copy ──────────────────────────────────────────────────────────────

/**
 * D11 copy — shown when a save/mutation (Board details, squares Save, or
 * starting a repeat) hits a board sealed or deleted mid-session. iOS twin:
 * `BoardEditError.boardClosedMessage` (curly apostrophe, verbatim on both
 * platforms).
 */
export const BOARD_CLOSED_MESSAGE =
  'This board has been closed, so your changes weren’t saved.';

// ─── Date helpers ─────────────────────────────────────────────────────────────

/** Extract YYYY-MM-DD from an ISO date string (safe for local-ISO). */
function toYMD(isoString: string | null | undefined): string {
  if (!isoString) return '';
  return isoString.slice(0, 10);
}

/** Snap a YYYY-MM-DD string to local start-of-day ISO. */
function snapStart(ymd: string): string {
  const [y, m, d] = ymd.split('-').map(Number);
  return toLocalISO(new Date(y, m - 1, d, 0, 0, 0, 0));
}

/** Snap a YYYY-MM-DD string to local end-of-day ISO. */
function snapEnd(ymd: string): string {
  const [y, m, d] = ymd.split('-').map(Number);
  return toLocalISO(new Date(y, m - 1, d, 23, 59, 59, 999));
}

/**
 * Pure decision core for the Save patch's date fields.
 *
 * A metadata-only Save must PRESERVE the board's stored window (returns
 * `{}` — omit both fields): under Windowed Completion, `startDate` is the
 * completion window's lower bound, and rewriting it wipes the windowed
 * progress of every task whose events predate the new start. Dates are
 * returned ONLY for a deliberate re-window: the timeframe changed, or the
 * (unchanged custom / ongoing) dates were edited.
 *
 * D12 (bugfix B1): an ongoing (INDEFINITE) board's start-date edit is a real
 * date edit (`{ startDate }` only — an ongoing board has no end), and
 * converting to INDEFINITE keeps the picked start instead of re-anchoring to
 * today (today is only the fallback when no start was picked). Re-anchoring
 * silently re-windowed the board — exactly what preserve-window forbids.
 *
 * @returns The date fields to write; `{}` preserves the stored window, and
 *   `endDate: null` clears the deadline.
 */
export function buildEditDatesPatch(args: {
  boardTimeframe: Timeframe;
  formTimeframe: Timeframe;
  origStart: string;
  origEnd: string;
  customStartDate: string;
  customEndDate: string;
  computedBoundaries: { startDate: string; endDate: string } | null;
  /** Injected "today" for determinism in tests; defaults to now. */
  now?: Date;
}): { startDate?: string; endDate?: string | null } {
  const {
    boardTimeframe, formTimeframe, origStart, origEnd,
    customStartDate, customEndDate, computedBoundaries,
  } = args;
  const timeframeChanged = formTimeframe !== boardTimeframe;

  if (timeframeChanged) {
    // A deliberate re-window: converting the board recomputes its dates.
    if (formTimeframe === Timeframe.INDEFINITE) {
      // Ongoing board — keep the picked start, clear the deadline.
      if (customStartDate) return { startDate: snapStart(customStartDate), endDate: null };
      const dayStart = args.now ? new Date(args.now) : new Date();
      dayStart.setHours(0, 0, 0, 0);
      return { startDate: toLocalISO(dayStart), endDate: null };
    }
    if (formTimeframe === Timeframe.CUSTOM) {
      return { startDate: snapStart(customStartDate), endDate: snapEnd(customEndDate) };
    }
    if (computedBoundaries) {
      return { startDate: computedBoundaries.startDate, endDate: computedBoundaries.endDate };
    }
    return {};
  }
  if (
    formTimeframe === Timeframe.CUSTOM &&
    (customStartDate !== origStart || customEndDate !== origEnd)
  ) {
    // Same CUSTOM timeframe, user picked new dates.
    return { startDate: snapStart(customStartDate), endDate: snapEnd(customEndDate) };
  }
  if (formTimeframe === Timeframe.INDEFINITE && customStartDate && customStartDate !== origStart) {
    // Same ONGOING timeframe, user moved the start (D12). No end to write.
    return { startDate: snapStart(customStartDate) };
  }
  // Window untouched — omit startDate/endDate so the stored window (and
  // every in-window completion event) survives the save.
  return {};
}

// ─── Board details draft ──────────────────────────────────────────────────────

/** The Board details sheet's editable state. Dates are YYYY-MM-DD. */
export interface BoardDetailsDraft {
  name: string;
  /** Only CUSTOM ⇄ INDEFINITE may differ from the board (via End date "None"). */
  timeframe: Timeframe;
  customStartDate: string;
  /** Empty for an ongoing board. */
  customEndDate: string;
}

/**
 * Seed a draft from the stored board (the sheet's open state).
 *
 * @param board - The board being edited.
 * @returns A draft equal to the board (zero edits).
 */
export function seedBoardDetailsDraft(board: Board): BoardDetailsDraft {
  return {
    name: board.name,
    timeframe: board.timeframe as Timeframe,
    customStartDate: toYMD(board.startDate),
    customEndDate: toYMD(board.endDate),
  };
}

/** Timeframes whose dates the user owns (D5) — the only switchable pair. */
function isDatedByUser(tf: Timeframe): boolean {
  return tf === Timeframe.CUSTOM || tf === Timeframe.INDEFINITE;
}

/** Shared body of the patch builder; `computedBoundaries` lets count skip the calendar. */
function detailsPatch(
  board: Board,
  draft: BoardDetailsDraft,
  computedBoundaries: { startDate: string; endDate: string } | null,
  now: Date | undefined,
): UpdateActiveBoardPatch {
  const patch: UpdateActiveBoardPatch = {};
  const boardTimeframe = board.timeframe as Timeframe;

  const trimmedName = draft.name.trim();
  if (trimmedName !== board.name) patch.name = trimmedName;

  // D5 — the timeframe never switches after creation, except custom ⇄
  // ongoing via the End-date "None" choice. Calendar boards have no
  // editable dates at all (their window is read-only).
  const formTimeframe =
    isDatedByUser(boardTimeframe) && isDatedByUser(draft.timeframe)
      ? draft.timeframe
      : boardTimeframe;
  if (formTimeframe !== boardTimeframe) patch.timeframe = formTimeframe;
  const dates = buildEditDatesPatch({
    boardTimeframe,
    formTimeframe,
    origStart: toYMD(board.startDate),
    origEnd: toYMD(board.endDate),
    customStartDate: draft.customStartDate,
    customEndDate: draft.customEndDate,
    computedBoundaries,
    now,
  });
  if (dates.startDate !== undefined) patch.startDate = dates.startDate;
  if (dates.endDate !== undefined) patch.endDate = dates.endDate;
  // No center group (Board Edit slice 3, D6): the center changes only in the
  // squares editor.
  return patch;
}

/**
 * Build the metadata patch the Board details sheet saves: only the fields
 * that actually change (trimmed name, custom ⇄ ongoing timeframe + dates).
 *
 * @param board - The board being edited.
 * @param draft - The sheet's current draft.
 * @param weekStartDay - Week-start preference for calendar boundaries.
 * @param now - Injected "today" for determinism; defaults to now.
 * @returns The patch, or `null` when nothing would change.
 */
export function buildBoardDetailsPatch(
  board: Board,
  draft: BoardDetailsDraft,
  weekStartDay: WeekStartDay,
  now?: Date,
): UpdateActiveBoardPatch | null {
  const tf = board.timeframe as Timeframe;
  const computedBoundaries = isDatedByUser(tf)
    ? null
    : getTimeframeBoundaries(tf, now ?? new Date(), weekStartDay);
  const patch = detailsPatch(board, draft, computedBoundaries, now);
  return Object.keys(patch).length > 0 ? patch : null;
}

/**
 * Count the draft's edits in field groups (name / dates), counting
 * ONLY what `buildBoardDetailsPatch` would write — derived from the same
 * builder, so the "N edits" counter and the Save can never disagree again
 * (bugfix B1 was exactly that disagreement).
 *
 * @param board - The board being edited.
 * @param draft - The sheet's current draft.
 * @param now - Injected "today" for determinism; defaults to now.
 * @returns 0–2.
 */
export function countBoardDetailsEdits(board: Board, draft: BoardDetailsDraft, now?: Date): number {
  const patch = detailsPatch(board, draft, null, now);
  let count = 0;
  if (patch.name !== undefined) count++;
  if (patch.timeframe !== undefined || patch.startDate !== undefined || patch.endDate !== undefined) count++;
  return count;
}

/**
 * Validate the draft before Save.
 *
 * @param draft - The sheet's current draft.
 * @returns The user-facing error, or `null` when the draft is valid.
 */
export function validateBoardDetails(draft: BoardDetailsDraft): string | null {
  if (!draft.name.trim()) return 'Board name is required.';
  if (draft.timeframe === Timeframe.CUSTOM) {
    if (!draft.customStartDate || !draft.customEndDate) {
      return 'Both start and end dates are required for a custom timeframe.';
    }
    if (draft.customEndDate < draft.customStartDate) {
      return 'End date must be on or after the start date.';
    }
  }
  return null;
}
