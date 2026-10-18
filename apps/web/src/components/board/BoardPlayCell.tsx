import { memo } from 'react';
import { RisoBoardCell } from './RisoBoardCell';
import { samePlayTaskEntry, type PlayTaskEntry } from './boardPlayCells';
import play from '../play/Play.module.css';

export interface BoardPlayCellProps {
  entry: PlayTaskEntry;
  cellSize: number;
  /** The hold menu is open on this square (it keeps its focus ring). */
  held: boolean;
  /** Must be stable across renders, or the memo below can never hold. */
  onTap: (entry: PlayTaskEntry) => void;
  /** Must be stable across renders. */
  onHold: (boardTaskId: string, e: React.MouseEvent) => void;
}

/** Re-render a cell only when something it draws or does has changed. */
function samePlayCell(a: BoardPlayCellProps, b: BoardPlayCellProps): boolean {
  return a.held === b.held && a.cellSize === b.cellSize && a.onTap === b.onTap && a.onHold === b.onHold
    && samePlayTaskEntry(a.entry, b.entry);
}

/**
 * One interactive square of the play board. Memoised on what it draws, so the
 * 6–9 renders a single log causes repaint only the squares that changed.
 *
 * @returns The cell.
 */
export const BoardPlayCell = memo(function BoardPlayCell({ entry, cellSize, held, onTap, onHold }: BoardPlayCellProps): React.ReactElement {
  return (
    <RisoBoardCell
      cell={entry.cell}
      cellSize={cellSize}
      badge={entry.hasBadge ? <span className={play.achvBadge} title="Achievement">A</span> : undefined}
      onClick={() => onTap(entry)}
      held={held}
      onContextMenu={(e) => {
        e.preventDefault();
        onHold(entry.boardTaskId, e);
      }}
    />
  );
}, samePlayCell);
