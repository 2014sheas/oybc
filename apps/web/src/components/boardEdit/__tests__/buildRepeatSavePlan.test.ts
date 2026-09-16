import { describe, expect, it } from 'vitest';
import { CenterSquareType, Timeframe } from '@oybc/shared';
import { buildRepeatSavePlan } from '../BoardEditRepeatSection';

/**
 * Repeat-in-edit rework — the staged REPEATS section's Save decision core.
 * `buildRepeatSavePlan` is the single source of truth for BOTH the panel's
 * edit-counter contribution and the two-phase Save's phase-2 mutation, so
 * every branch is pinned here (mirrors `buildEditDatesPatch.test.ts`).
 */

const oneOffBase = {
  spawnedFromTemplateId: undefined,
  sourceTemplateIsActive: undefined,
  stagedCadence: 'off' as const,
  stagedActive: null,
  centerType: CenterSquareType.FREE,
  hasUserId: true,
};

const spawnedBase = {
  spawnedFromTemplateId: 'tpl-1',
  sourceTemplateIsActive: true,
  stagedCadence: 'off' as const,
  stagedActive: null,
  centerType: CenterSquareType.FREE,
  hasUserId: true,
};

describe('buildRepeatSavePlan — one-off board', () => {
  it('returns null with cadence Off (the default staged state)', () => {
    expect(buildRepeatSavePlan(oneOffBase)).toBeNull();
  });

  it('returns startRepeating with the staged cadence', () => {
    expect(
      buildRepeatSavePlan({ ...oneOffBase, stagedCadence: Timeframe.WEEKLY }),
    ).toEqual({ kind: 'startRepeating', cadence: Timeframe.WEEKLY });
  });

  it('never starts repeating for a CHOSEN center (validateSpawnPool would reject it)', () => {
    expect(
      buildRepeatSavePlan({
        ...oneOffBase,
        stagedCadence: Timeframe.DAILY,
        centerType: CenterSquareType.CHOSEN,
      }),
    ).toBeNull();
  });

  it('never starts repeating without a user id', () => {
    expect(
      buildRepeatSavePlan({ ...oneOffBase, stagedCadence: Timeframe.DAILY, hasUserId: false }),
    ).toBeNull();
  });
});

describe('buildRepeatSavePlan — repeating board', () => {
  it('returns null when the Active toggle was never touched', () => {
    expect(buildRepeatSavePlan(spawnedBase)).toBeNull();
  });

  it('returns null when the staged Active matches the live record', () => {
    expect(buildRepeatSavePlan({ ...spawnedBase, stagedActive: true })).toBeNull();
  });

  it('returns setActive when the staged Active differs (pause)', () => {
    expect(buildRepeatSavePlan({ ...spawnedBase, stagedActive: false })).toEqual({
      kind: 'setActive',
      isActive: false,
    });
  });

  it('returns setActive when resuming a paused record', () => {
    expect(
      buildRepeatSavePlan({ ...spawnedBase, sourceTemplateIsActive: false, stagedActive: true }),
    ).toEqual({ kind: 'setActive', isActive: true });
  });

  it('stages nothing for an unresolved (soft-deleted) source record', () => {
    expect(
      buildRepeatSavePlan({
        ...spawnedBase,
        sourceTemplateIsActive: undefined,
        stagedActive: false,
      }),
    ).toBeNull();
  });

  it('ignores a staged cadence on a board that already repeats', () => {
    expect(
      buildRepeatSavePlan({ ...spawnedBase, stagedCadence: Timeframe.DAILY }),
    ).toBeNull();
  });
});
