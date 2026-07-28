import { useEffect } from 'react';
import { useSearchParams } from 'react-router-dom';
import { BoardStatus, type Board } from '@oybc/shared';
import { fetchBoard } from '../../db/operations/boards';

/**
 * Draft-resume deep link: `/create?resumeDraft=<boardId>` opens the wizard
 * hydrated from an existing DRAFT board. Watches the URL; when a valid id
 * appears, fetches the board, validates it's a non-deleted DRAFT, and invokes
 * `onConsumed(board)` exactly once. The param is always cleared from the URL
 * (even when the board is not found or not a draft) so a wizard cancel +
 * manual re-entry doesn't re-arm the flow.
 *
 * Edge cases:
 * - Board not found (deleted since the link was generated): param is cleared,
 *   no callback — the hub renders normally.
 * - Board exists but status is not DRAFT (already activated / completed):
 *   param is cleared, no callback — the hub renders normally.
 * - Board is soft-deleted: treated as not found (no callback).
 *
 * `onConsumed` should be stable (wrapped in `useCallback`).
 */
export function useResumeDraftParam(onConsumed: (board: Board) => void): void {
  const [searchParams, setSearchParams] = useSearchParams();

  useEffect(() => {
    const id = searchParams.get('resumeDraft');
    if (id === null) return;
    let cancelled = false;
    void (async () => {
      const board = await fetchBoard(id);
      if (cancelled) return;
      if (board !== undefined && !board.isDeleted && board.status === BoardStatus.DRAFT) {
        onConsumed(board);
      }
      setSearchParams(
        (prev) => {
          const next = new URLSearchParams(prev);
          next.delete('resumeDraft');
          return next;
        },
        { replace: true },
      );
    })();
    return () => {
      cancelled = true;
    };
  }, [searchParams, setSearchParams, onConsumed]);
}
