/**
 * Pending (optimistic) counts — the pure half of the instant-count rule
 * (docs/TASK_DETAIL_REDESIGN.md binding decision 6, amended 2026-10-18).
 *
 * A log moves the displayed count on tap, before the write lands and before
 * the `taskEvents` live query re-emits. Each in-flight write holds one
 * {@link PendingOp} on its counter's key: the count the square WILL show once
 * the write is in the live data. A surface renders
 * {@link resolvePendingCount}(live) instead of `live`, which is `live` itself
 * the moment the live data reaches an op's expected count — so the number goes
 * old → new once, never new → old → new, and never doubles.
 *
 * The state transitions are pure so they are unit-tested without a renderer;
 * `usePendingCounts` wires them to React.
 */
import { quantizeCount, type Task } from '@oybc/shared';

/** One in-flight (or just-settled) write's expected effect on a counter. */
export interface PendingOp {
  /** Unique per hook instance; the handle a settle / rollback addresses. */
  id: number;
  /** The count the key shows once this write is in the live data. */
  expected: number;
  /** The live-data token seen when the write resolved; undefined while in flight. */
  settledAt?: unknown;
  /** True once the write resolved and committed. */
  settled: boolean;
}

/** Pending ops per counter key, oldest first. */
export type PendingCounts = Readonly<Record<string, ReadonlyArray<PendingOp>>>;

/** The empty store (a stable reference, so "nothing pending" never re-renders). */
export const NO_PENDING: PendingCounts = Object.freeze({});

/** A settled op that never matched the live data is dropped after this long. */
export const PENDING_SETTLE_FALLBACK_MS = 1500;

/**
 * The key a count is pending under: the counter ROOT for a linked row, else
 * the task itself — the id whose events a log writes to.
 *
 * @param task - The counting task a square shows.
 * @returns The pending key.
 */
export function countKeyFor(task: Pick<Task, 'id' | 'sharedCounterId'>): string {
  return task.sharedCounterId ?? task.id;
}

/** Whether two counts are the same number (counts are quantised, so exact compare is safe). */
function sameCount(a: number, b: number): boolean {
  return quantizeCount(a) === quantizeCount(b);
}

/** Index of the LAST op whose expected count the live count has reached, or -1. */
function lastReachedIndex(ops: ReadonlyArray<PendingOp>, live: number): number {
  for (let i = ops.length - 1; i >= 0; i--) if (sameCount(ops[i].expected, live)) return i;
  return -1;
}

/**
 * The count to SHOW for `key`: the newest still-unreached op's expected count,
 * or `live` when nothing is pending or the live data has caught up.
 *
 * @param pending - The pending store.
 * @param key - The counter key ({@link countKeyFor}).
 * @param live - The count the live data currently gives this key.
 * @returns The displayed count.
 */
export function resolvePendingCount(pending: PendingCounts, key: string, live: number): number {
  const ops = pending[key];
  if (!ops || ops.length === 0) return live;
  const reached = lastReachedIndex(ops, live);
  return reached === ops.length - 1 ? live : ops[ops.length - 1].expected;
}

/** Whether `key` has a write still to be reflected in `live`. */
export function hasPendingCount(pending: PendingCounts, key: string, live: number): boolean {
  const ops = pending[key];
  return !!ops && ops.length > 0 && lastReachedIndex(ops, live) !== ops.length - 1;
}

/** Store transitions. */
export type PendingAction =
  | { type: 'add'; key: string; op: PendingOp }
  | { type: 'settle'; key: string; id: number; token: unknown }
  | { type: 'drop'; key: string; id: number }
  | { type: 'prune'; liveOf: (key: string) => number; token: unknown };

function replaceKey(pending: PendingCounts, key: string, ops: ReadonlyArray<PendingOp>): PendingCounts {
  const next = { ...pending };
  if (ops.length === 0) delete next[key];
  else next[key] = ops;
  return Object.keys(next).length === 0 ? NO_PENDING : next;
}

