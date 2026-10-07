import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { KindPicker } from '../KindPicker';
import { KindTag } from '../KindTag';

const strip = (h: string) => h.replace(/_([A-Za-z][A-Za-z0-9]*)_[0-9a-f]{6}/g, '$1');
const pick = (props: Parameters<typeof KindPicker>[0]) => strip(renderToStaticMarkup(React.createElement(KindPicker, props)));

describe('KindPicker', () => {
  it('create: three live segments in order, labelled Kind', () => {
    const html = pick({ value: 'continuous', lock: 'none', onChange: () => {} });
    expect(html).toContain('aria-label="Kind"');
    expect(html.indexOf('Discrete')).toBeLessThan(html.indexOf('Continuous'));
    expect(html.indexOf('Continuous')).toBeLessThan(html.indexOf('Duration'));
    expect(html).not.toContain('aria-disabled');
  });
  it('existing continuous: duration locked out with a glyph', () => {
    const html = pick({ value: 'continuous', lock: 'duration', onChange: () => {} });
    expect(html.match(/aria-disabled="true"/g)).toHaveLength(1);
    expect(html.match(/lockGlyph/g)).toHaveLength(1);
  });
  it('existing duration: every segment locked, glyph on the selected one only', () => {
    const html = pick({ value: 'duration', lock: 'all', onChange: () => {} });
    expect(html.match(/aria-disabled="true"/g)).toHaveLength(3);
    expect(html.match(/lockGlyph/g)).toHaveLength(1);
  });
  it('never says Amount', () => {
    expect(pick({ value: 'discrete', lock: 'none', onChange: () => {} })).not.toContain('Amount');
  });
});

describe('KindTag', () => {
  it('kind + counter name + all-time total', () => {
    const html = strip(renderToStaticMarkup(React.createElement(KindTag, { kind: 'continuous', counterName: 'Miles', lifetime: 148.6 })));
    expect(html).toContain('Continuous');
    expect(html).toContain('Miles · 148.6 all-time');
  });
  it('kind only', () => {
    const html = strip(renderToStaticMarkup(React.createElement(KindTag, { kind: 'duration' })));
    expect(html).toContain('Duration');
    expect(html).not.toContain('all-time');
  });
});
