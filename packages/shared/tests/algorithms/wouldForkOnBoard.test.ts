import * as fs from 'fs';
import * as path from 'path';
import { planBoardScopedFork, wouldForkOnBoard } from '../../src/algorithms/boardScopedFork';
import type { Board } from '../../src/types/board';
import type { CompoundChild } from '../../src/types/compoundChild';
import type { Task } from '../../src/types/task';
import { TaskType } from '../../src/constants/enums';

/**
 * Board-scoped task edits PR 2: `wouldForkOnBoard` drives the Board Edit
 * sheet's "Save for this board" label, `planBoardScopedFork` drives the Save.
 * Pinned against the SAME vectors as the planner (and the iOS twin runs the
 * same agreement over its byte-identical fixture copy): the label says fork
 * exactly when the commit forks.
 */

interface RawVector {
  name: string;
  task: { id: string; type: string; title: string; sharedCounterId?: string; forkedFromTaskId?: string };
  boardId: string;
  editedType: string;
  placements: Array<{ id: string; boardId: string; taskId: string; isDeleted: boolean }>;
  compoundChildren?: Array<{ id: string; compoundTaskId: string; childTaskId: string; childIndex: number; isDeleted: boolean }>;
  expected: { mode: 'inPlace' | 'fork' };
}

const fixture = JSON.parse(
  fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'boardScopedForkVectors.json'), 'utf8'),
) as { planBoardScopedFork: { now: string; boards: Array<Board & { endDate: string | null; sealedAt: string | null }>; vectors: RawVector[] } };

const OLD = '2026-01-01T00:00:00.000Z';
const { now, boards: rawBoards, vectors } = fixture.planBoardScopedFork;
const boards = rawBoards.map(
  (b) => ({ ...b, endDate: b.endDate ?? undefined, sealedAt: b.sealedAt ?? undefined }) as unknown as Board,
);

function task(raw: RawVector['task']): Task {
  return {
    id: raw.id, userId: 'u1', title: raw.title, type: raw.type as TaskType,
    sharedCounterId: raw.sharedCounterId, forkedFromTaskId: raw.forkedFromTaskId,
    isCompleted: false, totalCompletions: 0, totalInstances: 1,
    createdAt: OLD, updatedAt: OLD, version: 1, isDeleted: false,
  };
}
function links(v: RawVector): CompoundChild[] {
  return (v.compoundChildren ?? []).map((l) => ({ ...l, createdAt: OLD, updatedAt: OLD, version: 1 }));
}

describe('wouldForkOnBoard — agrees with planBoardScopedFork on every vector', () => {
  it.each(vectors.map((v) => [v.name, v] as const))('%s', (_n, v) => {
    const t = task(v.task);
    const board = boards.find((b) => b.id === v.boardId)!;
    const plan = planBoardScopedFork({
      task: t, board, editedType: v.editedType as TaskType, placements: v.placements,
      boards, compoundChildren: links(v), events: [], now,
    });
    const would = wouldForkOnBoard({ task: t, boardId: v.boardId, placements: v.placements, boards, compoundChildren: links(v) });
    expect(would).toBe(v.expected.mode === 'fork');
    expect(would).toBe(plan.mode === 'fork');
  });
});

describe('wouldForkOnBoard — direct cases', () => {
  const t = task({ id: 'T', type: TaskType.NORMAL, title: 'T' });
  const live = [{ id: 'B1', isDeleted: false }, { id: 'B2', isDeleted: false }];

  it('is false with no placements', () => {
    expect(wouldForkOnBoard({ task: t, boardId: 'B1', placements: [], boards: live, compoundChildren: [] })).toBe(false);
  });

  it('is true for a live placement on another board', () => {
    const placements = [
      { id: 'p1', boardId: 'B1', taskId: 'T', isDeleted: false },
      { id: 'p2', boardId: 'B2', taskId: 'T', isDeleted: false },
    ];
    expect(wouldForkOnBoard({ task: t, boardId: 'B1', placements, boards: live, compoundChildren: [] })).toBe(true);
  });

  it('is false for a fork or a linked counter even when placed elsewhere', () => {
    const placements = [{ id: 'p2', boardId: 'B2', taskId: 'T', isDeleted: false }];
    const fork = { ...t, forkedFromTaskId: 'X' };
    const linked = { ...t, sharedCounterId: 'R' };
    expect(wouldForkOnBoard({ task: fork, boardId: 'B1', placements, boards: live, compoundChildren: [] })).toBe(false);
    expect(wouldForkOnBoard({ task: linked, boardId: 'B1', placements, boards: live, compoundChildren: [] })).toBe(false);
  });
});
