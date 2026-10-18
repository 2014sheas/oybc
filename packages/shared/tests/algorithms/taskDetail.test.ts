import * as fs from 'fs';
import * as path from 'path';
import { buildTaskActivity, closestLine, nextCompoundSubtask, pickHeroAnchorBoard } from '../../src/algorithms/taskDetail';
import * as barrel from '../../src/algorithms';
import type { Board } from '../../src/types/board';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const V: any = JSON.parse(fs.readFileSync(path.join(__dirname, '../fixtures/taskDetailVectors.json'), 'utf8'));

describe('taskDetail vectors', () => {
  it.each(V.heroAnchor as any[])('heroAnchor: $name', (v: any) => {
    const boards = (v.boards as any[]).map((b) => ({ isDeleted: false, ...b })) as Board[];
    expect(pickHeroAnchorBoard(boards, new Date(v.now))?.id ?? null).toBe(v.expected);
  });
  it.each(V.nextSubtask as any[])('nextSubtask: $name', (v: any) => {
    expect(nextCompoundSubtask(v.children) ?? null).toEqual(v.expected);
  });
  it.each(V.activity as any[])('activity: $name', (v: any) => {
    expect(buildTaskActivity(v.input)).toEqual(v.expected);
  });
  it.each(V.closestLine as any[])('closestLine: $name', (v: any) => {
    expect(closestLine(v.grid, v.gridSize) ?? null).toEqual(v.expected);
  });
  it('every helper is in the barrel', () => {
    for (const n of ['pickHeroAnchorBoard', 'nextCompoundSubtask', 'buildTaskActivity', 'tapLogChips', 'closestLine']) {
      expect(typeof (barrel as Record<string, unknown>)[n]).toBe('function');
    }
  });
});
