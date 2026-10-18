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
    members: [],
    busy: false,
    onConfirm: () => {},
    onCancel: () => {},
    ...over,
  };
  return renderToStaticMarkup(React.createElement(CounterDeleteConfirmDialog, props));
}

describe('CounterDeleteConfirmDialog — members', () => {
  it('lists the linked tasks that will be unlinked', () => {
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
});

describe('CounterDeleteConfirmDialog — unit-task line', () => {
  it('says the unit tasks are kept as ordinary tasks, singular and plural, hidden at 0', () => {
    expect(render({ unitTaskCount: 6 })).toContain('Its 6 unit tasks are kept as ordinary tasks.');
    expect(render({ unitTaskCount: 1 })).toContain('Its 1 unit task is kept as an ordinary task.');
    expect(render({ unitTaskCount: 0 })).not.toContain('unit task');
    expect(render({})).not.toContain('unit task');
  });
});
