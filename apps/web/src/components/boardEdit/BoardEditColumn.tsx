import { useMemo } from 'react';
import type { Board, BoardSize, RecurringBoardTemplate, Task, WeekStartDay } from '@oybc/shared';
import { squaresLockedReason } from '../boardActions/boardMenu';
import { BoardOptionsSection } from '../boardActions/BoardOptionsSection';
import { SquaresEditGrid, type KeyboardMoveDir } from './SquaresEditGrid';
import type { EditSlot, UseSquaresEditDraftResult } from '../../hooks/useSquaresEditDraft';
import { taskCellLabel } from '../board/cellModel';
import pageStyles from '../../pages/BoardPlayPage.module.css';
import styles from './BoardEditColumn.module.css';

export interface BoardEditColumnProps {
  board: Board;
  /** Edit consolidation (plan D3/D4) — captured once at Edit entry
   *  (`canEditSquares`, frozen for the session). When false the squares
   *  editor is replaced by `squaresLockedReason`'s muted line. */
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
  taskMap: Record<string, Task>;
  dealtTaskIds: string[];
  counterFamilyByTaskId: Record<string, string>;
  onDetailsSaved: () => void;
  onExitEdit: () => void;
  onRemoved: () => void;
}

/**
 * BoardEditColumn — the edit-mode board column (Edit consolidation, plan
 * W2): the squares editor (or, when `!squaresEditable`, the D4 muted reason
 * line) plus the `BoardOptionsSection` BOARD card below it. Moved out of
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
  taskMap,
  dealtTaskIds,
  counterFamilyByTaskId,
  onDetailsSaved,
  onExitEdit,
  onRemoved,
}: BoardEditColumnProps): React.ReactElement {
  // Pinned per-render instant (react-hooks/purity — `Date.now()` itself is
  // flagged as an impure call by the react-compiler lint rule; mirrors
  // `BoardOptionsSection`'s `nowPinned`). This component only mounts for an
  // Edit session, so the pin is effectively "at Edit entry" too.
  const nowPinned = useMemo(() => new Date(), []);
  const reason = squaresLockedReason(board, nowPinned.getTime());

  return (
    <div className={styles.wrap}>
      {squaresEditable ? (
        <div>
          {/* D7 — the ONE squares-editor grid: tap routes to the square menu
              / add picker; press-and-hold moves a square; Shuffle and moves
              skip locked squares. */}
          <p className={pageStyles.editHint}>
            <b>Tap a square</b> to replace, edit, lock or remove it. Press and hold to move it.
            Shuffle and moves skip locked squares.
          </p>
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
      ) : (
        // D4 — SQUARES hidden: one muted line explaining why, no grid, no
        // save bar (the panel drops its 76pt clearance too — see BoardEditPanel).
        <p className={pageStyles.editHint}>{reason}</p>
      )}

      <BoardOptionsSection
        board={board}
        userId={userId}
        sourceTemplate={sourceTemplate}
        templatesLoaded={templatesLoaded}
        weekStartDay={weekStartDay}
        taskMap={taskMap}
        dealtTaskIds={dealtTaskIds}
        counterFamilyByTaskId={counterFamilyByTaskId}
        squaresDirty={squaresEditable && editDraft.editCount > 0}
        onDetailsSaved={onDetailsSaved}
        onExitEdit={onExitEdit}
        onRemoved={onRemoved}
      />
    </div>
  );
}
