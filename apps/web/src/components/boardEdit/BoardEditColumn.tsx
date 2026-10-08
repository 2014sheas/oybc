import type { Board, BoardSize, RecurringBoardTemplate, WeekStartDay } from '@oybc/shared';
import { BoardOptionsSection } from '../boardActions/BoardOptionsSection';
import { SquaresEditGrid, type KeyboardMoveDir } from './SquaresEditGrid';
import type { EditSlot, UseSquaresEditDraftResult } from '../../hooks/useSquaresEditDraft';
import { taskCellLabel } from '../board/cellModel';
import styles from './BoardEditColumn.module.css';

export interface BoardEditColumnProps {
  board: Board;
  /** Edit consolidation (plan D3/D4) — captured once at Edit entry
   *  (`canEditSquares`, frozen for the session). When false the squares
   *  editor is omitted. */
  squaresEditable: boolean;
  editDraft: UseSquaresEditDraftResult;
  gridSize: BoardSize;
  announcement: string;
  /** A plain empty (non-center) square was tapped — opens the Add picker. */
  onOpenPicker: (row: number, col: number) => void;
  /** Every other tap (a task cell, the pinned FREE center, an empty NONE
   *  center) — opens the square tap menu. */
  onOpenSquareMenu: (slot: EditSlot, row: number, col: number, x: number, y: number) => void;
  /** D9 keyboard-move aria-live announcement. */
  onAnnounce: (message: string) => void;
  // ── BoardOptionsSection passthrough ─────────────────────────────────────
  userId: string | undefined;
  sourceTemplate: RecurringBoardTemplate | null | undefined;
  templatesLoaded: boolean;
  weekStartDay: WeekStartDay;
  onDetailsSaved: () => void;
  onExitEdit: () => void;
  onRemoved: () => void;
}

/**
 * BoardEditColumn — the edit-mode board column (Edit consolidation, plan
 * W2): the squares editor (absent when `!squaresEditable`) plus the `BoardOptionsSection` BOARD card below it. Moved out of
 * `BoardPlaySurface` so its size stays under the D11 file-size cap; the
 * `onTapSlot` routing logic (plain-empty-square → Add picker, everything
 * else → the tap menu) and the `onKeyboardMove` announcement logic move
 * here too — `BoardPlaySurface` keeps only the overlay state
 * (`squareMenu`/`pickerState`) the callbacks below write into.
 */
export function BoardEditColumn({
  board,
  squaresEditable,
  editDraft,
  gridSize,
  announcement,
  onOpenPicker,
  onOpenSquareMenu,
  onAnnounce,
  userId,
  sourceTemplate,
  templatesLoaded,
  weekStartDay,
  onDetailsSaved,
  onExitEdit,
  onRemoved,
}: BoardEditColumnProps): React.ReactElement {
  return (
    <div className={styles.wrap}>
      {squaresEditable && (
        <div>
          {/* D7 — the ONE squares-editor grid: tap routes to the square menu
              / add picker; press-and-hold moves a square; Shuffle and moves
              skip locked squares. */}
          <SquaresEditGrid
            slots={editDraft.slots}
            gridSize={gridSize}
            announcement={announcement}
            onTapSlot={(slot, row, col, x, y) => {
              // A plain empty (non-center) square jumps straight to the Add
              // picker; every other tap (a task-holding cell, the pinned
              // FREE center, or an empty NONE center) opens the menu.
              const half = Math.floor(gridSize / 2);
              const isOddBoard = gridSize % 2 === 1;
              const atPositionalCenter = isOddBoard && row === half && col === half;
              if (slot.isEmpty && !atPositionalCenter) {
                onOpenPicker(row, col);
                return;
              }
              onOpenSquareMenu(slot, row, col, x, y);
            }}
            onCommitReorder={editDraft.commitReorder}
            onKeyboardMove={(cellId, dir) => {
              const cell = editDraft.cells.find((c) => c.cellId === cellId);
              const cellTask = cell ? editDraft.resolveTask(cell.taskId) : undefined;
              const title = (cellTask ? taskCellLabel(cellTask) : '') || 'This square';
              const result = editDraft.stageKeyboardMove(cellId, dir as KeyboardMoveDir);
              if (result.blocked === 'locked') {
                onAnnounce(`${title} is locked`);
              } else if (result.blocked === 'bounds') {
                onAnnounce('Already at the edge of the board');
              } else if (result.moved && result.row != null && result.col != null) {
                onAnnounce(`Moved ${title} to row ${result.row + 1}, column ${result.col + 1}`);
              }
            }}
          />
        </div>
      )}

      <BoardOptionsSection
        board={board}
        userId={userId}
        sourceTemplate={sourceTemplate}
        templatesLoaded={templatesLoaded}
        weekStartDay={weekStartDay}
        squaresDirty={squaresEditable && editDraft.editCount > 0}
        onDetailsSaved={onDetailsSaved}
        onExitEdit={onExitEdit}
        onRemoved={onRemoved}
      />
    </div>
  );
}
