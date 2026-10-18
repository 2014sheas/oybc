import { describe, expect, it } from 'vitest';
import { takeExistingPick, type PlacementBuffer } from '../squarePick';

/**
 * The picker buffers the quick-add row's parameters (reported BEFORE the pick)
 * and the pick carries them — a counter root picked with a typed goal yields
 * `{ taskId, placement }`.
 */
describe('takeExistingPick', () => {
  it('a typed-goal pick carries the buffered placement and consumes it', () => {
    const buffer: PlacementBuffer = new Map([['root', { targetOverride: 12, targetKind: 'discrete' }]]);
    expect(takeExistingPick(buffer, 'root')).toEqual({
      taskId: 'root',
      placement: { targetOverride: 12, targetKind: 'discrete' },
    });
    expect(buffer.size).toBe(0);
  });

  it('no parameters, or a cleared (null) entry, yields a bare pick', () => {
    expect(takeExistingPick(new Map(), 'a')).toEqual({ taskId: 'a' });
    expect(takeExistingPick(new Map([['a', null]]), 'a')).toEqual({ taskId: 'a' });
  });

  it('only the picked task\'s entry is used', () => {
    const buffer: PlacementBuffer = new Map([['other', { targetOverride: 3 }]]);
    expect(takeExistingPick(buffer, 'a')).toEqual({ taskId: 'a' });
    expect(buffer.has('other')).toBe(true);
  });
});
