import { useEffect, useRef, useState } from 'react';
import type { KeyboardEvent as ReactKeyboardEvent, RefObject } from 'react';

/**
 * The elements a keyboard user can Tab to inside a modal. Disabled controls
 * and `tabindex="-1"` are skipped, matching what the browser itself would
 * visit.
 */
const FOCUSABLE_SELECTOR = [
  'a[href]',
  'button:not(:disabled)',
  'input:not(:disabled):not([type="hidden"])',
  'textarea:not(:disabled)',
  'select:not(:disabled)',
  '[tabindex]:not([tabindex="-1"])',
].join(', ');

/**
 * Attribute that marks a dialog's safe "Cancel" control. `initialFocus:
 * 'cancel'` lands focus on the first element carrying it, so the dialog's
 * default action is always the non-destructive one.
 */
const MODAL_CANCEL_ATTR = 'data-modal-cancel';

/** Where focus lands when a modal opens. */
export type ModalInitialFocus = 'first' | 'cancel';

export interface UseModalA11yOptions {
  /** Whether the modal is currently shown. Pass `true` for a component that only mounts while open. */
  open: boolean;
  /** Dismiss the modal (Escape). Callers guard their own busy states here. */
  onCancel: () => void;
  /**
   * Where focus lands on open. Defaults to `'first'` (the first focusable
   * element). Destructive confirms (`role="alertdialog"`) pass `'cancel'` so
   * the safe choice is one keystroke away. If something inside the dialog
   * already holds focus (an `autoFocus` field), it is left alone.
   */
  initialFocus?: ModalInitialFocus;
}

/** Props to spread on the element that carries `role="dialog"` / `role="alertdialog"`. */
export interface ModalA11yProps {
  'aria-modal': true;
  /** Lets the container take focus itself when it holds nothing focusable. */
  tabIndex: -1;
  onKeyDown: (e: ReactKeyboardEvent<HTMLElement>) => void;
}

export interface UseModalA11yResult<T extends HTMLElement> {
  /** Attach to the dialog element. */
  ref: RefObject<T | null>;
  /** Spread on the dialog element (`role` is left to the caller). */
  props: ModalA11yProps;
}

/**
 * Pure focus-cycle decision for a Tab keypress inside a modal.
 *
 * @param count - Number of focusable elements in the modal.
 * @param activeIndex - Index of the focused element among them, or -1 when
 *   focus is on none of them (the container itself, or outside).
 * @param shiftKey - True for Shift+Tab (moving backwards).
 * @returns The index to move focus to, or `null` to let the browser handle
 *   the keypress (a move that stays inside the modal anyway).
 */
export function nextTrappedFocusIndex(
  count: number,
  activeIndex: number,
  shiftKey: boolean,
): number | null {
  if (count === 0) return null;
  if (shiftKey) {
    return activeIndex <= 0 ? count - 1 : null;
  }
  return activeIndex === -1 || activeIndex === count - 1 ? 0 : null;
}

/** The focused element right now, or null (also null outside a browser, e.g. SSR tests). */
function currentlyFocused(): HTMLElement | null {
  if (typeof document === 'undefined') return null;
  return document.activeElement instanceof HTMLElement ? document.activeElement : null;
}

/**
 * The last (topmost) open modal in the document other than `closing` — the
 * fallback focus target when a closing modal's opener is gone and it has no
 * modal ancestor. Typical case: a dialog opened from a floating menu item
 * (the menu unmounts on click) that is a DOM SIBLING of a still-open sheet.
 * Without this, focus lands on `<body>` and the sheet's Escape/Tab handling
 * stops working.
 */
function topmostOpenModal(closing: HTMLElement | null): HTMLElement | null {
  const open = Array.from(
    document.querySelectorAll<HTMLElement>('[aria-modal="true"]'),
  ).filter((el) => el !== closing && el.isConnected);
  return open[open.length - 1] ?? null;
}

function focusableIn(root: HTMLElement): HTMLElement[] {
  return Array.from(root.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR));
}

