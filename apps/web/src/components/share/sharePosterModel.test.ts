import { describe, expect, it } from 'vitest';
import { Timeframe, momentPosterCells, type BoardMomentReplay } from '@oybc/shared';
import {
  posterBadge, posterCellPx, posterLabelSize, posterStreakLabel, shareFilename, shareSheetTitle, shareText, shareTitle, slugify,
} from './sharePosterModel';

describe('share sheet model', () => {
  it('titles, badges and filenames follow the kind', () => {
    expect(shareSheetTitle('bingo')).toBe('Share bingo');
    expect(shareSheetTitle('greenlog')).toBe('Share greenlog');
    expect(posterBadge('bingo')).toBe('BINGO');
    expect(posterBadge('greenlog')).toBe('GREENLOG');
    expect(shareFilename('Week 41 Board!', 'bingo')).toBe('week-41-board-bingo.png');
    expect(shareFilename('Week 41 Board!', 'greenlog')).toBe('week-41-board-greenlog.png');
    expect(shareTitle('My Week', 'bingo')).toBe('My Week — BINGO');
    expect(shareTitle('My Week', 'greenlog')).toBe('My Week — GREENLOG');
  });

  it('an all-symbol board name falls back to "board" in the filename', () => {
    expect(shareFilename('★★★', 'bingo')).toBe('board-bingo.png');
    expect(shareFilename('!!!', 'greenlog')).toBe('board-greenlog.png');
  });

  it('slugify trims and caps', () => {
    expect(slugify('  --Hi  There--  ')).toBe('hi-there');
    expect(slugify('x'.repeat(100))).toHaveLength(60);
  });

  it('share text: bingo counts lines against the board size, greenlog keeps its copy', () => {
    expect(shareText('bingo', 'Week', 2, 5)).toBe('Bingo on Week! 2 of 12 lines.');
    expect(shareText('bingo', 'Week', 1, 3)).toBe('Bingo on Week! 1 of 8 lines.');
    expect(shareText('greenlog', 'Week', 8, 3)).toBe('I crushed every square. GREENLOG on On Your Bingo Card!');
  });

  it('the streak card shows only on a recurring timeframe with a streak above 1', () => {
    expect(posterStreakLabel(2, Timeframe.WEEKLY)).toBe('2w');
    expect(posterStreakLabel(5, Timeframe.MONTHLY)).toBe('5mo');
    expect(posterStreakLabel(1, Timeframe.WEEKLY)).toBeUndefined();
    expect(posterStreakLabel(0, Timeframe.DAILY)).toBeUndefined();
    expect(posterStreakLabel(9, Timeframe.CUSTOM)).toBeUndefined();
  });

  it('label size clamps and cell size follows the board size', () => {
    expect(posterCellPx(3)).toBeCloseTo(62.667, 2);
    expect(posterLabelSize(posterCellPx(5))).toBe(6.5);
    expect(posterLabelSize(posterCellPx(3))).toBeCloseTo(0.165 * 62.667, 2);
    expect(posterLabelSize(10)).toBe(6.5);
    expect(posterLabelSize(1000)).toBe(14);
  });

  it('momentPosterCells is exported to the web and marks landed cells done', () => {
    const replay: BoardMomentReplay = {
      order: [{ boardTaskId: 'a', idx: 0, completedAt: null }], freeIdx: null, lineClosureBeat: {}, completedTasks: 1, totalTasks: 4, size: 2,
    };
    const cells = [0, 1, 2, 3].map((idx) => ({ idx, label: `t${idx}`, type: 'normal' as const, isFree: false }));
    expect(momentPosterCells(replay, cells, 'bingo').map((c) => c.state)).toEqual(['done', 'undone', 'undone', 'undone']);
  });
});
