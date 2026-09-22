import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { DiceButton } from '../DiceButton';

/**
 * The dice is the opt-in "variation" toggle on every counting target
 * (docs/BOARD_SOURCES.md §Member rules; handoff §Interactions "Variation
 * (dice)"). Three things must not drift: the pip count per level (1 / 2 /
 * 5), the exact pip COORDINATES — cross-platform parity with the Swift
 * `RisoDiceButton.pips` table is the whole point of the square dice face,
 * and iOS's own cover is snapshot baselines that are advisory in CI
 * (ROADMAP A8), so a one-sided tweak would otherwise ship silently — and
 * the accessible name, which states the CURRENT level rather than the
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

/** Every rendered pip centre, in document order. */
function pipCentres(html: string): Array<[string, string]> {
  return [...html.matchAll(/cx="([^"]+)"\s+cy="([^"]+)"/g)].map(([, cx, cy]) => [cx, cy]);
}

/**
 * The pip table the Swift twin must match, coordinate for coordinate
 * (`apps/ios/OYBC/Views/Riso/RisoDiceButton.swift`, pinned there by
 * `RisoDiceButtonTests`). Corners at 5/13 rather than 6/12 (B3.1 review):
 * 6/12 left only 1.04px between a corner pip and the centre pip; 5/13
 * gives 2.46px and still clears the 1.5px keyline by 3.9px.
 */
const EXPECTED_PIPS: Record<0 | 1 | 2, Array<[string, string]>> = {
  0: [['9', '9']],
  1: [
    ['5', '5'],
    ['13', '13'],
  ],
  2: [
    ['5', '5'],
    ['13', '5'],
    ['9', '9'],
    ['5', '13'],
    ['13', '13'],
  ],
};

describe('DiceButton', () => {
  it('draws one dimmed pip and a muted outline when off, and names the state', () => {
    const html = render(0);
    expect(pipCount(html)).toBe(1);
    expect(html).toContain('aria-label="Vary: off"');
    expect(html).toMatch(/class="[^"]*_off_/);
    expect(html).not.toMatch(/class="[^"]*_on_/);
  });

  it('draws two pips on the blue fill for "a little"', () => {
    const html = render(1);
    expect(pipCount(html)).toBe(2);
    expect(html).toContain('aria-label="Vary: a little"');
    expect(html).toMatch(/class="[^"]*_on_/);
  });

  it('never claims a binary pressed state — it cycles through three', () => {
    // `aria-pressed` would announce "a little" and "a lot" identically;
    // the stateful accessible name carries the whole cycle instead.
    expect(render(0)).not.toContain('aria-pressed');
    expect(render(1)).not.toContain('aria-pressed');
    expect(render(2)).not.toContain('aria-pressed');
  });

  it('draws the five-pip quincunx for "a lot"', () => {
    const html = render(2);
    expect(pipCount(html)).toBe(5);
    expect(html).toContain('aria-label="Vary: a lot"');
    expect(html).toMatch(/class="[^"]*_on_/);
  });

  it('renders one centred, dimmed pip at vary level 0 so the die is not an empty box', () => {
    const html = render(0);
    expect(pipCount(html)).toBe(1);
    expect(pipCentres(html)).toEqual([['9', '9']]);
    expect(html).toMatch(/class="[^"]*_offPip_/);
  });

  it('keeps the lit faces at two and five pips', () => {
    expect(pipCount(render(1))).toBe(2);
    expect(pipCount(render(2))).toBe(5);
  });

  // The cross-platform pin. iOS renders the SAME table from
  // `RisoDiceButton.pips`, asserted there by `RisoDiceButtonTests`; if
  // either side is nudged alone, one of the two tests goes red.
  it('draws every face at the exact pip coordinates the Swift twin uses', () => {
    expect(pipCentres(render(0))).toEqual(EXPECTED_PIPS[0]);
    expect(pipCentres(render(1))).toEqual(EXPECTED_PIPS[1]);
    expect(pipCentres(render(2))).toEqual(EXPECTED_PIPS[2]);
  });

  // A corner pip centre is 7 from the face edge (the 18-box is inset 2),
  // so it clears the 1.5px keyline by 7 − 1.6 (r) − 1.5 = 3.9px. Pinned
  // as arithmetic on the rendered radius so a later `r` bump that would
  // clip the border fails here rather than in a snapshot diff.
  it('keeps every pip clear of the 1.5px keyline', () => {
    const html = render(2);
    const r = Number(/\br="([^"]+)"/.exec(html)?.[1]);
    expect(r).toBeGreaterThan(0);
    const minCentre = Math.min(...pipCentres(html).flat().map(Number));
    expect(minCentre + 2 - r - 1.5).toBeGreaterThan(0);
  });
});
