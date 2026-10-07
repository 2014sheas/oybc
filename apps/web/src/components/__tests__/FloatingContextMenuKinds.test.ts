import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { FloatingContextMenu } from '../InteractiveTaskSquare';

const noop = () => {};
const menu = (sq: object, amountActions?: object) =>
  renderToStaticMarkup(React.createElement(FloatingContextMenu, {
    sq: sq as never, state: { isCompleted: false, currentCount: 12.4, completedStepIds: new Set<string>() }, position: { x: 0, y: 0 },
    onClose: noop, onIncrementCount: noop, onDecrementCount: noop, onResetCount: noop, onViewDetails: noop,
    amountActions: amountActions as never,
  }));

describe('FloatingContextMenu — counter kinds', () => {
  it('continuous: + Add {last} unit / # Custom amount… / − Remove {last} unit', () => {
    const html = menu({ id: 's', title: 'Run', type: 'counting', action: 'Run', maxCount: 26.2, unit: 'mi', countKind: 'continuous' },
      { kind: 'continuous', amount: 3.1, unit: 'mi', onAdd: noop, onRemove: noop, onOpenCustom: noop, removeDisabled: false });
    expect(html).toContain('+ Add 3.1 mi');
    expect(html).toContain('# Custom amount…');
    expect(html).toContain('− Remove 3.1 mi');
  });
  it('duration has no unit', () => {
    const html = menu({ id: 's', title: 'Practice', type: 'counting', action: 'Practice', maxCount: 630, unit: '', countKind: 'duration' },
      { kind: 'duration', amount: 90, unit: '', onAdd: noop, onRemove: noop, onOpenCustom: noop, removeDisabled: false });
    expect(html).toContain('+ Add 1h 30m');
  });
  it('a discrete standalone square keeps today\'s items', () => {
    const html = menu({ id: 's', title: 'Push', type: 'counting', action: 'Do', maxCount: 10, unit: 'reps' });
    expect(html).toContain('+ Add Do (+1)');
    expect(html).toContain('− Remove Do (−1)');
  });
});
