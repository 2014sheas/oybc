import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  TaskType,
  deriveDisplayedCount,
  detectCounterArrivals,
  generateCounterTaskTitle,
  snapshotCounterSquares,
  type ArrivalSquare,
  type ArrivedCounter,
  type BoardTask,
  type Task,
} from '@oybc/shared';
import { readLastSeen, writeLastSeen } from '../utils/counterArrivalStore';

/** Auto-clear delay for the arrival banner + square pulse (spec: ~5.2s). */
const AUTO_CLEAR_MS = 5200;

/** The board-play read-model slice the detection adapter needs. */
export interface BuildArrivalSquaresInput {
  /** This board's placements. */
  boardTasks: BoardTask[];
  /** Workspace-wide task lookup (source names resolve through it). */
  taskMap: Record<string, Task>;
  /** Task ids that are shared-counter SOURCES (something links to them). */
  sharedCounterSourceIds: Set<string>;
}

/**
 * Resolve a counter's display name from its source task — the title, or the
 * auto-generated "Action N unit" for a titleless counting task. Matches the
 * label the board grid + Counter Detail show, so the banner copy is consistent.
 */
function counterDisplayName(source: Task | undefined): string {
  if (!source) return '';
  if (source.title && source.title.trim()) return source.title;
  return generateCounterTaskTitle(source.action ?? '', source.maxCount, source.unit ?? '');
}

/**
 * Pure adapter: build the shared-counting `ArrivalSquare[]` for a board from
 * its play read-model. One entry per COUNTING square that participates in a
 * shared-counter group (a linked derived counter, or a source with ≥1 linked
 * task). Firebase-free — imports only `@oybc/shared` — so it is unit-testable
 * in isolation (issue #280 lesson).
 *
 * `displayed` uses `deriveDisplayedCount` for linked members (baseline-adjusted)
 * and the raw `currentCount` for sources — matching what the grid cell shows.
 *
 * @param input - The board's placements + workspace task lookup + source ids.
 * @returns The shared-counting squares (empty when the board has none).
 */
export function buildArrivalSquares(input: BuildArrivalSquaresInput): ArrivalSquare[] {
  const { boardTasks, taskMap, sharedCounterSourceIds } = input;
  const squares: ArrivalSquare[] = [];
  for (const bt of boardTasks) {
    const task = taskMap[bt.taskId];
    if (!task || task.type !== TaskType.COUNTING) continue;

    // Resolve the counter's SOURCE task id: a linked member points at its
    // source via sharedCounterId; a source is its own counter id.
    let counterId: string | undefined;
    if (task.sharedCounterId != null) {
      counterId = task.sharedCounterId;
    } else if (sharedCounterSourceIds.has(task.id)) {
      counterId = task.id;
    }
    if (!counterId) continue; // Not part of a shared-counter group.

    const displayed =
      task.sharedCounterId != null
        ? deriveDisplayedCount(
            { baseline: task.baseline ?? 0, maxCount: task.maxCount ?? 0 },
            { currentCount: task.currentCount ?? 0 },
          ).displayed
        : task.currentCount ?? 0;

    squares.push({
      taskId: task.id,
      counterId,
      counterName: counterDisplayName(taskMap[counterId]),
      displayed,
    });
  }
  return squares;
}

/** The showing-banner state the surface renders + pulses from. */
export interface CounterArrivalState {
  /** Arrived square task ids — drives the gold pulse. */
  arrivedTaskIds: Set<string>;
  /** Distinct arrived counters (sorted by name) — drives the tap target. */
  arrivedCounters: ArrivedCounter[];
  /** Total arrived squares — drives the single-vs-multiple copy. */
  totalArrivedSquares: number;
  /** Remount key so a rapid re-arrival replays the banner animation. */
  key: number;
}

export interface UseCounterArrivalsResult {
  /** Non-null while the arrival banner is showing. */
  arrival: CounterArrivalState | null;
  /** Arrived square task ids (for the per-cell pulse). Empty when none showing. */
  arrivedTaskIds: Set<string>;
  /** Manually clear the banner (the ✕ dismiss). */
  dismiss: () => void;
}

