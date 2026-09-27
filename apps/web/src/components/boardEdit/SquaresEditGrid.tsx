import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { RisoBoardCell } from '../board/RisoBoardCell';
import {
  isFixedSlot,
  reorderToSlot,
  type EditSlot,
} from '../../hooks/useSquaresEditDraft';
import styles from './SquaresEditGrid.module.css';

export type KeyboardMoveDir = 'up' | 'down' | 'left' | 'right';

export interface SquaresEditGridProps {
  /** Flat row-major array of length gridSize². */
  slots: EditSlot[];
  gridSize: number;
  /**
   * Tap a square: open its menu (task/empty/FREE center — every slot is
   * tappable, D7). `x`/`y` are viewport coordinates for positioning a
   * popover menu near the tap point (the pointerdown position for a
   * pointer tap; the button's own center for a keyboard Enter/Space).
   */
  onTapSlot: (slot: EditSlot, row: number, col: number, x: number, y: number) => void;
  /** Commit a drag-to-insert reorder (not called for a net-zero drag). */
  onCommitReorder: (newSlots: EditSlot[]) => void;
  /** Alt+Arrow keyboard move (D9). */
  onKeyboardMove: (cellId: string, dir: KeyboardMoveDir) => void;
  /** Controlled `aria-live` announcement text (D9) — set by the caller after a move/blocked result. */
  announcement: string;
}

/** Hold duration before a press-and-drag lift begins (D8, OQ7). */
const HOLD_MS = 350;
/** Movement past this threshold before the hold timer fires cancels the hold — page scroll wins. */
const MOVE_CANCEL_PX = 6;

/**
 * SquaresEditGrid — the ONE squares-editor grid (Board Edit redesign slice
 * 3, D7–D9). Evolved from `ArrangeGrid.tsx` (Phase 3): retires the
 * Edit-tasks ⇄ Rearrange sub-mode split, tap-to-swap, and the jiggle. Every
 * square is simultaneously a tap target (menu / add) and, if movable, a
 * press-and-hold drag source — the FLIP cascade + drag-to-insert mechanics
 * are ported verbatim from `ArrangeGrid`.
 *
 * Hold-to-lift (D8): a 350ms hold timer starts on pointerdown. Moving more
 * than 6px BEFORE the timer fires cancels the hold (page scroll wins on
 * touch); a pointerup before the timer fires is a tap. Once the timer
 * fires, the square lifts (dashed hole + a tilted ghost following the
 * pointer) and drives the same slot-rect hit-testing / FLIP cascade as the
 * old rearrange mode.
 *
 * Keyboard (D9): every square is a focusable `button` in row-major tab
 * order. Enter/Space fires `onTapSlot`. Alt+Arrow calls `onKeyboardMove`
 * for a movable square; the caller controls `announcement` (an
 * `aria-live="polite"` region here) since only it knows the task titles.
 */
