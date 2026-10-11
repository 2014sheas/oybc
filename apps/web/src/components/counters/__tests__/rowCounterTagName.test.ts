import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { TaskType, type Task } from '@oybc/shared';
import { rowCounterTagName, taskSearchMatchesWithCounter } from '../rowCounterTagName';
import { selectLibraryPickerResults, selectQuickAddMatches } from '../../pools/poolEditSheetSelectors';
import { matchesSearch } from '../../../pages/tasks/useTasksFilters';
import { TaskRow } from '../../../pages/tasks/TaskRow';
import { buildTaskSubtitle, renderTaskRow } from '../../wizard/TaskRow';

const NOW = '2026-09-18T10:00:00.000Z';
const task = (o: Partial<Task>): Task =>
  ({
    id: 'x', userId: 'u', title: 'x', type: TaskType.NORMAL, isCompleted: false, totalCompletions: 0,
    totalInstances: 0, createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false, ...o,
  }) as Task;

const root = task({ id: 'root', type: TaskType.COUNTING, title: 'Read 2 books', action: 'Read', unit: 'books', maxCount: 2 });
const copy = task({ id: 'copy', type: TaskType.COUNTING, title: 'Weekly reading', action: 'Read', unit: 'books', maxCount: 2, sharedCounterId: 'root' });
const unit = task({ id: 'unit', title: 'Finish Dune', countsTowardCounterId: 'root' });
const plain = task({ id: 'plain', title: 'Walk the dog' });
const pool = [root, copy, unit, plain];

describe('rowCounterTagName', () => {
  it('names the root for a unit task and a linked copy', () => {
    expect(rowCounterTagName(unit, pool)).toBe('Read books');
    expect(rowCounterTagName(copy, pool)).toBe('Read books');
  });
  it('resolves through a Map or a Record as well as a list', () => {
    expect(rowCounterTagName(unit, new Map(pool.map((t) => [t.id, t])))).toBe('Read books');
    expect(rowCounterTagName(unit, Object.fromEntries(pool.map((t) => [t.id, t])))).toBe('Read books');
  });
  it('is null for anything flagged isCounter, even with a link id', () => {
    expect(rowCounterTagName({ ...unit, isCounter: true }, pool)).toBeNull();
  });
  it('is null for a counter root, a plain task and an unresolvable root', () => {
    expect(rowCounterTagName(root, pool)).toBeNull();
    expect(rowCounterTagName(plain, pool)).toBeNull();
    expect(rowCounterTagName(unit, [plain])).toBeNull();
  });
});

describe('counter name joins the match set', () => {
  it('a unit task matches its counter name, noun and verb; a plain task does not', () => {
    expect(taskSearchMatchesWithCounter('read books', unit, pool)).toBe(true);
    expect(taskSearchMatchesWithCounter('books', unit, pool)).toBe(true);
    expect(taskSearchMatchesWithCounter('Dune', unit, pool)).toBe(true);
    expect(taskSearchMatchesWithCounter('books', plain, pool)).toBe(false);
  });
  it('narrow: the stored title of the root does not match a unit task', () => {
    expect(taskSearchMatchesWithCounter('read 2', unit, pool)).toBe(false);
  });
  it('Tasks tab matchesSearch threads the pool', () => {
    expect(matchesSearch(unit, 'books', pool)).toBe(true);
    expect(matchesSearch(unit, 'books')).toBe(false);
  });
  it('ranks direct hits ahead of counter-name-only hits, so the cap never drops the counter row', () => {
    const many = Array.from({ length: 6 }, (_, i) => task({ id: `u${i}`, title: `Unit ${i}`, countsTowardCounterId: 'root' }));
    const ids = selectQuickAddMatches([...many, root], new Set(), 'books').map((t) => t.id);
    expect(ids).toHaveLength(4);
    expect(ids[0]).toBe('root');
  });
  it('a goal-less root missing from the browse list still resolves through the lookup', () => {
    const browse = [unit, plain];
    expect(selectQuickAddMatches(browse, new Set(), 'books')).toEqual([]);
    expect(selectQuickAddMatches(browse, new Set(), 'books', pool).map((t) => t.id)).toEqual(['unit']);
  });
  it('quick-add and library picker matchers surface the unit task by counter name', () => {
    expect(selectQuickAddMatches(pool, new Set(), 'books').map((t) => t.id)).toEqual(['root', 'copy', 'unit']);
    expect(selectLibraryPickerResults(pool, new Set(['root']), 'books').map((t) => t.id)).toEqual(['copy', 'unit']);
  });
});

describe('row subtitle composition', () => {
  it('Tasks tab row: the tag precedes the meta text', () => {
    const html = renderToStaticMarkup(
      React.createElement(TaskRow, {
        task: unit, placementCount: 1, activePlacementCount: 1, childCount: 0, onClick: () => {},
        counterTagName: rowCounterTagName(unit, pool),
      }),
    );
    expect(html).toContain('aria-label="Unit task of Read books"');
    expect(html.indexOf('Unit task of')).toBeLessThan(html.indexOf('On 1 active board'));
  });
  it('Tasks tab row: no tag without a name', () => {
    const html = renderToStaticMarkup(
      React.createElement(TaskRow, { task: plain, placementCount: 0, activePlacementCount: 0, childCount: 0, onClick: () => {} }),
    );
    expect(html).not.toContain('Unit task of');
  });
  it('wizard library row: tag first, then the counting subtitle', () => {
    const html = renderToStaticMarkup(
      renderTaskRow({ task: copy, isSelected: false, counterTagName: rowCounterTagName(copy, pool) }),
    );
    expect(html).toContain('Unit task of Read books');
    const text = buildTaskSubtitle(copy);
    expect(text).not.toBe('');
    expect(html.indexOf('Unit task of')).toBeLessThan(html.indexOf(text));
  });
});
