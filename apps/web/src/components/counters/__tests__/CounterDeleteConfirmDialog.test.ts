import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import {
  CounterDeleteConfirmDialog,
  type CounterDeleteConfirmDialogProps,
} from '../CounterDeleteConfirmDialog';

/**
 * §Member rules (B3, RC12) — deleting a shared counter UNLINKS its
 * hand-made members (they keep their counts) but RETIRES its per-window
 * derived ones outright. The confirm sheet says so on its own line, so the
 * "will be unlinked and keep their current counts" sentence is never read
 * as covering squares that are about to disappear.
 *
 * Rendered with `react-dom/server` — no jsdom/RTL harness in this repo (see
 * `components/wizard/__tests__/BoardSetupForm.test.ts`).
 */

function render(over: Partial<CounterDeleteConfirmDialogProps> = {}): string {
  const props: CounterDeleteConfirmDialogProps = {
    counterName: 'Miles run',
    memberCount: 0,
    derivedWindowCounterCount: 0,
    members: [],
    busy: false,
    onConfirm: () => {},
    onCancel: () => {},
    ...over,
  };
  return renderToStaticMarkup(React.createElement(CounterDeleteConfirmDialog, props));
}

describe('CounterDeleteConfirmDialog — derived-counter line (B3 RC12)', () => {
  it('says nothing about board counters when there are none', () => {
    const html = render({
      memberCount: 2,
      members: [
        { id: 'a', title: 'Morning run', boardName: 'This week' },
        { id: 'b', title: 'Evening run', boardName: null },
      ],
    });

    expect(html).toContain('2 linked tasks');
    expect(html).not.toContain('will be removed.');
  });

  it('uses the singular for exactly one board counter', () => {
    const html = render({ derivedWindowCounterCount: 1 });
    expect(html).toContain('1 board counter made from this one will be removed.');
  });

  it('uses the plural for more than one', () => {
    const html = render({
      memberCount: 1,
      members: [{ id: 'a', title: 'Morning run', boardName: 'This week' }],
      derivedWindowCounterCount: 4,
    });
    expect(html).toContain('4 board counters made from this one will be removed.');
  });

  it('shows the line even when the counter has no unlinkable members left', () => {
    // Every placement came from a wizard-built board: `memberCount` is 0, so
    // the members section never renders — but three squares are still going.
    const html = render({ memberCount: 0, derivedWindowCounterCount: 3 });
    expect(html).not.toContain('will be unlinked');
    expect(html).toContain('3 board counters made from this one will be removed.');
  });
});
