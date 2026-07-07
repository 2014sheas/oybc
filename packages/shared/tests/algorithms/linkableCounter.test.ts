import * as fs from 'fs';
import * as path from 'path';
import { findLinkableCounter } from '../../src/algorithms/linkableCounter';
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
