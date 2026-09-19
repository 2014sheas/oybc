import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { WizardEditModeNote } from '../WizardEditModeNote';

/**
 * Board Sources P4 (locked decision, frame 5a) — editing an existing
 * repeating board changes what the NEXT board is built from, never the one
 * already on the Boards tab. The wizard says so on every step while editing,
 * mirroring iOS `BoardWizardView.swift`.
 *
 * Its own component precisely so this gate + copy can be asserted without
 * mounting `BoardWizardPage` (which needs a router and an auth context).
 */

function render(editingTemplateId: string | null): string {
  return renderToStaticMarkup(
    React.createElement(WizardEditModeNote, { editingTemplateId }),
  );
}

describe('WizardEditModeNote (B3)', () => {
  it('shows the note while editing a repeating board', () => {
    expect(render('tmpl-1')).toContain('Changes apply from the next board.');
  });

  it('renders nothing for a fresh session', () => {
    expect(render(null)).toBe('');
  });
});
