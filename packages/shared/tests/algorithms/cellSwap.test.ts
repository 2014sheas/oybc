/**
 * cellSwap.test.ts — Unit tests for the cell-swap affected-board computation.
 *
 * The cascade math for a BoardTask.taskId swap:
 *   - The OLD task's affected boards (every board placing the old task, or a compound
 *     that contains it transitively) must be re-derived.
 *   - The NEW task's affected boards (same logic for the new task) must also be re-derived.
 *   - The union of both sets is the complete cascade target.
 *
 * These tests exercise that combinatorial logic using the shared
 * `findAffectedBoardIds` + `findTransitiveParentCompounds` helpers that the
 * production cascade wrappers call. No DB or platform code is imported.
 */

import {
  findAffectedBoardIds,
  findTransitiveParentCompounds,
} from '../../src/algorithms/derivationPass';
import type { BoardTask, CompoundChild } from '../../src/types';

// ─── Helpers ──────────────────────────────────────────────────────────────────

function makeBoardTask(
  id: string,
  boardId: string,
  taskId: string,
  overrides: Partial<BoardTask> = {},
): BoardTask {
  return {
    id,
    boardId,
    taskId,
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: '2024-01-01T00:00:00.000Z',
    updatedAt: '2024-01-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

function makeCompoundChild(
  id: string,
  compoundTaskId: string,
  childTaskId: string,
  childIndex = 0,
): CompoundChild {
  return {
    id,
    compoundTaskId,
    childTaskId,
    childIndex,
    createdAt: '2024-01-01T00:00:00.000Z',
    updatedAt: '2024-01-01T00:00:00.000Z',
    version: 1,
    isDeleted: false,
  };
}

/**
 * Compute the union of affected board IDs for both the old and new task,
 * mirroring what `updateBoardTaskAndCascade` does: re-derive boards that
 * contained the OLD task AND boards that contain (or will contain) the NEW task.
 */
function computeSwapAffectedBoardIds(
  oldTaskId: string,
  newTaskId: string,
  allBoardTasks: BoardTask[],
  allCompoundChildren: CompoundChild[],
): Set<string> {
  const oldParents = findTransitiveParentCompounds(oldTaskId, allCompoundChildren);
  const oldBoards = findAffectedBoardIds(oldTaskId, oldParents, allBoardTasks);

  const newParents = findTransitiveParentCompounds(newTaskId, allCompoundChildren);
  const newBoards = findAffectedBoardIds(newTaskId, newParents, allBoardTasks);

  return new Set([...oldBoards, ...newBoards]);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

describe('cellSwap cascade — affected board computation', () => {
  // 1. Happy path: both tasks placed on distinct boards — union covers both
  it('includes boards for both the old and new task', () => {
    const allBoardTasks = [
      makeBoardTask('bt1', 'board-A', 'task-old'),
      makeBoardTask('bt2', 'board-B', 'task-new'),
    ];

    const affected = computeSwapAffectedBoardIds('task-old', 'task-new', allBoardTasks, []);
    expect(affected).toEqual(new Set(['board-A', 'board-B']));
  });

  // 2. Swap to same task (no-op guard): only one board, deduplicated
  it('deduplicates when old and new task point to the same board', () => {
    const allBoardTasks = [
      makeBoardTask('bt1', 'board-A', 'task-same'),
    ];

    const affected = computeSwapAffectedBoardIds('task-same', 'task-same', allBoardTasks, []);
    expect(affected.size).toBe(1);
    expect(affected.has('board-A')).toBe(true);
  });

  // 3. New task already on the swapping board — same board appears once
  it('does not duplicate the swapping board when new task is already placed on it', () => {
    const allBoardTasks = [
      makeBoardTask('bt1', 'board-A', 'task-old'),
      makeBoardTask('bt2', 'board-A', 'task-new'),
    ];

    const affected = computeSwapAffectedBoardIds('task-old', 'task-new', allBoardTasks, []);
    expect(affected.size).toBe(1);
    expect(affected.has('board-A')).toBe(true);
  });

  // 4. Swap old counting task for a normal task — type is irrelevant to board cascade
  it('counts the board regardless of task type (counting ↔ normal)', () => {
    const allBoardTasks = [
      makeBoardTask('bt1', 'board-X', 'counting-task'),
      makeBoardTask('bt2', 'board-Y', 'normal-task'),
    ];

    const affected = computeSwapAffectedBoardIds('counting-task', 'normal-task', allBoardTasks, []);
    expect(affected).toEqual(new Set(['board-X', 'board-Y']));
  });

  // 5. Old task is a compound child — its compound parent's boards are also affected
  it('cascades to parent compound boards when old task is a compound child', () => {
    const allCompoundChildren = [
      makeCompoundChild('cc1', 'compound-T', 'task-old'),
    ];
    const allBoardTasks = [
      // The compound parent is on board-A; the old primitive task is NOT directly placed
      makeBoardTask('bt1', 'board-A', 'compound-T'),
    ];

    const affected = computeSwapAffectedBoardIds('task-old', 'task-new', allBoardTasks, allCompoundChildren);
    // board-A is affected because it places compound-T which contains task-old
    expect(affected.has('board-A')).toBe(true);
  });

  // 6. New task is a compound child — its compound parent's boards are affected
  it('cascades to parent compound boards when new task is a compound child', () => {
    const allCompoundChildren = [
      makeCompoundChild('cc1', 'compound-T', 'task-new'),
    ];
    const allBoardTasks = [
      makeBoardTask('bt1', 'board-B', 'compound-T'),
      makeBoardTask('bt2', 'board-C', 'task-old'),
    ];

    const affected = computeSwapAffectedBoardIds('task-old', 'task-new', allBoardTasks, allCompoundChildren);
    expect(affected.has('board-B')).toBe(true); // compound parent of new task
    expect(affected.has('board-C')).toBe(true); // old task's board
  });

  // 7. Neither task placed anywhere — affected set is empty
  it('returns empty set when neither task is placed on any board', () => {
    const affected = computeSwapAffectedBoardIds('task-old', 'task-new', [], []);
    expect(affected.size).toBe(0);
  });

  // 8. Old task placed on multiple boards — all included
  it('includes all boards where the old task was placed', () => {
    const allBoardTasks = [
      makeBoardTask('bt1', 'board-A', 'task-old'),
      makeBoardTask('bt2', 'board-B', 'task-old'),
      makeBoardTask('bt3', 'board-C', 'task-old'),
    ];

    const affected = computeSwapAffectedBoardIds('task-old', 'task-new', allBoardTasks, []);
    // All three boards for old task; new task has no placements
    expect(affected).toEqual(new Set(['board-A', 'board-B', 'board-C']));
  });

  // Board-integrity PR-1 (docs/BOARD_INTEGRITY.md) — findAffectedBoardIds
  // must never surface a board via a TOMBSTONED placement. A pulled
  // tombstone is exactly the case that would otherwise stall re-derivation:
  // the board that lost its only placement of a task must still be found
  // "affected" through some OTHER live path, never through the dead row.
  it('findAffectedBoardIds excludes boards reachable only via a tombstoned placement', () => {
    const allBoardTasks = [
      makeBoardTask('bt1', 'board-A', 'task-x', { isDeleted: true }),
      makeBoardTask('bt2', 'board-B', 'task-x'),
    ];
    const affected = findAffectedBoardIds('task-x', new Set(), allBoardTasks);
    expect(affected).toEqual(new Set(['board-B']));
  });
});
