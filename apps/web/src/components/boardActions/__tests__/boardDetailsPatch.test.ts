import { describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  Timeframe,
  type Board,
} from '@oybc/shared';
import {
  buildBoardDetailsPatch,
  buildEditDatesPatch,
  countBoardDetailsEdits,
  seedBoardDetailsDraft,
  validateBoardDetails,
  type BoardDetailsDraft,
} from '../boardDetailsPatch';

/**
 * Direct branch coverage for the Save patch's preserve-vs-rewindow decision
 * (review Important: this logic previously lived inline in the component
 * with zero direct coverage — an inverted boolean would have silently
 * reintroduced the progress-reset-on-edit bug).
 *
 * Board Edit redesign slice 2 (T1) moved it here from `BoardEditPanel` and
 * folded in bugfix B1 (D12): an ongoing board's start-date edit is saved,
 * and Custom → Ongoing keeps the picked start instead of re-anchoring to
 * today. Mirrored case-for-case by iOS `BoardDetailsDraftTests`.
 */
const base = {
  origStart: '2026-07-01',
  origEnd: '2026-07-31',
  customStartDate: '2026-07-01',
  customEndDate: '2026-07-31',
  computedBoundaries: { startDate: 'CB-START', endDate: 'CB-END' },
  now: new Date(2026, 6, 27, 15, 30), // deterministic "today"
};

describe('buildEditDatesPatch — preserve vs rewindow', () => {
  it('metadata-only save (unchanged timeframe + dates) omits BOTH fields — the window survives', () => {
    for (const tf of [
      Timeframe.DAILY,
      Timeframe.WEEKLY,
      Timeframe.MONTHLY,
      Timeframe.YEARLY,
      Timeframe.INDEFINITE,
      Timeframe.CUSTOM,
    ]) {
      const out = buildEditDatesPatch({ ...base, boardTimeframe: tf, formTimeframe: tf });
      expect(out, `timeframe ${tf} must preserve`).toEqual({});
    }
  });

  it('unchanged INDEFINITE board is NOT re-anchored to today (the original bug)', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.INDEFINITE,
      formTimeframe: Timeframe.INDEFINITE,
    });
    expect(out.startDate).toBeUndefined();
    expect(out.endDate).toBeUndefined();
  });

  it('D12/B1 — an ongoing board with an EDITED start writes the start only', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.INDEFINITE,
      formTimeframe: Timeframe.INDEFINITE,
      customStartDate: '2026-06-15',
      customEndDate: '',
      origEnd: '',
    });
    expect(Object.keys(out)).toEqual(['startDate']);
    expect(out.startDate).toContain('2026-06-15T00:00:00');
  });

  it('D12/B1 — a stale end-picker value on an ongoing board is not a date edit', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.INDEFINITE,
      formTimeframe: Timeframe.INDEFINITE,
      customEndDate: '2026-08-31',
    });
    expect(out).toEqual({});
  });

  it('timeframe CHANGE to a core timeframe re-windows via computed boundaries', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.WEEKLY,
      formTimeframe: Timeframe.DAILY,
    });
    expect(out).toEqual({ startDate: 'CB-START', endDate: 'CB-END' });
  });

  it('D12/B1 — Custom → Ongoing KEEPS the (possibly edited) start and clears the deadline', () => {
    const kept = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.CUSTOM,
      formTimeframe: Timeframe.INDEFINITE,
    });
    expect(kept.startDate).toContain('2026-07-01T00:00:00');
    expect(kept.endDate).toBeNull();

    const edited = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.CUSTOM,
      formTimeframe: Timeframe.INDEFINITE,
      customStartDate: '2026-07-03',
    });
    expect(edited.startDate).toContain('2026-07-03T00:00:00');
    expect(edited.endDate).toBeNull();
  });

  it('a conversion to INDEFINITE with no picked start falls back to today', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.WEEKLY,
      formTimeframe: Timeframe.INDEFINITE,
      customStartDate: '',
    });
    expect(out.startDate).toContain('2026-07-27T00:00:00');
    expect(out.endDate).toBeNull();
  });

  it('timeframe CHANGE to CUSTOM uses the picked dates', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.WEEKLY,
      formTimeframe: Timeframe.CUSTOM,
      customStartDate: '2026-07-10',
      customEndDate: '2026-07-20',
    });
    expect(out.startDate).toContain('2026-07-10T00:00:00');
    expect(out.endDate).toContain('2026-07-20T23:59:59');
  });

  it('Ongoing → Custom writes the picked start AND end', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.INDEFINITE,
      formTimeframe: Timeframe.CUSTOM,
      origEnd: '',
      customStartDate: '2026-07-01',
      customEndDate: '2026-08-15',
    });
    expect(out.startDate).toContain('2026-07-01T00:00:00');
    expect(out.endDate).toContain('2026-08-15T23:59:59');
  });

  it('unchanged CUSTOM timeframe with EDITED dates applies the new window', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.CUSTOM,
      formTimeframe: Timeframe.CUSTOM,
      customStartDate: '2026-07-05', // differs from origStart
    });
    expect(out.startDate).toContain('2026-07-05T00:00:00');
    expect(out.endDate).toContain('2026-07-31T23:59:59');
  });

  it('unchanged CUSTOM with UNTOUCHED dates preserves (dates equal to orig)', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.CUSTOM,
      formTimeframe: Timeframe.CUSTOM,
    });
    expect(out).toEqual({});
  });

  it('date edits on a NON-custom timeframe are ignored (form state cannot re-window a core board)', () => {
    const out = buildEditDatesPatch({
      ...base,
      boardTimeframe: Timeframe.WEEKLY,
      formTimeframe: Timeframe.WEEKLY,
      customStartDate: '2026-07-05', // stale picker state — must not leak
    });
    expect(out).toEqual({});
  });
});

