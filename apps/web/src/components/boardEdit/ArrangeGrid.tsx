import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { RisoBoardCell, type BoardCellModel } from '../board/RisoBoardCell';
import styles from './ArrangeGrid.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

/**
 * One slot in the flat row-major grid array.
 *
 * Lifecycle:
 *   - Real cell: cid = boardTaskId, isEmpty = false, isCenter = false, model ≠ null
 *   - Center cell: cid = "center-r-c", isCenter = true, model = FREE cell model (or real task for CHOSEN)
 *   - Empty slot: cid = "empty-r-c", isEmpty = true, model = null
 *
 * Invariants:
 *   - isCenter → never lifts, never a drop target (the grid flows around it).
 *   - isEmpty → cannot be picked up (source), but CAN receive a dropped tile.
 *   - Phase-4 reuse: the create-arrange wizard provides its own ArrangeSlot[]
 *     built from (Task | null)[]; the cid naming convention can differ.
 */
export interface ArrangeSlot {
  cid: string;
  isCenter: boolean;
  isEmpty: boolean;
  model: BoardCellModel | null;
}

export interface ArrangeGridProps {
  /** Flat row-major array of length gridSize². Index i → row=⌊i/gridSize⌋, col=i%gridSize. */
  slots: ArrangeSlot[];
  gridSize: number;
  /**
   * When true, enables jiggle + drag-to-insert + tap-to-swap.
   * When false, renders display-only (Phase-4 Preview mode).
   */
  rearrange: boolean;
  /**
   * Called when the user commits a reorder (drag drop OR tap-swap).
   * Receives the new ordered ArrangeSlot[] — caller maps cid → new {row,col}.
   * NOT called for net-zero moves (drag returning to original slot).
   */
  onReorder: (newSlots: ArrangeSlot[]) => void;
}

// ─── Pure helpers ─────────────────────────────────────────────────────────────

/**
 * Cascade helper for drag-to-insert: lift `dragCid` out of its current slot
 * and insert it before `slotIndex`, flowing the other movable tiles around it.
 *
 * Center slots are excluded from the movable list and never modified.
 * Empty slots participate in the cascade (they can shift around just like real tiles).
 * A tile CAN be inserted at an empty slot's position (vacating the tile's old slot).
 *
 * Returns `slots` unchanged if `slotIndex` is the center, or if `dragCid` is not found.
 */
