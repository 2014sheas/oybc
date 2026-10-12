import { describe, expect, it } from 'vitest';
import { BoardStatus, type Board } from '@oybc/shared';
import { deriveFlashOutcome, flashFromBoardSnapshots, type FlashOutcomeInput } from '../boardPlayFlash';

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
      kind: 'message',
      newLineIds: [],
    });
  });

  it('lostBingos alone → lost-bingo message listing the lines', () => {
    expect(deriveFlashOutcome({ ...base, lostBingos: ['row_0', 'col_1'] })).toEqual({
      text: 'Bingo lost: row_0, col_1',
      kind: 'message',
      newLineIds: [],
    });
  });

  it('isGreenlog alone → greenlog message', () => {
    expect(deriveFlashOutcome({ ...base, isGreenlog: true })).toEqual({
      text: 'GREENLOG! Board complete!',
      kind: 'greenlog',
      newLineIds: [],
    });
  });

  it('newBingos alone → new-bingo message listing the lines', () => {
    expect(deriveFlashOutcome({ ...base, newBingos: ['diag_0'] })).toEqual({
      text: 'Bingo! diag_0',
      kind: 'bingo',
      newLineIds: ['diag_0'],
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
    ).toEqual({ text: 'Board reactivated — no longer complete', kind: 'message', newLineIds: [] });
  });

  it('lostBingos beats isGreenlog and newBingos', () => {
    expect(
      deriveFlashOutcome({
        boardReactivated: false,
        lostBingos: ['row_0'],
        isGreenlog: true,
        newBingos: ['col_1'],
      }),
    ).toEqual({ text: 'Bingo lost: row_0', kind: 'message', newLineIds: [] });
  });

  it('isGreenlog beats newBingos', () => {
    expect(
      deriveFlashOutcome({
        boardReactivated: false,
        lostBingos: [],
        isGreenlog: true,
        newBingos: ['col_1'],
      }),
    ).toEqual({ text: 'GREENLOG! Board complete!', kind: 'greenlog', newLineIds: ['col_1'] });
  });
});

describe('flashFromBoardSnapshots', () => {
  const board = (over: Partial<Board>): Board => ({
    id: 'b', boardSize: 3, status: BoardStatus.ACTIVE, completedTasks: 2, completedLineIds: [], ...over,
  } as Board);

  it('a write that forms a line is a bingo', () => {
    expect(flashFromBoardSnapshots(board({}), board({ completedLineIds: ['row_0'] }), true)).toMatchObject({ kind: 'bingo', newLineIds: ['row_0'] });
  });
  it('a write that clears the board is a greenlog carrying its new lines', () => {
    const after = board({ status: BoardStatus.COMPLETED, completedTasks: 9, completedLineIds: ['row_0'] });
    expect(flashFromBoardSnapshots(board({}), after, true)).toMatchObject({ kind: 'greenlog', newLineIds: ['row_0'] });
  });
  it('a compound-child toggle off the board can complete a line (the fallback path)', () => {
    expect(flashFromBoardSnapshots(board({}), board({ completedLineIds: ['col_1', 'diag_main'] }), true)?.newLineIds).toEqual(['col_1', 'diag_main']);
  });
  it('a removal never produces a bingo or greenlog, only reactivated / lost', () => {
    const before = board({ status: BoardStatus.COMPLETED, completedLineIds: ['row_0'] });
    expect(flashFromBoardSnapshots(before, board({ completedLineIds: ['row_0'] }), false)?.kind).toBe('message');
    expect(flashFromBoardSnapshots(board({}), board({ completedLineIds: ['row_0'] }), false)).toBeNull();
  });
  it('no change is no flash', () => {
    expect(flashFromBoardSnapshots(board({}), board({}), true)).toBeNull();
  });
});
