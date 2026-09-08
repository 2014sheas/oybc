import { useCallback, useRef, useState } from 'react';
import styles from './RangeSlider.module.css';

export interface RangeSliderProps {
  /** The source's live available count (N). Stops are 0…N. */
  available: number;
  minValue: number;
  /** `null` = the "all" latch (renders at stop N). */
  maxValue: number | null;
  onChange: (min: number, max: number | null) => void;
}

/**
 * RangeSlider — two-handle range slider for a source row's membership
 * range (Board Sources P4 — docs/BOARD_SOURCES.md §Surfaces item 1;
 * handoff frame 2a "Range block"). Web port of iOS `RisoRangeSlider`.
 *
 * Geometry (from the handoff): 60px tall; 6px track with a 1.5px ink
 * keyline (radius 999); blue fill between the handles; ticks at each stop
 * only when N > 12; stop labels under the track — every stop when N ≤ 12,
 * else multiples of 5 plus the two handle values (a multiple within 1 of
 * a handle is dropped); two 22px knobs. Pointer-driven: the drag grabs
 * the NEARER handle (ties go to min); a bare tap moves that handle to the
 * tapped stop. Min can't pass max; max can't pass min.
 *
 * Keyboard: each knob is its own focusable `role="slider"` thumb (the
 * WAI-ARIA two-thumb pattern) — ←/↓ −1, →/↑ +1, Home/End jump to the
 * bound; End on the max thumb re-latches "all".
 *
 * Value semantics: `maxValue === null` is the "all" latch. Dragging the
 * max handle to the top stop re-latches to null (a numeric N is visually
 * indistinguishable, and the latch is what makes excludes/pool edits
 * follow the live count — docs/BOARD_SOURCES.md §Data model).
 */