function reorderToSlot(
  slots: ArrangeSlot[],
  dragCid: string,
  slotIndex: number,
): ArrangeSlot[] {
  // Center never accepts drops.
  if (slots[slotIndex]?.isCenter) return slots;

  // Movable indices: all non-center slots (includes empties).
  const movableIndices = slots.map((_, i) => i).filter((i) => !slots[i].isCenter);

  const toK = movableIndices.indexOf(slotIndex);
  if (toK < 0) return slots; // target is a center slot (shouldn't reach here given the guard)

  // Ordered content of movable slots.
  const order = movableIndices.map((i) => slots[i]);

  const dragItem = order.find((s) => s.cid === dragCid);
  if (!dragItem) return slots;

  const without = order.filter((s) => s.cid !== dragCid);
  without.splice(toK, 0, dragItem);

  const next = slots.slice();
  movableIndices.forEach((slotI, k) => {
    next[slotI] = without[k];
  });
  return next;
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * ArrangeGrid — self-contained, controlled rearrange grid.
 *
 * Interaction model (Phase 3 — locked design):
 *   - **Drag-to-insert (default):** move >6px lifts the tile into a tilted ghost;
 *     the source slot becomes a dashed hole; the grid cascades live via FLIP as
 *     the ghost passes over other slots. On release, the new order is committed.
 *   - **Tap-to-swap:** tap to pick a tile (gold ring); tap another to swap;
 *     tap the same to cancel.
 *
 * FLIP implementation:
 *   - `useLayoutEffect` (runs after every render) records each `[data-cid]`
 *     element's `offsetLeft`/`offsetTop` relative to the grid container.
 *   - On a reorder, the new positions differ from the stored ones; FLIP applies
 *     the inverse delta transform, forces a reflow, then clears the transform
 *     triggering the CSS transition slide.
 *   - Uses `offsetLeft`/`offsetTop` (not `getBoundingClientRect`) so device-
 *     level CSS scale (e.g. browser zoom) doesn't distort the deltas.
 *   - The actively-dragged element (identified by `dragCid`) is excluded from
 *     FLIP — it follows the ghost, not the cascade.
 *
 * Slot-rect hit-testing:
 *   - Slot rects are captured at drag-start (static snapshot of the slot
 *     `getBoundingClientRect`s from `[data-wbcell]` elements).
 *   - The pointer position is mapped to the nearest slot via a simple AABB scan
 *     of the captured rects — NOT via `elementFromPoint` on live tiles, which
 *     would read cascade-in-progress positions and produce flicker.
 *
 * Reusability (Phase 4):
 *   The caller owns both the `slots` array shape and the `onReorder` callback,
 *   so Phase-4 can use `ArrangeGrid` with an in-memory `(Task | null)[]`
 *   placement without touching any DB. Only the CSS and interaction change.
 */
export function ArrangeGrid({
  slots,
  gridSize,
  rearrange,
  onReorder,
}: ArrangeGridProps): React.ReactElement {
  // ── Tap-to-swap state ────────────────────────────────────────────────────
  // Index of the currently picked-up slot (null = nothing picked).
  const [moveSrc, setMoveSrc] = useState<number | null>(null);

  // ── Drag-to-insert state ─────────────────────────────────────────────────
  // cid of the tile being dragged (null = not dragging).
  const [dragCid, setDragCid] = useState<string | null>(null);
  // Live-preview array during drag (null = not active, display `slots`).
  const [preview, setPreview] = useState<ArrangeSlot[] | null>(null);
  // Ref mirrors `preview` so the pointer-move closure always sees the latest value
  // (closures over `useState` would be stale).
  const previewRef = useRef<ArrangeSlot[] | null>(null);
  const setPrev = (v: ArrangeSlot[] | null) => {
    previewRef.current = v;
    setPreview(v);
  };
  // Current ghost position (fixed viewport coordinates).
  const [ghost, setGhost] = useState<{ x: number; y: number } | null>(null);

  // ── DOM refs ─────────────────────────────────────────────────────────────
  const gridRef = useRef<HTMLDivElement | null>(null);
  // Stores previous render's {cid → {x, y}} for FLIP delta computation.
  const flipRef = useRef<Record<string, { x: number; y: number }>>({});
  // Static snapshot of slot rects captured at drag-start for hit-testing.
  const slotRectsRef = useRef<{ i: number; r: DOMRect }[]>([]);
  // Removes any window pointer listeners from an in-flight drag — invoked by
  // onUp normally, and by the unmount effect if the grid unmounts mid-drag
  // (e.g. sub-mode switch / Cancel while holding) so a late pointerup can't
  // fire onReorder on an unmounted tree.
  const dragCleanupRef = useRef<(() => void) | null>(null);
  useEffect(() => () => dragCleanupRef.current?.(), []);

  // ── Derived display ───────────────────────────────────────────────────────
  // Use the live-preview array when dragging, otherwise the canonical slots.
  const displayed = preview ?? slots;
  const movingSlot = moveSrc !== null ? displayed[moveSrc] : null;
  const ghostSlot = dragCid != null ? displayed.find((s) => s.cid === dragCid) : null;

  // ── FLIP animation ────────────────────────────────────────────────────────
  // Runs after every render (including preview updates) to slide moved elements
  // from their old position to their new position.
  useLayoutEffect(() => {
    const g = gridRef.current;
    if (!g) {
      flipRef.current = {};
      return;
    }
    const prev = flipRef.current;
    const next: Record<string, { x: number; y: number }> = {};
    // The FLIP slide is driven by inline JS, so it bypasses the CSS
    // prefers-reduced-motion guards — honor the preference here too.
    const reducedMotion =
      typeof window !== 'undefined' &&
      window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;

    g.querySelectorAll<HTMLElement>('[data-cid]').forEach((el) => {
      const id = el.getAttribute('data-cid')!;
      // offsetLeft/offsetTop relative to the grid container (which is position:relative).
      const x = el.offsetLeft;
      const y = el.offsetTop;
      next[id] = { x, y };

      const p = prev[id];
      // Skip: first render (no previous), no movement, or the active drag tile.
      if (!p || (p.x === x && p.y === y) || id === dragCid) return;

      // Reduced motion: leave tiles in their final positions, no slide.
      if (reducedMotion) return;

      const dx = p.x - x;
      const dy = p.y - y;
      // Apply inverse transform synchronously (no transition), force reflow,
      // then clear to trigger the CSS transition slide.
      el.style.transition = 'none';
      el.style.transform = `translate(${dx}px, ${dy}px)`;
      void el.offsetWidth; // force reflow
      el.style.transition = 'transform 0.2s cubic-bezier(0.2, 0.9, 0.3, 1.1)';
      el.style.transform = '';
    });

    flipRef.current = next;
  }); // intentionally no dep array — must re-run after every render

  // ── Slot-rect capture (at drag-start) ─────────────────────────────────────
  function captureSlots() {
    const g = gridRef.current;
    slotRectsRef.current = g
      ? [...g.querySelectorAll<HTMLElement>('[data-wbcell]')].map((el) => ({
          i: Number(el.getAttribute('data-wbcell')),
          r: el.getBoundingClientRect(),
        }))
      : [];
  }

  function slotAt(x: number, y: number): number | null {
    for (const s of slotRectsRef.current) {
      const r = s.r;
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return s.i;
    }
    return null;
  }

  // ── Tap-to-swap ───────────────────────────────────────────────────────────
  function rearrangeTap(i: number) {
    const slot = displayed[i];

    // First tap: pick up (must be non-center, non-empty).
    if (moveSrc === null) {
      if (!slot || slot.isCenter || slot.isEmpty) return;
      setMoveSrc(i);
      return;
    }

    // Second tap on the same slot → cancel.
    if (moveSrc === i) {
      setMoveSrc(null);
      return;
    }

    // Second tap on the center → cancel (can't drop on center).
    if (slot?.isCenter) {
      setMoveSrc(null);
      return;
    }

    // Perform a swap (works for empty destination slots too: the selected tile
    // moves to the empty position and the old slot becomes empty).
    const next = displayed.slice();
    const tmp = next[moveSrc];
    next[moveSrc] = next[i];
    next[i] = tmp;
    setMoveSrc(null);

    // Check for net-zero (unlikely for a swap but correct to verify).
    const changed = next.some((s, k) => s.cid !== slots[k]?.cid);
    if (changed) onReorder(next);
  }

  // ── Drag-to-insert ────────────────────────────────────────────────────────
  function onPointerDown(i: number, e: React.PointerEvent) {
    if (!rearrange) return;
    const displayedSlot = displayed[i];
    // Only real, non-center, non-empty tiles can be dragged.
    if (!displayedSlot || displayedSlot.isCenter || displayedSlot.isEmpty) return;

    const myCid = displayedSlot.cid;
    const start = { x: e.clientX, y: e.clientY, moved: false };

    const onMove = (ev: PointerEvent) => {
      if (
        !start.moved &&
        Math.hypot(ev.clientX - start.x, ev.clientY - start.y) > 6
      ) {
        // Threshold crossed: begin drag, cancel any tap-to-swap in progress.
        start.moved = true;
        setMoveSrc(null);
        setDragCid(myCid);
        // Seed the preview with a snapshot of the current displayed order.
        setPrev(displayed.slice());
        captureSlots();
      }

      if (start.moved) {
        setGhost({ x: ev.clientX, y: ev.clientY });
        // Hit-test against the STATIC slot rects captured at drag-start.
        const targetSlot = slotAt(ev.clientX, ev.clientY);
        if (targetSlot != null) {
          const base = previewRef.current ?? displayed;
          const cur = base.findIndex((s) => s.cid === myCid);
          if (targetSlot !== cur) {
            setPrev(reorderToSlot(base, myCid, targetSlot));
          }
        }
      }
    };

    const onUp = () => {
      window.removeEventListener('pointermove', onMove);
      window.removeEventListener('pointerup', onUp);
      dragCleanupRef.current = null;

      if (start.moved) {
        // Commit the final preview order if it differs from the pre-drag slots.
        const finalArr = previewRef.current;
        setPrev(null);
        setDragCid(null);
        setGhost(null);
        if (finalArr) {
          const changed = finalArr.some((s, k) => s.cid !== slots[k]?.cid);
          if (changed) onReorder(finalArr);
        }
      } else {
        // No movement: treat as a tap-to-swap tap.
        rearrangeTap(i);
      }
    };

    window.addEventListener('pointermove', onMove);
    window.addEventListener('pointerup', onUp);
    dragCleanupRef.current = () => {
      window.removeEventListener('pointermove', onMove);
      window.removeEventListener('pointerup', onUp);
    };
    // Prevent browser text selection / scroll hijack during drag.
    e.preventDefault();
  }

  // ── Render ────────────────────────────────────────────────────────────────

  const isDragging = dragCid != null;
  const isPicked = moveSrc !== null;
  const isDim = rearrange && (isPicked || isDragging);

  const gridClassName = [
    styles.grid,
    rearrange ? styles.editing : '',
    isDim ? styles.dim : '',
    isDragging ? styles.sorting : '',
  ]
    .filter(Boolean)
    .join(' ');

  return (
    <div className={styles.wrap}>
      {/* Tap-to-swap in-progress hint */}
      {rearrange && isPicked && movingSlot && (
        <p className={styles.hintBar}>
          <b>Tap a square</b> to swap with "{movingSlot.model?.label ?? ''}".
        </p>
      )}

      <div
        ref={gridRef}
        className={gridClassName}
        style={{ gridTemplateColumns: `repeat(${gridSize}, 90px)` }}
      >
        {displayed.map((slot, i) => {
          // The dragged tile's source slot renders as a dashed gap (hole).
          const isHole = isDragging && slot.cid === dragCid;
          const isSelected = rearrange && moveSrc === i && !isDragging;
          // Highlight valid swap targets when a tile is tap-picked.
          const isTarget =
            rearrange &&
            isPicked &&
            !isDragging &&
            !slot.isCenter &&
            moveSrc !== i;

          // Jiggle: all non-locked, non-hole cells in rearrange mode,
          // suspended during drag (sorting) and when the cell itself is selected.
          const shouldJiggle =
            rearrange &&
            !slot.isCenter &&
            !slot.isEmpty &&
            !isDragging &&
            !isSelected;

          const wrapperClassName = [
            styles.cellWrapper,
            isHole ? styles.hole : '',
            isSelected ? styles.sel : '',
            isTarget ? styles.tgt : '',
            shouldJiggle ? styles.jiggle : '',
          ]
            .filter(Boolean)
            .join(' ');

          return (
            <div
              key={slot.cid}
              data-cid={slot.cid}
              data-wbcell={i}
              className={wrapperClassName}
              {...(rearrange
                ? {
                    onPointerDown: (e: React.PointerEvent) => onPointerDown(i, e),
                  }
                : {})}
            >
              {!isHole && (
                <>
                  {slot.model ? (
                    // No onClick/onContextMenu: ArrangeGrid owns all pointer interactions.
                    <RisoBoardCell cell={slot.model} />
                  ) : slot.isEmpty ? (
                    <div className={styles.emptyCell} />
                  ) : null}
                  {/* Grip handle: visible on non-locked cells in rearrange mode */}
                  {rearrange && !slot.isCenter && !slot.isEmpty && (
                    <span className={styles.grip} aria-hidden="true">
                      {/* 2×3 dot grid rendered as an inline grid of <i> elements */}
                      <i /><i /><i /><i /><i /><i />
                    </span>
                  )}
                </>
              )}
            </div>
          );
        })}
      </div>

      {/* Drag ghost: tilted tile that follows the pointer */}
      {ghost && ghostSlot?.model && (
        <div
          className={styles.ghost}
          style={{ left: ghost.x, top: ghost.y }}
          aria-hidden="true"
        >
          {ghostSlot.model.label}
        </div>
      )}
    </div>
  );
}