/** Stable empty set so `arrivedTaskIds` keeps a constant identity when idle. */
const EMPTY_IDS: Set<string> = new Set();

/**
 * Detect + present shared-counter arrivals on this board (Shared Counters P3).
 *
 * On board-open (mount, or a board-id change in the reused core-board pager
 * instance) it diffs the board's current shared-counting squares against the
 * device-local last-seen snapshot and, if any square's displayed count
 * increased since last view, surfaces a gold arrival banner + pulses the
 * arrived squares. First view (no stored baseline) never arrives — the shared
 * `detectCounterArrivals` guarantees it.
 *
 * Detection is latched to run exactly once per board-open (keyed on `boardId`),
 * so a LOCAL tap on this board — which raises the count above the baseline —
 * never masquerades as an arrival. After that first detect (arrival or not) the
 * baseline is seeded, and every subsequent squares change on the same board
 * re-snapshots it, so leaving + returning after local taps stays quiet while a
 * cross-surface log made while the board was closed still fires on return.
 *
 * @param params - `boardId` + the play read-model slice the adapter needs.
 */
export function useCounterArrivals(params: {
  boardId: string;
  boardTasks: BoardTask[];
  taskMap: Record<string, Task>;
  sharedCounterSourceIds: Set<string>;
}): UseCounterArrivalsResult {
  const { boardId, boardTasks, taskMap, sharedCounterSourceIds } = params;

  const arrivalSquares = useMemo(
    () => buildArrivalSquares({ boardTasks, taskMap, sharedCounterSourceIds }),
    [boardTasks, taskMap, sharedCounterSourceIds],
  );

  // "Settled" data: both live queries have resolved. A board with placements
  // referencing loaded tasks yields non-empty maps; a truly empty board has
  // nothing to detect, so a late latch is harmless.
  const ready = boardTasks.length > 0 && Object.keys(taskMap).length > 0;

  const [arrival, setArrival] = useState<CounterArrivalState | null>(null);
  const detectedBoardRef = useRef<string | null>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const clearTimer = useCallback(() => {
    if (timerRef.current) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  const dismiss = useCallback(() => {
    clearTimer();
    setArrival(null);
  }, [clearTimer]);

  useEffect(() => {
    if (!ready) return;
    if (detectedBoardRef.current !== boardId) {
      // ── First settled render for this board → DETECT once. ──
      detectedBoardRef.current = boardId;
      const lastSeen = readLastSeen(boardId);
      const result = detectCounterArrivals({ lastSeen, squares: arrivalSquares });
      // Seed / refresh the baseline immediately (after-shown + first-view
      // baseline): an acknowledged arrival won't re-fire, and a fresh first
      // view establishes the baseline so the NEXT cross-surface log is caught.
      writeLastSeen(boardId, snapshotCounterSquares(arrivalSquares));
      if (result.totalArrivedSquares > 0) {
        setArrival({
          arrivedTaskIds: new Set(result.arrivedTaskIds),
          arrivedCounters: result.arrivedCounters,
          totalArrivedSquares: result.totalArrivedSquares,
          key: Date.now(),
        });
        clearTimer();
        timerRef.current = setTimeout(() => setArrival(null), AUTO_CLEAR_MS);
      }
    } else {
      // ── Later squares change on the SAME board (a local tap) → keep the
      //    baseline current so leaving + returning doesn't re-fire. ──
      writeLastSeen(boardId, snapshotCounterSquares(arrivalSquares));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [boardId, ready, arrivalSquares]);

  // Clear any showing banner when navigating to a different board.
  useEffect(() => {
    return () => {
      clearTimer();
      setArrival(null);
    };
  }, [boardId, clearTimer]);

  return {
    arrival,
    arrivedTaskIds: arrival?.arrivedTaskIds ?? EMPTY_IDS,
    dismiss,
  };
}
