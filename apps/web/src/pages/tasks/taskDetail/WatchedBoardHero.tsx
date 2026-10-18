import { useState } from 'react';
import { AchievementTrigger, BoardStatus, CenterSquareType, closestLine, effectiveCenter, isCoreBoard, type Board, type RecurringBoardTemplate, type Task } from '@oybc/shared';
import { useBoardPlayData } from '../../../hooks';
import { AchievementBody } from '../../../components/boardPlay/squareSheet/AchievementBody';
import { daysLeftLabel } from '../../../components/boardPlay/squareSheet/squareSheetModel';
import sheet from '../../../components/boardPlay/squareSheet/SquareSheet.module.css';

/**
 * The Achievement hero's watched-board card. It reads the WATCHED board's own
 * per-cell completion through the kernel (`useBoardPlayData`; a closed board
 * reads its `sealedCompletedCells`), so the closest-line row and the progress
 * need no anchor placement.
 */
function WatchedBoard({ task, board, userId, onOpenBoard, trailing }: {
  task: Task; board: Board; userId: string; onOpenBoard: () => void; trailing: React.ReactNode;
}): React.ReactElement | null {
  const data = useBoardPlayData(board, userId);
  const [now] = useState(() => Date.now());
  const size = board.boardSize;
  if (!data.boardTasksLoaded) return null;
  const sealed = board.sealedAt != null;
  const grid = Array.from({ length: size * size }, () => false);
  if (sealed) for (const i of board.sealedCompletedCells ?? []) grid[i] = true;
  else for (const c of Object.values(data.cellStateByBoardTaskId)) grid[c.idx] = c.isCompleted;
  // A FREE centre counts as complete (the kernel's completion grid), so it never reads as a gap.
  if (size % 2 === 1 && effectiveCenter(board.centerSquareType) === CenterSquareType.FREE) grid[Math.floor(size / 2) * size + Math.floor(size / 2)] = true;
  const line = closestLine(grid, size);
  const lines = sealed ? (board.completedLineIds ?? []).length : data.liveCompletedLineIds.length;
  const bingo = task.achievementTrigger === AchievementTrigger.BINGO;
  const met = bingo ? lines > 0 : grid.every(Boolean) || board.status === BoardStatus.COMPLETED;
  return (
    <div className={`${sheet.body} ${sheet.onColor}`} style={{ marginTop: 18 }}>
      <AchievementBody
        statusLabel={met ? 'Done' : 'Watching'}
        timeframeLabel={`${isCoreBoard(board) ? 'Core · ' : ''}${board.timeframe}`}
        daysLeft={daysLeftLabel(board.endDate, now)}
        watchedName={board.name}
        progress={bingo ? `${lines > 0 ? 1 : 0} / 1 bingo` : 'Greenlog'}
        closestLine={line ? { done: line.done, cells: line.cells.map((i) => grid[i]) } : undefined}
        onOpenBoard={onOpenBoard}
        trailing={trailing}
      />
    </div>
  );
}

export interface WatchedBoardHeroProps {
  task: Task;
  userId: string;
  /** undefined while loading, null when the board is gone. */
  board: Board | null | undefined;
  template: RecurringBoardTemplate | null | undefined;
  onOpenBoard: (boardId: string) => void;
  trailing: React.ReactNode;
}

/**
 * The Achievement hero (no manual completion): the watched-board card and
 * `Open ‹board›`. A template watcher has no single board to open.
 *
 * @returns The hero body, or null while loading.
 */
export function WatchedBoardHero({ task, userId, board, template, onOpenBoard, trailing }: WatchedBoardHeroProps): React.ReactElement | null {
  if (board) return <WatchedBoard task={task} board={board} userId={userId} onOpenBoard={() => onOpenBoard(board.id)} trailing={trailing} />;
  if (board === undefined && template === undefined) return null;
  const tplName = template?.name;
  return (
    <div className={`${sheet.body} ${sheet.onColor}`} style={{ marginTop: 18 }}>
      <AchievementBody
        statusLabel={task.isCompleted ? 'Done' : 'Watching'} timeframeLabel={null} daysLeft={null}
        watchedName={tplName ?? 'Board unavailable'}
        progress={task.referencedTemplateId ? `${task.requiredCount ?? 0} required` : ''}
        trailing={trailing}
      />
    </div>
  );
}
