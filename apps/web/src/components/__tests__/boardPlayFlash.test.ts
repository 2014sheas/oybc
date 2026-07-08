import { describe, expect, it } from 'vitest';
import { deriveFlashOutcome, type FlashOutcomeInput } from '../boardPlayFlash';

/**
 * Branch table for `deriveFlashOutcome` (issue #270, B2-W2 dedup) — the
 * priority ladder shared by `BoardPlaySurface.handleComplete` and
 * `handleSharedCounterIncrement`. Priority order:
 *   reactivated > lostBingos > greenlog > newBingos > (nothing)
 * One case per rung, plus the priority-ordering cases that prove a
 * higher-priority signal wins even when multiple are true at once —
 * matching the `if / else if` chain both call sites used before this
 * extraction (see BoardPlaySurface.tsx).
 */
describe('deriveFlashOutcome', () => {
  const base: FlashOutcomeInput = {
    boardReactivated: false,
    lostBingos: [],
    isGreenlog: false,
    newBingos: [],
  };

  it('returns null when no signal is set', () => {
    expect(deriveFlashOutcome(base)).toBeNull();
  });

  it('boardReactivated alone → reactivated message', () => {
    expect(deriveFlashOutcome({ ...base, boardReactivated: true })).toEqual({
      text: 'Board reactivated — no longer complete',
      variant: 'bingo',
    });
  });

  it('lostBingos alone → lost-bingo message listing the lines', () => {
    expect(deriveFlashOutcome({ ...base, lostBingos: ['row_0', 'col_1'] })).toEqual({
      text: 'Bingo lost: row_0, col_1',
      variant: 'bingo',
    });
  });

  it('isGreenlog alone → greenlog message', () => {
    expect(deriveFlashOutcome({ ...base, isGreenlog: true })).toEqual({
      text: 'GREENLOG! Board complete!',
      variant: 'greenlog',
    });
  });

  it('newBingos alone → new-bingo message listing the lines', () => {
    expect(deriveFlashOutcome({ ...base, newBingos: ['diag_0'] })).toEqual({
      text: 'Bingo! diag_0',
      variant: 'bingo',
    });
  });

  it('boardReactivated beats lostBingos, isGreenlog, and newBingos', () => {
    expect(
      deriveFlashOutcome({
        boardReactivated: true,
        lostBingos: ['row_0'],
        isGreenlog: true,
        newBingos: ['col_1'],
      }),
    ).toEqual({ text: 'Board reactivated — no longer complete', variant: 'bingo' });
  });

  it('lostBingos beats isGreenlog and newBingos', () => {
    expect(
      deriveFlashOutcome({
        boardReactivated: false,
        lostBingos: ['row_0'],
        isGreenlog: true,
        newBingos: ['col_1'],
      }),
    ).toEqual({ text: 'Bingo lost: row_0', variant: 'bingo' });
  });

  it('isGreenlog beats newBingos', () => {
    expect(
      deriveFlashOutcome({
        boardReactivated: false,
        lostBingos: [],
        isGreenlog: true,
        newBingos: ['col_1'],
      }),
    ).toEqual({ text: 'GREENLOG! Board complete!', variant: 'greenlog' });
  });
});
