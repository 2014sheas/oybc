import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { CenterSquareType, Timeframe } from '@oybc/shared';
import { BoardSetupForm, type BoardSetupFormProps } from '../BoardSetupForm';

/**
 * P4 (Task Pools + Recurring Boards Rework) — covers the "Repeats"
 * segmented's render branching: the full Timeframe picker (including
 * Custom) shows ONLY when `repeats === null` (Once); a chosen cadence
 * hides it entirely (the cadence IS the window).
 *
 * This repo's Vitest harness has no jsdom/`@testing-library/react` (see
 * `vitest.config.ts`'s docstring + the precedent set in
 * `wizardTimeframeSeed.test.ts` / `wizardPersist.test.ts` /
 * `boardEditSaveAtomicity.test.ts`), so there's no `fireEvent`/interaction
 * layer here. `react-dom/server`'s `renderToStaticMarkup` needs no DOM —
 * it's a pure string serializer — so it's used here for presence/absence
 * assertions on the rendered markup, which is exactly what this
 * requirement needs (no click simulation required: the Repeats value is
 * a controlled prop).
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
    repeats: null,
    onRepeatsChange: () => {},
    isCore: false,
    weekStartDay: 'monday',
    ...overrides,
  };
}

function render(props: Partial<BoardSetupFormProps> = {}): string {
  return renderToStaticMarkup(React.createElement(BoardSetupForm, baseProps(props)));
}

describe('BoardSetupForm — Repeats segmented (P4)', () => {
  it('renders the Repeats segmented with Once/Daily/Weekly/Monthly/Yearly options', () => {
    const html = render({ repeats: null });
    expect(html).toContain('>Repeats<');
    expect(html).toContain('>Once<');
    expect(html).toContain('>Daily<');
    expect(html).toContain('>Weekly<');
    expect(html).toContain('>Monthly<');
    expect(html).toContain('>Yearly<');
  });

  it('shows the full Timeframe picker (including Custom) when repeats === null', () => {
    const html = render({ repeats: null, timeframe: Timeframe.DAILY });
    expect(html).toContain('>Timeframe<');
    expect(html).toContain('>Custom<');
  });

  it('hides the Timeframe picker entirely once a cadence is chosen', () => {
    const html = render({ repeats: Timeframe.WEEKLY, timeframe: Timeframe.WEEKLY });
    expect(html).not.toContain('>Timeframe<');
    expect(html).not.toContain('>Custom<');
  });

  it('shows the Once one-line note when repeats === null', () => {
    const html = render({ repeats: null });
    expect(html).toContain('A one-off board for the timeframe you pick below.');
  });

  it('shows the cadence one-line note ("<cadence>, drawn from a task pool.") when a cadence is chosen', () => {
    const html = render({ repeats: Timeframe.DAILY, timeframe: Timeframe.DAILY });
    expect(html).toContain('Every day, drawn from a task pool.');
  });

  it('coerces the CHOSEN center option away in recurring mode (matches the long-standing recurring exclusion)', () => {
    const html = render({
      repeats: Timeframe.DAILY,
      timeframe: Timeframe.DAILY,
      centerType: CenterSquareType.FREE,
    });
    expect(html).not.toContain('Pick one of my board tasks');
  });

  it('hides the Repeats segmented entirely in edit-active mode', () => {
    const html = render({ mode: 'edit-active', repeats: null });
    expect(html).not.toContain('>Repeats<');
  });

  it('hides the Repeats segmented entirely in the core layout', () => {
    const html = render({ isCore: true, repeats: null });
    expect(html).not.toContain('>Repeats<');
  });
});
