import { useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { AchievementTrigger, boardDisplayName, isCoreBoard, type Board, type BoardTask, type Task } from '@oybc/shared';
import { placedTaskFor } from '../../../db/adapters';
import { resolveSquareView, type SquareViewData } from './resolveSquareView';
import { isUncompleteBlockedBySeal } from '../../../db/operations/taskEvents';
import { AchievementBody } from './AchievementBody';
import { ClosedRow } from './ClosedRow';
import { CompoundBody } from './CompoundBody';
import { CountingBody } from './CountingBody';
import { NormalBody } from './NormalBody';
import { SquareSheet } from './SquareSheet';
import styles from './SquareSheet.module.css';
import { childLog, childRemove, childToggle, countingLog, type Play, type WriteDeps } from './squareWrites';
import { useBusyLook } from '../../../hooks/useBusyLook';
import { closedLabel, daysLeftLabel, isLateLogRoutable, liveStrip, logStripText } from './squareSheetModel';

type Data = SquareViewData;

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
  onToggleNormal?: (boardTaskId: string, title: string, wasDone: boolean) => void;
  /** The hold menu's "Log other amount…" / "Remove…": open the counting entry straight away. */
  initialEntry?: 'add' | 'remove';
  /** `hero` renders the body alone on Task Detail's coloured band (no frame); default `sheet`. */
  variant?: 'sheet' | 'hero';
  /** Hero only: Edit, placed by each body (beside Mark done / right of Remove… / below the list). */
  trailing?: React.ReactNode;
  /** Hero only: the Normal not-done pill's label, from the anchor's timeframe. */
  notDoneLabel?: string;
  /**
   * Hero only: the compound child the hero drives (the task is a direct child of
   * this square's compound — binding decision 3, amended 2026-10-18). Its own
   * body renders — counting chips / the Normal toggle — through the compound
   * child writes.
   */
  heroChildTaskId?: string | null;
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
function ResolvedSheet({ board, data, play, quiet, onClose, onOpenInLibrary, onLateLog, onOpenBoard, onToggleNormal, initialEntry, variant = 'sheet', trailing, notDoneLabel, heroChildTaskId, bt, task }: SquareSheetHostProps & { bt: BoardTask; task: Task }): React.ReactElement {
  const [strip, setStrip] = useState<Strip | null>(null);
  const [openChildId, setOpenChildId] = useState<string | null>(null);
  const [now] = useState(() => Date.now());

  const { taskMap } = data;
  const { sq, sealed, done, count, kind } = resolveSquareView(board, data, bt, task, play.pendingCounts);
  // Controls are inert for the whole write; they only LOOK busy if it runs long.
  const dim = useBusyLook(play.isWriting);

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
  const closedRow = sealed
    ? <ClosedRow label={closedLabel(board.sealedAt)} onLateLog={isLateLogRoutable(sq.type) ? () => onLateLog(task.id) : undefined} />
    : null;


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

  const deps: WriteDeps = { play, quiet, taskMap, sharedCounterSourceIds: data.sharedCounterSourceIds };

  /** Each log resolves whether it COMMITTED (an entry field clears only then). */
  const logCounting = async (direction: 'add' | 'remove', amount: number, persist: boolean): Promise<boolean> => {
    if (sealed) return false;
    const r = await countingLog(deps, bt, task, direction, amount, persist);
    if (r) showStrip('self', logStripText(direction === 'add' ? 'logged' : 'removed', r.applied, kind, sq.unit ?? '', boardLabel), r.undo);
    return r !== null;
  };

  const logChild = async (childTaskId: string, amount: number, persist: boolean): Promise<boolean> => {
    const child = sq.children?.find((c) => c.taskId === childTaskId);
    if (!child?.count || sealed) return false;
    const r = await childLog(deps, childTaskId, amount, persist);
    if (r) showStrip(childTaskId, logStripText('logged', r.applied, child.count.kind, child.count.unit, boardLabel), r.undo);
    return r !== null;
  };

  const toggleChild = async (childTaskId: string): Promise<void> => {
    const child = sq.children?.find((c) => c.taskId === childTaskId);
    if (!child || sealed) return;
    const r = await childToggle(deps, childTaskId);
    if (r) showStrip('toggle', `${child.title} · ${r.to ? 'done' : 'not done'}`, r.undo);
  };

  const removeChild = async (childTaskId: string, amount: number): Promise<boolean> => {
    const child = sq.children?.find((c) => c.taskId === childTaskId);
    if (!child?.count || sealed) return false;
    const r = await childRemove(deps, childTaskId, amount);
    if (r) showStrip(childTaskId, logStripText('removed', r.applied, child.count.kind, child.count.unit, boardLabel), r.undo);
    return r !== null;
  };

  const toggleNormal = async (): Promise<void> => {
    if (onToggleNormal) {
      onToggleNormal(bt.id, task.title, done);
      return;
    }
    if (play.isWriting) return;
    let ok = false;
    await quiet(async () => { ok = await play.handleComplete(bt.id, { isCompleted: !done }); });
    // The Undo is quiet like the forward write (it never raises the credited toast).
    const reverse = async (): Promise<boolean> => {
      let reverted = false;
      await quiet(async () => { reverted = await play.handleComplete(bt.id, { isCompleted: done }); });
      return reverted;
    };
    if (ok) showStrip('normal', `${task.title} · ${done ? 'not done' : 'done'}`, reverse);
  };

  const hero = variant === 'hero';
  const header = { type: sq.type, title: sq.title, closedBoardName: sealed ? boardLabel : undefined, onClose, onOpenInLibrary: () => onOpenInLibrary(task.id) };

  // The hero drives one compound child: that child's own body, not the compound's.
  const heroChild = hero && heroChildTaskId ? sq.children?.find((c) => c.taskId === heroChildTaskId) : undefined;
  if (heroChild) {
    const childBody = heroChild.count ? (
      <CountingBody
        count={heroChild.count.current} goal={heroChild.count.max} kind={heroChild.count.kind} unit={heroChild.count.unit}
        boardLabel={boardLabel} busy={play.isWriting} dim={dim} closedRow={closedRow}
        stripText={visible?.key === heroChild.taskId ? visible.text : null}
        removeDisabled={heroChild.count.current <= 0} trailing={trailing}
        onLog={(d, a, p) => (d === 'add' ? logChild(heroChild.taskId, a, p) : removeChild(heroChild.taskId, a))}
        onUndo={() => void runUndo()}
      />
    ) : (
      <NormalBody
        done={heroChild.isCompleted} busy={play.isWriting} dim={dim} blocked={blockedIds.has(heroChild.taskId)} closedRow={closedRow}
        onToggle={() => void toggleChild(heroChild.taskId)} stripText={visible?.key === 'toggle' ? visible.text : null}
        onUndo={() => void runUndo()} trailing={trailing} notDoneLabel={notDoneLabel}
      />
    );
    return (
      <div className={`${styles.body} ${heroChild.count ? styles.onColor : ''}`} style={{ marginTop: 18 }}>
        {childBody}
      </div>
    );
  }

  let body: React.ReactElement;
  if (sq.type === 'counting') {
    body = (
      <CountingBody
        count={count} goal={sq.maxCount ?? 0} kind={kind} unit={sq.unit ?? ''} boardLabel={boardLabel}
        busy={play.isWriting} dim={dim} closedRow={closedRow} stripText={visible?.key === 'self' ? visible.text : null}
        removeDisabled={count <= 0} initialEntry={initialEntry} trailing={hero ? trailing : undefined}
        onLog={(d, a, p) => logCounting(d, a, p)} onUndo={() => void runUndo()}
      />
    );
  } else if (sq.type === 'compound') {
    body = (
      <CompoundBody
        children={sq.children ?? []} done={done} boardLabel={boardLabel} busy={play.isWriting} dim={dim} closedRow={closedRow}
        blockedChildIds={blockedIds}
        openChildId={openChildId} stripText={visible && visible.key === openChildId ? visible.text : null}
        toggleStripText={visible?.key === 'toggle' ? visible.text : null}
        onToggleChild={(id) => void toggleChild(id)}
        onUnfoldChild={setOpenChildId}
        onLogChild={(id, a, p) => logChild(id, a, p)} onUndoChild={() => void runUndo()} onUndoToggle={() => void runUndo()}
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
        done={done} busy={play.isWriting} dim={dim} blocked={blockedIds.has(task.id)} closedRow={closedRow}
        onToggle={() => void toggleNormal()} stripText={visible?.key === 'normal' ? visible.text : null}
        onUndo={() => void runUndo()} trailing={hero ? trailing : undefined} notDoneLabel={hero ? notDoneLabel : undefined}
      />
    );
  }
  if (hero) {
    return (
      <div className={`${styles.body} ${sq.type === 'normal' ? '' : styles.onColor}`} style={{ marginTop: 18 }}>
        {body}
        {sq.type === 'compound' && trailing && <div style={{ display: 'flex', justifyContent: 'flex-end' }}>{trailing}</div>}
      </div>
    );
  }
  return <SquareSheet {...header}>{body}</SquareSheet>;
}
