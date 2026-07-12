import * as fs from 'fs';
import * as path from 'path';
import {
  backfillTaskEventId,
  buildBackfillTaskEvent,
} from '../../src/algorithms/migrationHelpers';
import { uuidv5 } from '../../src/algorithms/uuidv5';
import type { Task } from '../../src/types';
import { TaskType } from '../../src/constants/enums';

/**
 * taskEventBackfill.test.ts — Windowed Completion PR A migration helpers
 * (docs/WINDOWED_COMPLETION.md §Migration & backfill). Fixture-driven from
 * `tests/fixtures/backfillEventVectors.json` — the SAME file the deferred iOS
 * `BackfillEventVectorTests.swift` (PR B) will run through the Swift mirror.
 * The determinism the vectors pin is what makes the union-dedupe converge.
 */

interface Fixture {
  uuidv5Vectors: { name: string; namespace: string; name_input: string; expected: string }[];
  idVectors: { taskId: string; completionId: string; incrementId: string }[];
  eventVectors: {
    name: string;
    task: {
      id: string;
      userId: string;
      type: string;
      sharedCounterId: string | null;
      isCompleted: boolean;
      completedAt: string | null;
      currentCount: number | null;
      updatedAt: string;
      isDeleted: boolean;
    };
    expected: Record<string, unknown> | null;
  }[];
}

const fixture: Fixture = JSON.parse(
  fs.readFileSync(path.join(__dirname, '../fixtures/backfillEventVectors.json'), 'utf8'),
);

function makeTask(v: Fixture['eventVectors'][number]['task']): Task {
  return {
    id: v.id,
    userId: v.userId,
    title: 'T',
    type: v.type as TaskType,
    sharedCounterId: v.sharedCounterId,
    isCompleted: v.isCompleted,
    completedAt: v.completedAt ?? undefined,
    currentCount: v.currentCount ?? undefined,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: v.updatedAt,
    updatedAt: v.updatedAt,
    version: 1,
    isDeleted: v.isDeleted,
  };
}

describe('uuidv5 fixture vectors', () => {
  for (const v of fixture.uuidv5Vectors) {
    it(v.name, () => {
      expect(uuidv5(v.name_input, v.namespace)).toBe(v.expected);
    });
  }
});

describe('backfillTaskEventId (deterministic, kind-qualified)', () => {
  it('idVectors fixture is non-empty', () => {
    expect(fixture.idVectors.length).toBeGreaterThan(0);
  });

  for (const v of fixture.idVectors) {
    it(`ids for ${v.taskId} match the fixture`, () => {
      expect(backfillTaskEventId(v.taskId, 'completion')).toBe(v.completionId);
      expect(backfillTaskEventId(v.taskId, 'increment')).toBe(v.incrementId);
    });

    it(`completion and increment ids differ (kind-qualified) for ${v.taskId}`, () => {
      expect(v.completionId).not.toBe(v.incrementId);
    });
  }

  it('is stable across repeated calls (same input → same id)', () => {
    const id = '11111111-1111-1111-1111-111111111111';
    expect(backfillTaskEventId(id, 'completion')).toBe(backfillTaskEventId(id, 'completion'));
  });
});

describe('buildBackfillTaskEvent (fixture-driven)', () => {
  it('eventVectors fixture is non-empty', () => {
    expect(fixture.eventVectors.length).toBeGreaterThan(0);
  });

  for (const v of fixture.eventVectors) {
    it(v.name, () => {
      const result = buildBackfillTaskEvent(makeTask(v.task));
      if (v.expected === null) {
        expect(result).toBeNull();
        return;
      }
      // Normalize the fixture's `delta: null` (JSON has no `undefined`) to the
      // omitted field the builder produces.
      const expected = { ...v.expected };
      if (expected.delta === null) delete expected.delta;
      expect(result).toEqual(expected);
    });
  }

  it('timestamps come from the task snapshot, not wall-clock (createdAt == updatedAt == task.updatedAt)', () => {
    const task = makeTask({
      id: '11111111-1111-1111-1111-111111111111',
      userId: 'user-1',
      type: 'normal',
      sharedCounterId: null,
      isCompleted: true,
      completedAt: '2026-07-05T12:00:00.000Z',
      currentCount: null,
      updatedAt: '2026-07-05T12:00:05.000Z',
      isDeleted: false,
    });
    const event = buildBackfillTaskEvent(task);
    expect(event?.createdAt).toBe('2026-07-05T12:00:05.000Z');
    expect(event?.updatedAt).toBe('2026-07-05T12:00:05.000Z');
    // occurredAt is the semantic completion time, not the snapshot updatedAt.
    expect(event?.occurredAt).toBe('2026-07-05T12:00:00.000Z');
  });
});
