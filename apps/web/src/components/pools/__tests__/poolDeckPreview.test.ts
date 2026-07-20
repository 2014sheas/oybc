import { describe, expect, it } from 'vitest';
import { CenterSquareType, Timeframe } from '@oybc/shared';
import type { RecurringBoardTemplate } from '@oybc/shared';
import { computeDeckFloor, formatDeckPreview } from '../poolDeckPreview';

/**
 * poolDeckPreview.test.ts — Pool edit sheet's dashed deck-preview line
 * (P2 Task 2). Covers the "smallest consuming floor, else the 3×3-FREE
 * default 8" rule (docs/POOLS_RECURRING.md §Surfaces item 2) and the
 * exact copy for both the "fills" and "short" branches.
 */

function buildTemplate(
  id: string,
  overrides: Partial<RecurringBoardTemplate> = {},
): RecurringBoardTemplate {
  return {
    id,
    userId: 'u1',
    name: `Template ${id}`,
    timeframe: Timeframe.WEEKLY,
    boardSize: 3,
    centerSquareType: CenterSquareType.FREE,
    isRandomized: false,
    seedTaskIds: [],
    poolIds: [],
    manualTaskIds: [],
    removedTaskIds: [],
    lastSpawnedWindowKey: null,
    isActive: true,
    createdAt: '2026-07-19T00:00:00.000Z',
    updatedAt: '2026-07-19T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

describe('computeDeckFloor', () => {
  it('defaults to the 3×3-FREE floor (8) when there are no consumers', () => {
    expect(computeDeckFloor([], 'p1')).toEqual({ boardSize: 3, floor: 8 });
  });

  it('defaults to 8 for a brand-new pool id no template references yet', () => {
    const template = buildTemplate('tpl1', { poolIds: ['some-other-pool'] });
    expect(computeDeckFloor([template], 'p1')).toEqual({ boardSize: 3, floor: 8 });
  });

  it('skips a soft-deleted consumer', () => {
    const template = buildTemplate('tpl1', {
      poolIds: ['p1'],
      isDeleted: true,
      boardSize: 4,
    });
    expect(computeDeckFloor([template], 'p1')).toEqual({ boardSize: 3, floor: 8 });
  });

  it('skips a paused consumer', () => {
    const template = buildTemplate('tpl1', {
      poolIds: ['p1'],
      isActive: false,
      boardSize: 4,
    });
    expect(computeDeckFloor([template], 'p1')).toEqual({ boardSize: 3, floor: 8 });
  });

  it('uses a single active consumer floor when smaller/larger than default', () => {
    const template = buildTemplate('tpl1', {
      poolIds: ['p1'],
      boardSize: 3,
      centerSquareType: CenterSquareType.NONE, // floor 9
    });
    expect(computeDeckFloor([template], 'p1')).toEqual({ boardSize: 3, floor: 9 });
  });

  it('picks the SMALLEST floor among multiple consumers', () => {
    const small = buildTemplate('small', {
      poolIds: ['p1'],
      boardSize: 3,
      centerSquareType: CenterSquareType.FREE, // floor 8
    });
    const large = buildTemplate('large', {
      poolIds: ['p1'],
      boardSize: 4,
      centerSquareType: CenterSquareType.FREE, // floor 16
    });
    expect(computeDeckFloor([large, small], 'p1')).toEqual({ boardSize: 3, floor: 8 });
  });
});

describe('formatDeckPreview', () => {
  it('formats the "fills" branch when the task count meets the floor', () => {
    expect(formatDeckPreview(8, { boardSize: 3, floor: 8 })).toBe(
      '8 tasks in the deck · fills a 3×3',
    );
    expect(formatDeckPreview(10, { boardSize: 3, floor: 8 })).toBe(
      '10 tasks in the deck · fills a 3×3',
    );
  });

  it('formats the "short" branch when below the floor', () => {
    expect(formatDeckPreview(6, { boardSize: 3, floor: 8 })).toBe(
      '6 tasks in the deck · 2 short of a 3×3',
    );
  });

  it('handles the 0-task / singular-"task" edges', () => {
    expect(formatDeckPreview(0, { boardSize: 3, floor: 8 })).toBe(
      '0 tasks in the deck · 8 short of a 3×3',
    );
    expect(formatDeckPreview(1, { boardSize: 3, floor: 8 })).toBe(
      '1 task in the deck · 7 short of a 3×3',
    );
  });
});
