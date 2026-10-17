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
  let out: Committed | null = null;
  await d.quiet(async () => {
    if (sourceId) {
      const applied = direction === 'add'
        ? await d.play.handleSharedCounterIncrement(sourceId, amount, persist)
        : await d.play.handleSharedCounterDecrement(sourceId, amount, false);
      if (applied > 0) out = { applied, undo: () => d.play.undoCounterLog(sourceId) };
      return;
    }
    const r = await d.play.logStandaloneCount(bt.id, direction === 'add' ? amount : -amount);
    // Restore the count read INSIDE the write — the true prior value.
    if (r) out = { applied: r.applied, undo: () => d.play.handleComplete(bt.id, { currentCount: quantizeCount(r.before) }) };
  });
  if (out && persist && direction === 'add' && !sourceId) persistDefault(task.id, amount);
  return out;
}

/** Logs `amount` on a compound's counting child; Undo removes exactly what was applied. */
export async function childLog(d: WriteDeps, childTaskId: string, amount: number, persist: boolean): Promise<Committed | null> {
  const childTask = d.taskMap[childTaskId];
  if (!childTask || d.play.isWriting) return null;
  const childSource = resolveSharedCounterSourceId(childTask, d.sharedCounterSourceIds);
  let applied = 0;
  await d.quiet(async () => { applied = await d.play.handleCompoundChildIncrement(childTaskId, 1, amount); });
  if (applied <= 0) return null;
  if (persist) persistDefault(childSource ?? childTaskId, amount);
  return {
    applied,
    undo: () => (childSource ? d.play.undoCounterLog(childSource) : d.play.handleCompoundChildIncrement(childTaskId, -1, applied).then((n) => n > 0)),
  };
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
