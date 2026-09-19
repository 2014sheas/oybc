import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { TaskType, varyRangeLabel, type Task, type VaryLevel } from '@oybc/shared';
import { PoolList } from '../PoolList';

/**
 * Hand-added counting rows get the same dice as a pulled member (handoff
 * §2a item 5: "dice (counting only) · 32pt edit button · 28pt ✕"), and
 * its range line sits under the row, left-aligned with the title.
 *
 * A hand-added counter has no source window to pro-rate against, so the
 * range is taken around its own goal — that's what keeps this row's label
 * identical to `varyRangeLabel`'s output rather than a second formatting.
 *
 * Rendered with `react-dom/server` (no jsdom/RTL harness in this repo).
 */

const NOW = '2026-09-18T00:00:00.000Z';

function makeTask(id: string, title: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'user-1',
    title,
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

const RUN = makeTask('t-run', 'Run', {
  type: TaskType.COUNTING,
  action: 'Run',
  unit: 'min',
  maxCount: 20,
});
const BED = makeTask('t-bed', 'Make the bed');

function render(manualTaskVary: Record<string, VaryLevel>, wired = true): string {
  const effectiveTaskMap: Record<string, Task> = { [RUN.id]: RUN, [BED.id]: BED };
  return renderToStaticMarkup(
    React.createElement(PoolList, {
      poolOrder: [RUN.id, BED.id],
      effectiveTaskMap,
      effectiveChildrenByCompound: {},
      taskBoardCounts: {},
      centerTaskMode: false,
      centerTaskId: null,
      onCenterClick: () => {},
      onRemove: () => {},
      onContextMenu: () => {},
      manualTaskVary,
      onSetManualVary: wired ? () => {} : undefined,
    }),
  );
}

describe('PoolList — hand-added dice', () => {
  it('puts a dice before the edit pencil on a counting row, and none on a normal row', () => {
    const html = render({});
    expect(html.split('aria-label="Vary: ').length - 1).toBe(1);
    expect(html.indexOf('aria-label="Vary: off"')).toBeLessThan(
      html.indexOf('aria-label="Edit Run"'),
    );
    // The normal row's dice slot is an empty placeholder, so the gutter
    // columns stay aligned down the list.
    expect(html.indexOf('aria-label="Vary: off"')).toBeLessThan(
      html.indexOf('aria-label="Edit Make the bed"'),
    );
  });

  it('shows the shared range label under the row once the dice is on', () => {
    expect(render({})).not.toContain('–');
    const little = render({ [RUN.id]: 1 });
    // The literal AND the shared helper — a format change in one must not
    // slide both sides of the assertion together.
    expect(little).toContain('16–20 min');
    expect(little).toContain(varyRangeLabel(20, 1, 20, 'min') as string);
    expect(little).toContain('aria-label="Vary: a little"');
  });

  it('renders neither the dice column nor a range line when unwired', () => {
    const html = render({ [RUN.id]: 1 }, false);
    expect(html).not.toContain('aria-label="Vary: ');
    // An unactionable blue range with no control to change it is a dead end.
    expect(html).not.toContain('16–20 min');
  });
});
