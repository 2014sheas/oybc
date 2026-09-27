import {
  BoardStatus,
  isBoardClosed,
  isBoardEnded,
  type Board,
  type RecurringBoardTemplate,
} from '@oybc/shared';
import type { RisoIconName } from '../riso/RisoIcon';

/**
 * Board Edit redesign slice 2 — originally the title-row "…" board menu, as
 * a pure builder (docs/BOARD_EDIT_REDESIGN.md; plan D3 / D6). Slice 4 (D12)
 * added the `close` / `reopen` rows. Edit consolidation (slice 5) retired the
 * "…" trigger: these rows now render as the Edit screen's **BOARD section**
 * (`BoardOptionsSection`), below the squares editor — the builder itself and
 * its ordering rules are unchanged. The iOS twin is
 * `BoardMenuItems.items(board:sourceTemplate:now:)` in
 * `Views/BoardsTab/BoardActions/BoardMenuItems.swift` — same rules, same
 * order, pinned by mirrored case tables (`boardMenu.test.ts` ↔
 * `BoardMenuItemsTests`).
 */

/** What a board-menu row does when chosen. */
export type BoardMenuItemKind =
  | 'details'
  | 'coreDefaults'
  | 'repeat'
  | 'archive'
  | 'delete'
  | 'close'
  | 'reopen';

/** One row of the board menu. */
export interface BoardMenuItem {
  kind: BoardMenuItemKind;
  /** Verbatim on-screen label. */
  label: string;
  /** Riso stroke icon drawn at the row's leading edge. */
  icon: RisoIconName;
  /** Destructive row (drawn in `--riso-red`). */
  danger: boolean;
}

const ITEMS: Record<BoardMenuItemKind, BoardMenuItem> = {
  details: { kind: 'details', label: 'Board details…', icon: 'sliders', danger: false },
  coreDefaults: { kind: 'coreDefaults', label: 'Core defaults…', icon: 'sliders', danger: false },
  repeat: { kind: 'repeat', label: 'Repeat this board…', icon: 'repeat', danger: false },
  archive: { kind: 'archive', label: 'Archive', icon: 'boards', danger: false },
  delete: { kind: 'delete', label: 'Delete', icon: 'trash', danger: true },
  close: { kind: 'close', label: 'Close board', icon: 'lock', danger: false },
  reopen: { kind: 'reopen', label: 'Reopen board', icon: 'sync', danger: false },
};

/**
 * Whether "Repeat this board…" is offered — the exact hide rule of the
 * retired edit-panel REPEATS section (`BoardEditRepeatSection`):
 *   - unknown while the templates query is unresolved → hidden;
 *   - a repeating board (`spawnedFromTemplateId` set) needs its source
 *     record resolved (a soft-deleted / missing record hides it);
 *   - any one-off board is eligible. A legacy CHOSEN center reads through
 *     `effectiveCenter` as NONE (+ a locked center square), and the template
 *     is built with that effective center, so it no longer blocks Repeat
 *     (Board Edit slice 3, D5; locks don't carry into templates).
 *
 * @param board - The board the menu is for.
 * @param sourceTemplate - The board's resolved source record (`undefined`
 *   for a one-off board or an unresolved / gone record).
 * @param templatesLoaded - False while the templates query is unresolved.
 * @returns True when the Repeat sheet may open.
 */
export function isRepeatEligible(
  board: Board,
  sourceTemplate: RecurringBoardTemplate | null | undefined,
  templatesLoaded: boolean,
): boolean {
  if (!templatesLoaded) return false;
  if (board.spawnedFromTemplateId != null) return sourceTemplate != null;
  return true;
}

/**
 * Build the board menu's rows, in display order (plan D3, extended by slice
 * 4's D12):
 *   - draft → no menu (the draft-resume prompt replaces the header);
 *   - archived → Delete only (+ Core defaults… on core) — no Close/Reopen
 *     on an archived board (OQ5);
 *   - core, ended → Close board · Core defaults… · Delete;
 *   - core, closed → Reopen board · Core defaults… · Delete;
 *   - core, otherwise → Core defaults… · Delete;
 *   - ad-hoc, ended → Close board · Board details… · Repeat this board…
 *     (`isRepeatEligible`) · Archive · Delete;
 *   - ad-hoc, closed → Reopen board · Repeat this board… · Archive · Delete
 *     (no Board details — handoff `MENU_CLOSED`);
 *   - ad-hoc, otherwise (active/completed, unsealed, not yet ended) →
 *     Board details… · Repeat this board… · Archive (only while editable:
 *     `status === ACTIVE`) · Delete (always).
 * Repeat and Archive are offered on a closed board (D12: both are relaxed
 * to `assertBoardMetadataWritable`, which allows a sealed board).
 *
 * @param args.board - The board the menu is for.
 * @param args.sourceTemplate - See `isRepeatEligible`.
 * @param args.templatesLoaded - See `isRepeatEligible`.
 * @param args.now - Current time as epoch ms (drives the ended/closed state).
 * @returns The rows to render; empty means "render no menu".
 */
