import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { TaskType, type Task } from '@oybc/shared';
import { linkedKindTagProps } from '../linkedKindTagProps';
import { KindTag } from '../KindTag';

const task = (o: Partial<Task>): Task =>
  ({
    id: 'x', userId: 'u', title: 'x', type: TaskType.COUNTING, isCompleted: false, totalCompletions: 0,
    totalInstances: 0, createdAt: 'x', updatedAt: 'x', version: 1, isDeleted: false, ...o,
  }) as Task;

const root = task({ id: 'root', title: 'Run 26.2 miles', action: 'Run', unit: 'miles', countKind: 'continuous', currentCount: 1240.5 });
const linked = task({ id: 'l', title: 'Run 3 miles', action: 'Run', unit: 'miles', countKind: 'continuous', sharedCounterId: 'root' });

describe('linkedKindTagProps (spec §5 linked rows)', () => {
  it("names the family root and its grouped all-time at the family's kind", () => {
    const props = linkedKindTagProps(linked, [root, linked]);
    expect(props).toEqual({ kind: 'continuous', counterName: 'Run miles', lifetime: 1240.5 });
    const html = renderToStaticMarkup(React.createElement(KindTag, props));
    expect(html).toContain('Run miles · 1,240.5 all-time');
  });
  it('Duration family: Xh Ym total', () => {
    const dur = task({ id: 'root', title: 'Practice 10h', action: 'Practice', unit: '', countKind: 'duration', currentCount: 6735 });
    const props = linkedKindTagProps(task({ id: 'l', countKind: 'duration', sharedCounterId: 'root' }), [dur]);
    expect(renderToStaticMarkup(React.createElement(KindTag, props))).toContain('Practice · 112h 15m all-time');
  });
  it('root not loaded yet: the row kind only, no meta line', () => {
    expect(linkedKindTagProps(linked, [])).toEqual({ kind: 'continuous' });
  });
});
