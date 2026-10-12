import { useEffect, useRef, useState } from 'react';
import type { MomentKind } from '@oybc/shared';

/** Milliseconds per beat: a bingo replays a little slower than a greenlog's wave. */
export const MOMENT_BEAT_MS: Record<MomentKind, number> = { bingo: 175, greenlog: 120 };

/** The beat the clock reads at `elapsedMs` since it started (beat 0 holds for one cadence). */
export function momentBeatAt(elapsedMs: number, cadenceMs: number): number {
  return Math.max(0, Math.floor(elapsedMs / cadenceMs));
}

/**
 * The beat to draw: the end state when motion is reduced, otherwise the
 * clock's beat clamped to the replay's last beat.
 */
export function shownMomentBeat(rawBeat: number, finalBeat: number, reducedMotion: boolean): number {
  return reducedMotion ? finalBeat : Math.min(rawBeat, finalBeat);
}

/** Whether the user asked for reduced motion (false outside a browser). */
export function prefersReducedMotion(): boolean {
  try {
    return typeof window !== 'undefined' && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  } catch {
    return false;
  }
}

/** The frame scheduler the clock runs on (`requestAnimationFrame` in the app). */
export interface MomentScheduler {
  request: (cb: (nowMs: number) => void) => number;
  cancel: (id: number) => void;
}

/** What {@link startMomentClock} needs. */
export interface MomentClockOptions {
  cadenceMs: number;
  /** The last beat; the clock stops asking for frames once it reaches it. */
  finalBeat: number;
  /** Holds the first frame's timestamp, so a restarted clock resumes instead of rewinding. */
  start: { current: number | null };
  onBeat: (beat: number) => void;
  scheduler: MomentScheduler;
}

/**
 * Run the single replay clock: one frame loop that reports the current beat
 * until it reaches `finalBeat`. Returns its stop function.
 */
export function startMomentClock(o: MomentClockOptions): () => void {
  let handle = 0;
  const tick = (nowMs: number): void => {
    if (o.start.current === null) o.start.current = nowMs;
    const beat = momentBeatAt(nowMs - o.start.current, o.cadenceMs);
    o.onBeat(beat);
    if (beat < o.finalBeat) handle = o.scheduler.request(tick);
  };
  handle = o.scheduler.request(tick);
  return () => o.scheduler.cancel(handle);
}

/** What a moment draws from. */
export interface MomentReplayClock {
  /** The beat to draw this frame. */
  beat: number;
  /** True when the replay animates (false under reduced motion: the end state, immediately). */
  animate: boolean;
}

/**
 * The moment's one clock. Every cell's visual is derived from the beat it
 * returns (see `momentCellVisual`), so a re-render never restarts a pop; the
 * replay runs once per mount.
 *
 * @param kind - Which moment (sets the cadence).
 * @param finalBeat - The replay's last beat (`momentFinalBeat`).
 */
export function useMomentReplay(kind: MomentKind, finalBeat: number): MomentReplayClock {
  const [reducedMotion] = useState(prefersReducedMotion);
  const [rawBeat, setRawBeat] = useState(0);
  const start = useRef<number | null>(null);
  const cadenceMs = MOMENT_BEAT_MS[kind];

  useEffect(() => {
    if (reducedMotion) return undefined;
    return startMomentClock({
      cadenceMs,
      finalBeat,
      start,
      onBeat: setRawBeat,
      scheduler: { request: (cb) => requestAnimationFrame(cb), cancel: (id) => cancelAnimationFrame(id) },
    });
  }, [reducedMotion, cadenceMs, finalBeat]);

  return { beat: shownMomentBeat(rawBeat, finalBeat, reducedMotion), animate: !reducedMotion };
}
