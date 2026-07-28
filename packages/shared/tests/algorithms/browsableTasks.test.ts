/**
 * browsableTasks.test.ts — the draft-board library-visibility rule.
 *
 * Mirror of the iOS `DraftTaskVisibilityTests`. A wizard-born task is hidden
 * from library-browse surfaces iff it has NO placement on a live non-draft
 * board (draft-only, or orphaned — deleted from the pool / board gone).
 */

import {
  computeBrowsableTasks,
  isGoalLessCounter,
} from '../../src/algorithms/browsableTasks';
import { BoardStatus, TaskType } from '../../src/constants/enums';
import type { Task } from '../../src/types/task';
import type { BoardTask } from '../../src/types/boardTask';

function task(
  id: string,
  createdInWizard: boolean,
  overrides: Partial<Task> = {},
): Task {
  return {
    id,
    userId: 'u1',
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: '2026-07-01T12:00:00.000Z',
    updatedAt: '2026-07-01T12:00:00.000Z',
    version: 1,
    isDeleted: false,
    createdInWizard,
    ...overrides,
  };
}

function placement(taskId: string, boardId: string, overrides: Partial<BoardTask> = {}): BoardTask {
  return {
    id: `bt-${taskId}-${boardId}`,
    boardId,
    taskId,
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: '2026-07-01T12:00:00.000Z',
    updatedAt: '2026-07-01T12:00:00.000Z',
    version: 1,
    isDeleted: false,
    ...overrides,
  };
}

const ids = (tasks: Task[]): Set<string> => new Set(tasks.map((t) => t.id));

describe('computeBrowsableTasks', () => {
  it('standalone task always visible, even only on a draft', () => {
    const result = computeBrowsableTasks(
      [task('a', false)],
      [placement('a', 'draftBoard')],
      { draftBoard: BoardStatus.DRAFT },
    );
    expect(ids(result)).toEqual(new Set(['a']));
  });

  it('wizard task only on a draft board is hidden', () => {
    const result = computeBrowsableTasks(
      [task('a', true)],
      [placement('a', 'draftBoard')],
      { draftBoard: BoardStatus.DRAFT },
    );
    expect(result).toHaveLength(0);
  });

  it('wizard task on an active board is visible', () => {
    const result = computeBrowsableTasks(
      [task('a', true)],
      [placement('a', 'activeBoard')],
      { activeBoard: BoardStatus.ACTIVE },
    );
    expect(ids(result)).toEqual(new Set(['a']));
  });

  it('wizard task on both draft and active is visible', () => {
    const result = computeBrowsableTasks(
      [task('a', true)],
      [placement('a', 'draftBoard'), placement('a', 'activeBoard')],
      { draftBoard: BoardStatus.DRAFT, activeBoard: BoardStatus.ACTIVE },
    );
    expect(ids(result)).toEqual(new Set(['a']));
  });

  it('wizard task on a completed board is visible', () => {
    const result = computeBrowsableTasks(
      [task('a', true)],
      [placement('a', 'doneBoard')],
      { doneBoard: BoardStatus.COMPLETED },
    );
    expect(ids(result)).toEqual(new Set(['a']));
  });

  it('wizard orphan whose only board is deleted is HIDDEN', () => {
    // The only placement points at a board absent from the status map (deleted)
    // → no live placement → orphan → hidden.
    const result = computeBrowsableTasks(
      [task('a', true)],
      [placement('a', 'deletedBoard')],
      {}, // deletedBoard absent
    );
    expect(result).toHaveLength(0);
  });

  it('wizard task with no placements at all is HIDDEN', () => {
    // Removed from the pool — its Task row lingers but has no board_task.
    const result = computeBrowsableTasks([task('a', true)], [], {});
    expect(result).toHaveLength(0);
  });

  it('mixed set — only draft-only + orphan wizard tasks hide', () => {
    const tasks = [
      task('standalone', false), // visible
      task('wizDraft', true), // hidden (only on draft)
      task('wizActive', true), // visible (on active)
      task('wizOrphan', true), // hidden (no placement)
    ];
    const placements = [
      placement('standalone', 'draftBoard'),
      placement('wizDraft', 'draftBoard'),
      placement('wizActive', 'activeBoard'),
    ];
    const statuses = {
      draftBoard: BoardStatus.DRAFT,
      activeBoard: BoardStatus.ACTIVE,
    };
    const result = computeBrowsableTasks(tasks, placements, statuses);
    expect(ids(result)).toEqual(new Set(['standalone', 'wizActive']));
  });

  it('wizard-born compound child inherits parent placement — parent active → child visible', () => {
    // A compound inline subtask is never directly placed; it must inherit the
    // parent compound's placements or it would hide forever.
    const tasks = [task('parent', true), task('child', true)];
    const placements = [placement('parent', 'activeBoard')];
    const statuses = { activeBoard: BoardStatus.ACTIVE };
    const result = computeBrowsableTasks(tasks, placements, statuses, {
      child: ['parent'],
    });
    expect(ids(result)).toEqual(new Set(['parent', 'child']));
  });

  it('wizard-born compound child of a draft-only parent is hidden', () => {
    const tasks = [task('parent', true), task('child', true)];
    const placements = [placement('parent', 'draftBoard')];
    const statuses = { draftBoard: BoardStatus.DRAFT };
    const result = computeBrowsableTasks(tasks, placements, statuses, {
      child: ['parent'],
    });
    expect(result).toHaveLength(0);
  });

  it('wizard-born compound child with no parent placement is hidden', () => {
    const tasks = [task('parent', true), task('child', true)];
    const result = computeBrowsableTasks(tasks, [], {}, { child: ['parent'] });
    expect(result).toHaveLength(0);
  });

  // Board-integrity PR-1 (docs/BOARD_INTEGRITY.md) — a tombstoned BoardTask
  // placement must not count as "live" for the wizard-orphan visibility rule.
  it('wizard task whose only placement is TOMBSTONED is hidden (not visible via a dead placement)', () => {
    const result = computeBrowsableTasks(
      [task('a', true)],
      [placement('a', 'activeBoard', { isDeleted: true })],
      { activeBoard: BoardStatus.ACTIVE },
    );
    expect(result).toHaveLength(0);
  });

  it('wizard task stays visible via a live placement even with an unrelated tombstoned one', () => {
    const result = computeBrowsableTasks(
      [task('a', true)],
      [
        placement('a', 'draftBoard', { isDeleted: true }),
        placement('a', 'activeBoard'),
      ],
      { draftBoard: BoardStatus.DRAFT, activeBoard: BoardStatus.ACTIVE },
    );
    expect(ids(result)).toEqual(new Set(['a']));
  });
});

