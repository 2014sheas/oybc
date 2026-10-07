import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { DetailModal } from '../InteractiveTaskSquare';
import type { QuickAmountProps } from '../interactiveTaskSquareUtils';

const noop = () => {};
const base = { onClose: noop, onToggleComplete: noop, onIncrementCount: noop, onDecrementCount: noop };
const quick = (o: Partial<QuickAmountProps>): QuickAmountProps => ({
  kind: 'continuous', options: [{ value: 6.6, label: '6.6' }, { value: 13.1, label: '13.1' }, { value: 26.2, label: '26.2' }, { value: null, label: '#' }],
  selected: 3.1, isCustomActive: true, customOpen: false, customDraft: '', amountText: '3.1', unit: 'mi', addLabel: '+ 3.1 mi',
  busy: false, removeDisabled: false, onSelectChip: noop, onOpenCustom: noop, onCustomDraftChange: noop, onConfirmCustom: noop,
  onAmountTextChange: noop, onAdd: noop, onRemove: noop, ...o,
});
const render = (sq: object, cur: number, q?: QuickAmountProps) =>
  renderToStaticMarkup(React.createElement(DetailModal, { ...base, sq: sq as never, state: { isCompleted: false, currentCount: cur, completedStepIds: new Set<string>() }, quickAmount: q }));

describe('DetailModal — counter kinds', () => {
  it('continuous: chips with #3.1 selected, pinned decimal field, + {amount} {unit}, no OK', () => {
    const html = render({ id: 's', title: 'Run 26.2 mi', type: 'counting', action: 'Run', maxCount: 26.2, unit: 'mi', countKind: 'continuous' }, 12.4, quick({}));
    expect(html).toContain('#3.1');
    expect(html).toContain('inputMode="decimal"');
    expect(html).toContain('+ 3.1 mi');
    expect(html).toContain('12.4/26.2');
    expect(html).not.toContain('>OK<');
  });
  it('duration: h / m fields, no unit in the meta line', () => {
    const html = render({ id: 's', title: 'Practice 10h 30m', type: 'counting', action: 'Practice', maxCount: 630, unit: '', countKind: 'duration' }, 270,
      quick({ kind: 'duration', amountText: '2h 38m', unit: '', addLabel: '+ 2h 38m', selected: 158, isCustomActive: false,
        options: [{ value: 158, label: '2h 38m' }, { value: 315, label: '5h 15m' }, { value: 630, label: '10h 30m' }, { value: null, label: '#' }] }));
    expect(html).toContain('aria-label="Log amount hours"');
    expect(html).toContain('4h 30m/10h 30m');
    expect(html).toContain('Practice · 10h 30m');
  });
  it('overshoot paints the modal bar gold (handoff LogSheet web frame)', () => {
    const html = render({ id: 's', title: 'Run 26.2 mi', type: 'counting', action: 'Run', maxCount: 26.2, unit: 'mi', countKind: 'continuous' }, 28.4, quick({}));
    expect(html).toMatch(/modalProgressFillOver/);
  });
  it('a linked discrete square renders the plain stepper without the removed captions (#548 5/7/8)', () => {
    const html = render({ id: 's', title: 'Push', type: 'counting', action: 'Do', maxCount: 10, unit: 'reps', sharedCounterId: 'r' }, 3);
    expect(html).toContain('3 / 10');
    expect(html).not.toContain('also counts on');
    expect(html).not.toContain('cannot be decremented');
    expect(html).not.toContain('Tap: +1');
  });
});
