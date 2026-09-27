import type { Board } from '@oybc/shared';
import { RisoButton, RisoIcon } from '../riso';
import { showsEditButton } from './boardMenu';

export interface BoardEditButtonProps {
  board: Board;
  /** Enters Edit (captures `editSession.squaresEditable` in the caller's
   *  click handler, not here — react-compiler purity, plan W2). */
  onClick: () => void;
}

/**
 * BoardEditButton — the title-row `Edit` button (Edit consolidation, plan
 * D1/D2). Replaces the old `Edit squares` button + the "…" `BoardActionsMenu`
 * trigger: ALL board options now live in the Edit screen's BOARD section
 * (`BoardOptionsSection`), so the title row needs only this one entry point.
 * Visible label is `Edit`; the accessible name is the more specific
 * `Edit board` (screen readers / tests shouldn't see a bare "Edit" next to
 * the square buttons).
 *
 * Gated on `showsEditButton(board)` — true for every non-draft board (the
 * squares-only gate survives, renamed, as `canEditSquares`).
 */
export function BoardEditButton({ board, onClick }: BoardEditButtonProps): React.ReactElement | null {
  if (!showsEditButton(board)) return null;
  return (
    <RisoButton
      kind="neutral"
      size="small"
      icon={<RisoIcon name="edit" size={16} />}
      onClick={onClick}
      aria-label="Edit board"
      title="Edit board"
    >
      Edit
    </RisoButton>
  );
}