// ─── Board details draft (slice 2) ───────────────────────────────────────────

const NOW = new Date(2026, 6, 27, 15, 30);

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

const ONGOING = { timeframe: Timeframe.INDEFINITE, endDate: undefined } as const;

function draftOf(board: Board, patch: Partial<BoardDetailsDraft> = {}): BoardDetailsDraft {
  return { ...seedBoardDetailsDraft(board), ...patch };
}

describe('seedBoardDetailsDraft', () => {
  it('seeds name / timeframe / Y-M-D dates / center from the board', () => {
    expect(seedBoardDetailsDraft(makeBoard())).toEqual({
      name: 'Summer goals',
      timeframe: Timeframe.CUSTOM,
      customStartDate: '2026-07-01',
      customEndDate: '2026-07-31',
      centerType: CenterSquareType.FREE,
    });
  });

  it('an ongoing board seeds an empty end date', () => {
    expect(seedBoardDetailsDraft(makeBoard(ONGOING)).customEndDate).toBe('');
  });
});

describe('buildBoardDetailsPatch', () => {
  it('an untouched draft is null (no changes)', () => {
    for (const board of [makeBoard(), makeBoard(ONGOING), makeBoard({ timeframe: Timeframe.MONTHLY })]) {
      expect(buildBoardDetailsPatch(board, seedBoardDetailsDraft(board), 'monday', NOW)).toBeNull();
    }
  });

  it('a rename writes the TRIMMED name only', () => {
    const board = makeBoard();
    expect(buildBoardDetailsPatch(board, draftOf(board, { name: '  Fall goals ' }), 'monday', NOW)).toEqual({
      name: 'Fall goals',
    });
  });

  it('a whitespace-only name change is not a change', () => {
    const board = makeBoard();
    expect(buildBoardDetailsPatch(board, draftOf(board, { name: 'Summer goals  ' }), 'monday', NOW)).toBeNull();
  });

  it('D12/B1 — ongoing start edit → { startDate } only', () => {
    const board = makeBoard(ONGOING);
    const patch = buildBoardDetailsPatch(
      board,
      draftOf(board, { customStartDate: '2026-06-20' }),
      'monday',
      NOW,
    );
    expect(Object.keys(patch ?? {})).toEqual(['startDate']);
    expect(patch?.startDate).toContain('2026-06-20T00:00:00');
  });

  it('D12/B1 — custom → ongoing writes timeframe + kept start + cleared end', () => {
    const board = makeBoard();
    const patch = buildBoardDetailsPatch(
      board,
      draftOf(board, { timeframe: Timeframe.INDEFINITE, customEndDate: '' }),
      'monday',
      NOW,
    );
    expect(patch?.timeframe).toBe(Timeframe.INDEFINITE);
    expect(patch?.startDate).toContain('2026-07-01T00:00:00');
    expect(patch?.endDate).toBeNull();
  });

  it('ongoing → custom writes timeframe + picked start and end', () => {
    const board = makeBoard(ONGOING);
    const patch = buildBoardDetailsPatch(
      board,
      draftOf(board, { timeframe: Timeframe.CUSTOM, customEndDate: '2026-08-10' }),
      'monday',
      NOW,
    );
    expect(patch?.timeframe).toBe(Timeframe.CUSTOM);
    expect(patch?.startDate).toContain('2026-07-01T00:00:00');
    expect(patch?.endDate).toContain('2026-08-10T23:59:59');
  });

  it('a calendar board never re-windows: timeframe and date drafts are ignored', () => {
    const board = makeBoard({ timeframe: Timeframe.MONTHLY });
    const patch = buildBoardDetailsPatch(
      board,
      draftOf(board, {
        timeframe: Timeframe.INDEFINITE,
        customStartDate: '2026-07-09',
      }),
      'monday',
      NOW,
    );
    expect(patch).toBeNull();
  });

  it('a center change writes centerSquareType only', () => {
    const board = makeBoard();
    expect(
      buildBoardDetailsPatch(board, draftOf(board, { centerType: CenterSquareType.NONE }), 'monday', NOW),
    ).toEqual({ centerSquareType: CenterSquareType.NONE });
  });
});

