import {
  BoardStatus,
  CenterSquareType,
  type Board,
  type RecurringBoardTemplate,
} from '@oybc/shared';
import type { RisoIconName } from '../riso/RisoIcon';

/**
 * Board Edit redesign slice 2 — the title-row "…" board menu, as a pure
 * builder (docs/BOARD_EDIT_REDESIGN.md; plan D3 / D6). The iOS twin is
 * `BoardMenuItems.items(board:sourceTemplate:)` in
 * `Views/BoardsTab/BoardActions/BoardMenuItems.swift` — same rules, same
 * order, pinned by mirrored case tables (`boardMenu.test.ts` ↔
 * `BoardMenuItemsTests`).
 */

/** What a board-menu row does when chosen. */
export type BoardMenuItemKind = 'details' | 'coreDefaults' | 'repeat' | 'archive' | 'delete';

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
};

/**
 * Whether "Repeat this board…" is offered — the exact hide rule of the
 * retired edit-panel REPEATS section (`BoardEditRepeatSection`):
 *   - unknown while the templates query is unresolved → hidden;
 *   - a repeating board (`spawnedFromTemplateId` set) needs its source
 *     record resolved (a soft-deleted / missing record hides it);
 *   - a one-off board with a CHOSEN center can never start repeating
 *     (`validateSpawnPool` rejects it as `unsupportedCenter`).
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
  return board.centerSquareType !== CenterSquareType.CHOSEN;
}

/**
 * Build the board menu's rows, in display order (plan D3):
 *   - draft → no menu (the draft-resume prompt replaces the header);
 *   - core → Core defaults… · Delete (name, timeframe, repeats and archive
 *     are not fields on a core board);
 *   - ad-hoc → Board details… · Repeat this board… · Archive (each only
 *     while editable: active and unsealed; Repeat also needs
 *     `isRepeatEligible`) · Delete (always).
 * Sealed boards therefore get Delete (+ Core defaults… on core) only —
 * Repeat and Archive write the sealed row and wait for slice 4.
 *
 * @param args.board - The board the menu is for.
 * @param args.sourceTemplate - See `isRepeatEligible`.
 * @param args.templatesLoaded - See `isRepeatEligible`.
 * @returns The rows to render; empty means "render no menu".
 */
export function buildBoardMenuItems(args: {
  board: Board;
  sourceTemplate: RecurringBoardTemplate | null | undefined;
  templatesLoaded: boolean;
}): BoardMenuItem[] {
  const { board, sourceTemplate, templatesLoaded } = args;
  if (board.status === BoardStatus.DRAFT) return [];
  if (board.isCore) return [ITEMS.coreDefaults, ITEMS.delete];

  const editable = board.status === BoardStatus.ACTIVE && board.sealedAt == null;
  const items: BoardMenuItem[] = [];
  if (editable) {
    items.push(ITEMS.details);
    if (isRepeatEligible(board, sourceTemplate, templatesLoaded)) items.push(ITEMS.repeat);
    items.push(ITEMS.archive);
  }
  items.push(ITEMS.delete);
  return items;
}
