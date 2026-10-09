import { expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { MemoryRouter } from 'react-router-dom';
import type { Task } from '@oybc/shared';
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

const editRoot = {
  id: 'root', userId: 'u1', title: 'Run miles', type: 'counting', action: 'Run', unit: 'miles',
  isCounter: true, countKind: 'continuous', currentCount: 12, isCompleted: false, totalCompletions: 0,
  totalInstances: 0, createdAt: '', updatedAt: '', version: 1, isDeleted: false,
} as unknown as Task;

it('edit mode: "Edit counter" with the root prefilled, kind live, no Type / Description / Start from, Save', () => {
  const html = renderToStaticMarkup(
    React.createElement(MemoryRouter, null,
      React.createElement(CreateCounterSheet, { open: true, onClose: () => {}, tasks: [], userId: 'u1', root: editRoot })),
  );
  expect(html).toContain('aria-label="Edit counter"');
  expect(html).toContain('>Edit counter</h3>');
  expect(html).toContain('value="miles"');
  expect(html).toContain('value="Run"');
  expect(html).toContain('aria-pressed="true">Continuous');
  for (const s of ['Start from', 'Description', 'Simple', 'Compound', 'Create counter', 'New counter']) expect(html).not.toContain(s);
  expect(html).toContain('>Save</button>');
});
