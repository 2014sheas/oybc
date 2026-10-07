import { useState } from 'react';
import type { QuickAmountProps } from '../interactiveTaskSquareUtils';
import { buildQuickAmount, initialCountingLogState, type CountingLogContext, type CountingLogState } from './countingLogModel';

/**
 * The open DetailModal's quick-amount props. The state re-seeds only when a
 * DIFFERENT square opens (or the modal closes) — never on a live-query update
 * of the same square, which would clobber an in-progress amount edit. Until
 * the user touches a control, the props read the square's opening state
 * straight from `ctxFor`, so the first paint already shows the right chips.
 *
 * @param selectedSquareId - The open modal's placement id, or null.
 * @param ctxFor - Resolves a placement's counting context (null for a non-counting square).
 * @returns The props, or undefined (no modal, non-counting, or a standalone Discrete square).
 */
export function useCountingLogModal(
  selectedSquareId: string | null,
  ctxFor: (boardTaskId: string) => CountingLogContext | null,
): QuickAmountProps | undefined {
  const [state, setState] = useState<CountingLogState | null>(null);
  const [openFor, setOpenFor] = useState<string | null>(selectedSquareId);
  if (openFor !== selectedSquareId) {
    setOpenFor(selectedSquareId);
    setState(null);
  }
  const ctx = selectedSquareId ? ctxFor(selectedSquareId) : null;
  if (!ctx) return undefined;
  const current = state && state.boardTaskId === selectedSquareId ? state : initialCountingLogState(ctx);
  return current ? buildQuickAmount(current, ctx, setState) : undefined;
}