export function RangeSlider({
  available,
  minValue,
  maxValue,
  onChange,
}: RangeSliderProps): React.ReactElement {
  const trackRef = useRef<HTMLDivElement>(null);
  /** Which handle the in-flight drag grabbed (sticky for the gesture). */
  const activeHandleRef = useRef<'min' | 'max' | null>(null);
  const [dragging, setDragging] = useState(false);

  const effectiveMax = maxValue ?? available;
  const KNOB = 22;

  /** Stop → percentage position (centers span [KNOB/2, width−KNOB/2]). */
  const pctFor = useCallback(
    (stop: number): number => (available > 0 ? (stop / available) * 100 : 0),
    [available],
  );

  const stopForClientX = useCallback(
    (clientX: number): number => {
      const el = trackRef.current;
      if (!el || available <= 0) return 0;
      const rect = el.getBoundingClientRect();
      const usable = Math.max(rect.width - KNOB, 1);
      const raw = Math.round(((clientX - rect.left - KNOB / 2) / usable) * available);
      return Math.min(Math.max(raw, 0), available);
    },
    [available],
  );

  const apply = useCallback(
    (stop: number): void => {
      const handle = activeHandleRef.current;
      if (handle === 'min') {
        onChange(Math.min(stop, effectiveMax), maxValue);
      } else if (handle === 'max') {
        const newMax = Math.max(stop, minValue);
        onChange(minValue, newMax >= available ? null : newMax);
      }
    },
    [onChange, effectiveMax, maxValue, minValue, available],
  );

  const handlePointerDown = useCallback(
    (e: React.PointerEvent<HTMLDivElement>): void => {
      if (available <= 0) return;
      e.currentTarget.setPointerCapture(e.pointerId);
      const el = trackRef.current;
      if (!el) return;
      const rect = el.getBoundingClientRect();
      const usable = Math.max(rect.width - KNOB, 1);
      const xFor = (stop: number): number => KNOB / 2 + (stop / available) * usable;
      const x = e.clientX - rect.left;
      // Grab the nearer handle; ties go to min (spec).
      const dMin = Math.abs(x - xFor(Math.min(minValue, available)));
      const dMax = Math.abs(x - xFor(effectiveMax));
      activeHandleRef.current = dMin <= dMax ? 'min' : 'max';
      setDragging(true);
      apply(stopForClientX(e.clientX));
    },
    [available, minValue, effectiveMax, apply, stopForClientX],
  );

  const handlePointerMove = useCallback(
    (e: React.PointerEvent<HTMLDivElement>): void => {
      if (activeHandleRef.current === null) return;
      apply(stopForClientX(e.clientX));
    },
    [apply, stopForClientX],
  );

  const endDrag = useCallback((): void => {
    activeHandleRef.current = null;
    setDragging(false);
  }, []);

  /** Label stops per the spec: everything at small N; multiples of 5 +
   *  the two handle values at scale, dropping a multiple within 1 of a
   *  handle (so labels never collide). Mirrors iOS `labelStops`. */
  const labelStops = ((): number[] => {
    if (available <= 0) return [0];
    if (available <= 12) {
      return Array.from({ length: available + 1 }, (_, i) => i);
    }
    let stops = new Set<number>();
    for (let s = 0; s <= available; s += 5) stops.add(s);
    stops.add(available);
    for (const handle of [Math.min(minValue, available), effectiveMax]) {
      stops = new Set(
        [...stops].filter((s) => s === handle || Math.abs(s - handle) > 1 || s % 5 !== 0),
      );
      stops.add(handle);
    }
    return [...stops].sort((a, b) => a - b);
  })();

  const shownMin = Math.min(minValue, available);

  /** Keyboard ops per thumb (min can't pass max; max can't pass min; the
   *  max thumb's End re-latches the "all" state). */
  const handleThumbKeyDown = useCallback(
    (handle: 'min' | 'max') =>
      (e: React.KeyboardEvent<HTMLDivElement>): void => {
        const current = handle === 'min' ? Math.min(minValue, available) : effectiveMax;
        let next: number;
        switch (e.key) {
          case 'ArrowLeft':
          case 'ArrowDown':
            next = current - 1;
            break;
          case 'ArrowRight':
          case 'ArrowUp':
            next = current + 1;
            break;
          case 'Home':
            next = handle === 'min' ? 0 : minValue;
            break;
          case 'End':
            next = handle === 'min' ? effectiveMax : available;
            break;
          default:
            return;
        }
        e.preventDefault();
        if (handle === 'min') {
          onChange(Math.min(Math.max(next, 0), effectiveMax), maxValue);
        } else {
          const newMax = Math.max(Math.min(next, available), minValue);
          onChange(minValue, newMax >= available ? null : newMax);
        }
      },
    [minValue, maxValue, effectiveMax, available, onChange],
  );

  return (
    <div
      ref={trackRef}
      className={`${styles.slider} ${dragging ? styles.dragging : ''}`}
      role="group"
      aria-label="Range"
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={endDrag}
      onPointerCancel={endDrag}
    >
      <div className={styles.track} />
      <div
        className={styles.fill}
        style={{
          left: `calc(${KNOB / 2}px + ${pctFor(shownMin)} * (100% - ${KNOB}px) / 100)`,
          width: `calc(${pctFor(effectiveMax) - pctFor(shownMin)} * (100% - ${KNOB}px) / 100)`,
        }}
      />
      {available > 12 &&
        Array.from({ length: Math.max(available - 1, 0) }, (_, i) => i + 1).map((stop) => (
          <div
            key={`tick-${stop}`}
            className={styles.tick}
            style={{ left: `calc(${KNOB / 2}px + ${pctFor(stop)} * (100% - ${KNOB}px) / 100)` }}
          />
        ))}
      {labelStops.map((stop) => (
        <span
          key={`label-${stop}`}
          className={styles.stopLabel}
          style={{ left: `calc(${KNOB / 2}px + ${pctFor(stop)} * (100% - ${KNOB}px) / 100)` }}
        >
          {stop}
        </span>
      ))}
      {/* Min drawn under max so a fully-collapsed range still lets the max
          handle be grabbed. Each knob is a focusable ARIA slider thumb
          (pointer input stays on the container; `pointer-events: none`
          doesn't block keyboard focus). */}
      <div
        className={styles.knob}
        role="slider"
        tabIndex={0}
        aria-label="Minimum on the board"
        aria-valuemin={0}
        aria-valuemax={effectiveMax}
        aria-valuenow={shownMin}
        onKeyDown={handleThumbKeyDown('min')}
        style={{ left: `calc(${KNOB / 2}px + ${pctFor(shownMin)} * (100% - ${KNOB}px) / 100)` }}
      />
      <div
        className={styles.knob}
        role="slider"
        tabIndex={0}
        aria-label="Maximum on the board"
        aria-valuemin={minValue}
        aria-valuemax={available}
        aria-valuenow={effectiveMax}
        aria-valuetext={
          maxValue === null ? `all ${available}` : `${effectiveMax} of ${available}`
        }
        onKeyDown={handleThumbKeyDown('max')}
        style={{ left: `calc(${KNOB / 2}px + ${pctFor(effectiveMax)} * (100% - ${KNOB}px) / 100)` }}
      />
    </div>
  );
}
