import {
  getCenterSquareIndex,
  isCenterAutoCompleted,
  getCenterDisplayText,
  effectiveCenter,
  isLegacyChosen,
  isLegacyChosenCenterLocked,
} from '../src/centerSquare';
import { CenterSquareType } from '../src/constants';

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

  it('returns empty string for CHOSEN type', () => {
    expect(getCenterDisplayText(CenterSquareType.CHOSEN)).toBe('');
  });

  it('returns empty string for NONE type', () => {
    expect(getCenterDisplayText(CenterSquareType.NONE)).toBe('');
  });
});

describe('effectiveCenter (legacy CHOSEN read-path normalization)', () => {
  it('maps CHOSEN to NONE', () => {
    expect(effectiveCenter(CenterSquareType.CHOSEN)).toBe(CenterSquareType.NONE);
  });

  it('passes FREE and NONE through unchanged', () => {
    expect(effectiveCenter(CenterSquareType.FREE)).toBe(CenterSquareType.FREE);
    expect(effectiveCenter(CenterSquareType.NONE)).toBe(CenterSquareType.NONE);
  });
});

describe('isLegacyChosen', () => {
  it('is true only for CHOSEN', () => {
    expect(isLegacyChosen(CenterSquareType.CHOSEN)).toBe(true);
    expect(isLegacyChosen(CenterSquareType.FREE)).toBe(false);
    expect(isLegacyChosen(CenterSquareType.NONE)).toBe(false);
  });
});

describe('isLegacyChosenCenterLocked', () => {
  it('is true for the positional center of a CHOSEN odd board', () => {
    expect(isLegacyChosenCenterLocked(CenterSquareType.CHOSEN, 2, 2, 5)).toBe(true);
    expect(isLegacyChosenCenterLocked(CenterSquareType.CHOSEN, 1, 1, 3)).toBe(true);
  });

  it('is false off-center on a CHOSEN board', () => {
    expect(isLegacyChosenCenterLocked(CenterSquareType.CHOSEN, 0, 0, 5)).toBe(false);
    expect(isLegacyChosenCenterLocked(CenterSquareType.CHOSEN, 2, 1, 5)).toBe(false);
  });

  it('is false for FREE / NONE centers', () => {
    expect(isLegacyChosenCenterLocked(CenterSquareType.FREE, 2, 2, 5)).toBe(false);
    expect(isLegacyChosenCenterLocked(CenterSquareType.NONE, 2, 2, 5)).toBe(false);
  });

  it('is false on an even board (no positional center)', () => {
    expect(isLegacyChosenCenterLocked(CenterSquareType.CHOSEN, 2, 2, 4)).toBe(false);
    expect(isLegacyChosenCenterLocked(CenterSquareType.CHOSEN, 1, 1, 4)).toBe(false);
  });
});
