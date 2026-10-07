import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { KindSwitchConfirmDialog } from '../KindSwitchConfirmDialog';

/**
 * The Continuous → Discrete confirm renders the handoff copy, with Cancel as
 * the modal's safe default. Rendered with `react-dom/server` (no RTL harness
 * in this repo).
 */
describe('KindSwitchConfirmDialog', () => {
  it('renders the heading, both before → after rows, the body and the two actions', () => {
    const html = renderToStaticMarkup(
      React.createElement(KindSwitchConfirmDialog, {
        preview: {
          from: 'continuous', to: 'discrete', titleBefore: 'Run 26.2 miles', titleAfter: 'Run 26 miles',
          loggedBefore: 12.75, loggedAfter: 13, linkedCount: 2,
        },
        onCancel: () => {},
        onConfirm: () => {},
      }),
    );
    expect(html).toContain('role="alertdialog"');
    expect(html).toContain('Switch to Discrete?');
    expect(html).toContain('Run 26.2 miles');
    expect(html).toContain('Run 26 miles');
    expect(html).toContain('12.75 logged');
    expect(html).toContain('13 logged');
    expect(html).toContain('Switching back restores the exact values. Follows on 2 linked squares.');
    expect(html).toMatch(/data-modal-cancel[^>]*>Cancel</);
    expect(html).toContain('>Switch</button>');
  });
});
