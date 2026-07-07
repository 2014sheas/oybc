import * as fs from 'fs';
import * as path from 'path';
import { evaluateCompound } from '../../src/algorithms/compoundEvaluation';
import { OperatorType, TaskType } from '../../src/constants/enums';
import type { Task, CompoundChild } from '../../src';

/**
 * C1 (issue #267): fully fixture-driven from
 * `tests/fixtures/compoundEvaluationVectors.json` — the SAME file
 * `apps/ios/OYBCTests/CompoundEvaluationVectorTests.swift` runs through the
 * Swift mirror `CompoundEvaluation.evaluate`. Pre-C1: 20 `it` blocks (one —
 * "missing threshold" — asserted 2 sub-cases; one — "non-compound tasks" —
 * asserted 2 sub-cases), for 22 total input/output pairs. Post-C1: 22
 * fixture vectors — a 1:1 mapping, no case dropped.
 */

const FIXTURE_PATH = path.join(__dirname, '../fixtures/compoundEvaluationVectors.json');

interface MiniTask {
  id: string;
  type?: string;
  operator?: string;
  threshold?: number;
  isCompleted?: boolean;
  isDeleted?: boolean;
}

interface MiniChild {
  compoundTaskId: string;
  childTaskId: string;
  isDeleted?: boolean;
}

interface Vector {
  name: string;
  compoundId: string;
  tasks: MiniTask[];
  children: MiniChild[];
  expected: boolean;
}

interface Fixture {
  vectors: Vector[];
}

const fixture: Fixture = JSON.parse(fs.readFileSync(FIXTURE_PATH, 'utf8'));

const BASE_TS = '2026-04-23T00:00:00.000Z';

function toTask(m: MiniTask): Task {
  return {
    id: m.id,
    userId: 'u',
    title: m.id,
    type: (m.type as TaskType) ?? TaskType.NORMAL,
    operator: m.operator as OperatorType | undefined,
    threshold: m.threshold,
    isCompleted: m.isCompleted ?? false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: BASE_TS,
    updatedAt: BASE_TS,
    version: 1,
    isDeleted: m.isDeleted ?? false,
  };
}

function toChild(m: MiniChild, idx: number): CompoundChild {
  return {
    id: `${m.compoundTaskId}-${m.childTaskId}-${idx}`,
    compoundTaskId: m.compoundTaskId,
    childTaskId: m.childTaskId,
    childIndex: idx,
    createdAt: BASE_TS,
    updatedAt: BASE_TS,
    version: 1,
    isDeleted: m.isDeleted ?? false,
  };
}

describe('evaluateCompound (fixture-driven, tests/fixtures/compoundEvaluationVectors.json)', () => {
  it('fixture is non-empty', () => {
    expect(fixture.vectors.length).toBeGreaterThan(0);
  });

  for (const v of fixture.vectors) {
    it(v.name, () => {
      const taskById: Record<string, Task> = {};
      for (const t of v.tasks) taskById[t.id] = toTask(t);

      const childrenByCompound: Record<string, CompoundChild[]> = {};
      v.children.forEach((c, idx) => {
        const list = childrenByCompound[c.compoundTaskId] ?? [];
        list.push(toChild(c, idx));
        childrenByCompound[c.compoundTaskId] = list;
      });
      // A vector that carries zero children for a compound whose id doesn't
      // appear in `children` at all still needs the (possibly absent) key
      // preserved as "missing" vs "present but empty" per the original
      // TS test's distinct cases — both decode to `[]` via evaluateCompound's
      // own `?? []` fallback, so no special-casing is needed here.

      const compound = taskById[v.compoundId];
      expect(evaluateCompound(compound, childrenByCompound, taskById)).toBe(v.expected);
    });
  }
});
