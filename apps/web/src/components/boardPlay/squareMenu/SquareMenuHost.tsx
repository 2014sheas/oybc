import { useLiveQuery } from 'dexie-react-hooks';
import { boardDisplayName, type Board, type BoardTask, type Task, type TaskType } from '@oybc/shared';
import { placedTaskFor } from '../../../db/adapters';
import { isUncompleteBlockedBySeal } from '../../../db/operations/taskEvents';
import { resolveSharedCounterSourceId } from '../../boardPlaySharedCounterUtils';
import { resolveSquareView, type SquareViewData } from '../squareSheet/resolveSquareView';
import { isLateLogRoutable, logStripText } from '../squareSheet/squareSheetModel';
import { childLog, childToggle, countingLog, type Play, type Undo, type WriteDeps } from '../squareSheet/squareWrites';
import type { useSquareToasts } from '../squareSheet/useSquareToasts';
import { SquareMenu } from './SquareMenu';
import { buildSquareMenu, type MenuChild, type MenuItem } from './squareMenuItems';

export interface SquareMenuHostProps {
  squareId: string;
  position: { x: number; y: number };
  board: Board;
  data: SquareViewData;
  play: Play;
  toasts: ReturnType<typeof useSquareToasts>;
  onClose: () => void;
  /** Opens the square sheet; `entry` goes straight into the counting entry. */
  onOpenSheet: (boardTaskId: string, entry?: 'add' | 'remove') => void;
  onOpenInLibrary: (taskId: string) => void;
  onLateLog: (taskId: string) => void;
  onOpenBoard: (boardId: string) => void;
}

/**
 * SquareMenuHost — resolves one square, builds its hold menu
 * (`buildSquareMenu`) and routes each item to the same writes the tap and the
 * sheet use. A menu write has no sheet open, so it raises the toast whose Undo
 * reverses exactly that write (committed-only, the amount actually applied).
 *
 * @returns The menu, or null when the placement or its task is gone.
 */
export function SquareMenuHost(props: SquareMenuHostProps): React.ReactElement | null {
  const bt = props.data.boardTasks.find((b) => b.id === props.squareId);
  const task = bt ? placedTaskFor(bt, props.data.taskMap) : undefined;
  if (!bt || !task) return null;
  return <ResolvedMenu {...props} bt={bt} task={task} />;
}

function ResolvedMenu({ position, board, data, play, toasts, onClose, onOpenSheet, onOpenInLibrary, onLateLog, onOpenBoard, bt, task }: SquareMenuHostProps & { bt: BoardTask; task: Task }): React.ReactElement {
  const { taskMap } = data;
  const view = resolveSquareView(board, data, bt, task, play.pendingCounts);
  const { sq } = view;
  const boardLabel = boardDisplayName(board);
  const uncompleteBlocked = useLiveQuery(
    async () => (sq.type === 'normal' && view.done ? isUncompleteBlockedBySeal(task.id) : false),
    [task.id, sq.type, view.done],
  );

  const defaultOf = (t: Task): number | null | undefined => {
    const source = resolveSharedCounterSourceId(t, data.sharedCounterSourceIds);
    return (source ? taskMap[source] : t)?.defaultLogAmount;
  };
  const children: MenuChild[] = (sq.children ?? []).map((c) => ({
    id: c.taskId, title: c.title, type: (c.taskType ?? 'normal') as TaskType, isCompleted: c.isCompleted,
    count: c.count && { kind: c.count.kind, unit: c.count.unit, defaultAmount: taskMap[c.taskId] ? defaultOf(taskMap[c.taskId]) : undefined },
  }));
  const watched = data.achievementBadgesByBoardTaskId[bt.id];
  const watchedBoard = task.referencedBoardId ? data.allBoards.find((b) => b.id === task.referencedBoardId && !b.isDeleted) : undefined;

  const model = buildSquareMenu({
    type: sq.type, title: sq.title, closed: view.sealed,
    lateLogRoutable: isLateLogRoutable(sq.type),
    done: view.done, uncompleteBlocked,
    counting: sq.type === 'counting' ? { count: view.count, goal: sq.maxCount ?? 0, kind: view.kind, unit: sq.unit ?? '', defaultAmount: defaultOf(task) } : undefined,
    compound: sq.type === 'compound' ? { children } : undefined,
    watchedBoardName: watchedBoard ? (watched?.referencedBoardName?.trim() || watchedBoard.name) : null,
  });

  const deps: WriteDeps = { play, quiet: toasts.captureCredits, taskMap, sharedCounterSourceIds: data.sharedCounterSourceIds };

  /** The toast whose Undo reverses exactly this committed write. */
  const raise = (text: string, undo: Undo, detail?: string): void => {
    toasts.setCreditedToast({
      sourceTaskId: task.id, counterName: '', amount: 1, verb: 'logged', boardNames: [], key: Date.now(), text, detail,
      undo: { kind: 'uncomplete', revert: async () => { if ((await undo()) === false) throw new Error('Undo did not commit'); } },
    });
  };

  const run = async (item: MenuItem): Promise<void> => {
    const a = item.action;
    switch (a.kind) {
      case 'toggleNormal':
        if (play.isWriting) return;
        await toasts.tapNormal(play.handleComplete, { boardTaskId: bt.id, taskId: task.id, title: task.title, wasDone: view.done, boardLabel });
        return;
      case 'log': {
        const r = await countingLog(deps, bt, task, 'add', a.amount, false);
        if (r) raise(logStripText('logged', r.applied, view.kind, sq.unit ?? '', boardLabel), r.undo);
        return;
      }
      case 'completeNext': {
        const child = sq.children?.find((c) => c.taskId === a.next.childId);
        if (!child) return;
        if (a.next.kind === 'toggle') {
          const r = await childToggle(deps, child.taskId);
          if (r) raise(`${child.title} · ${r.to ? 'done' : 'not done'}`, r.undo, boardLabel);
        } else if (child.count) {
          const r = await childLog(deps, child.taskId, a.amount ?? 1, false);
          if (r) raise(logStripText('logged', r.applied, child.count.kind, child.count.unit, boardLabel), r.undo);
        }
        return;
      }
      case 'logOther': onOpenSheet(bt.id, 'add'); return;
      case 'remove': onOpenSheet(bt.id, 'remove'); return;
      case 'allSubtasks':
      case 'details': onOpenSheet(bt.id); return;
      case 'library': onOpenInLibrary(task.id); return;
      case 'lateLog': onLateLog(task.id); return;
      case 'openBoard': if (watchedBoard) onOpenBoard(watchedBoard.id); return;
    }
  };

  return (
    <SquareMenu
      model={model} position={position} busy={play.isWriting}
      onChoose={(item) => { onClose(); void run(item); }}
      onClose={onClose}
    />
  );
}
