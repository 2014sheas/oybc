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
 * `RisoDiceButtonTests`). The B3.1 review's proportions — corners one step
 * out from the naive 6/12, which left only 1.04px between a corner pip and
 * the centre — carried over verbatim when the face grew 22 → 28 on
 * 2026-09-22: the 18-box became 24 and every coordinate scaled by 24/18,
 * rounded (9 → 12, 5 → 7, 13 → 17).
 */
const EXPECTED_PIPS: Record<0 | 1 | 2, Array<[string, string]>> = {
  0: [['12', '12']],
  1: [
    ['7', '7'],
    ['17', '17'],
  ],
  2: [
    ['7', '7'],
    ['17', '7'],
    ['12', '12'],
    ['7', '17'],
    ['17', '17'],
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
    expect(pipCentres(html)).toEqual([['12', '12']]);
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

  // A corner pip centre is 9 from the face edge (the 24-box is inset 2 in
  // the 28 face), so it clears the 1.5px keyline by 9 − 2 (r) − 1.5 =
  // 5.5px — equivalently, the outermost pip EDGE sits at 21 while the
  // border's inner edge is at 26.5. Checked against all FOUR face edges
  // (left/top/right/bottom) for every pip on every face, not just the near
  // two an `x`/`y` minimum alone implies — a pip could clip the far edge
  // while clearing the near one — and the tightest of all of them is
  // pinned to the documented 5.5px, not just `> 0`, so a regression back
  // toward a cramped geometry would fail here rather than pass on a loose
  // bound. Pinned as arithmetic on the rendered radius so a later `r` bump
  // that would clip the border fails here rather than in a snapshot diff.
  it('keeps every pip clear of the 1.5px keyline', () => {
    const faceSize = 28;
    const inset = 2;
    const keyline = 1.5;
    let tightestClearance = Infinity;
    for (const level of [0, 1, 2] as const) {
      const html = render(level);
      const r = Number(/\br="([^"]+)"/.exec(html)?.[1]);
      expect(r).toBeGreaterThan(0);
      for (const [cx, cy] of pipCentres(html)) {
        const faceX = Number(cx) + inset;
        const faceY = Number(cy) + inset;
        const edgeClearances = [
          faceX - r - keyline, // left
          faceY - r - keyline, // top
          faceSize - faceX - r - keyline, // right
          faceSize - faceY - r - keyline, // bottom
        ];
        for (const clearance of edgeClearances) {
          expect(clearance).toBeGreaterThan(0);
        }
        tightestClearance = Math.min(tightestClearance, ...edgeClearances);
      }
    }
    expect(tightestClearance).toBeCloseTo(5.5, 3);
  });
});