/**
 * Modal accessibility contract shared by every web dialog (2026-09 audit):
 * `aria-modal`, Escape → `onCancel`, initial focus (first focusable, or the
 * `data-modal-cancel` control for destructive confirms), a Tab/Shift+Tab
 * trap, and focus restored to whatever held it before the modal opened.
 *
 * Key handling is a React `onKeyDown` on the dialog element (not a document
 * listener), so a dialog nested inside another handles Escape/Tab first: it
 * marks Escape handled (`preventDefault`) and stops Tab's propagation, and
 * the outer one is left open and untouched.
 *
 * @param options - See {@link UseModalA11yOptions}.
 * @returns A ref and props to spread on the dialog element.
 *
 * Destructure the result (`{ ref: modalRef, props: modalProps }`) rather than
 * keeping it as one object: the React Compiler lint treats any object that
 * holds a ref as a ref, and rejects reading `.props` off it during render.
 *
 * @example
 * const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({
 *   open: true,
 *   onCancel,
 *   initialFocus: 'cancel',
 * });
 * return (
 *   <div ref={modalRef} role="alertdialog" {...modalProps}>
 *     …<button data-modal-cancel onClick={onCancel}>Cancel</button>
 *   </div>
 * );
 */
export function useModalA11y<T extends HTMLElement = HTMLDivElement>({
  open,
  onCancel,
  initialFocus = 'first',
}: UseModalA11yOptions): UseModalA11yResult<T> {
  const ref = useRef<T>(null);

  // The element to hand focus back to on close. Captured DURING the render
  // in which `open` flips true — i.e. before commit — because an `autoFocus`
  // field inside the dialog steals focus during commit, before any effect
  // could see the opener. (React's "adjust state when a prop changes" pattern.)
  const [opener, setOpener] = useState<HTMLElement | null>(() =>
    open ? currentlyFocused() : null,
  );
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    setOpener(open ? currentlyFocused() : null);
  }

  useEffect(() => {
    if (!open) return undefined;
    const root = ref.current;
    // A modal nested inside another (an inline confirm in a sheet): if the
    // opener is gone by close time, focus falls back to the outer modal so
    // its Escape/Tab handling keeps working.
    const outerModal =
      root?.parentElement?.closest<HTMLElement>('[aria-modal="true"]') ?? null;
    // If the render-time opener is already gone (a menu item that unmounted
    // in this same commit), whatever holds focus NOW — before we move it —
    // is the better hand-back target: e.g. the row a closing context menu
    // just restored focus to.
    const active = currentlyFocused();
    const restoreTarget =
      opener && opener.isConnected
        ? opener
        : active && active !== document.body && !root?.contains(active)
          ? active
          : opener;
    if (root && !root.contains(document.activeElement)) {
      const cancel =
        initialFocus === 'cancel'
          ? root.querySelector<HTMLElement>(`[${MODAL_CANCEL_ATTR}]`)
          : null;
      const target = cancel ?? focusableIn(root)[0] ?? root;
      target.focus();
    }
    return () => {
      if (restoreTarget && restoreTarget.isConnected) restoreTarget.focus();
      else if (outerModal && outerModal.isConnected) outerModal.focus();
      else topmostOpenModal(root)?.focus();
    };
  }, [open, initialFocus, opener]);

  const onKeyDown = (e: ReactKeyboardEvent<HTMLElement>): void => {
    if (e.key === 'Escape') {
      // A nested modal already consumed this Escape — leave this one open.
      if (e.defaultPrevented) return;
      // preventDefault (not stopPropagation): the outer modal skips it, but
      // document-level listeners (a floating context menu over the sheet)
      // still hear the Escape and close alongside, as they always did.
      e.preventDefault();
      onCancel();
      return;
    }
    if (e.key !== 'Tab') return;
    const root = ref.current;
    if (!root) return;
    // The innermost modal owns Tab; an enclosing one must not re-wrap it.
    e.stopPropagation();
    const focusable = focusableIn(root);
    const active = document.activeElement;
    const activeIndex = focusable.findIndex((el) => el === active);
    const next = nextTrappedFocusIndex(focusable.length, activeIndex, e.shiftKey);
    if (focusable.length === 0) {
      e.preventDefault();
      return;
    }
    if (next !== null) {
      e.preventDefault();
      focusable[next].focus();
    }
  };

  return { ref, props: { 'aria-modal': true, tabIndex: -1, onKeyDown } };
}
