import { describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  Timeframe,
  type Board,
  type RecurringBoardTemplate,
} from '@oybc/shared';
import {
  boardItemDraftPolicy,
  buildBoardMenuItems,
  canEditSquares,
  DISCARD_SQUARES_SUFFIX,
  isRepeatEligible,
  showsEditButton,
  squaresLockedReason,
  type BoardItemDraftPolicy,
  type BoardMenuItemKind,
} from '../boardMenu';

/**
 * Board Edit redesign slice 2 (T1) + slice 4 (T3, D12) — the title-row "…"
 * menu builder. Mirrored case-for-case by iOS `BoardMenuItemsTests`.
 */

const NOW = new Date('2026-07-15T12:00:00.000Z').getTime();

function makeBoard(overrides: Partial<Board> = {}): Board {
  return {
    id: 'board-1',
    userId: 'user-1',
    name: 'Summer goals',
    status: BoardStatus.ACTIVE,
    boardSize: 5,
    timeframe: Timeframe.CUSTOM,
    startDate: '2026-07-01T00:00:00.000',
    endDate: '2026-07-31T23:59:59.999',
    centerSquareType: CenterSquareType.FREE,
    isRandomized: false,
    totalTasks: 25,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: '2026-07-01T00:00:00.000Z',
    updatedAt: '2026-07-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

const TEMPLATE = { id: 'tpl-1', isActive: true } as RecurringBoardTemplate;

function kinds(
  board: Board,
  sourceTemplate: RecurringBoardTemplate | undefined = undefined,
  templatesLoaded = true,
  now = NOW,
): BoardMenuItemKind[] {
  return buildBoardMenuItems({ board, sourceTemplate, templatesLoaded, now }).map((i) => i.kind);
}

describe('buildBoardMenuItems', () => {
  it('ad-hoc active one-off: Board details · Repeat · Archive · Delete', () => {
    expect(kinds(makeBoard())).toEqual(['details', 'repeat', 'archive', 'delete']);
  });

  it('ad-hoc ENDED but unsealed: Close board · Board details · Repeat · Archive · Delete (D12)', () => {
    const ended = makeBoard({ endDate: '2026-01-31T23:59:59.999' });
    expect(kinds(ended)).toEqual(['close', 'details', 'repeat', 'archive', 'delete']);
  });

  it('ad-hoc CLOSED (sealed): Reopen · Repeat · Archive · Delete — no Board details (D12, MENU_CLOSED)', () => {
    expect(kinds(makeBoard({ sealedAt: '2026-08-01T00:00:00.000Z' }))).toEqual([
      'reopen',
      'repeat',
      'archive',
      'delete',
    ]);
  });

  it('core active: Core defaults… · Delete', () => {
    expect(kinds(makeBoard({ isCore: true, timeframe: Timeframe.WEEKLY }))).toEqual(['coreDefaults', 'delete']);
  });

  it('core ENDED: Close board · Core defaults… · Delete (D12)', () => {
    const ended = makeBoard({ isCore: true, timeframe: Timeframe.WEEKLY, endDate: '2026-01-31T23:59:59.999' });
    expect(kinds(ended)).toEqual(['close', 'coreDefaults', 'delete']);
  });

  it('core CLOSED (sealed): Reopen board · Core defaults… · Delete (D12)', () => {
    expect(
      kinds(makeBoard({ isCore: true, timeframe: Timeframe.WEEKLY, sealedAt: '2026-08-01T00:00:00.000Z' })),
    ).toEqual(['reopen', 'coreDefaults', 'delete']);
  });

  it('archived ad-hoc: Delete only — no Close/Reopen even when ended or sealed (OQ5)', () => {
    expect(kinds(makeBoard({ status: BoardStatus.ARCHIVED }))).toEqual(['delete']);
    expect(
      kinds(makeBoard({ status: BoardStatus.ARCHIVED, endDate: '2026-01-01T00:00:00.000Z' })),
    ).toEqual(['delete']);
    expect(
      kinds(makeBoard({ status: BoardStatus.ARCHIVED, sealedAt: '2026-01-01T00:00:00.000Z' })),
    ).toEqual(['delete']);
  });

  it('archived core: Core defaults… · Delete', () => {
    expect(kinds(makeBoard({ status: BoardStatus.ARCHIVED, isCore: true }))).toEqual(['coreDefaults', 'delete']);
  });

  it('completed (greenlogged before window end), unsealed: Delete only — same as before slice 4', () => {
    expect(kinds(makeBoard({ status: BoardStatus.COMPLETED }))).toEqual(['delete']);
  });

  it('draft: no menu', () => {
    expect(kinds(makeBoard({ status: BoardStatus.DRAFT }))).toEqual([]);
    expect(kinds(makeBoard({ status: BoardStatus.DRAFT, isCore: true }))).toEqual([]);
  });

  it('legacy CHOSEN-center one-off: Repeat shown (slice 3 D5 — repeats with a NONE template)', () => {
    expect(kinds(makeBoard({ centerSquareType: CenterSquareType.CHOSEN }))).toEqual([
      'details',
      'repeat',
      'archive',
      'delete',
    ]);
  });

  it('unresolved source record (loading or gone): no Repeat', () => {
    const repeating = makeBoard({ spawnedFromTemplateId: 'tpl-1' });
    expect(kinds(repeating, undefined, false)).toEqual(['details', 'archive', 'delete']);
    expect(kinds(repeating, undefined, true)).toEqual(['details', 'archive', 'delete']);
    // One-off whose templates query hasn't resolved yet — unknown, stay hidden.
    expect(kinds(makeBoard(), undefined, false)).toEqual(['details', 'archive', 'delete']);
  });

  it('repeating board with a resolved record: Repeat shown', () => {
    expect(kinds(makeBoard({ spawnedFromTemplateId: 'tpl-1' }), TEMPLATE)).toEqual([
      'details',
      'repeat',
      'archive',
      'delete',
    ]);
  });

  it('ENDED + unresolved source record: no Repeat, Close still shown', () => {
    const ended = makeBoard({ endDate: '2026-01-31T23:59:59.999', spawnedFromTemplateId: 'tpl-1' });
    expect(kinds(ended, undefined, false)).toEqual(['close', 'details', 'archive', 'delete']);
  });

  it('carries the verbatim labels, icons, and danger flag', () => {
    expect(buildBoardMenuItems({ board: makeBoard(), sourceTemplate: undefined, templatesLoaded: true, now: NOW })).toEqual([
      { kind: 'details', label: 'Board details…', icon: 'sliders', danger: false },
      { kind: 'repeat', label: 'Repeat this board…', icon: 'repeat', danger: false },
      { kind: 'archive', label: 'Archive', icon: 'boards', danger: false },
      { kind: 'delete', label: 'Delete', icon: 'trash', danger: true },
    ]);
    expect(
      buildBoardMenuItems({
        board: makeBoard({ isCore: true }),
        sourceTemplate: undefined,
        templatesLoaded: true,
        now: NOW,
      })[0],
    ).toEqual({ kind: 'coreDefaults', label: 'Core defaults…', icon: 'sliders', danger: false });
    expect(
      buildBoardMenuItems({
        board: makeBoard({ endDate: '2026-01-31T23:59:59.999' }),
        sourceTemplate: undefined,
        templatesLoaded: true,
        now: NOW,
      })[0],
    ).toEqual({ kind: 'close', label: 'Close board', icon: 'lock', danger: false });
    expect(
      buildBoardMenuItems({
        board: makeBoard({ sealedAt: '2026-08-01T00:00:00.000Z' }),
        sourceTemplate: undefined,
        templatesLoaded: true,
        now: NOW,
      })[0],
    ).toEqual({ kind: 'reopen', label: 'Reopen board', icon: 'sync', danger: false });
  });
});

describe('isRepeatEligible', () => {
  it('hides only while unresolved (any center type is eligible)', () => {
    expect(isRepeatEligible(makeBoard(), undefined, true)).toBe(true);
    expect(isRepeatEligible(makeBoard(), undefined, false)).toBe(false);
    // Slice 3 D5: a legacy CHOSEN one-off is eligible (effective center = NONE).
    expect(isRepeatEligible(makeBoard({ centerSquareType: CenterSquareType.CHOSEN }), undefined, true)).toBe(true);
    expect(isRepeatEligible(makeBoard({ centerSquareType: CenterSquareType.CHOSEN }), undefined, false)).toBe(false);
    expect(isRepeatEligible(makeBoard({ spawnedFromTemplateId: 'tpl-1' }), undefined, true)).toBe(false);
    expect(isRepeatEligible(makeBoard({ spawnedFromTemplateId: 'tpl-1' }), TEMPLATE, true)).toBe(true);
    // A repeating board keeps its (Repeating / Paused) sheet even with a CHOSEN center.
    expect(
      isRepeatEligible(
        makeBoard({ spawnedFromTemplateId: 'tpl-1', centerSquareType: CenterSquareType.CHOSEN }),
        TEMPLATE,
        true,
      ),
    ).toBe(true);
  });
});

/**
 * Edit consolidation (plan W1) — pure helpers backing the Edit screen. Case
 * tables mirrored line-for-line with iOS `BoardMenuItemsTests`.
 */

// Board-state table shared by canEditSquares / squaresLockedReason /
// showsEditButton / the invariant below.
const STATES: Record<string, Board> = {
  'active-live': makeBoard(),
  'active-not-yet-ended': makeBoard({ endDate: new Date(NOW + 1000).toISOString() }),
  'ended-unsealed': makeBoard({ endDate: '2026-01-31T23:59:59.999' }),
  closed: makeBoard({ sealedAt: '2026-08-01T00:00:00.000Z' }),
  archived: makeBoard({ status: BoardStatus.ARCHIVED }),
  'archived-sealed': makeBoard({ status: BoardStatus.ARCHIVED, sealedAt: '2026-01-01T00:00:00.000Z' }),
  'completed-unsealed': makeBoard({ status: BoardStatus.COMPLETED }),
  draft: makeBoard({ status: BoardStatus.DRAFT }),
};

describe('canEditSquares', () => {
  it('true only for an active, unsealed, not-yet-ended board', () => {
    expect(canEditSquares(STATES['active-live'], NOW)).toBe(true);
    expect(canEditSquares(STATES['active-not-yet-ended'], NOW)).toBe(true);
    expect(canEditSquares(STATES['ended-unsealed'], NOW)).toBe(false);
    expect(canEditSquares(STATES.closed, NOW)).toBe(false);
    expect(canEditSquares(STATES.archived, NOW)).toBe(false);
    expect(canEditSquares(STATES['archived-sealed'], NOW)).toBe(false);
    expect(canEditSquares(STATES['completed-unsealed'], NOW)).toBe(false);
    expect(canEditSquares(STATES.draft, NOW)).toBe(false);
  });
});

describe('squaresLockedReason', () => {
  it('null exactly when canEditSquares is true', () => {
    expect(squaresLockedReason(STATES['active-live'], NOW)).toBeNull();
    expect(squaresLockedReason(STATES['active-not-yet-ended'], NOW)).toBeNull();
  });

  it("ended or closed (not archived): \"This board has ended, so its squares can't change.\"", () => {
    expect(squaresLockedReason(STATES['ended-unsealed'], NOW)).toBe(
      "This board has ended, so its squares can't change.",
    );
    expect(squaresLockedReason(STATES.closed, NOW)).toBe(
      "This board has ended, so its squares can't change.",
    );
  });

  it("archived: \"This board is archived, so its squares can't change.\" — even when also ended/sealed", () => {
    expect(squaresLockedReason(STATES.archived, NOW)).toBe(
      "This board is archived, so its squares can't change.",
    );
    expect(squaresLockedReason(STATES['archived-sealed'], NOW)).toBe(
      "This board is archived, so its squares can't change.",
    );
  });

  it("completed (in window, unsealed): \"This board is complete, so its squares can't change.\"", () => {
    expect(squaresLockedReason(STATES['completed-unsealed'], NOW)).toBe(
      "This board is complete, so its squares can't change.",
    );
  });
});

describe('showsEditButton', () => {
  it('false only for a draft board', () => {
    for (const [name, board] of Object.entries(STATES)) {
      expect(showsEditButton(board)).toBe(name !== 'draft');
    }
    expect(showsEditButton(makeBoard({ status: BoardStatus.DRAFT, isCore: true }))).toBe(false);
  });
});

describe('boardItemDraftPolicy', () => {
  it('covers every row kind', () => {
    const expected: Record<BoardMenuItemKind, BoardItemDraftPolicy> = {
      details: 'keep',
      repeat: 'keep',
      coreDefaults: 'keep',
      archive: 'discardInConfirm',
      delete: 'discardInConfirm',
      close: 'discardFirst',
      reopen: 'discardFirst',
    };
    for (const [kind, policy] of Object.entries(expected) as [BoardMenuItemKind, BoardItemDraftPolicy][]) {
      expect(boardItemDraftPolicy(kind)).toBe(policy);
    }
  });
});

describe('DISCARD_SQUARES_SUFFIX', () => {
  it('is the verbatim D8 sentence, leading-space so it appends cleanly', () => {
    expect(DISCARD_SQUARES_SUFFIX).toBe(' Your unsaved square changes will be discarded.');
  });
});

describe('invariant: canEditSquares ⇒ no close/reopen rows', () => {
  it('holds for every state in the table', () => {
    for (const board of Object.values(STATES)) {
      if (!canEditSquares(board, NOW)) continue;
      const kinds = buildBoardMenuItems({ board, sourceTemplate: undefined, templatesLoaded: true, now: NOW }).map(
        (i) => i.kind,
      );
      expect(kinds).not.toContain('close');
      expect(kinds).not.toContain('reopen');
    }
  });
});
