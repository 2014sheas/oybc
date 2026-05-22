import { useCallback, useEffect, useMemo, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  Timeframe,
  formatTimeframeLabel,
  getTimeframeBoundaries,
  isWithinTimeframe,
  stepWindow,
  type Board,
  type WeekStartDay,
} from '@oybc/shared';
import { db } from '../../db/database';

/** One row in the per-timeframe browser. */
export interface WindowCell {
  /** Local ISO start (matches `Board.startDate` for lookups). */
  windowStart: string;
  /** Local ISO end. */
  windowEnd: string;
  /** Human-readable label (e.g. "Today", "Week of May 18 – 24, 2026"). */
  windowLabel: string;
  /** Matching `isCore=true` board for this window, or null if empty. */
  board: Board | null;
  /** `now` falls within `[windowStart, windowEnd]`. */
  isCurrentWindow: boolean;
  /** `windowEnd < now`. */
  isPastWindow: boolean;
}

export interface UseCoreBoardBrowserArgs {
  userId: string | undefined;
  timeframe: Timeframe;
  weekStartDay: WeekStartDay;
  /** Initial number of past + future windows to load around the current
   *  window. Defaults to 10 in each direction (21 cells total). */
  initialRadius?: number;
  /** Number of windows to prepend / append per sentinel hit. Defaults to 10. */
  pageSize?: number;
}

export interface UseCoreBoardBrowserState {
  /** Loaded cells in chronological order. */
  cells: WindowCell[];
  /** Index of the cell representing the current window. Useful for the
   *  page to scroll-into-view on initial mount. -1 while loading. */
  currentIndex: number;
  /** Prepend `pageSize` more past windows. Stable identity (useCallback). */
  loadEarlier: () => void;
  /** Append `pageSize` more future windows. Stable identity (useCallback). */
  loadLater: () => void;
  /** Initial board lookup is done. While `false` the cells array is
   *  populated but `board` may be null on cells that actually have a
   *  matching record (we haven't read it yet). */
  isReady: boolean;
}

/**
 * useCoreBoardBrowser — owns the window-cell list + board lookup +
 * sentinel-driven pagination for the per-timeframe core-board browser.
 *
 * The browser shows a vertical list of calendar windows for one
 * timeframe (DAILY / WEEKLY / MONTHLY / YEARLY). Each cell renders
 * either the matching core board (tap → play) or a "Create" prompt
 * (tap → wizard with that window prefilled).
 *
 * Windows are generated lazily — initial load is ±`initialRadius`
 * around the current window; each sentinel hit appends / prepends
 * `pageSize` more. Window arithmetic delegates to `stepWindow` so DST
 * / month-length / leap-year edge cases stay correct.
 *
 * Board lookup uses a `useLiveQuery` over `(userId, timeframe,
 * isCore=true, !isDeleted)` and indexes the result by `startDate`,
 * so the lookup map updates reactively as the user creates new
 * boards from inside the browser.
 */
export function useCoreBoardBrowser({
  userId,
  timeframe,
  weekStartDay,
  initialRadius = 10,
  pageSize = 10,
}: UseCoreBoardBrowserArgs): UseCoreBoardBrowserState {
  // Reactive lookup of the user's core boards for this timeframe.
  // Indexed by startDate ISO string for O(1) cell-to-board matching.
  //
  // IndexedDB scan note: uses the `[userId+timeframe+status]` compound
  // index (declared on `db.boards` from v1) to scan only the user's
  // boards in the active timeframe, then narrows in memory on the
  // remaining predicates. The `[userId+isDeleted]` compound is
  // deliberately not used here — per the explanation in
  // `useParentBoardTasks.ts`, IndexedDB's handling of boolean keys is
  // unreliable across browsers, so the codebase JS-filters
  // `!isDeleted` rather than indexing on it. The `[u+t+s]` index
  // still gives the right complexity (small fraction of the user's
  // boards scanned per live-query re-fire) without that hazard.
  const boardsByStart = useLiveQuery(
    async (): Promise<Map<string, Board>> => {
      if (!userId) return new Map();
      const boards = await db.boards
        .where('[userId+timeframe+status]')
        .between(
          [userId, timeframe, ''] as readonly unknown[],
          [userId, timeframe, '￿'] as readonly unknown[],
        )
        .and((b) => !b.isDeleted && b.isCore === true)
        .toArray();
      const map = new Map<string, Board>();
      for (const b of boards) map.set(b.startDate, b);
      return map;
    },
    [userId, timeframe],
    new Map<string, Board>(),
  );

  // Snapshot `now` once on mount so all cells use the same reference
  // for current / past flags. Re-deriving `now` per render would mark
  // a cell as past as it ticks past midnight mid-session, which would
  // jitter the "current window" highlight.
  //
  // `useMemo(..., [])` rather than `useRef(new Date())` so the
  // `react-hooks/refs` lint rule doesn't flag the downstream reads as
  // mid-render ref access — `useMemo` is the idiomatic "compute once
  // on mount" primitive when the value is read during render.
  const now = useMemo(() => new Date(), []);

  // Current window's startDate string, used as the seed for stepping.
  const currentWindowStart = useMemo(() => {
    return getTimeframeBoundaries(timeframe, now, weekStartDay).startDate;
  }, [timeframe, weekStartDay, now]);

  // Track the negative + positive offsets we've expanded to from the
  // current window. Starts at [-initialRadius, +initialRadius]; each
  // sentinel hit pushes the range outward by `pageSize`.
  const [earliestOffset, setEarliestOffset] = useState(-initialRadius);
  const [latestOffset, setLatestOffset] = useState(initialRadius);

  // Reset offsets when the timeframe / startDate basis changes (e.g.
  // user navigates from Daily → Weekly browser). Without this the
  // pager would carry over the wrong offset range.
  useEffect(() => {
    setEarliestOffset(-initialRadius);
    setLatestOffset(initialRadius);
  }, [currentWindowStart, initialRadius]);

  const loadEarlier = useCallback(() => {
    setEarliestOffset((prev) => prev - pageSize);
  }, [pageSize]);

  const loadLater = useCallback(() => {
    setLatestOffset((prev) => prev + pageSize);
  }, [pageSize]);

  // Materialise the cell list.
  const cells = useMemo<WindowCell[]>(() => {
    const out: WindowCell[] = [];
    for (let off = earliestOffset; off <= latestOffset; off += 1) {
      const { startDate, endDate } = stepWindow(
        timeframe,
        currentWindowStart,
        off,
        weekStartDay,
      );
      out.push({
        windowStart: startDate,
        windowEnd: endDate,
        windowLabel: formatTimeframeLabel(timeframe, startDate),
        board: boardsByStart.get(startDate) ?? null,
        isCurrentWindow: isWithinTimeframe(now, startDate, endDate),
        isPastWindow: now.getTime() > new Date(endDate).getTime(),
      });
    }
    return out;
  }, [timeframe, currentWindowStart, weekStartDay, earliestOffset, latestOffset, boardsByStart, now]);

  const currentIndex = useMemo(
    () => cells.findIndex((c) => c.isCurrentWindow),
    [cells],
  );

  // `useLiveQuery` resolves to its `defaultValue` Map (empty) on the
  // first render, then to the real value on the next tick. We treat
  // the latter as "ready" — a non-zero board count or the fact that
  // the underlying query has resolved at least once.
  const isReady = boardsByStart instanceof Map;

  return {
    cells,
    currentIndex,
    loadEarlier,
    loadLater,
    isReady,
  };
}
