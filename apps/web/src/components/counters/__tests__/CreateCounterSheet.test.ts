import { expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { MemoryRouter } from 'react-router-dom';
import { CreateCounterSheet } from '../CreateCounterSheet';

const renderSheet = (): string =>
  renderToStaticMarkup(
    React.createElement(MemoryRouter, null,
      React.createElement(CreateCounterSheet, { open: true, onClose: () => {}, tasks: [], userId: 'u1', onCreated: () => {} })),
  );

it('Kind is the first field and no helper sentence renders (#548 69-76)', () => {
  const html = renderSheet();
  expect(html.indexOf('aria-label="Kind"')).toBeLessThan(html.indexOf('What are you counting?'));
  for (const s of ['A plural noun', 'Used in task titles', 'Already partway', 'link up automatically']) expect(html).not.toContain(s);
});
