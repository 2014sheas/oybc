import { describe, expect, it } from 'vitest';
import { Timeframe, type Board } from '@oybc/shared';
import { draftKind, draftTypePillLabel, formatDraftMeta } from '../draftRowFormat';

function makeDraft(overrides: Partial<Board> = {}): Pick<Board, 'boardSize' | 'timeframe' | 'isRecurringDraft'> {
  return {
    boardSize: 4,
    timeframe: Timeframe.DAILY,
    isRecurringDraft: false,
    ...overrides,
  };
}

describe('draftKind', () => {
  it('is oneOff when isRecurringDraft is false or undefined', () => {
    expect(draftKind({ isRecurringDraft: false })).toBe('oneOff');
    expect(draftKind({ isRecurringDraft: undefined })).toBe('oneOff');
  });

  it('is recurring when isRecurringDraft is true', () => {
    expect(draftKind({ isRecurringDraft: true })).toBe('recurring');
  });
});

describe('draftTypePillLabel', () => {
  it('renders the canonical uppercase labels', () => {
    expect(draftTypePillLabel('oneOff')).toBe('ONE-OFF');
    expect(draftTypePillLabel('recurring')).toBe('RECURRING');
  });
});

describe('formatDraftMeta', () => {
  it('formats a one-off draft as "SIZE×SIZE · N tasks" — no cadence prefix', () => {
    const draft = makeDraft({ boardSize: 4, isRecurringDraft: false });
    expect(formatDraftMeta(draft, 9)).toBe('4×4 · 9 tasks');
  });

  it('singularizes "task" for a count of exactly 1', () => {
    const draft = makeDraft({ boardSize: 3, isRecurringDraft: false });
    expect(formatDraftMeta(draft, 1)).toBe('3×3 · 1 task');
  });

  it('formats a recurring draft with the cadence prefix', () => {
    const draft = makeDraft({ boardSize: 5, timeframe: Timeframe.WEEKLY, isRecurringDraft: true });
    expect(formatDraftMeta(draft, 12)).toBe('Every week · 5×5 · 12 tasks');
  });

  it('reflects the FULL resolved pool size for a recurring draft, including overfill', () => {
    const draft = makeDraft({ boardSize: 3, timeframe: Timeframe.DAILY, isRecurringDraft: true });
    // A 3×3 FREE-center board needs 8 — 12 is a valid (overfilled) pool.
    expect(formatDraftMeta(draft, 12)).toBe('Every day · 3×3 · 12 tasks');
  });
});
