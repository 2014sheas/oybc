import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { tapLogChips } from '@oybc/shared';
import { chipKey } from '../chipKey';
import { TapLogChipRow } from '../TapLogChipRow';
import { UndoStrip } from '../UndoStrip';

const noop = () => {};
const row = (props: Partial<React.ComponentProps<typeof TapLogChipRow>>) =>
  renderToStaticMarkup(React.createElement(TapLogChipRow, { chips: tapLogChips('discrete', 20, 12), onChip: noop, ...props }));

describe('TapLogChipRow', () => {
  it('renders one button per chip, rest chip included, Other… last', () => {
    const out = row({});
    expect(out.match(/<button/g)?.length).toBe(5);
    expect(out).toContain('+8 ✓');
    expect(out.lastIndexOf('Other…')).toBeGreaterThan(out.indexOf('+8 ✓'));
  });
  it('disabled keeps every chip rendered', () => {
    const out = row({ disabled: true });
    expect(out.match(/<button[^>]*disabled/g)?.length).toBe(5);
  });
  it('a 4+ character rest label takes the long variant; compact size is a class', () => {
    expect(row({ chips: tapLogChips('duration', 630, 270) })).toMatch(/long/);
    expect(row({ size: 'compact' })).toMatch(/compact/);
  });
});

describe('TapLogChipRow busy handling', () => {
  it('inert (a write in flight, busy look not shown yet) keeps every chip enabled and looking live', () => {
    const out = row({ inert: true });
    expect(out.match(/ disabled=""/g)).toBeNull();
    expect(out.match(/aria-disabled="true"/g)?.length).toBe(5);
  });
  it('disabled (the busy look) really disables every chip', () => {
    expect(row({ disabled: true }).match(/ disabled=""/g)?.length).toBe(5);
  });
});

describe('chipKey', () => {
  it('keeps the rest chip on ONE key as its amount shrinks, so a log never remounts it', () => {
    const at = (count: number) => tapLogChips('discrete', 20, count).filter((c) => c.role === 'rest').map(chipKey);
    expect(at(12)).toEqual(['rest']);
    expect(at(13)).toEqual(['rest']);
  });
  it('is unique within a row and stable across counts', () => {
    const keys = (count: number) => tapLogChips('discrete', 20, count).map(chipKey);
    expect(new Set(keys(12)).size).toBe(keys(12).length);
    expect(keys(12).filter((k) => k !== 'rest')).toEqual(keys(13).filter((k) => k !== 'rest'));
  });
});

describe('TapLogChipRow accessible names', () => {
  it('names each chip by what it logs', () => {
    const out = row({ unit: 'pages' });
    expect(out).toContain('aria-label="Log +10 pages"');
    expect(out).toContain('aria-label="Log the rest, +8 pages"');
    expect(out).toContain('aria-label="Log another amount"');
  });
});

describe('UndoStrip', () => {
  it('compact variant adds its class', () => {
    expect(renderToStaticMarkup(React.createElement(UndoStrip, { text: 'x', onUndo: noop, compact: true }))).toMatch(/compact/);
  });
  it('shows one line and an Undo pill', () => {
    const out = renderToStaticMarkup(React.createElement(UndoStrip, { text: 'Logged +5 pages · Week 42', onUndo: noop }));
    expect(out).toContain('Logged +5 pages · Week 42');
    expect(out).toContain('>Undo<');
    expect(out).toContain('role="status"');
  });
});
