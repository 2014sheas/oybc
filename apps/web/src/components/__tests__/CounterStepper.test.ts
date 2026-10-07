import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { CounterStepper } from '../CounterStepper';
import { compactStepperBase } from '../counterStepperMath';

/**
 * `size="compact"` (B3, docs/BOARD_SOURCES.md §Member rules) adds the
 * wizard member row's 32px target pill WITHOUT disturbing the default
 * variant the compound builder already ships — hence the literal
 * equality check on the default markup below.
 *
 * CSS-module class names carry a per-file content hash, so the assertion
 * strips it (`_stepperRow_6d73a4` → `stepperRow`): the test pins the
 * ELEMENT shape, not the stylesheet's hash.
 */
function render(props: Parameters<typeof CounterStepper>[0]): string {
  return renderToStaticMarkup(React.createElement(CounterStepper, props));
}

/** `_name_deadbee` → `name`, so a CSS edit doesn't fail a markup test. */
function stripHash(html: string): string {
  return html.replace(/_([A-Za-z][A-Za-z0-9]*)_[0-9a-f]{6}/g, '$1');
}

describe('CounterStepper', () => {
  it('renders the default variant unchanged', () => {
    const html = stripHash(render({ value: 2, min: 1, max: 5, onChange: () => {} }));
    expect(html).toBe(
      '<div class="stepperRow">' +
        '<button type="button" class="stepperButton">−</button>' +
        '<span class="stepperValue">2</span>' +
        '<button type="button" class="stepperButton">+</button>' +
        '</div>',
    );
  });

  it('renders the compact pill with named controls and a typeable value', () => {
    const html = render({ value: 5, min: 1, max: 35, onChange: () => {}, size: 'compact' });
    expect(html).toContain('aria-label="Decrease target"');
    expect(html).toContain('aria-label="Increase target"');
    expect(html).toContain('aria-label="Target"');
    expect(html).toContain('inputMode="numeric"');
    expect(html).toContain('value="5"');
  });

  it('lets an explicit label name the compact field', () => {
    const html = render({
      value: 5,
      min: 1,
      max: 35,
      onChange: () => {},
      size: 'compact',
      label: 'Pages a day',
    });
    expect(html).toContain('aria-label="Pages a day"');
    expect(html).not.toContain('aria-label="Target"');
  });

  it('disables the compact −/＋ at the bounds', () => {
    const atMin = render({ value: 1, min: 1, max: 35, onChange: () => {}, size: 'compact' });
    expect(atMin).toMatch(/aria-label="Decrease target"[^>]*disabled|disabled[^>]*aria-label="Decrease target"/);

    const atMax = render({ value: 35, min: 1, max: 35, onChange: () => {}, size: 'compact' });
    expect(atMax).toMatch(/aria-label="Increase target"[^>]*disabled|disabled[^>]*aria-label="Increase target"/);
  });

  /**
   * B3.1 — folding the member row's goal into the pill instead of a
   * separate caption beside it. `renderToStaticMarkup` (see the file-top
   * docstring: no jsdom/`@testing-library/react` in this harness) can't
   * exercise `getByLabelText`/DOM queries, so these assert on the
   * serialized markup instead — same intent (suffix text present, input
   * value untouched; no suffix element at all when omitted).
   */
  it('renders a compact suffix inside the pill without touching the editable value', () => {
    const html = render({
      value: 24,
      min: 1,
      max: 30,
      onChange: () => {},
      size: 'compact',
      suffix: '/ 30 Miles',
    });
    expect(html).toContain('/ 30 Miles');
    expect(html).toContain('value="24"');
  });

  it('renders no suffix element when none is given', () => {
    const html = render({ value: 24, min: 1, max: 30, onChange: () => {}, size: 'compact' });
    expect(html).not.toContain('data-testid="stepper-suffix"');
  });
});

/**
 * Final review M3 — the compact −/＋ gate on the UNCOMMITTED draft when
 * there is one, so typing `1` into a `min: 1` field disables `−` right
 * away instead of at blur. Twin of iOS
 * `RisoCountStepperMath.base(value:draft:kind:min:max:)`; pinned here as a
 * predicate because the server render never has a draft.
 */
describe('compactStepperBase (the −/＋ disabled gate)', () => {
  it('falls back to the committed value when nothing is being typed', () => {
    expect(compactStepperBase(5, null, 1, 35)).toBe(5);
  });

  it('reads the typed draft, clamped to the bounds', () => {
    expect(compactStepperBase(5, '1', 1, 35)).toBe(1);
    expect(compactStepperBase(5, ' 12 ', 1, 35)).toBe(12);
    expect(compactStepperBase(5, '900', 1, 35)).toBe(35);
    expect(compactStepperBase(5, '0', 1, 35)).toBe(1);
  });

  it('falls back to the committed value for a draft that is not a number', () => {
    expect(compactStepperBase(5, '', 1, 35)).toBe(5);
    expect(compactStepperBase(5, 'abc', 1, 35)).toBe(5);
    expect(compactStepperBase(5, '-', 1, 35)).toBe(5);
  });
});

import { compactStepperNext } from '../counterStepperMath';

describe('compact stepper — counter kinds', () => {
  it('continuous steps 0.1 and never drifts', () => {
    expect(compactStepperNext(6.1, null, 1, 0.1, 26.2, 'continuous')).toBe(6.2);
    expect(compactStepperNext(0.2, null, -1, 0.1, 26.2, 'continuous')).toBe(0.1);
    expect(compactStepperNext(0.1, null, -1, 0.1, 26.2, 'continuous')).toBe(0.1);
  });
  it('duration steps one minute', () => {
    expect(compactStepperNext(630, null, 1, 1, 630, 'duration')).toBe(630);
    expect(compactStepperNext(630, null, -1, 1, 630, 'duration')).toBe(629);
  });
  it('a typed draft parses at the kind before stepping', () => {
    expect(compactStepperBase(5, '10h 30m', 1, 700, 'duration')).toBe(630);
    expect(compactStepperBase(5, '6,15', 0.1, 26.2, 'continuous')).toBe(6.15);
    expect(compactStepperNext(5, '6,15', 1, 0.1, 26.2, 'continuous')).toBe(6.25);
  });
  it('discrete behaviour is unchanged', () => {
    expect(compactStepperBase(6, '1.5', 1, 35)).toBe(6);
    expect(compactStepperNext(6, null, 1, 1, 35)).toBe(7);
  });
  it('renders continuous / duration values at the kind', () => {
    const c = render({ value: 3.8, min: 0.1, max: 26.2, onChange: () => {}, size: 'compact', kind: 'continuous' });
    expect(c).toContain('inputMode="decimal"');
    expect(c).toContain('value="3.8"');
    const d = render({ value: 630, min: 1, max: 630, onChange: () => {}, size: 'compact', kind: 'duration' });
    expect(d).toContain('value="10h 30m"');
  });
});
