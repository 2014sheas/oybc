import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import {
  RemoveSourceConfirmDialog,
  type RemoveSourceConfirmDialogProps,
} from '../RemoveSourceConfirmDialog';

/**
 * The wizard's remove-source confirm (owner ruling 2026-09-19): it names
 * the pulled source, names what the removal costs, offers both choices, and
 * announces itself as an alert dialog. The repeating-board line only shows
 * while a repeating board is under edit.
 *
 * Rendered with `react-dom/server` — no jsdom/RTL harness in this repo (see
 * `components/counters/__tests__/CounterDeleteConfirmDialog.test.ts`), so
 * the focus/Escape behaviour (both effects) is not covered here.
 */

function render(over: Partial<RemoveSourceConfirmDialogProps> = {}): string {
  const props: RemoveSourceConfirmDialogProps = {
    displayName: 'Morning Kickstart',
    lossSentence: "You'll lose 1 exclusion.",
    editingRepeatingBoard: false,
    onConfirm: () => {},
    onCancel: () => {},
    ...over,
  };
  return renderToStaticMarkup(React.createElement(RemoveSourceConfirmDialog, props));
}

describe('RemoveSourceConfirmDialog', () => {
  it('names the source in the heading', () => {
    expect(render()).toContain('Remove &quot;Morning Kickstart&quot;?');
  });

  it('shows the loss sentence it was handed', () => {
    expect(render({ lossSentence: "You'll lose 3 exclusions and 2 member rules." })).toContain(
      'You&#x27;ll lose 3 exclusions and 2 member rules.',
    );
  });

  it('offers Cancel and Remove', () => {
    const html = render();
    expect(html).toContain('>Cancel<');
    expect(html).toContain('>Remove<');
  });

  it('announces itself as an alert dialog with a test hook', () => {
    const html = render();
    expect(html).toContain('role="alertdialog"');
    expect(html).toContain('aria-label="Confirm remove source"');
    expect(html).toContain('data-testid="remove-source-confirm"');
  });

  it('stays silent about the next board for a one-off wizard', () => {
    expect(render()).not.toContain('Changes apply from the next board.');
  });

  it('appends the edit-mode line while a repeating board is under edit', () => {
    expect(render({ editingRepeatingBoard: true })).toContain(
      'Changes apply from the next board.',
    );
  });
});
