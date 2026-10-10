import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { derivedTimeframeGoals } from '@oybc/shared';
import { DefaultsRow } from '../DefaultsRow';
import { defaultsCellIsSet, defaultsRowGoals, defaultsRowInvalidCells } from '../defaultsRowModel';
import { inputTag } from './inputTag';

const html = (p: Partial<React.ComponentProps<typeof DefaultsRow>>): string =>
  renderToStaticMarkup(
    React.createElement(DefaultsRow, {
      kind: 'discrete', unit: 'books', entered: {}, onChange: () => {},
      derived: { daily: null, weekly: null, monthly: null, yearly: null }, idPrefix: 'd', ...p,
    }),
  );

describe('DefaultsRow', () => {
  it('nothing set: four empty cells with the unit suffix, no dim text', () => {
    const h = html({});
    for (const t of ['Daily', 'Weekly', 'Monthly', 'Yearly']) expect(inputTag(h, `aria-label="${t} default"`)).toContain('value=""');
    expect(h).not.toContain('data-dim');
    expect((h.match(/>books</g) ?? []).length).toBe(4);
  });

  it('weekly set: solid; the others derived (× 1/7/30/365, ceil) and dimmed', () => {
    const entered = { weekly: '2' };
    const derived = derivedTimeframeGoals({ countKind: 'discrete', timeframeGoals: defaultsRowGoals(entered, 'discrete') });
    const h = html({ entered, derived });
    expect(inputTag(h, 'aria-label="Weekly default"')).toContain('value="2"');
    expect(inputTag(h, 'aria-label="Daily default"')).toContain('value="1"');
    expect(inputTag(h, 'aria-label="Monthly default"')).toContain('value="9"');
    expect(inputTag(h, 'aria-label="Yearly default"')).toContain('value="105"');
    expect((h.match(/data-dim="true"/g) ?? []).length).toBe(3);
  });

  it('duration: h / m fields, no unit suffix, derived shown as hours + minutes', () => {
    const entered = { weekly: '5h' };
    const derived = derivedTimeframeGoals({ countKind: 'duration', timeframeGoals: defaultsRowGoals(entered, 'duration') });
    const h = html({ kind: 'duration', unit: 'piano', entered, derived });
    expect(h).toContain('aria-label="Weekly default hours"');
    expect(h).not.toContain('>piano<');
    // 300 min / 7 → 43 min → 0h 43m.
    expect(inputTag(h, 'aria-label="Daily default hours"')).toContain('value="0"');
    expect(inputTag(h, 'aria-label="Daily default minutes"')).toContain('value="43"');
  });

  it('an unparseable entry is set + invalid; the goals helpers skip it', () => {
    const entered = { weekly: '2', monthly: 'x' };
    expect(defaultsCellIsSet(entered, 'monthly')).toBe(true);
    expect(defaultsRowInvalidCells(entered, 'discrete')).toEqual(['monthly']);
    expect(defaultsRowGoals(entered, 'discrete')).toEqual({ weekly: 2 });
    const h = html({ entered, derived: { daily: null, weekly: null, monthly: null, yearly: null } });
    expect(inputTag(h, 'aria-label="Monthly default"')).toContain('aria-invalid="true"');
  });
});
