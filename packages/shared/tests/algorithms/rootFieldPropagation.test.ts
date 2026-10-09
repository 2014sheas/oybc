import * as fs from 'fs';
import * as path from 'path';
import {
  planRootFieldPropagation,
  type RootFieldEditPatch,
  type RootPropagationCopy,
} from '../../src/algorithms/rootFieldPropagation';
import type { CountKind } from '../../src/algorithms/countValue';
import type { Task } from '../../src/types/task';
import { TaskType } from '../../src/constants/enums';

/**
 * Board-scoped task edits PR 3 (docs/BOARD_SCOPED_TASK_EDITS.md §6): pins
 * `planRootFieldPropagation` against `tests/fixtures/rootFieldPropagationVectors.json`
 * — the SAME fixture the iOS `RootFieldPropagationVectorTests` runs
 * (byte-identical copy under `apps/ios/OYBCTests/Fixtures/`).
 */

interface FixRoot {
  id: string;
  title: string;
  action?: string;
  unit?: string;
  maxCount?: number;
  countKind?: CountKind;
  sharedCounterId?: string;
}
interface FixCopy {
  id: string;
  title: string;
  type?: string;
  action?: string;
  unit?: string;
  maxCount?: number;
  countKind?: CountKind;
  sharedCounterId?: string | null;
  startDate?: string;
  endDate?: string;
  createdInWizard?: boolean;
  isDeleted?: boolean;
  onSealedBoard?: boolean;
}
interface FixVector {
  name: string;
  root: FixRoot;
  patch: RootFieldEditPatch;
  copies: FixCopy[];
  expected: Array<{ copyId: string; patch: Record<string, string> }>;
}
interface Fixture {
  now: string;
  vectors: FixVector[];
}

const fixture = JSON.parse(
  fs.readFileSync(path.join(__dirname, '../fixtures/rootFieldPropagationVectors.json'), 'utf8'),
) as Fixture;

const makeRoot = (r: FixRoot): Pick<
  Task,
  'id' | 'type' | 'title' | 'action' | 'unit' | 'maxCount' | 'countKind' | 'sharedCounterId'
> => ({ ...r, type: TaskType.COUNTING });

const makeCopy = (c: FixCopy): RootPropagationCopy => ({
  id: c.id,
  title: c.title,
  type: (c.type as TaskType | undefined) ?? TaskType.COUNTING,
  action: c.action,
  unit: c.unit,
  maxCount: c.maxCount,
  countKind: c.countKind,
  sharedCounterId: c.sharedCounterId === null ? undefined : (c.sharedCounterId ?? 'root'),
  startDate: c.startDate,
  endDate: c.endDate,
  createdInWizard: c.createdInWizard ?? true,
  isDeleted: c.isDeleted ?? false,
  onSealedBoard: c.onSealedBoard ?? false,
});

describe('planRootFieldPropagation — shared vectors', () => {
  it('covers the fixture', () => {
    expect(fixture.vectors.length).toBe(12);
  });

  for (const v of fixture.vectors) {
    it(v.name, () => {
      const out = planRootFieldPropagation(makeRoot(v.root), v.patch, v.copies.map(makeCopy), fixture.now);
      expect(out).toEqual(v.expected);
      for (const entry of out) expect(entry.patch).not.toHaveProperty('maxCount');
    });
  }
});
