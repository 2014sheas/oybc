import { useEffect, useRef, type RefObject } from 'react';

/** The interactions that count as "doing something else". */
const OUTSIDE_EVENTS = ['pointerdown', 'keydown', 'wheel'] as const;

/** Keys that move focus or modify — Tab must still reach the Undo button. */
const IGNORED_KEYS = new Set(['Tab', 'Shift', 'Control', 'Alt', 'Meta']);

/**
 * Dismisses a transient surface (an Undo toast) on the user's next
 * interaction anywhere outside it — a tap, the start of a scroll / drag, a
 * wheel, a key press (not Tab / modifiers, so the keyboard can still reach
 * Undo) — so it never gets in the way (owner rule 2026-10-13).
 * Listens in the capture phase, so it runs before the interaction's own
 * handler and never blocks it. iOS twin: `View.dismissOnOutsideTouch`.
 *
 * @param ref - The surface; interactions inside it (the Undo button) are ignored.
 * @param onDismiss - Called once per outside interaction while `active`.
 * @param active - Whether the surface is showing (default true).
 */
export function useDismissOnOutsideInteraction(
  ref: RefObject<HTMLElement | null>,
  onDismiss: () => void,
  active = true,
): void {
  // Latest callback without re-subscribing on every parent render.
  const dismissRef = useRef(onDismiss);
  useEffect(() => {
    dismissRef.current = onDismiss;
  }, [onDismiss]);
  useEffect(() => {
    if (!active) return undefined;
    function handle(event: Event): void {
      const target = event.target;
      if (target instanceof Node && ref.current?.contains(target)) return;
      if (event instanceof KeyboardEvent && IGNORED_KEYS.has(event.key)) return;
      dismissRef.current();
    }
    for (const type of OUTSIDE_EVENTS) document.addEventListener(type, handle, true);
    return () => {
      for (const type of OUTSIDE_EVENTS) document.removeEventListener(type, handle, true);
    };
  }, [active, ref]);
}
