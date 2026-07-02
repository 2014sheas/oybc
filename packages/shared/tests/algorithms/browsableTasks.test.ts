/**
 * browsableTasks.test.ts — the draft-board library-visibility rule.
 *
 * Mirror of the iOS `DraftTaskVisibilityTests`. A wizard-born task is hidden
 * from library-browse surfaces iff it has NO placement on a live non-draft
 * board (draft-only, or orphaned — deleted from the pool / board gone).
 */

import { computeBrowsableTasks } from '../../src/algorithms/browsableTasks';
import { BoardStatus, TaskType } from '../../src/constants/enums';
import type { Task } from '../../src/types/task';
import type { BoardTask } from '../../src/types/boardTask';

function task(id: string, createdInWizard: boolean): Task {
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
  };
}

function placement(taskId: string, boardId: string): BoardTask {
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
});
