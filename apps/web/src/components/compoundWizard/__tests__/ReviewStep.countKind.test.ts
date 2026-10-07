import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { OperatorType } from '@oybc/shared';
import { ReviewStep } from '../ReviewStep';
import type { InlineSubtaskDraft } from '../compoundSubtaskDraft';

const draft = (o: Partial<InlineSubtaskDraft>): InlineSubtaskDraft => ({
  id: 'd', mode: 'inline', inlineType: 'counting', title: '', action: 'Run', unit: 'miles', maxCountStr: '26.2', steps: [], ...o,
});

function render(subtask: InlineSubtaskDraft): string {
  return renderToStaticMarkup(
    React.createElement(ReviewStep, {
      title: 'Marathon', operator: OperatorType.AND, threshold: 1, subtasks: [subtask],
      allTasks: [], allCompoundTasks: [], isSubmitting: false, errorMessage: null,
      onBack: () => {}, onCreate: () => {},
    }),
  );
}

describe('ReviewStep inline counting chip — counter kinds', () => {
  it('a Continuous sub-task keeps its decimal goal in the title and meta', () => {
    const html = render(draft({ countKind: 'continuous' }));
    expect(html).toContain('Run 26.2 miles');
    expect(html).toContain('>26.2 miles<');
  });

  it('a Duration sub-task shows h/m with no unit', () => {
    const html = render(draft({ action: 'Practice', unit: '', maxCountStr: '1h 30m', countKind: 'duration' }));
    expect(html).toContain('Practice 1h 30m');
    expect(html).toContain('>1h 30m<');
  });

  it('a Discrete sub-task is unchanged', () => {
    const html = render(draft({ action: 'Do', unit: 'push-ups', maxCountStr: '50' }));
    expect(html).toContain('Do 50 push-ups');
    expect(html).toContain('>50 push-ups<');
  });
});
