import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { CenterSquareType, Timeframe } from '@oybc/shared';
import { BoardSetupForm, type BoardSetupFormProps } from '../BoardSetupForm';

/**
 * Board Creation Split (web PR C) — `isRecurring` is now a fixed prop
 * (set once at wizard entry, mirroring iOS `BoardWizardViewModel.isRecurring`)
 * rather than derived from a mid-form "Repeats" segmented. This covers the
 * per-mode render branching: one-off shows the full Timeframe picker
 * (including Custom); recurring shows the "Repeats every" cadence
 * segmented (Day/Week/Month/Year, no Custom) instead, plus a dashed
 * cadence note, and excludes CHOSEN from the center options.
 *
 * This repo's Vitest harness has no jsdom/`@testing-library/react` (see
 * `vitest.config.ts`'s docstring + the precedent set in
 * `wizardTimeframeSeed.test.ts` / `wizardPersist.test.ts` /
 * `boardEditSaveAtomicity.test.ts`), so there's no `fireEvent`/interaction
 * layer here. `react-dom/server`'s `renderToStaticMarkup` needs no DOM —
 * it's a pure string serializer — so it's used here for presence/absence
 * assertions on the rendered markup, which is exactly what this
 * requirement needs (no click simulation required: `isRecurring` is a
 * controlled prop).
 */

function baseProps(overrides: Partial<BoardSetupFormProps> = {}): BoardSetupFormProps {
  return {
    name: 'Test board',
    onNameChange: () => {},
    size: 3,
    onSizeChange: () => {},
    timeframe: Timeframe.DAILY,
    onTimeframeChange: () => {},
    customStartDate: '',
    onCustomStartDateChange: () => {},
    customEndDate: '',
    onCustomEndDateChange: () => {},
    centerType: CenterSquareType.FREE,
    onCenterTypeChange: () => {},
    isRecurring: false,
    isCore: false,
    weekStartDay: 'monday',
    ...overrides,
  };
}

function render(props: Partial<BoardSetupFormProps> = {}): string {
  return renderToStaticMarkup(React.createElement(BoardSetupForm, baseProps(props)));
}

describe('BoardSetupForm — mode-locked schedule field (Board Creation Split, web PR C)', () => {
  it('one-off: shows the full Timeframe picker (including Custom) and no Repeats-every segmented', () => {
    const html = render({ isRecurring: false, timeframe: Timeframe.DAILY });
    expect(html).toContain('>Timeframe<');
    expect(html).toContain('>Custom<');
    expect(html).not.toContain('Repeats every');
  });

  it('recurring: shows the "Repeats every" cadence segmented (Day/Week/Month/Year), no Timeframe picker, no Custom', () => {
    const html = render({ isRecurring: true, timeframe: Timeframe.WEEKLY });
    expect(html).toContain('Repeats every');
    expect(html).toContain('>Day<');
    expect(html).toContain('>Week<');
    expect(html).toContain('>Month<');
    expect(html).toContain('>Year<');
    expect(html).not.toContain('>Timeframe<');
    expect(html).not.toContain('>Custom<');
  });

  it('recurring: shows the dashed "A fresh board every {cadence} · starts {window}" note', () => {
    const html = render({ isRecurring: true, timeframe: Timeframe.WEEKLY });
    expect(html).toContain('A fresh board every week');
  });

  it('coerces the CHOSEN center option away in recurring mode (matches the long-standing recurring exclusion)', () => {
    const html = render({
      isRecurring: true,
      timeframe: Timeframe.DAILY,
      centerType: CenterSquareType.FREE,
    });
    expect(html).not.toContain('Pick one of my board tasks');
  });

  it('one-off board-size caption states the exact requirement', () => {
    const html = render({ isRecurring: false, size: 5, centerType: CenterSquareType.FREE });
    expect(html).toContain('A 5×5 board needs 24 tasks.');
  });

  it('recurring board-size caption drops the "A n×n board" framing (overfill is the variety mechanism)', () => {
    const html = render({ isRecurring: true, size: 5, centerType: CenterSquareType.FREE });
    expect(html).toContain('Needs at least 24 tasks — extras rotate in.');
  });

  it('hides both schedule fields entirely in edit-active mode', () => {
    const html = render({ mode: 'edit-active', isRecurring: false });
    expect(html).not.toContain('>Timeframe<');
    expect(html).not.toContain('Repeats every');
  });

  it('hides both schedule fields entirely in the core layout', () => {
    const html = render({ isCore: true, isRecurring: false });
    expect(html).not.toContain('>Timeframe<');
    expect(html).not.toContain('Repeats every');
  });
});
