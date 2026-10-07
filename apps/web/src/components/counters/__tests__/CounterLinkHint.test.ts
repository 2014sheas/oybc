import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { CounterLinkHint } from '../CounterLinkHint';

describe('CounterLinkHint (#548 rows 77/78)', () => {
  it('shows the counter and the pill, never a sentence', () => {
    const html = renderToStaticMarkup(React.createElement(CounterLinkHint, { counterName: 'Miles', linked: true, onToggle: () => {} }));
    expect(html).toContain('Miles');
    expect(html).toContain("Don&#x27;t link");
    expect(html).not.toContain('all-time');
    expect(html).not.toContain('keeps its own');
    expect(html).not.toContain('Creates a separate');
  });
});
