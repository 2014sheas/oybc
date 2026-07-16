import * as fs from 'fs';
import * as path from 'path';
import { classifyCounterCreateMatch, findLinkableCounter } from '../../src/algorithms/linkableCounter';
import { TaskType } from '../../src/constants/enums';
import type { Task } from '../../src/types/task';

/**
 * linkableCounter.test.ts — "add a new task to an existing counter" match.
 *
 * C1 (issue #267): fully fixture-driven from
 * `tests/fixtures/linkableCounterVectors.json` — the SAME file
 * `apps/ios/OYBCTests/LinkableCounterVectorTests.swift` runs through the
 * Swift mirror `findLinkableCounter` in `LinkableCounter.swift`. Pre-C1: 8
 * `it` blocks (one asserted 2 blank-field sub-cases in one block). Post-C1:
 * 9 fixture vectors (the blank-action / blank-unit sub-cases became two
 * vectors instead of one `it` with two `expect`s) — no case dropped.
 */

const FIXTURE_PATH = path.join(__dirname, '../fixtures/linkableCounterVectors.json');
const TS = '2026-07-01T12:00:00.000Z';

interface MiniTask {
  id: string;
  action?: string;
  unit?: string;
  currentCount?: number;
  sharedCounterId?: string | null;
  isDeleted?: boolean;
  type?: string;
  isCounter?: boolean;
}

interface Vector {
  name: string;
  action: string;
  unit: string;
  excludeTaskId?: string;
  tasks: MiniTask[];
  expected: { counterId: string; name: string; lifetime: number; memberCount: number } | null;
}

interface Fixture {
  vectors: Vector[];
}

const fixture: Fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));

function toTask(m: MiniTask): Task {
  return {
    id: m.id,
    userId: 'u1',
    title: `Task ${m.id}`,
    type: (m.type as TaskType) ?? TaskType.COUNTING,
    action: m.action,
    unit: m.unit,
    maxCount: 30,
    currentCount: m.currentCount,
    sharedCounterId: m.sharedCounterId ?? null,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: TS,
    updatedAt: TS,
    version: 1,
    isDeleted: m.isDeleted ?? false,
    isCounter: m.isCounter,
  };
}

describe('findLinkableCounter (fixture-driven, tests/fixtures/linkableCounterVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.vectors.length).toBeGreaterThan(0);
  });

  for (const v of fixture.vectors) {
    it(v.name, () => {
      const tasks = v.tasks.map(toTask);
      const result = findLinkableCounter(
        { action: v.action, unit: v.unit, excludeTaskId: v.excludeTaskId },
        tasks,
      );
      if (v.expected === null) {
        expect(result).toBeNull();
      } else {
        expect(result).not.toBeNull();
        expect(result!.counterId).toBe(v.expected.counterId);
        expect(result!.name).toBe(v.expected.name);
        expect(result!.lifetime).toBe(v.expected.lifetime);
        expect(result!.memberCount).toBe(v.expected.memberCount);
      }
    });
  }
});

describe('classifyCounterCreateMatch (P5 hub-create dedupe)', () => {
  it('classifies a linked source as established', () => {
    // Source "Push-ups" + one linker sharing the counter → memberCount 2, kind 'established'.
    const source = toTask({ id: 'source', action: 'Push-ups', unit: 'reps', currentCount: 40 });
    const linker = toTask({
      id: 'linker',
      action: 'Push-ups',
      unit: 'reps',
      sharedCounterId: 'source',
    });
    const tasks = [source, linker];

    const result = classifyCounterCreateMatch({ action: 'Push-ups', unit: 'reps' }, tasks);

    expect(result).not.toBeNull();
    expect(result!.kind).toBe('established');
    expect(result!.task.id).toBe('source');
    expect(result!.lifetime).toBe(40);
    expect(result!.memberCount).toBe(2);
  });

  it('classifies a flagged zero-link counter as established', () => {
    // isCounter: true, no linkers → memberCount 1 but still 'established' because of the flag.
    const flagged = toTask({
      id: 'flagged',
      action: 'Sit-ups',
      unit: 'reps',
      currentCount: 10,
      isCounter: true,
    });
    const tasks = [flagged];

    const result = classifyCounterCreateMatch({ action: 'Sit-ups', unit: 'reps' }, tasks);

    expect(result).not.toBeNull();
    expect(result!.kind).toBe('established');
    expect(result!.task.id).toBe('flagged');
    expect(result!.lifetime).toBe(10);
    expect(result!.memberCount).toBe(1);
  });

  it('classifies a plain standalone counting task as standalone', () => {
    // No isCounter flag, no linkers → 'standalone', matched task row returned as the promote target.
    const standalone = toTask({
      id: 'standalone',
      action: 'Squats',
      unit: 'reps',
      currentCount: 5,
    });
    const tasks = [standalone];

    const result = classifyCounterCreateMatch({ action: 'Squats', unit: 'reps' }, tasks);

    expect(result).not.toBeNull();
    expect(result!.kind).toBe('standalone');
    expect(result!.task.id).toBe('standalone');
    expect(result!.lifetime).toBe(5);
    expect(result!.memberCount).toBe(1);
  });

  it('returns null when nothing matches', () => {
    const other = toTask({ id: 'other', action: 'Push-ups', unit: 'reps' });
    const tasks = [other];

    const result = classifyCounterCreateMatch({ action: 'Lunges', unit: 'reps' }, tasks);

    expect(result).toBeNull();
  });
});
