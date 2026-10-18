/**
 * The square gestures' writes, shared by the square sheet and the hold menu:
 * each runs ONE `useBoardPlay` write with its credit toast withheld and
 * reports what COMMITTED (the amount actually applied, and the write that
 * reverses exactly it) — or null when nothing was written.
 */
import { quantizeCount, type BoardTask, type Task } from '@oybc/shared';
import type { UseBoardPlayResult } from '../../../hooks';
import { setCounterDefaultLogAmount } from '../../../db/operations/tasks';
import { resolveSharedCounterSourceId } from '../../boardPlaySharedCounterUtils';

export type Play = Pick<
  UseBoardPlayResult,
  | 'handleComplete' | 'handleSharedCounterIncrement' | 'handleSharedCounterDecrement' | 'undoCounterLog'
  | 'handleCompoundChildToggle' | 'handleCompoundChildIncrement' | 'logStandaloneCount' | 'isWriting' | 'writeSeq' | 'getWriteSeq'
  | 'pendingCounts' | 'withPending'
>;

export interface WriteDeps {
  play: Play;
  /** Runs a write with its counter-credit toast withheld. */
  quiet: (write: () => Promise<void>) => Promise<unknown>;
  taskMap: Record<string, Task>;
  sharedCounterSourceIds: Set<string>;
}

/** Resolves false (or throws) when the reversal did not commit. */
export type Undo = () => Promise<boolean | void>;

export interface Committed {
  /** The amount actually applied (a clamped removal reports the real amount). */
  applied: number;
  undo: Undo;
}

function logError(what: string, err: unknown): void {
  console.error(`${what} failed:`, err);
}

/** Persists a typed amount as the counter's default, after the write committed. */
function persistDefault(taskId: string, amount: number): void {
  void setCounterDefaultLogAmount(taskId, amount).catch((e) => logError('Persist default log amount', e));
}

/**
 * Adds / removes an amount on a Counting square. A shared counter writes
 * through its source (which persists its own default); a standalone square
 * reads its prior count INSIDE the write (`logStandaloneCount`).
 *
 * @returns what committed, or null (busy, locked, clamped no-op, failure).
 */
export async function countingLog(
  d: WriteDeps, bt: BoardTask, task: Task, direction: 'add' | 'remove', amount: number, persist: boolean,
): Promise<Committed | null> {
  if (d.play.isWriting) return null;
  const sourceId = resolveSharedCounterSourceId(task, d.sharedCounterSourceIds);
  const key = sourceId ?? task.id;
  const sign = direction === 'add' ? 1 : -1;
  let out: Committed | null = null;
  await d.quiet(async () => {
    if (sourceId) {
      const applied = await d.play.withPending(
        key, sign * amount,
        () => (direction === 'add'
          ? d.play.handleSharedCounterIncrement(sourceId, amount, persist)
          : d.play.handleSharedCounterDecrement(sourceId, amount, false)),
        (n) => n > 0,
      );
      if (applied > 0) out = { applied, undo: () => d.play.withPending(key, -sign * applied, () => d.play.undoCounterLog(sourceId), () => true) };
      return;
    }
    const r = await d.play.withPending(key, sign * amount, () => d.play.logStandaloneCount(bt.id, sign * amount), (c) => c !== null);
    // Restore the count read INSIDE the write — the true prior value.
    if (r) {
      out = {
        applied: r.applied,
        undo: () => d.play.withPending(key, -sign * r.applied, () => d.play.handleComplete(bt.id, { currentCount: quantizeCount(r.before) }), (ok) => ok),
      };
    }
  });
  if (out && persist && direction === 'add' && !sourceId) persistDefault(task.id, amount);
  return out;
}

/**
 * Steps a compound's counting child by `direction * amount` and reports what
 * committed; Undo steps back exactly what was applied. A linked child steps
 * on its counter's key.
 */
async function childStep(
  d: WriteDeps, childTaskId: string, direction: 1 | -1, amount: number, persist: boolean,
): Promise<Committed | null> {
  const childTask = d.taskMap[childTaskId];
  if (!childTask || d.play.isWriting) return null;
  const childSource = resolveSharedCounterSourceId(childTask, d.sharedCounterSourceIds);
  const key = childSource ?? childTaskId;
  let applied = 0;
  await d.quiet(async () => {
    applied = await d.play.withPending(key, direction * amount, () => d.play.handleCompoundChildIncrement(childTaskId, direction, amount), (n) => n > 0);
  });
  if (applied <= 0) return null;
  if (persist && direction > 0) persistDefault(childSource ?? childTaskId, amount);
  // Undo reverses exactly what was applied: a linked child's log undoes on its counter,
  // anything else steps the other way.
  const reverse = async (): Promise<boolean | void> => {
    if (direction > 0 && childSource) return d.play.withPending(key, -applied, () => d.play.undoCounterLog(childSource), () => true);
    const back = (direction > 0 ? -1 : 1) as 1 | -1;
    return d.play.withPending<boolean>(key, back * applied, () => d.play.handleCompoundChildIncrement(childTaskId, back, applied).then((n) => n > 0), (ok) => ok);
  };
  return { applied, undo: reverse };
}

/** Logs `amount` on a compound's counting child; Undo removes exactly what was applied. */
export function childLog(d: WriteDeps, childTaskId: string, amount: number, persist: boolean): Promise<Committed | null> {
  return childStep(d, childTaskId, 1, amount, persist);
}

/** Removes `amount` from a compound's counting child; Undo logs exactly what was removed. */
export function childRemove(d: WriteDeps, childTaskId: string, amount: number): Promise<Committed | null> {
  return childStep(d, childTaskId, -1, amount, false);
}

/** Toggles a compound child; Undo is the explicit revert to the prior state. */
export async function childToggle(d: WriteDeps, childTaskId: string): Promise<{ to: boolean; undo: Undo } | null> {
  if (d.play.isWriting) return null;
  let to: boolean | null = null;
  await d.quiet(async () => { to = await d.play.handleCompoundChildToggle(childTaskId); });
  if (to === null) return null;
  const now = to as boolean;
  return { to: now, undo: () => d.play.handleCompoundChildToggle(childTaskId, !now).then((r) => r !== null) };
}
