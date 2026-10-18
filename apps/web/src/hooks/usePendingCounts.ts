import { useCallback, useEffect, useReducer, useRef } from 'react';
import {
  NO_PENDING,
  holdPending,
  pendingReducer,
  prunePending,
  resolvePendingCount,
  type PendingCounts,
} from './pendingCounts';

/** What a hook instance reads at write time (never during render). */
interface Latest {
  pending: PendingCounts;
  liveOf: (key: string) => number;
  token: unknown;
}

export interface UsePendingCountsResult {
  /** The pending store; surfaces read it through `resolvePendingCount`. */
  pending: PendingCounts;
  /**
   * Runs `write` while holding a pending op: the key's displayed count becomes
   * `shown + delta` at once. A write that throws or reports "not committed"
   * rolls the count back; a committed one is released when the live data
   * reaches it (or, failing that, on the next emission / after a short fallback).
   *
   * @param key - The counter key (`countKeyFor`).
   * @param delta - The signed amount the write applies.
   * @param write - The write.
   * @param committed - Whether `write`'s result means it committed.
   * @returns `write`'s result (a thrown error propagates after the rollback).
   */
  withPending: <T>(key: string, delta: number, write: () => Promise<T>, committed: (result: T) => boolean) => Promise<T>;
}

/**
 * The instant-count store for one play surface (see `pendingCounts.ts`).
 *
 * @param liveOf - The live count for a key (the same number the surface renders).
 * @param token - Identity of the live data; changes on every `taskEvents` emission.
 * @returns The store and the write wrapper.
 */
export function usePendingCounts(liveOf: (key: string) => number, token: unknown): UsePendingCountsResult {
  const [pending, dispatch] = useReducer(pendingReducer, NO_PENDING);
  const latest = useRef<Latest>({ pending, liveOf, token });
  const nextId = useRef(1);

  useEffect(() => {
    latest.current = { pending, liveOf, token };
  });

  // Release ops the live data has reached (or moved past) — only dispatches when something goes.
  useEffect(() => {
    if (prunePending(pending, liveOf, token) !== pending) dispatch({ type: 'prune', liveOf, token });
  }, [pending, liveOf, token]);

  const withPending = useCallback(
    <T,>(key: string, delta: number, write: () => Promise<T>, committed: (result: T) => boolean): Promise<T> =>
      holdPending(
        {
          dispatch,
          newId: () => nextId.current++,
          shownNow: () => resolvePendingCount(latest.current.pending, key, latest.current.liveOf(key)),
          tokenNow: () => latest.current.token,
        },
        key, delta, write, committed,
      ),
    [],
  );

  return { pending, withPending };
}
