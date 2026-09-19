import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { CounterStepper } from '../CounterStepper';

/**
 * `size="compact"` (B3, docs/BOARD_SOURCES.md §Member rules) adds the
 * wizard member row's 22px target pill WITHOUT disturbing the default
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

  it('disables the compact −/＋ at the bounds', () => {
    const atMin = render({ value: 1, min: 1, max: 35, onChange: () => {}, size: 'compact' });
    expect(atMin).toMatch(/aria-label="Decrease target"[^>]*disabled|disabled[^>]*aria-label="Decrease target"/);

    const atMax = render({ value: 35, min: 1, max: 35, onChange: () => {}, size: 'compact' });
    expect(atMax).toMatch(/aria-label="Increase target"[^>]*disabled|disabled[^>]*aria-label="Increase target"/);
  });
});
