import { describe, expect, it, vi } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { OperatorType, TaskType, type Task } from '@oybc/shared';

vi.mock('../../../firebase/config', () => ({ auth: {}, firestore: {} }));

import { TaskEditSheet } from '../TaskEditSheet';

/**
 * TaskEditSheet's compound mode, as far as a static render can see it:
 * effects don't run under `renderToStaticMarkup`, so the sheet is pinned in
 * its "sub-tasks still loading" state — the editor section is present, the
 * stale "edited from the board-creation wizard" hint is gone, and Save is
 * disabled until the structure has loaded. The loaded/edited/saved path is
 * driven in a real browser by `e2e/task-detail-compound-edit.spec.ts`.
 */

const NOW = '2026-09-24T00:00:00.000Z';

function makeTask(over: Partial<Task>): Task {
  return {
    id: 't-1',
    userId: 'user-1',
    title: 'Morning routine',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function render(task: Task): string {
  return renderToStaticMarkup(
    React.createElement(TaskEditSheet, { task, onSubmit: async () => {}, onCancel: () => {} }),
  );
}

function saveButton(html: string): string {
  return html.match(/<button[^>]*>Save changes<\/button>/)?.[0] ?? '';
}

describe('TaskEditSheet — compound mode', () => {
  const compound = makeTask({ type: TaskType.COMPOUND, operator: OperatorType.AND });

  it('shows the sub-tasks & rule section in its loading state', () => {
    const html = render(compound);
    expect(html).toContain('Sub-tasks &amp; rule');
    expect(html).toContain('Loading sub-tasks…');
  });

  it('no longer says compound sub-tasks are wizard-only', () => {
    expect(render(compound)).not.toContain('board-creation wizard');
  });

  it('keeps Save disabled until the sub-tasks have loaded', () => {
    const btn = saveButton(render(compound));
    expect(btn).not.toBe('');
    expect(btn).toContain('disabled');
  });

  it('leaves a non-compound task without the compound section and Save enabled', () => {
    const html = render(makeTask({ title: 'Read' }));
    expect(html).not.toContain('Sub-tasks &amp; rule');
    const btn = saveButton(html);
    expect(btn).not.toBe('');
    expect(btn).not.toContain('disabled');
  });
});
