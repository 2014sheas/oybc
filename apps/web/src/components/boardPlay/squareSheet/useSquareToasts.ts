import { useCallback, useRef, useState } from 'react';
import { formatCount, resolveCountKind } from '@oybc/shared';
import type { CreditedToast } from '../../../hooks';
import { isUncompleteBlockedBySeal } from '../../../db/operations/taskEvents';

type Complete = (boardTaskId: string, updates: { isCompleted?: boolean }) => Promise<boolean>;

/**
 * The tap-contract toast line for a Normal square (docs/TASK_DETAIL_REDESIGN.md
 * §Tap contract): "‹title› · done" over "‹board›" (+ " · +1 ‹counter›" when the
 * write credited a counter).
 *
 * @param title - The square's title.
 * @param nowDone - The state the tap moved the square to.
 * @param boardLabel - The board's display name.
 * @param credit - The counter credit the write produced, if any.
 * @returns The toast's two lines.
 */
export function normalToastLines(
  title: string,
  nowDone: boolean,
  boardLabel: string,
  credit?: Pick<CreditedToast, 'amount' | 'counterName' | 'kind'>,
): { text: string; detail: string } {
  const detail = credit
    ? `${boardLabel} · +${formatCount(credit.amount, credit.kind ?? resolveCountKind({}))} ${credit.counterName}`
    : boardLabel;
  return { text: `${title} · ${nowDone ? 'done' : 'not done'}`, detail };
}

/** What a Normal tap needs to know about its square. */
export interface NormalTap {
  boardTaskId: string;
  taskId: string;
  title: string;
  wasDone: boolean;
  boardLabel: string;
}

/**
 * The board surface's single toast slot (one at a time, latest wins) plus the
 * two things the tap contract needs from it: `captureCredits` runs a write
 * and returns the counter credits it would have toasted instead of showing
 * them (every write made from inside the open square sheet withholds the
 * credited toast; a Normal tap merges the credit into its own toast), and
 * `tapNormal` is the Normal square's toggle + Undo toast.
 *
 * @returns The slot and its helpers.
 */
export function useSquareToasts(): {
  creditedToast: CreditedToast | null;
  setCreditedToast: (toast: CreditedToast | null) => void;
  /** Pass as `useBoardPlay`'s `onCreditedToast`. */
  onCreditedToast: (toast: CreditedToast) => void;
  captureCredits: (write: () => Promise<void>) => Promise<CreditedToast[]>;
  tapNormal: (handleComplete: Complete, tap: NormalTap) => Promise<void>;
} {
  const [creditedToast, setCreditedToast] = useState<CreditedToast | null>(null);
  const captured = useRef<CreditedToast[] | null>(null);

  const onCreditedToast = useCallback((toast: CreditedToast): void => {
    if (captured.current) captured.current.push(toast);
    else setCreditedToast(toast);
  }, []);

  const captureCredits = useCallback(async (write: () => Promise<void>): Promise<CreditedToast[]> => {
    const outer = captured.current;
    const mine: CreditedToast[] = [];
    captured.current = mine;
    try {
      await write();
    } finally {
      captured.current = outer;
    }
    return mine;
  }, []);

  const tapNormal = useCallback(
    async (handleComplete: Complete, tap: NormalTap): Promise<void> => {
      // A completion held by a sealed window cannot be un-completed from here.
      if (tap.wasDone && (await isUncompleteBlockedBySeal(tap.taskId))) return;
      let committed = false;
      const credits = await captureCredits(async () => {
        committed = await handleComplete(tap.boardTaskId, { isCompleted: !tap.wasDone });
      });
      if (!committed) return;
      const credit = credits[0];
      const { text, detail } = normalToastLines(tap.title, !tap.wasDone, tap.boardLabel, credit);
      setCreditedToast({
        sourceTaskId: credit?.sourceTaskId ?? tap.boardTaskId,
        counterName: credit?.counterName ?? '',
        amount: credit?.amount ?? 1,
        verb: 'logged',
        boardNames: [],
        key: Date.now(),
        text,
        detail,
        // Undo is the explicit revert to the state before the tap.
        undo: { kind: 'uncomplete', revert: async () => {
            if (!(await handleComplete(tap.boardTaskId, { isCompleted: tap.wasDone }))) throw new Error('Undo did not commit');
          },
        },
      });
    },
    [captureCredits],
  );

  return { creditedToast, setCreditedToast, onCreditedToast, captureCredits, tapNormal };
}
