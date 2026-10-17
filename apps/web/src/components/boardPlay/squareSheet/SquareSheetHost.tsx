import { useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  AchievementTrigger, boardDisplayName, isCoreBoard, isWindowStampedDerived, resolveFamilyCountKind,
  type Board, type BoardTask, type Task,
} from '@oybc/shared';
import type { BoardPlayData, UseBoardPlayResult } from '../../../hooks';
import { placedTaskFor, resolveClosedBoardCounterDisplay, taskToSquareData, taskToSquareState } from '../../../db/adapters';
import { setCounterDefaultLogAmount } from '../../../db/operations/tasks';
import { isUncompleteBlockedBySeal } from '../../../db/operations/taskEvents';
import { resolveSharedCounterSourceId } from '../../boardPlaySharedCounterUtils';
import { AchievementBody } from './AchievementBody';
import { ClosedRow } from './ClosedRow';
import { CompoundBody } from './CompoundBody';
import { CountingBody } from './CountingBody';
import { NormalBody } from './NormalBody';
import { SquareSheet } from './SquareSheet';
import { closedLabel, daysLeftLabel, isLateLogRoutable, liveStrip, logStripText } from './squareSheetModel';

type Data = Pick<
  BoardPlayData,
  | 'boardTasks' | 'taskMap' | 'compoundChildrenByCompound' | 'allBoards' | 'achievementBadgesByBoardTaskId'
  | 'cellStateByBoardTaskId' | 'sharedCounterSourceIds' | 'squareWindowContext' | 'gridSize'
>;
type Play = Pick<
  UseBoardPlayResult,
  | 'handleComplete' | 'handleSharedCounterIncrement' | 'handleSharedCounterDecrement' | 'undoCounterLog'
  | 'handleCompoundChildToggle' | 'handleCompoundChildIncrement' | 'logStandaloneCount' | 'isWriting' | 'writeSeq' | 'getWriteSeq'
>;

export interface SquareSheetHostProps {
  boardTaskId: string;
  board: Board;
  data: Data;
  play: Play;
  /** Runs a write with its counter-credit toast withheld: EVERY write made from inside the sheet. */
  quiet: (write: () => Promise<void>) => Promise<unknown>;
  onClose: () => void;
  onOpenInLibrary: (taskId: string) => void;
  /** Closed boards: dismiss, then open the existing late-log sheet. */
  onLateLog: (taskId: string) => void;
  onOpenBoard: (boardId: string) => void;
  /** Normal "Mark done": the surface closes the sheet and raises the same Undo toast a tap does. */
  onToggleNormal: (boardTaskId: string, title: string, wasDone: boolean) => void;
}

/** An Undo strip: its line, the one write that reverses it, and the write sequence it was made at. */
interface Strip {
  /** `self` (the hero), `toggle` (the checklist) or the unfolded child's task id. */
  key: string;
  text: string;
  /** Resolves false (or throws) when the reversal did not commit. */
  undo: () => Promise<boolean | void>;
  seq: number;
}

const NO_IDS: ReadonlySet<string> = new Set();

/**
 * SquareSheetHost — resolves one placement against the board's read-model and
 * routes the sheet's gestures to the existing writes (`useBoardPlay`).
 *
 * @returns The sheet, or null when the placement or its task is gone.
 */
export function SquareSheetHost(props: SquareSheetHostProps): React.ReactElement | null {
  const bt = props.data.boardTasks.find((b) => b.id === props.boardTaskId);
  const task = bt ? placedTaskFor(bt, props.data.taskMap) : undefined;
  if (!bt || !task) return null;
  return <ResolvedSheet {...props} bt={bt} task={task} />;
}

function logError(what: string, err: unknown): void {
  console.error(`${what} failed:`, err);
}

/**
 * The sheet for a resolved placement. Owns only transient state: the Undo
 * strip (written only when its write committed; hidden by any later write on
 * this board; gone when the sheet closes) and the one unfolded compound child.
 */
