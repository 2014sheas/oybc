import {
  BoardStatus,
  isBoardClosed,
  isBoardEnded,
  type Board,
  type RecurringBoardTemplate,
} from '@oybc/shared';
import type { RisoIconName } from '../riso/RisoIcon';

/**
 * Board Edit redesign slice 2 — the title-row "…" board menu, as a pure
 * builder (docs/BOARD_EDIT_REDESIGN.md; plan D3 / D6). Slice 4 (D12) adds
 * the `close` / `reopen` rows. The iOS twin is
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
