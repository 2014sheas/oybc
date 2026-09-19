import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { DiceButton } from '../DiceButton';

/**
 * The dice is the opt-in "variation" toggle on every counting target
 * (docs/BOARD_SOURCES.md §Member rules; handoff §Interactions "Variation
 * (dice)"). Two things must not drift: the pip count per level (0 / 2 / 5)
 * and the accessible name, which states the CURRENT level rather than the
 * action (B3 RC1) so a screen-reader user can tell what a row is set to
 * without activating it.
 *
 * Rendered with `react-dom/server` — there is no jsdom/RTL harness in this
 * repo (see `BoardSetupForm.test.ts`); the cycle's click behaviour is
 * covered by the Playwright specs, not here.
 */
function render(level: 0 | 1 | 2): string {
  return renderToStaticMarkup(React.createElement(DiceButton, { level, onCycle: () => {} }));
}

function pipCount(html: string): number {
  return html.split('<circle').length - 1;
}

describe('DiceButton', () => {
  it('draws no pips and a muted outline when off, and names the state', () => {
    const html = render(0);
    expect(pipCount(html)).toBe(0);
    expect(html).toContain('aria-label="Vary: off"');
    expect(html).toContain('aria-pressed="false"');
    expect(html).toMatch(/class="[^"]*_off_/);
    expect(html).not.toMatch(/class="[^"]*_on_/);
  });

  it('draws two pips on the blue fill for "a little"', () => {
    const html = render(1);
    expect(pipCount(html)).toBe(2);
    expect(html).toContain('aria-label="Vary: a little"');
    expect(html).toContain('aria-pressed="true"');
    expect(html).toMatch(/class="[^"]*_on_/);
  });

  it('draws the five-pip quincunx for "a lot"', () => {
    const html = render(2);
    expect(pipCount(html)).toBe(5);
    expect(html).toContain('aria-label="Vary: a lot"');
    expect(html).toMatch(/class="[^"]*_on_/);
  });
});
