import fs from 'fs';
import path from 'path';
import type { Task } from '../../src/types';
import { placementGoal, placementTitle, withPlacementParams, childTargetFor, withChildTarget } from '../../src/algorithms/placementParams';

const V: any = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'placementParamsVectors.json'), 'utf8')
);

const toTask = (t: any): Task =>
  ({
    id: 't',
    userId: 'u',
    type: t.type,
    title: t.title,
    action: t.action ?? undefined,
    unit: t.unit ?? undefined,
    maxCount: t.maxCount ?? undefined,
    countKind: t.countKind ?? undefined,
    sharedCounterId: t.sharedCounterId ?? undefined,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  }) as Task;

describe('placementParams (fixture-driven, placementParamsVectors.json)', () => {
  it('fixture is non-trivial', () => {
    expect(V.vectors.length).toBeGreaterThanOrEqual(8);
  });

  it.each(V.vectors as any[])('$name', (v: any) => {
    const task = toTask(v.task);
    expect(placementGoal(task, v.placement) ?? null).toBe(v.expectedGoal);
    expect(placementTitle(task, v.placement, v.settings)).toBe(v.expectedTitle);
    const adjusted = withPlacementParams(task, v.placement, v.settings);
    expect(adjusted.title).toBe(v.expectedTitle);
    if (task.type === 'counting') expect(adjusted.maxCount ?? null).toBe(v.expectedGoal);
  });

  it('withPlacementParams returns the same object when nothing applies', () => {
    const task = toTask(V.vectors[0].task);
    expect(withPlacementParams(task, null)).toBe(task);
    expect(withPlacementParams(task, {})).toBe(task);
  });

  it('childTargets apply to the named direct child only', () => {
    const targets = [{ childId: 'a', target: 1 }];
    expect(childTargetFor({ childTargets: targets }, 'a')).toBe(1);
    expect(childTargetFor({ childTargets: targets }, 'b')).toBeUndefined();
    const a = toTask({ type: 'counting', title: 'A', maxCount: 10, countKind: 'discrete' });
    expect(withChildTarget({ ...a, id: 'a' }, targets).maxCount).toBe(1);
    expect(withChildTarget({ ...a, id: 'b' }, targets).maxCount).toBe(10);
  });
});
