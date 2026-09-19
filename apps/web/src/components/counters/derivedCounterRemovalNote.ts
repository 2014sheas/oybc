/**
 * derivedCounterRemovalNote — the delete-confirm sentence warning that the
 * window-stamped derived counters made from a root go with it
 * (docs/BOARD_SOURCES.md §Member rules, B3 RC12).
 *
 * Deleting a counter root (from the Counters detail page) or a task (from
 * the Tasks tab / task detail) soft-deletes every per-window derived counter
 * minted from it AND their placements — rows that live on OTHER boards, so
 * they never show up in an `affectedBoards` list or in the compound
 * child/parent link counts. Both web confirm dialogs therefore have to say
 * so, and they have to say it the SAME way: the twin of iOS's single
 * `BoardSources.derivedCounterRemovalNote(count:)`, which both iOS sheets
 * (`CounterDeleteConfirmView`, `TaskDeleteConfirmView`) already share.
 *
 * @param count - `impact.derivedWindowCounterCount` for the row being deleted.
 * @returns The sentence, or `null` when there is nothing to warn about.
 */
export function derivedCounterRemovalNote(count: number): string | null {
  if (count <= 0) return null;
  return `${count} board counter${count === 1 ? '' : 's'} made from this one will be removed.`;
}
