/**
 * counterArrivals.ts — Shared Counters passive-completion detection (P3).
 *
 * The "arrival banner" signature moment: when a shared counter is logged
 * ELSEWHERE (its Counter Detail, or another board — same device in the MVP),
 * the P2 engine has already fanned the increment out to this board's square
 * (marked done, bingo recomputed) in one transaction. This helper is the pure
 * DETECTION layer: on board open, it diffs each shared-counting square's
 * current displayed value against a LOCAL last-seen snapshot (persisted per
 * board in UserDefaults / localStorage — NOT synced schema) and reports which
 * squares "arrived" (increased since last view) so the UI can banner + pulse.
 *
 * Increase-only: a decrement made elsewhere never triggers an arrival. A square
 * with no last-seen entry is a first view — it establishes the baseline and is
 * NOT an arrival.
 *
 * Same math on both platforms — the iOS `CounterArrivals.swift` port mirrors it.
 */

/** One shared-counting square on the board being opened. */
export interface ArrivalSquare {
  /** The square's task id (a board_task's taskId). Keys the last-seen snapshot. */
  taskId: string;
  /** The shared counter's source task id — used to deep-link the banner to Counter Detail. */
  counterId: string;
  /** The counter's display name — used in the banner copy. */
  counterName: string;
  /** The square's current displayed count (post cross-board fan-out). */
  displayed: number;
}

export interface DetectCounterArrivalsInput {
  /**
   * taskId → displayed count when this board was last viewed. An absent taskId
   * is a first view (establishes a baseline, never an arrival).
   */
  lastSeen: Readonly<Record<string, number>>;
  /** The board's current shared-counting squares. */
  squares: readonly ArrivalSquare[];
}

/** One distinct counter that arrived, aggregated across its squares on this board. */
export interface ArrivedCounter {
  counterId: string;
  counterName: string;
  /** How many squares on this board arrived from this counter. */
  squareCount: number;
}

export interface CounterArrivalResult {
  /** Task ids of arrived squares — for the gold pulse. */
  arrivedTaskIds: string[];
  /** Distinct arrived counters (for the banner), sorted by name. */
  arrivedCounters: ArrivedCounter[];
  /** Total arrived squares across all counters (drives the "N squares" copy). */
  totalArrivedSquares: number;
}

/**
 * Detect which shared-counting squares arrived since the board was last viewed.
 *
 * @returns arrived task ids (to pulse), distinct arrived counters (for the
 *   banner), and the total arrived-square count. All empty when nothing arrived.
 */
export function detectCounterArrivals(
  input: DetectCounterArrivalsInput,
): CounterArrivalResult {
  const arrivedTaskIds: string[] = [];
  const byCounter = new Map<string, ArrivedCounter>();

  for (const sq of input.squares) {
    const seen = input.lastSeen[sq.taskId];
    // First view (no baseline) is never an arrival — it seeds the baseline.
    if (seen === undefined) continue;
    if (sq.displayed > seen) {
      arrivedTaskIds.push(sq.taskId);
      const existing = byCounter.get(sq.counterId);
      if (existing) {
        existing.squareCount += 1;
      } else {
        byCounter.set(sq.counterId, {
          counterId: sq.counterId,
          counterName: sq.counterName,
          squareCount: 1,
        });
      }
    }
  }

  const arrivedCounters = [...byCounter.values()].sort((a, b) =>
    a.counterName.localeCompare(b.counterName, undefined, { sensitivity: 'base' }),
  );

  return {
    arrivedTaskIds,
    arrivedCounters,
    totalArrivedSquares: arrivedTaskIds.length,
  };
}

/**
 * Build the next last-seen snapshot to persist (taskId → displayed) from the
 * board's current shared-counting squares. Call on board disappear (and after
 * an arrival is shown) so a local tap or an acknowledged arrival doesn't
 * re-trigger the banner on the next open.
 */
export function snapshotCounterSquares(
  squares: readonly { taskId: string; displayed: number }[],
): Record<string, number> {
  const out: Record<string, number> = {};
  for (const sq of squares) out[sq.taskId] = sq.displayed;
  return out;
}