describe('countBoardDetailsEdits — counts exactly what the patch writes', () => {
  // Agreement table: [label, board, draft overrides, expected count, expected patch keys].
  const cases: Array<[string, Board, Partial<BoardDetailsDraft>, number, string[]]> = [
    ['untouched custom', makeBoard(), {}, 0, []],
    ['untouched ongoing', makeBoard(ONGOING), {}, 0, []],
    ['rename', makeBoard(), { name: 'X' }, 1, ['name']],
    ['whitespace rename', makeBoard(), { name: ' Summer goals ' }, 0, []],
    ['custom start + end edit = one group', makeBoard(), { customStartDate: '2026-07-02', customEndDate: '2026-07-30' }, 1, ['startDate', 'endDate']],
    ['ongoing start edit', makeBoard(ONGOING), { customStartDate: '2026-06-01' }, 1, ['startDate']],
    ['ongoing stale end picker', makeBoard(ONGOING), { customEndDate: '2026-09-01' }, 0, []],
    ['custom → ongoing', makeBoard(), { timeframe: Timeframe.INDEFINITE, customEndDate: '' }, 1, ['timeframe', 'startDate', 'endDate']],
    ['monthly with stale date picker', makeBoard({ timeframe: Timeframe.MONTHLY }), { customStartDate: '2026-07-09' }, 0, []],
    ['center', makeBoard(), { centerType: CenterSquareType.NONE }, 1, ['centerSquareType']],
    ['rename + dates + center', makeBoard(), { name: 'Y', customEndDate: '2026-08-01', centerType: CenterSquareType.NONE }, 3, ['name', 'startDate', 'endDate', 'centerSquareType']],
  ];

  for (const [label, board, overrides, count, keys] of cases) {
    it(label, () => {
      const draft = draftOf(board, overrides);
      expect(countBoardDetailsEdits(board, draft, NOW)).toBe(count);
      const patch = buildBoardDetailsPatch(board, draft, 'monday', NOW);
      expect(Object.keys(patch ?? {}).sort()).toEqual([...keys].sort());
    });
  }
});

describe('validateBoardDetails', () => {
  const ok = { hasCandidateTasks: true, centerTaskId: 'task-1' };

  it('a valid draft passes', () => {
    expect(validateBoardDetails(seedBoardDetailsDraft(makeBoard()), ok)).toBeNull();
  });

  it('name is required', () => {
    expect(validateBoardDetails(draftOf(makeBoard(), { name: '   ' }), ok)).toBe('Board name is required.');
  });

  it('custom needs both dates', () => {
    expect(validateBoardDetails(draftOf(makeBoard(), { customEndDate: '' }), ok)).toBe(
      'Both start and end dates are required for a custom timeframe.',
    );
  });

  it('custom end must be on or after the start', () => {
    expect(
      validateBoardDetails(draftOf(makeBoard(), { customStartDate: '2026-07-10', customEndDate: '2026-07-09' }), ok),
    ).toBe('End date must be on or after the start date.');
  });

  it('an ongoing board needs no end date', () => {
    expect(validateBoardDetails(seedBoardDetailsDraft(makeBoard(ONGOING)), ok)).toBeNull();
  });

  it('CHOSEN only with a candidate', () => {
    const chosen = draftOf(makeBoard(), { centerType: CenterSquareType.CHOSEN });
    const msg = 'CHOSEN is unavailable — this board has no existing center task to restore.';
    expect(validateBoardDetails(chosen, { hasCandidateTasks: false, centerTaskId: 'task-1' })).toBe(msg);
    expect(validateBoardDetails(chosen, { hasCandidateTasks: true, centerTaskId: undefined })).toBe(msg);
    expect(validateBoardDetails(chosen, ok)).toBeNull();
  });
});
