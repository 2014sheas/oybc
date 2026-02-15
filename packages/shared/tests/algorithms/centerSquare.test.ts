import {
  getCenterSquareIndex,
  isCenterAutoCompleted,
  getCenterDisplayText,
} from '../../src/algorithms/centerSquare';
import { CenterSquareType } from '../../src/constants/enums';

describe('getCenterSquareIndex', () => {
  it('returns 4 for a 3x3 board', () => {
    expect(getCenterSquareIndex(3)).toBe(4);
  });

  it('returns 12 for a 5x5 board', () => {
    expect(getCenterSquareIndex(5)).toBe(12);
  });

  it('returns -1 for a 4x4 board (even-sized)', () => {
    expect(getCenterSquareIndex(4)).toBe(-1);
  });

  it('returns -1 for a 2x2 board (even-sized)', () => {
    expect(getCenterSquareIndex(2)).toBe(-1);
  });

  it('returns 0 for a 1x1 board', () => {
    expect(getCenterSquareIndex(1)).toBe(0);
  });

  it('returns 24 for a 7x7 board', () => {
    expect(getCenterSquareIndex(7)).toBe(24);
  });
});

describe('isCenterAutoCompleted', () => {
  it('returns true for FREE type', () => {
    expect(isCenterAutoCompleted(CenterSquareType.FREE)).toBe(true);
  });

  it('returns true for CUSTOM_FREE type', () => {
    expect(isCenterAutoCompleted(CenterSquareType.CUSTOM_FREE)).toBe(true);
  });

  it('returns false for CHOSEN type', () => {
    expect(isCenterAutoCompleted(CenterSquareType.CHOSEN)).toBe(false);
  });

  it('returns false for NONE type', () => {
    expect(isCenterAutoCompleted(CenterSquareType.NONE)).toBe(false);
  });
});

describe('getCenterDisplayText', () => {
  it('returns "FREE SPACE" for FREE type', () => {
    expect(getCenterDisplayText(CenterSquareType.FREE)).toBe('FREE SPACE');
  });

  it('returns custom name for CUSTOM_FREE type when provided', () => {
    expect(getCenterDisplayText(CenterSquareType.CUSTOM_FREE, 'My Goal!')).toBe('My Goal!');
  });

  it('returns "FREE SPACE" for CUSTOM_FREE type when no custom name provided', () => {
    expect(getCenterDisplayText(CenterSquareType.CUSTOM_FREE)).toBe('FREE SPACE');
  });

  it('returns "FREE SPACE" for CUSTOM_FREE type when custom name is undefined', () => {
    expect(getCenterDisplayText(CenterSquareType.CUSTOM_FREE, undefined)).toBe('FREE SPACE');
  });

  it('returns empty string for CHOSEN type', () => {
    expect(getCenterDisplayText(CenterSquareType.CHOSEN)).toBe('');
  });

  it('returns empty string for CHOSEN type even with custom name', () => {
    expect(getCenterDisplayText(CenterSquareType.CHOSEN, 'ignored')).toBe('');
  });

  it('returns empty string for NONE type', () => {
    expect(getCenterDisplayText(CenterSquareType.NONE)).toBe('');
  });
});