function ResolvedSheet({ board, data, play, quiet, onClose, onOpenInLibrary, onLateLog, onOpenBoard, onToggleNormal, bt, task }: SquareSheetHostProps & { bt: BoardTask; task: Task }): React.ReactElement {
  const [strip, setStrip] = useState<Strip | null>(null);
  const [openChildId, setOpenChildId] = useState<string | null>(null);
  const [now] = useState(() => Date.now());

  const { taskMap, squareWindowContext } = data;
  const sealed = board.sealedAt != null;
  const children = data.compoundChildrenByCompound[task.id] ?? [];
  const sq = taskToSquareData(task, children, taskMap, data.compoundChildrenByCompound, squareWindowContext, bt.childTargets);
  const state = taskToSquareState(
    task, children, taskMap, data.compoundChildrenByCompound, squareWindowContext, data.cellStateByBoardTaskId[bt.id], bt.childTargets,
  );
  const cellIndex = bt.row * data.gridSize + bt.col;
  const done = sealed ? (board.sealedCompletedCells ?? []).includes(cellIndex) : state.isCompleted;

  // Completed Normal rows whose green a sealed window holds cannot be un-completed.
  const heldIds = [
    ...(sq.type === 'normal' && done ? [task.id] : []),
    ...(sq.children ?? []).filter((c) => !c.count && c.isCompleted).map((c) => c.taskId),
  ];
  const heldKey = heldIds.join('|');
  const blockedIds = useLiveQuery(
    async () => new Set((await Promise.all(heldIds.map(async (id) => ((await isUncompleteBlockedBySeal(id)) ? id : null)))).filter((id): id is string => id !== null)),
    [heldKey],
  ) ?? NO_IDS;

  const boardLabel = boardDisplayName(board);
  const count = sealed
    ? (sq.type === 'counting' ? resolveClosedBoardCounterDisplay(task, squareWindowContext.eventsByTaskId, board).displayed : 0)
    : state.currentCount;
  const hubLinked = sq.type === 'counting' && task.sharedCounterId != null && !isWindowStampedDerived(task);
  const closedRow = sealed
    ? <ClosedRow label={closedLabel(board.sealedAt)} onLateLog={isLateLogRoutable(sq.type, hubLinked) ? () => onLateLog(task.id) : undefined} />
    : null;

  const sourceId = resolveSharedCounterSourceId(task, data.sharedCounterSourceIds);
  const kind = sq.countKind ?? resolveFamilyCountKind(task, (id) => taskMap[id]);

  /** Shows a strip made by a write that COMMITTED. */
  const showStrip = (key: string, text: string, undo: Strip['undo']): void => setStrip({ key, text, undo, seq: play.getWriteSeq() });
  const visible = liveStrip(strip, play.writeSeq);

  const runUndo = async (): Promise<void> => {
    if (!visible) return;
    let ok: boolean;
    try {
      ok = (await visible.undo()) !== false;
    } catch (err) {
      logError('Undo', err);
      ok = false;
    }
    // A failed Undo keeps the strip (re-stamped: the undo attempt was itself a write).
    if (ok) setStrip(null);
    else setStrip((cur) => (cur ? { ...cur, seq: play.getWriteSeq() } : cur));
  };

  const logCounting = async (direction: 'add' | 'remove', amount: number, persist: boolean): Promise<void> => {
    if (play.isWriting || sealed) return;
    let applied = 0;
    let undo: Strip['undo'] | null = null;
    await quiet(async () => {
      if (sourceId) {
        applied = direction === 'add'
          ? await play.handleSharedCounterIncrement(sourceId, amount, persist)
          : await play.handleSharedCounterDecrement(sourceId, amount, false);
        undo = () => play.undoCounterLog(sourceId);
        return;
      }
      const r = await play.logStandaloneCount(bt.id, direction === 'add' ? amount : -amount);
      if (!r) return;
      applied = r.applied;
      // Restore the count read INSIDE the write — the true prior value.
      undo = () => play.handleComplete(bt.id, { currentCount: r.before });
    });
    if (applied <= 0 || !undo) return;
    // A shared counter's own write already persisted its default.
    if (persist && direction === 'add' && !sourceId) void setCounterDefaultLogAmount(task.id, amount).catch((e) => logError('Persist default log amount', e));
    showStrip('self', logStripText(direction === 'add' ? 'logged' : 'removed', applied, kind, sq.unit ?? '', boardLabel), undo);
  };

  const logChild = async (childTaskId: string, amount: number, persist: boolean): Promise<void> => {
    const child = sq.children?.find((c) => c.taskId === childTaskId);
    const childTask = taskMap[childTaskId];
    if (!child?.count || !childTask || play.isWriting || sealed) return;
    const childSource = resolveSharedCounterSourceId(childTask, data.sharedCounterSourceIds);
    let applied = 0;
    await quiet(async () => { applied = await play.handleCompoundChildIncrement(childTaskId, 1, amount); });
    if (applied <= 0) return;
    if (persist) void setCounterDefaultLogAmount(childSource ?? childTaskId, amount).catch((e) => logError('Persist default log amount', e));
    showStrip(
      childTaskId,
      logStripText('logged', applied, child.count.kind, child.count.unit, boardLabel),
      () => (childSource ? play.undoCounterLog(childSource) : play.handleCompoundChildIncrement(childTaskId, -1, applied).then((n) => n > 0)),
    );
  };

  const toggleChild = async (childTaskId: string): Promise<void> => {
    const child = sq.children?.find((c) => c.taskId === childTaskId);
    if (!child || play.isWriting || sealed) return;
    let to: boolean | null = null;
    await quiet(async () => { to = await play.handleCompoundChildToggle(childTaskId); });
    if (to === null) return;
    const now = to as boolean;
    showStrip('toggle', `${child.title} · ${now ? 'done' : 'not done'}`, () => play.handleCompoundChildToggle(childTaskId, !now).then((r) => r !== null));
  };

  const header = { type: sq.type, title: sq.title, closedBoardName: sealed ? boardLabel : undefined, onClose, onOpenInLibrary: () => onOpenInLibrary(task.id) };

  let body: React.ReactElement;
  if (sq.type === 'counting') {
    body = (
      <CountingBody
        count={count} goal={sq.maxCount ?? 0} kind={kind} unit={sq.unit ?? ''} boardLabel={boardLabel}
        busy={play.isWriting} closedRow={closedRow} stripText={visible?.key === 'self' ? visible.text : null}
        removeDisabled={count <= 0}
        onLog={(d, a, p) => void logCounting(d, a, p)} onUndo={() => void runUndo()}
      />
    );
  } else if (sq.type === 'compound') {
    body = (
      <CompoundBody
        children={sq.children ?? []} done={done} boardLabel={boardLabel} busy={play.isWriting} closedRow={closedRow}
        blockedChildIds={blockedIds}
        openChildId={openChildId} stripText={visible && visible.key === openChildId ? visible.text : null}
        toggleStripText={visible?.key === 'toggle' ? visible.text : null}
        onToggleChild={(id) => void toggleChild(id)}
        onUnfoldChild={setOpenChildId}
        onLogChild={(id, a, p) => void logChild(id, a, p)} onUndoChild={() => void runUndo()} onUndoToggle={() => void runUndo()}
        onOpenChild={onOpenInLibrary}
      />
    );
  } else if (sq.type === 'achievement') {
    const badge = data.achievementBadgesByBoardTaskId[bt.id];
    const ref = task.referencedBoardId ? data.allBoards.find((b) => b.id === task.referencedBoardId && !b.isDeleted) : undefined;
    // An absent trigger is GREENLOG (the default everywhere else).
    const bingo = task.achievementTrigger === AchievementTrigger.BINGO;
    const template = badge?.mode === 'recurringTemplate';
    body = (
      <AchievementBody
        statusLabel={done ? 'Done' : 'Watching'}
        timeframeLabel={ref ? `${isCoreBoard(ref) ? 'Core · ' : ''}${ref.timeframe}` : null}
        daysLeft={ref ? daysLeftLabel(ref.endDate, now) : null}
        watchedName={(template ? badge?.templateName : badge?.referencedBoardName)?.trim() || 'Board unavailable'}
        progress={template
          ? `${badge?.templateInWindowMet ?? 0} / ${badge?.templateRequiredCount ?? 0}`
          : bingo ? `${badge?.referencedBoardCompleted ? 1 : 0} / 1 bingo` : 'Greenlog'}
        onOpenBoard={ref ? () => onOpenBoard(ref.id) : undefined}
      />
    );
  } else {
    body = (
      <NormalBody
        done={done} busy={play.isWriting} blocked={blockedIds.has(task.id)} closedRow={closedRow}
        onToggle={() => onToggleNormal(bt.id, task.title, done)}
      />
    );
  }
  return <SquareSheet {...header}>{body}</SquareSheet>;
}
