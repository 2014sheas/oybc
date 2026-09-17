import { boardDisplayName, type BoardNameFields } from '@oybc/shared';

/**
 * Read-path healing for board names frozen as a clock-relative label.
 *
 * Historical daily core boards are all stored as `"Today"` (the wizard
 * locks the name field for core boards, so the user never had a chance to
 * change it). `boardDisplayName` derives an absolute label for those; see
 * that function for why this is a read-time derivation rather than a
 * rename migration — past core boards are *sealed*, and sealed rows must
 * not mutate.
 *
 * Applied in `db/operations` and the board hooks, i.e. the paths CLAUDE.md
 * requires every UI board read to go through. Deliberately NOT applied at
 * the Dexie table level: `firebase/syncService.ts` reads rows via a generic
 * `db.table(entityType)`, so a lower hook would push healed names to other
 * devices and write to exactly the sealed rows this approach protects.
 */

/**
 * Returns the board with a display-safe `name`.
 *
 * Returns the SAME object reference when the name needs no healing, so
 * `useLiveQuery` results and memoized components don't see a new identity
 * on every read.
 *
 * @param board - a board row straight from the database
 * @returns the board, or a shallow copy carrying the healed name
 */
export function healBoardName<T extends BoardNameFields>(board: T): T {
  const healed = boardDisplayName(board);
  return healed === board.name ? board : { ...board, name: healed };
}

/**
 * {@link healBoardName} over a list, preserving the array reference when
 * no element needed healing.
 *
 * @param boards - board rows straight from the database
 * @returns the same array, or a new array with healed entries
 */
export function healBoardNames<T extends BoardNameFields>(boards: T[]): T[] {
  let changed = false;
  const out = boards.map((b) => {
    const healed = healBoardName(b);
    if (healed !== b) changed = true;
    return healed;
  });
  return changed ? out : boards;
}
