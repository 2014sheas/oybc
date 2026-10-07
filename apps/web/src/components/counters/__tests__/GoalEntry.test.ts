import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { GoalEntry } from '../GoalEntry';
import { goalEntryInputMode } from '../goalEntryModel';

const html = (p: Parameters<typeof GoalEntry>[0]) => renderToStaticMarkup(React.createElement(GoalEntry, p));

describe('GoalEntry', () => {
  it('discrete: one numeric text field', () => {
    const h = html({ kind: 'discrete', value: '300', onChange: () => {}, 'aria-label': 'Goal' });
    expect(h).toContain('inputMode="numeric"');
    expect(h).toContain('type="text"');
    expect(h).toContain('value="300"');
  });
  it('continuous: decimal keypad, unit suffix', () => {
    const h = html({ kind: 'continuous', value: '26.2', onChange: () => {}, suffix: 'mi', 'aria-label': 'Goal' });
    expect(h).toContain('inputMode="decimal"');
    expect(h).toContain('>mi<');
  });
  it('duration: two fields seeded from the value, labelled h and m', () => {
    const h = html({ kind: 'duration', value: '10h 30m', onChange: () => {}, 'aria-label': 'Goal' });
    expect(h).toContain('aria-label="Goal hours"');
    expect(h).toContain('aria-label="Goal minutes"');
    expect(h).toContain('value="10"');
    expect(h).toContain('value="30"');
    expect(h).not.toContain('>mi<');
  });
  it('input modes per kind', () => {
    expect(goalEntryInputMode('discrete')).toBe('numeric');
    expect(goalEntryInputMode('continuous')).toBe('decimal');
    expect(goalEntryInputMode('duration')).toBe('numeric');
  });
});
