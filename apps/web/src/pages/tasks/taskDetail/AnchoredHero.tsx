import type { Board, BoardTask, Task } from '@oybc/shared';
import { useBoardPlay, useBoardPlayData } from '../../../hooks';
import { notDoneLabel } from './taskDetailModel';
import { SquareSheetHost } from '../../../components/boardPlay/squareSheet/SquareSheetHost';
import { useSquareToasts } from '../../../components/boardPlay/squareSheet/useSquareToasts';

const noop = (): void => {};

export interface AnchoredHeroProps {
  task: Task;
  anchor: { board: Board; placement: BoardTask };
  userId: string;
  /** Edit (placed by each body). */
  trailing: React.ReactNode;
  onOpenTask: (taskId: string) => void;
}

/**
 * The hero's one live control, anchored to the task's soonest-ending in-play
 * board: the SAME body, resolvers and writes the square sheet uses — a log from
 * Task Detail is a log on that board (it is active, so it stamps `now` — E6).
 * Mounted only while an anchor exists (hooks can't be conditional), which is
 * how "no anchor → no control" falls out. Bingo / greenlog moments are not
 * raised from here (no board surface to host them).
 *
 * @returns The hero body.
 */
export function AnchoredHero({ task, anchor, userId, trailing, onOpenTask }: AnchoredHeroProps): React.ReactElement | null {
  const { board } = anchor;
  const data = useBoardPlayData(board, userId);
  const toasts = useSquareToasts();
  const play = useBoardPlay({
    board, editMode: false, boardTasks: data.boardTasks, taskMap: data.taskMap, compoundChildrenByCompound: data.compoundChildrenByCompound,
    gridSize: data.gridSize, playLocked: board.sealedAt != null, squareWindowContext: data.squareWindowContext,
    sharedCounterSourceIds: data.sharedCounterSourceIds, onFlash: noop, onCreditedToast: toasts.onCreditedToast, setContextMenu: noop,
  });
  if (!data.boardTasksLoaded || !data.taskMap[task.id]) return null;
  return (
    <SquareSheetHost
      variant="hero" boardTaskId={anchor.placement.id} board={board} data={data} play={play} quiet={toasts.captureCredits}
      onClose={noop} onOpenInLibrary={onOpenTask} onLateLog={noop} onOpenBoard={noop} trailing={trailing} notDoneLabel={notDoneLabel(board.timeframe)}
    />
  );
}