export function buildBoardMenuItems(args: {
  board: Board;
  sourceTemplate: RecurringBoardTemplate | null | undefined;
  templatesLoaded: boolean;
  now: number;
}): BoardMenuItem[] {
  const { board, sourceTemplate, templatesLoaded, now } = args;
  if (board.status === BoardStatus.DRAFT) return [];
  if (board.status === BoardStatus.ARCHIVED) {
    return board.isCore ? [ITEMS.coreDefaults, ITEMS.delete] : [ITEMS.delete];
  }

  const ended = isBoardEnded(board, now);
  const closed = isBoardClosed(board);
  const repeatEligible = isRepeatEligible(board, sourceTemplate, templatesLoaded);

  if (board.isCore) {
    const items: BoardMenuItem[] = [];
    if (closed) items.push(ITEMS.reopen);
    else if (ended) items.push(ITEMS.close);
    items.push(ITEMS.coreDefaults, ITEMS.delete);
    return items;
  }

  const items: BoardMenuItem[] = [];
  if (closed) {
    items.push(ITEMS.reopen);
    if (repeatEligible) items.push(ITEMS.repeat);
    items.push(ITEMS.archive);
  } else if (ended) {
    items.push(ITEMS.close, ITEMS.details);
    if (repeatEligible) items.push(ITEMS.repeat);
    items.push(ITEMS.archive);
  } else if (board.status === BoardStatus.ACTIVE) {
    items.push(ITEMS.details);
    if (repeatEligible) items.push(ITEMS.repeat);
    items.push(ITEMS.archive);
  }
  items.push(ITEMS.delete);
  return items;
}

/**
 * Edit consolidation (plan D2/D3) — the Edit screen's title-row gate: "any
 * non-draft, loaded board, not already editing" (the `!editMode` half is the
 * caller's responsibility). Replaces the old squares-only gate below, which
 * survives renamed as `canEditSquares`.
 *
 * @param board - The board to test.
 * @returns True unless the board is a DRAFT (drafts never reach the play
 *   surface — the draft-resume prompt replaces the header instead).
 */
export function showsEditButton(board: Board): boolean {
  return board.status !== BoardStatus.DRAFT;
}

/**
 * Edit consolidation (plan D3) — whether the SQUARES section may be edited:
 * the exact rule the old title-row "Edit squares" button used to gate on
 * (`status == ACTIVE && sealedAt == nil && !isBoardEnded`). Captured ONCE at
 * Edit entry (`editSession.squaresEditable` / iOS `@State
 * editSquaresEditable`) — does not flip mid-session; see plan D3 for the
 * race this avoids.
 *
 * @param board - The board to test.
 * @param now - Current time as epoch ms.
 * @returns True when the squares editor may be shown.
 */
export function canEditSquares(board: Board, now: number): boolean {
  return board.status === BoardStatus.ACTIVE && board.sealedAt == null && !isBoardEnded(board, now);
}

/**
 * Edit consolidation (plan D4) — the muted line replacing the SQUARES
 * section on a board whose squares can't be edited. Copy is verbatim per
 * D4; precedence is archived, then ended/closed, then completed (an
 * archived-and-ended board reads as archived, matching `buildBoardMenuItems`
 * — OQ5).
 *
 * @param board - The board to test.
 * @param now - Current time as epoch ms.
 * @returns The reason line, or `null` when `canEditSquares` is true.
 */
export function squaresLockedReason(board: Board, now: number): string | null {
  if (canEditSquares(board, now)) return null;
  if (board.status === BoardStatus.ARCHIVED) {
    return "This board is archived, so its squares can't change.";
  }
  if (isBoardEnded(board, now) || isBoardClosed(board)) {
    return "This board has ended, so its squares can't change.";
  }
  if (board.status === BoardStatus.COMPLETED) {
    return "This board is complete, so its squares can't change.";
  }
  return null;
}

/** How a BOARD-section row treats a dirty squares draft on selection
 *  (plan D8). `keep` — the sheet opens over Edit, the draft is untouched.
 *  `discardInConfirm` — the row's own confirm gets `DISCARD_SQUARES_SUFFIX`
 *  appended when dirty. `discardFirst` — a "Discard changes?" confirm runs
 *  BEFORE the row's own action when dirty. */
export type BoardItemDraftPolicy = 'keep' | 'discardInConfirm' | 'discardFirst';

const DRAFT_POLICY_BY_KIND: Record<BoardMenuItemKind, BoardItemDraftPolicy> = {
  details: 'keep',
  repeat: 'keep',
  coreDefaults: 'keep',
  archive: 'discardInConfirm',
  delete: 'discardInConfirm',
  close: 'discardFirst',
  reopen: 'discardFirst',
};

/**
 * Edit consolidation (plan D8) — the dirty-draft policy for a BOARD-section
 * row kind. `close`/`reopen` are only reachable with a dirty draft via the
 * D3 race (squares were editable at entry, then the board ended/sealed
 * mid-session), since those rows exist only when `canEditSquares` is false.
 *
 * @param kind - The row kind.
 * @returns The policy to apply.
 */
export function boardItemDraftPolicy(kind: BoardMenuItemKind): BoardItemDraftPolicy {
  return DRAFT_POLICY_BY_KIND[kind];
}

/** Appended to the Archive/Delete confirm body when the squares draft is
 *  dirty (plan D8, verbatim copy). */
export const DISCARD_SQUARES_SUFFIX = ' Your unsaved square changes will be discarded.';