describe('goal-less counter exclusion (P5)', () => {
  it('hides a goal-less isCounter task from browse', () => {
    const tasks = [
      task('a', false, {
        type: TaskType.COUNTING,
        isCounter: true,
        maxCount: undefined,
      }),
    ];
    const result = computeBrowsableTasks(tasks, [], {});
    expect(result).toHaveLength(0);
  });

  it('keeps a promoted counter (isCounter + maxCount) visible', () => {
    const tasks = [
      task('a', false, {
        type: TaskType.COUNTING,
        isCounter: true,
        maxCount: 50,
      }),
    ];
    const result = computeBrowsableTasks(tasks, [], {});
    expect(ids(result)).toEqual(new Set(['a']));
  });

  it('keeps a goal-less row WITHOUT the flag visible (old-client flag-drop degrades safely)', () => {
    const tasks = [
      task('a', false, {
        type: TaskType.COUNTING,
        isCounter: undefined,
        maxCount: undefined,
      }),
    ];
    const result = computeBrowsableTasks(tasks, [], {});
    expect(ids(result)).toEqual(new Set(['a']));
  });

  it('isGoalLessCounter truth table', () => {
    expect(
      isGoalLessCounter({
        type: TaskType.COUNTING,
        isCounter: true,
        maxCount: undefined,
      }),
    ).toBe(true);
    expect(
      isGoalLessCounter({
        type: TaskType.COUNTING,
        isCounter: true,
        maxCount: 50,
      }),
    ).toBe(false);
    expect(
      isGoalLessCounter({
        type: TaskType.COUNTING,
        isCounter: undefined,
        maxCount: undefined,
      }),
    ).toBe(false);
    expect(
      isGoalLessCounter({
        type: TaskType.NORMAL,
        isCounter: true,
        maxCount: undefined,
      }),
    ).toBe(false);
  });
});
