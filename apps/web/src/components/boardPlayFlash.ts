/**
 * Pure flash-priority ladder shared by `BoardPlaySurface`'s two completion
 * handlers (issue #270, B2-W2 dedup):
 *
 *   - `handleComplete` — compares fields straight off a `TaskCompletionResult`
 *     (the orchestration layer's return value from `handleTaskCompletion`).
 *   - `handleSharedCounterIncrement` — has no result object to read; it
 *     diffs a captured pre-increment `Board` snapshot against a re-fetched
 *     post-increment snapshot to derive the same four signals.
 *
 * The two call sites derive `boardReactivated` / `isGreenlog` differently
 * (see each call site for its own derivation — that logic is NOT shared,
 * because the inputs available at each site differ), but once derived, both
 * apply the exact same priority order to decide what to flash:
 *
 *   reactivated > lostBingos > greenlog > newBingos > (nothing)
 *
 * This module extracts ONLY that shared decision ladder. Callers normalize
 * their own signal shape into `FlashOutcomeInput` first.
 */

import { BoardStatus, type Board } from '@oybc/shared';

/** Normalized signals both call sites reduce their own state down to. */
export interface FlashOutcomeInput {
  /** True when the board just transitioned from COMPLETED back to ACTIVE. */
  boardReactivated: boolean;
  /** Bingo line ids that were completed before this write and are not anymore. */
  lostBingos: string[];
  /** True when the board is (now) fully complete — i.e. a GREENLOG state. */
  isGreenlog: boolean;
  /** Bingo line ids that just became complete as of this write. */
  newBingos: string[];
}

/**
 * What a flash is. `bingo` / `greenlog` open the full-screen moment
 * (`RisoMomentOverlay`); `message` is a transient line (lost bingo,
 * reactivated, an error).
 */
export type FlashKind = 'bingo' | 'greenlog' | 'message';

/** What to hand to `showFlash`, or `null` when none of the ladder's rungs match. */
export interface FlashOutcome {
  text: string;
  kind: FlashKind;
  /** The line ids this write newly completed (empty for a `message`). */
  newLineIds: string[];
}

/** A transient message outcome (errors and the like). */
export function messageOutcome(text: string): FlashOutcome {
  return { text, kind: 'message', newLineIds: [] };
}

/**
 * Reduce a normalized signal set down to the (single) flash message to show,
 * in priority order: reactivated > lostBingos > greenlog > newBingos.
 * Returns `null` when none apply (no flash for this write). A write that
 * completes the board is a `greenlog` (it wins over any bingo it also formed);
 * both kinds carry the lines the write newly completed.
 */
export function deriveFlashOutcome(input: FlashOutcomeInput): FlashOutcome | null {
  if (input.boardReactivated) {
    return messageOutcome('No longer complete');
  }
  if (input.lostBingos.length > 0) {
    return messageOutcome(`Bingo lost: ${input.lostBingos.join(', ')}`);
  }
  if (input.isGreenlog) {
    return { text: 'GREENLOG! Board complete!', kind: 'greenlog', newLineIds: input.newBingos };
  }
  if (input.newBingos.length > 0) {
    return { text: `Bingo! ${input.newBingos.join(', ')}`, kind: 'bingo', newLineIds: input.newBingos };
  }
  return null;
}

/**
 * The flash a write caused, read off a before / after pair of board rows (the
 * paths with no `TaskCompletionResult`: shared-counter log / remove / undo and
 * the off-board compound-child toggle). `gains` also reads the ACTIVE ->
 * COMPLETED transition and newly formed lines; a removal passes `false`, so
 * only the reactivated / lost-bingo rungs can fire.
 */
export function flashFromBoardSnapshots(before: Board, after: Board, gains: boolean): FlashOutcome | null {
  const prev = new Set(before.completedLineIds ?? []);
  const next = new Set(after.completedLineIds ?? []);
  const wasActive = before.status === BoardStatus.ACTIVE;
  const isNowCompleted = after.status === BoardStatus.COMPLETED;
  return deriveFlashOutcome({
    boardReactivated: before.status === BoardStatus.COMPLETED && after.status === BoardStatus.ACTIVE,
    lostBingos: [...prev].filter((id) => !next.has(id)),
    isGreenlog: gains && wasActive && isNowCompleted && after.completedTasks >= after.boardSize * after.boardSize,
    newBingos: gains ? [...next].filter((id) => !prev.has(id)) : [],
  });
}
