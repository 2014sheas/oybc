import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { RisoSegmented } from '../RisoSegmented';

/**
 * `size="compact"` (B3 — the wizard member row's 22pt One square / Split
 * up toggle) must be additive: every existing caller renders exactly what
 * it rendered before, which is what the literal-equality checks below pin.
 * CSS-module class names carry a per-file content hash, so the assertions
 * strip it — the ELEMENT shape is the contract, not the stylesheet's hash.
 */
function render(props: Parameters<typeof RisoSegmented<string>>[0]): string {
  return renderToStaticMarkup(React.createElement(RisoSegmented<string>, props));
}

/** `_name_deadbee` → `name`, so a CSS edit doesn't fail a markup test. */
function stripHash(html: string): string {
  return html.replace(/_([A-Za-z][A-Za-z0-9]*)_[0-9a-f]{6}/g, '$1');
}

const OPTIONS = [
  { value: 'one', label: 'One square' },
  { value: 'split', label: 'Split up' },
];

describe('RisoSegmented', () => {
  it('renders the card variant unchanged', () => {
    const html = stripHash(
      render({ options: OPTIONS, value: 'one', onChange: () => {}, 'aria-label': 'Squares' }),
    );
    expect(html).toBe(
      '<div class="card" role="group" aria-label="Squares">' +
        '<button type="button" class="seg on" aria-pressed="true">One square</button>' +
        '<button type="button" class="seg" aria-pressed="false">Split up</button>' +
        '</div>',
    );
  });

  it('renders the pill variant unchanged at the default size', () => {
    const html = stripHash(
      render({
        options: OPTIONS,
        value: 'split',
        onChange: () => {},
        variant: 'pill',
        'aria-label': 'Squares',
      }),
    );
    expect(html).toBe(
      '<div class="pill" role="group" aria-label="Squares">' +
        '<button type="button" class="seg" aria-pressed="false">One square</button>' +
        '<button type="button" class="seg on" aria-pressed="true">Split up</button>' +
        '</div>',
    );
  });

  it('adds only the compact class when sized down', () => {
    const html = stripHash(
      render({
        options: OPTIONS,
        value: 'one',
        onChange: () => {},
        variant: 'pill',
        size: 'compact',
        'aria-label': 'Squares',
      }),
    );
    expect(html).toBe(
      '<div class="pill compact" role="group" aria-label="Squares">' +
        '<button type="button" class="seg on" aria-pressed="true">One square</button>' +
        '<button type="button" class="seg" aria-pressed="false">Split up</button>' +
        '</div>',
    );
  });
});
