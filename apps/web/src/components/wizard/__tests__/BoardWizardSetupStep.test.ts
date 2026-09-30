import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { CenterSquareType, Timeframe } from '@oybc/shared';
import { BoardWizardSetupStep } from '../BoardWizardSetupStep';
import type { BoardWizardController } from '../../../pages/createHub/useBoardWizard';

/**
 * Profile reorg PR3 — Delete left the Board-settings roster row and now
 * lives in the editor: the Setup step (where the editor lands) renders a
 * "Delete repeating board" danger row ONLY while editing an existing
 * repeating board AND the parent wired the handler. A fresh session — or a
 * parent that didn't wire it — renders no such row.
 *
 * Rendered with `react-dom/server` — no jsdom/RTL harness in this repo (see
 * `BoardSetupForm.test.ts`), so this pins presence/absence, not the click.
 */

function makeController(overrides: Partial<BoardWizardController> = {}): BoardWizardController {
  return {
    name: 'Weekend Reset',
    setName: () => {},
    size: 3,
    setSize: () => {},
    timeframe: Timeframe.WEEKLY,
    setTimeframe: () => {},
    customStartDate: '',
    setCustomStartDate: () => {},
    customEndDate: '',
    setCustomEndDate: () => {},
    centerType: CenterSquareType.FREE,
    setCenterType: () => {},
    isRecurring: true,
    isCore: false,
    weekStartDay: 'monday',
    isStep1Valid: true,
    step1ValidationMessage: null,
    editingTemplateId: null,
    ...overrides,
  } as unknown as BoardWizardController;
}

function render(
  controller: BoardWizardController,
  onDeleteRepeatingBoard?: () => void,
): string {
  return renderToStaticMarkup(
    React.createElement(BoardWizardSetupStep, {
      controller,
      onCancel: () => {},
      onNext: () => {},
      onDeleteRepeatingBoard,
    }),
  );
}

describe('BoardWizardSetupStep — "Delete repeating board" danger row (Profile reorg PR3)', () => {
  it('renders the danger row while editing an existing repeating board with the handler wired', () => {
    const html = render(makeController({ editingTemplateId: 'tmpl-1' }), () => {});
    expect(html).toContain('Delete repeating board');
  });

  it('renders no danger row for a fresh session, even with a handler', () => {
    const html = render(makeController({ editingTemplateId: null }), () => {});
    expect(html).not.toContain('Delete repeating board');
  });

  it('renders no danger row when the parent did not wire the handler', () => {
    const html = render(makeController({ editingTemplateId: 'tmpl-1' }));
    expect(html).not.toContain('Delete repeating board');
  });

  it('keeps the Cancel / Next footer either way', () => {
    const html = render(makeController({ editingTemplateId: 'tmpl-1' }), () => {});
    expect(html).toContain('>Cancel</button>');
    expect(html).toContain('Next ›');
  });
});
