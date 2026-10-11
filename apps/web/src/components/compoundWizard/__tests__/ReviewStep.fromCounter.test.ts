import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { OperatorType } from '@oybc/shared';
import { ReviewStep } from '../ReviewStep';

function render(counterName?: string): string {
  return renderToStaticMarkup(
    React.createElement(ReviewStep, {
      title: 'Book club night', operator: OperatorType.AND, threshold: 1, subtasks: [],
      allTasks: [], allCompoundTasks: [], isSubmitting: false, errorMessage: null, counterName,
      onBack: () => {}, onCreate: () => {},
    }),
  );
}

describe('ReviewStep — from-counter mode (unit-tasks handoff B4)', () => {
  it('adds a Counter row holding the dense UnitTag and the "No subtasks yet" line', () => {
    const html = render('Books');
    expect(html).toContain('<dt>Counter</dt>');
    expect(html).toContain('aria-label="Unit task of Books"');
    expect(html).toContain('tagDense');
    expect(html).toContain('No subtasks yet');
    expect(html).toContain('0 subtasks');
  });

  it('shows no Counter row outside from-counter mode', () => {
    const html = render();
    expect(html).not.toContain('<dt>Counter</dt>');
    expect(html).not.toContain('Unit task of');
  });
});