export function SquaresEditGrid({
  slots,
  gridSize,
  onTapSlot,
  onCommitReorder,
  onKeyboardMove,
  announcement,
}: SquaresEditGridProps): React.ReactElement {
  // ── Drag-to-insert (hold-to-lift) state ──────────────────────────────────
  const [liftedCid, setLiftedCid] = useState<string | null>(null);
  const [preview, setPreview] = useState<EditSlot[] | null>(null);
  const previewRef = useRef<EditSlot[] | null>(null);
  const setPrev = (v: EditSlot[] | null) => {
    previewRef.current = v;
    setPreview(v);
  };
  const [ghost, setGhost] = useState<{ x: number; y: number } | null>(null);

  const gridRef = useRef<HTMLDivElement | null>(null);
  const flipRef = useRef<Record<string, { x: number; y: number }>>({});
  const slotRectsRef = useRef<{ i: number; r: DOMRect }[]>([]);
  const dragCleanupRef = useRef<(() => void) | null>(null);
  useEffect(() => () => dragCleanupRef.current?.(), []);

  const displayed = preview ?? slots;
  const ghostSlot = liftedCid != null ? displayed.find((s) => s.cellId === liftedCid) : null;

  // ── FLIP animation (ported verbatim from ArrangeGrid) ────────────────────
  useLayoutEffect(() => {
    const g = gridRef.current;
    if (!g) {
      flipRef.current = {};
      return;
    }
    const prev = flipRef.current;
    const next: Record<string, { x: number; y: number }> = {};
    const reducedMotion =
      typeof window !== 'undefined' &&
      window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;

    g.querySelectorAll<HTMLElement>('[data-cid]').forEach((el) => {
      const id = el.getAttribute('data-cid')!;
      const x = el.offsetLeft;
      const y = el.offsetTop;
      next[id] = { x, y };
      const p = prev[id];
      if (!p || (p.x === x && p.y === y) || id === liftedCid) return;
      if (reducedMotion) return;
      const dx = p.x - x;
      const dy = p.y - y;
      el.style.transition = 'none';
      el.style.transform = `translate(${dx}px, ${dy}px)`;
      void el.offsetWidth;
      el.style.transition = 'transform 0.2s cubic-bezier(0.2, 0.9, 0.3, 1.1)';
      el.style.transform = '';
    });
    flipRef.current = next;
  });

  function captureSlots(): void {
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

  function onPointerDown(i: number, e: React.PointerEvent): void {
    const slot = displayed[i];
    if (!slot) return;
    // Primary button / touch / pen only — a right-click is not a tap.
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    // A locked square or the pinned FREE center is still TAPPABLE (Unlock /
    // "Make it a task square"); an empty square is tappable too (opens the
    // Add picker). Only a MOVABLE slot gets the hold-to-lift timer — every
    // slot still gets tap detection below.
    const isMovable = !isFixedSlot(slot) && !slot.isEmpty;
    const myCid = slot.cellId;
    const start = { x: e.clientX, y: e.clientY, cancelled: false };
    let holding = false;
    let touchmoveGuard: ((ev: TouchEvent) => void) | null = null;

    const beginLift = (): void => {
      holding = true;
      setPrev(displayed.slice());
      captureSlots();
      setLiftedCid(myCid);
      setGhost({ x: start.x, y: start.y });
      // Non-passive touchmove preventDefault only while lifted, so a plain
      // scroll gesture (cancelled hold) is never blocked (D8).
      touchmoveGuard = (ev: TouchEvent) => ev.preventDefault();
      window.addEventListener('touchmove', touchmoveGuard, { passive: false });
    };

    const holdTimer = isMovable
      ? window.setTimeout(() => {
          if (!start.cancelled) beginLift();
        }, HOLD_MS)
      : null;

    const onMove = (ev: PointerEvent): void => {
      if (!holding) {
        if (Math.hypot(ev.clientX - start.x, ev.clientY - start.y) > MOVE_CANCEL_PX) {
          start.cancelled = true;
          if (holdTimer != null) window.clearTimeout(holdTimer);
        }
        return;
      }
      setGhost({ x: ev.clientX, y: ev.clientY });
      const targetSlot = slotAt(ev.clientX, ev.clientY);
      if (targetSlot != null) {
        const base = previewRef.current ?? displayed;
        const cur = base.findIndex((s) => s.cellId === myCid);
        if (targetSlot !== cur) {
          setPrev(reorderToSlot(base, myCid, targetSlot));
        }
      }
    };

    const detach = (): void => {
      if (holdTimer != null) window.clearTimeout(holdTimer);
      window.removeEventListener('pointermove', onMove);
      window.removeEventListener('pointerup', onUp);
      window.removeEventListener('pointercancel', onCancel);
      if (touchmoveGuard) window.removeEventListener('touchmove', touchmoveGuard);
      dragCleanupRef.current = null;
    };

    // The browser claimed the gesture (a touch scroll began, D8: "page scroll
    // wins"). Without this the hold timer would still fire mid-scroll and lift
    // the square — then the non-passive touchmove guard would freeze page
    // scroll until some later pointerup. Abort: no tap, no commit.
    const onCancel = (): void => {
      start.cancelled = true;
      detach();
      if (holding) {
        setPrev(null);
        setLiftedCid(null);
        setGhost(null);
      }
    };

    const onUp = (): void => {
      detach();

      if (holding) {
        const finalArr = previewRef.current;
        setPrev(null);
        setLiftedCid(null);
        setGhost(null);
        if (finalArr) {
          const changed = finalArr.some((s, k) => s.cellId !== slots[k]?.cellId);
          if (changed) onCommitReorder(finalArr);
        }
      } else if (!start.cancelled) {
        // A plain tap: no hold fired, no scroll cancellation.
        onTapSlot(slot, Math.floor(i / gridSize), i % gridSize, start.x, start.y);
      }
    };

    window.addEventListener('pointermove', onMove);
    window.addEventListener('pointerup', onUp);
    window.addEventListener('pointercancel', onCancel);
    dragCleanupRef.current = detach;
  }

  function onKeyDown(i: number, slot: EditSlot, e: React.KeyboardEvent<HTMLButtonElement>): void {
    if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      const r = e.currentTarget.getBoundingClientRect();
      onTapSlot(slot, Math.floor(i / gridSize), i % gridSize, r.left + r.width / 2, r.top + r.height / 2);
      return;
    }
    if (!e.altKey) return;
    const dir: KeyboardMoveDir | null =
      e.key === 'ArrowUp' ? 'up' : e.key === 'ArrowDown' ? 'down' : e.key === 'ArrowLeft' ? 'left' : e.key === 'ArrowRight' ? 'right' : null;
    if (!dir || isFixedSlot(slot) || slot.isEmpty) return;
    e.preventDefault();
    onKeyboardMove(slot.cellId, dir);
  }

  const isDragging = liftedCid != null;
  const gridClassName = [styles.grid, isDragging ? styles.dim : ''].filter(Boolean).join(' ');

  return (
    <div className={styles.wrap}>
      <div aria-live="polite" className={styles.srOnly}>
        {announcement}
      </div>
      <div
        ref={gridRef}
        className={gridClassName}
        style={{ gridTemplateColumns: `repeat(${gridSize}, 90px)` }}
      >
        {displayed.map((slot, i) => {
          const isHole = isDragging && slot.cellId === liftedCid;
          const isMovable = !isFixedSlot(slot) && !slot.isEmpty;
          const wrapperClassName = [
            styles.cellButton,
            isMovable ? styles.movable : '',
            isHole ? styles.lifted : '',
          ]
            .filter(Boolean)
            .join(' ');
          const ariaLabel = slot.isEmpty
            ? `Empty square, row ${Math.floor(i / gridSize) + 1}, column ${(i % gridSize) + 1}`
            : slot.isCenter
              ? 'Free space'
              : `${slot.model?.label || '(untitled)'}${slot.model?.locked ? ', locked in place' : ''}${slot.model?.dirty ? ', unsaved edit' : ''}`;

          return (
            <button
              key={slot.cellId}
              type="button"
              data-cid={slot.cellId}
              data-wbcell={i}
              className={wrapperClassName}
              aria-label={ariaLabel}
              onPointerDown={(e) => onPointerDown(i, e)}
              onKeyDown={(e) => onKeyDown(i, slot, e)}
              onContextMenu={(e) => e.preventDefault()}
            >
              {!isHole && (
                <>
                  {slot.model ? (
                    <RisoBoardCell cell={slot.model} />
                  ) : slot.isEmpty ? (
                    <div className={styles.emptyCell} />
                  ) : null}
                  {isMovable && (
                    <span className={styles.grip} aria-hidden="true">
                      <i /><i /><i /><i /><i /><i />
                    </span>
                  )}
                </>
              )}
            </button>
          );
        })}
      </div>

      {ghost && ghostSlot?.model && (
        <div className={styles.ghost} style={{ left: ghost.x, top: ghost.y }} aria-hidden="true">
          {ghostSlot.model.label}
        </div>
      )}
    </div>
  );
}
