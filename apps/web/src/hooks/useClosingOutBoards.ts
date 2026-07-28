import { useLiveQuery } from 'dexie-react-hooks';
import { isBoardClosingOut, type Board } from '@oybc/shared';
import { db } from '../db/internal';

/**
 * Windowed Completion — the closing-out set (docs §Sealing → Lifecycle →
 * Detection). Reactive: returns the user's non-draft, non-indefinite boards
 * whose window has ended but which aren't sealed yet — the set the Boards-tab
 * closing-out banner prompts to Log / Seal.
 *
 * Lazy-detection only (mirrors `usePendingRecurringBoards`): closure is
 * *observed* on Boards-tab open, never background-scheduled. Snapshots `now`
 * per recompute for a stable render. Longest-ended-first so the oldest closed
 * window sits at the top. Rebuilds whenever the user's boards change (so a Seal
 * or a silent backstop auto-seal drops the row immediately).
 *
 * @param userId The authenticated user's uid, or undefined when signed out.
 * @returns The closing-out boards (possibly empty).
 */
export function useClosingOutBoards(userId: string | undefined): Board[] {
  return (
    useLiveQuery(
      async (): Promise<Board[]> => {
        if (!userId) return [];
        const nowMs = Date.now();
        const boards = await db.boards
          .filter((b) => b.userId === userId && !b.isDeleted)
          .toArray();
        return boards
          .filter((b) => isBoardClosingOut(b, nowMs))
          .sort(
            (a, b) =>
              new Date(a.endDate ?? 0).getTime() - new Date(b.endDate ?? 0).getTime(),
          );
      },
      [userId],
      [],
    ) ?? []
  );
}
