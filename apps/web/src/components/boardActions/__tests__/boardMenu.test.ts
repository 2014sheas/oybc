import { describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  Timeframe,
  type Board,
  type RecurringBoardTemplate,
} from '@oybc/shared';
import { buildBoardMenuItems, isRepeatEligible, type BoardMenuItemKind } from '../boardMenu';

/**
 * Board Edit redesign slice 2 (T1) — the title-row "…" menu builder (plan
 * D3 / D6). Mirrored case-for-case by iOS `BoardMenuItemsTests`.
 */

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
): BoardMenuItemKind[] {
  return buildBoardMenuItems({ board, sourceTemplate, templatesLoaded }).map((i) => i.kind);
}

describe('buildBoardMenuItems', () => {
  it('ad-hoc active one-off: Board details · Repeat · Archive · Delete', () => {
    expect(kinds(makeBoard())).toEqual(['details', 'repeat', 'archive', 'delete']);
  });

  it('ad-hoc ended but unsealed: still editable — same four items', () => {
    const ended = makeBoard({ endDate: '2026-01-31T23:59:59.999' });
    expect(kinds(ended)).toEqual(['details', 'repeat', 'archive', 'delete']);
  });

  it('sealed ad-hoc: Delete only', () => {
    expect(kinds(makeBoard({ sealedAt: '2026-08-01T00:00:00.000Z' }))).toEqual(['delete']);
  });

  it('core active: Core defaults… · Delete', () => {
    expect(kinds(makeBoard({ isCore: true, timeframe: Timeframe.WEEKLY }))).toEqual(['coreDefaults', 'delete']);
  });

  it('core sealed: Core defaults… · Delete', () => {
    expect(
      kinds(makeBoard({ isCore: true, timeframe: Timeframe.WEEKLY, sealedAt: '2026-08-01T00:00:00.000Z' })),
    ).toEqual(['coreDefaults', 'delete']);
  });

  it('archived / completed ad-hoc: Delete only', () => {
    expect(kinds(makeBoard({ status: BoardStatus.ARCHIVED }))).toEqual(['delete']);
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

  it('carries the verbatim labels, icons, and danger flag', () => {
    expect(buildBoardMenuItems({ board: makeBoard(), sourceTemplate: undefined, templatesLoaded: true })).toEqual([
      { kind: 'details', label: 'Board details…', icon: 'sliders', danger: false },
      { kind: 'repeat', label: 'Repeat this board…', icon: 'repeat', danger: false },
      { kind: 'archive', label: 'Archive', icon: 'boards', danger: false },
      { kind: 'delete', label: 'Delete', icon: 'trash', danger: true },
    ]);
    expect(
      buildBoardMenuItems({ board: makeBoard({ isCore: true }), sourceTemplate: undefined, templatesLoaded: true })[0],
    ).toEqual({ kind: 'coreDefaults', label: 'Core defaults…', icon: 'sliders', danger: false });
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
