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

/** What to hand to `showFlash`, or `null` when none of the ladder's rungs match. */
export interface FlashOutcome {
  text: string;
  variant: 'bingo' | 'greenlog';
}

/**
 * Reduce a normalized signal set down to the (single) flash message to show,
 * in priority order: reactivated > lostBingos > greenlog > newBingos.
 * Returns `null` when none apply (no flash for this write).
 */
export function deriveFlashOutcome(input: FlashOutcomeInput): FlashOutcome | null {
  if (input.boardReactivated) {
    return { text: 'Board reactivated — no longer complete', variant: 'bingo' };
  }
  if (input.lostBingos.length > 0) {
    return { text: `Bingo lost: ${input.lostBingos.join(', ')}`, variant: 'bingo' };
  }
  if (input.isGreenlog) {
    return { text: 'GREENLOG! Board complete!', variant: 'greenlog' };
  }
  if (input.newBingos.length > 0) {
    return { text: `Bingo! ${input.newBingos.join(', ')}`, variant: 'bingo' };
  }
  return null;
}