/**
 * Drops, per key, every op up to the newest one the live count has reached,
 * and every settled op the live data has moved past since it resolved.
 * Returns the SAME object when nothing changes.
 *
 * @param pending - The pending store.
 * @param liveOf - The live count for a key.
 * @param token - Identity of the live data (changes on every emission).
 * @returns The pruned store.
 */
export function prunePending(
  pending: PendingCounts,
  liveOf: (key: string) => number,
  token: unknown,
): PendingCounts {
  let out = pending;
  for (const key of Object.keys(pending)) {
    const ops = pending[key];
    const reached = lastReachedIndex(ops, liveOf(key));
    const kept = ops.filter((op, i) => i > reached && !(op.settled && op.settledAt !== token));
    if (kept.length !== ops.length) out = replaceKey(out, key, kept);
  }
  return out;
}

/**
 * The reducer behind `usePendingCounts`.
 *
 * @param state - The current store.
 * @param action - The transition.
 * @returns The next store (the same object when the action is a no-op).
 */
export function pendingReducer(state: PendingCounts, action: PendingAction): PendingCounts {
  switch (action.type) {
    case 'add':
      return replaceKey(state, action.key, [...(state[action.key] ?? []), action.op]);
    case 'settle': {
      const ops = state[action.key];
      if (!ops?.some((o) => o.id === action.id)) return state;
      return replaceKey(state, action.key, ops.map((o) => (o.id === action.id ? { ...o, settled: true, settledAt: action.token } : o)));
    }
    case 'drop': {
      const ops = state[action.key];
      if (!ops?.some((o) => o.id === action.id)) return state;
      return replaceKey(state, action.key, ops.filter((o) => o.id !== action.id));
    }
    case 'prune':
      return prunePending(state, action.liveOf, action.token);
  }
}

/**
 * The count a write will leave behind: `shown + delta`, never below zero.
 *
 * @param shown - The count the user sees now.
 * @param delta - The signed amount the write applies.
 * @returns The expected count.
 */
export function expectedCount(shown: number, delta: number): number {
  return Math.max(0, quantizeCount(shown + delta));
}

/** What {@link holdPending} needs from its host. */
export interface HoldPendingEnv {
  dispatch: (action: PendingAction) => void;
  /** A fresh op id. */
  newId: () => number;
  /** The count the key shows right now (pending included). */
  shownNow: () => number;
  /** The live-data token right now. */
  tokenNow: () => unknown;
}

/**
 * Runs `write` while holding a pending op on `key`: the displayed count becomes
 * `shown + delta` at once. A write that throws or reports "not committed" rolls
 * the op back (the error still propagates); a committed one settles and is
 * released when the live data reaches it, on the next emission, or after
 * {@link PENDING_SETTLE_FALLBACK_MS}.
 *
 * @param env - The host's store hooks.
 * @param key - The counter key ({@link countKeyFor}).
 * @param delta - The signed amount the write applies.
 * @param write - The write.
 * @param committed - Whether `write`'s result means it committed.
 * @returns `write`'s result.
 */
export async function holdPending<T>(
  env: HoldPendingEnv,
  key: string,
  delta: number,
  write: () => Promise<T>,
  committed: (result: T) => boolean,
): Promise<T> {
  const shown = env.shownNow();
  // A write that cannot move the count (clamped at zero) holds nothing.
  if (expectedCount(shown, delta) === shown) return write();
  const id = env.newId();
  env.dispatch({ type: 'add', key, op: { id, expected: expectedCount(shown, delta), settled: false } });
  let result: T;
  try {
    result = await write();
  } catch (err) {
    env.dispatch({ type: 'drop', key, id });
    throw err;
  }
  if (committed(result)) {
    env.dispatch({ type: 'settle', key, id, token: env.tokenNow() });
    setTimeout(() => env.dispatch({ type: 'drop', key, id }), PENDING_SETTLE_FALLBACK_MS);
  } else {
    env.dispatch({ type: 'drop', key, id });
  }
  return result;
}
