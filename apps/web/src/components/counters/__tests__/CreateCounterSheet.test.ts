import { expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { MemoryRouter } from 'react-router-dom';
import type { Task } from '@oybc/shared';
import { CreateCounterSheet } from '../CreateCounterSheet';
import { inputTag } from './inputTag';

const renderSheet = (props: Partial<React.ComponentProps<typeof CreateCounterSheet>> = {}): string =>
  renderToStaticMarkup(
    React.createElement(MemoryRouter, null,
      React.createElement(CreateCounterSheet, { open: true, onClose: () => {}, tasks: [], userId: 'u1', onCreated: () => {}, ...props })),
  );

it('field order: Name · Kind · noun · verb · Singular · Plural · Defaults · Start from; no helper sentences, no preview card', () => {
  const html = renderSheet();
  const order = ['>Name<', 'aria-label="Kind"', 'What are you counting?', '>Task verb<', 'Singular title', 'Plural title', '>Defaults<', 'Start from (optional)'];
  const idx = order.map((s) => html.indexOf(s));
  for (const i of idx) expect(i).toBeGreaterThan(-1);
  expect([...idx].sort((a, b) => a - b)).toEqual(idx);
  for (const s of ['A plural noun', 'Used in task titles', 'Already partway', 'link up automatically', 'All-time', 'placeholder="Do"']) expect(html).not.toContain(s);
  expect(html).toContain('placeholder="push-ups"');
  expect(html).toContain('placeholder="Read"');
  // Nothing typed: no validation copy yet, the primary disabled, the Defaults cells empty.
  expect(html).not.toContain("Enter what you're counting.");
  expect(html).not.toContain('Enter a verb.');
  expect(html).toMatch(/<button[^>]*disabled[^>]*>Create counter<\/button>/);
  expect(inputTag(html, 'aria-label="Daily default"')).toContain('value=""');
  expect(inputTag(html, 'aria-label="Yearly default"')).toContain('value=""');
  // The Name field shows the (empty) derived name dimmed.
  expect(inputTag(html, 'id="create-counter-name"')).toContain('data-dim="true"');
});

const editRoot = {
  id: 'root', userId: 'u1', title: 'Books', type: 'counting', action: 'Read', unit: 'books',
  isCounter: true, countKind: 'discrete', currentCount: 12, isCompleted: false, totalCompletions: 0,
  totalInstances: 0, createdAt: '', updatedAt: '', version: 1, isDeleted: false,
  counterName: 'Books', titleTemplateSingular: 'Read #N book', timeframeGoals: { weekly: 2 },
} as unknown as Task;

it('edit mode: stored settings solid, derived ones dimmed, no Start from, Save', () => {
  const html = renderSheet({ root: editRoot });
  expect(html).toContain('aria-label="Edit counter"');
  expect(html).toContain('>Edit counter</h3>');
  expect(inputTag(html, 'id="create-counter-noun"')).toContain('value="books"');
  expect(inputTag(html, 'id="create-counter-verb"')).toContain('value="Read"');
  // Name + singular are stored → solid (no data-dim); plural derived → dimmed.
  const name = inputTag(html, 'id="create-counter-name"');
  expect(name).toContain('value="Books"');
  expect(name).not.toContain('data-dim');
  expect(inputTag(html, 'id="create-counter-singular"')).toContain('value="Read #N book"');
  expect(inputTag(html, 'id="create-counter-singular"')).not.toContain('data-dim');
  const plural = inputTag(html, 'id="create-counter-plural"');
  expect(plural).toContain('value="Read #N books"');
  expect(plural).toContain('data-dim="true"');
  // Value rows render the examples: singular at 1, plural at 12.
  expect(html).toContain('>Read 1 book<');
  expect(html).toContain('>Read 12 books<');
  // Weekly 2 is set (solid); Daily derives 1, Monthly 9, Yearly 105 (dimmed).
  expect(inputTag(html, 'aria-label="Weekly default"')).toContain('value="2"');
  expect(inputTag(html, 'aria-label="Daily default"')).toContain('value="1"');
  expect(inputTag(html, 'aria-label="Monthly default"')).toContain('value="9"');
  expect(inputTag(html, 'aria-label="Yearly default"')).toContain('value="105"');
  for (const s of ['Start from', 'Description', 'Simple', 'Compound', 'Create counter', 'New counter']) expect(html).not.toContain(s);
  expect(html).toContain('>Save</button>');
  expect(html).not.toMatch(/<button[^>]*disabled[^>]*>Save<\/button>/);
});
