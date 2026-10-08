/**
 * Board-scoped task edits PR 1 (docs/BOARD_SCOPED_TASK_EDITS.md §3, §6): a
 * fork (`forkedFromTaskId` set) is board-bound — never library-browsable,
 * never a compound sub-task picker candidate, never source supply.
 */
import { computeBrowsableTasks } from '../../src/algorithms/browsableTasks';
import { compoundChildPickerCandidates } from '../../src/algorithms/compoundChildEligibility';
import { isSourceSupplyTask } from '../../src/algorithms/boardSources';
import { BoardStatus, TaskType } from '../../src/constants/enums';
import type { BoardTask } from '../../src/types/boardTask';
import type { Task } from '../../src/types/task';

const T0 = '2026-10-01T12:00:00.000Z';

function task(id: string, overrides: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'u1',
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
    ...overrides,
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
    createdAt: T0,
    updatedAt: T0,
    version: 1,
    isDeleted: false,
  };
}

describe('computeBrowsableTasks — forks', () => {
  const statuses = { active: BoardStatus.ACTIVE };

  it('hides a fork placed on an active board (a wizard-born task there is visible)', () => {
    const original = task('orig');
    const wizardBorn = task('wiz', { createdInWizard: true });
    const fork = task('fork', { createdInWizard: true, forkedFromTaskId: 'orig' });
    const out = computeBrowsableTasks(
      [original, wizardBorn, fork],
      [placement('orig', 'active'), placement('wiz', 'active'), placement('fork', 'active')],
      statuses,
    );
    expect(out.map((t) => t.id)).toEqual(['orig', 'wiz']);
  });

  it('hides a fork even when createdInWizard was stripped by an old client', () => {
    const fork = task('fork', { forkedFromTaskId: 'orig' });
    expect(computeBrowsableTasks([fork], [placement('fork', 'active')], statuses)).toEqual([]);
  });

  it('a null forkedFromTaskId is not a fork', () => {
    const plain = task('plain', { forkedFromTaskId: null });
    expect(computeBrowsableTasks([plain], [], statuses).map((t) => t.id)).toEqual(['plain']);
  });
});

describe('compoundChildPickerCandidates — forks', () => {
  it('drops a fork even if a caller passes it as browsable', () => {
    const a = task('a', { title: 'Alpha' });
    const fork = task('f', { title: 'Beta', forkedFromTaskId: 'a' });
    const out = compoundChildPickerCandidates('parent', [a, fork], [], new Set());
    expect(out.map((t) => t.id)).toEqual(['a']);
  });
});

describe('isSourceSupplyTask — forks', () => {
  it('a fork is never source supply; its original still is', () => {
    expect(isSourceSupplyTask(task('orig'))).toBe(true);
    expect(isSourceSupplyTask(task('fork', { forkedFromTaskId: 'orig' }))).toBe(false);
    expect(isSourceSupplyTask(task('c', { type: TaskType.COUNTING, forkedFromTaskId: 'k' }))).toBe(false);
  });
});
