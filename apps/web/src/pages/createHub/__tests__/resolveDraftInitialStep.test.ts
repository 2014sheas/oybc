import { describe, expect, it } from 'vitest';
import { computeDraftInitialStep } from '../resolveDraftInitialStep';

describe('computeDraftInitialStep', () => {
  it('returns Setup (1) when nothing has been selected yet', () => {
    expect(computeDraftInitialStep(8, 0)).toBe(1);
  });

  it('returns Tasks/Pool (2) when the selection is below the requirement', () => {
    expect(computeDraftInitialStep(8, 1)).toBe(2);
    expect(computeDraftInitialStep(8, 7)).toBe(2);
  });

  it('returns Preview (3) once the selection can fill the board exactly', () => {
    expect(computeDraftInitialStep(8, 8)).toBe(3);
  });

  it('returns Preview (3) for an overfilled recurring pool (extras rotate in)', () => {
    expect(computeDraftInitialStep(8, 27)).toBe(3);
  });
});
