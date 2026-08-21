import { describe, it, expect, afterEach } from 'vitest';
import { db } from '../../internal';
import { copyTask, copyCompound } from '../tasks.copy';
import {
  AchievementTrigger,
  OperatorType,
  TaskType,
  type Task,
  type CompoundChild,
} from '@oybc/shared';

/**
 * Coverage for the wizard "From a board…" Copy flow (`db/operations/tasks.copy.ts`).
 *
 * The copy helpers translate a (source, overrides) pair into the same
 * `createTask` / `createCompound` write a brand-new task takes. These tests pin
 * the field-inheritance/override translation, the Achievement XOR
 * reference-switch (undefined-as-clear), and the compound *shallow* copy
 * (children reference the SAME primitive child Tasks, ordered, deleted excluded).
 */

const NOW = '2026-08-01T10:00:00.000Z';

function baseTask(over: Partial<Task> = {}): Task {
  return {
    id: 'src',
    userId: 'u1',
    title: 'Source',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...over,
  } as unknown as Task;
}

afterEach(async () => {
  await Promise.all([
    db.tasks.clear(),
    db.compoundChildren.clear(),
    db.syncQueue.clear(),
  ]);
});

describe('copyTask (primitive)', () => {
  it('copies a NORMAL task, inheriting fields and applying a title override', async () => {
    const source = baseTask({ title: 'Meditate', description: 'daily' });
    const copy = await copyTask('u1', source, { title: 'Meditate (copy)' });

    expect(copy.id).not.toBe(source.id);
    expect(copy.userId).toBe('u1');
    expect(copy.type).toBe(TaskType.NORMAL);
    expect(copy.title).toBe('Meditate (copy)');
    expect(copy.description).toBe('daily'); // inherited
    // Persisted through the real createTask path.
    expect(await db.tasks.get(copy.id)).toBeTruthy();
  });

  it('copies a COUNTING task, inheriting action/unit/maxCount and overriding some', async () => {
    const source = baseTask({
      type: TaskType.COUNTING,
      title: 'Run 5 km',
      action: 'Run',
      unit: 'km',
      maxCount: 5,
    });
    const copy = await copyTask('u1', source, { maxCount: 10, action: 'Jog' });

    expect(copy.type).toBe(TaskType.COUNTING);
    expect(copy.action).toBe('Jog'); // overridden
    expect(copy.unit).toBe('km'); // inherited
    expect(copy.maxCount).toBe(10); // overridden
  });

  it('copies a board-mode ACHIEVEMENT task, inheriting trigger + referenced board when no ref override', async () => {
    // Board mode carries no requiredCount (that field is template-mode only —
    // createTask enforces it, which is why the source omits it here).
    const source = baseTask({
      type: TaskType.ACHIEVEMENT,
      title: 'Bingo on April',
      achievementTrigger: AchievementTrigger.BINGO,
      referencedBoardId: 'board-april',
    });
    const copy = await copyTask('u1', source, {});

    expect(copy.type).toBe(TaskType.ACHIEVEMENT);
    expect(copy.achievementTrigger).toBe(AchievementTrigger.BINGO);
    expect(copy.referencedBoardId).toBe('board-april'); // inherited
    expect(copy.referencedTemplateId).toBeUndefined();
  });

  it('switches an ACHIEVEMENT copy from board → template mode, clearing the other ref (undefined-as-clear)', async () => {
    const source = baseTask({
      type: TaskType.ACHIEVEMENT,
      title: 'Bingo on April',
      achievementTrigger: AchievementTrigger.BINGO,
      referencedBoardId: 'board-april',
    });
    // Touch only referencedTemplateId → both refs come from overrides, so the
    // source's referencedBoardId must be cleared (not left set, which would
    // trip the board-XOR-template refinement).
    const copy = await copyTask('u1', source, {
      referencedTemplateId: 'tmpl-monthly',
      requiredCount: 3,
    });

    expect(copy.referencedTemplateId).toBe('tmpl-monthly');
    expect(copy.referencedBoardId).toBeUndefined();
    expect(copy.requiredCount).toBe(3);
  });

  it('throws when asked to copy a compound source', async () => {
    const source = baseTask({ type: TaskType.COMPOUND, operator: OperatorType.AND });
    await expect(copyTask('u1', source)).rejects.toThrow(/compound/i);
  });
});

describe('copyCompound', () => {
  async function seedCompoundSource(): Promise<Task> {
    const childA = baseTask({ id: 'childA', title: 'Child A' });
    const childB = baseTask({ id: 'childB', title: 'Child B' });
    const childGone = baseTask({ id: 'childGone', title: 'Removed child' });
    const parent = baseTask({
      id: 'parent',
      type: TaskType.COMPOUND,
      title: 'Morning routine',
      operator: OperatorType.M_OF_N,
      threshold: 2,
    });
    await db.tasks.bulkAdd([childA, childB, childGone, parent]);

    const link = (over: Partial<CompoundChild>): CompoundChild => ({
      id: `link-${over.childTaskId}`,
      compoundTaskId: 'parent',
      childTaskId: 'x',
      childIndex: 0,
      createdAt: NOW,
      updatedAt: NOW,
      version: 1,
      isDeleted: false,
      ...over,
    });
    // Intentionally out of index order + one soft-deleted, to prove ordering
    // and deleted-filtering in the copy.
    await db.compoundChildren.bulkAdd([
      link({ childTaskId: 'childB', childIndex: 1 }),
      link({ childTaskId: 'childA', childIndex: 0 }),
      link({ childTaskId: 'childGone', childIndex: 2, isDeleted: true }),
    ]);
    return parent;
  }

  it('shallow-copies a compound: new parent id, same child Tasks in childIndex order, deleted excluded', async () => {
    const source = await seedCompoundSource();
    const copy = await copyCompound('u1', source, { title: 'Morning routine (copy)' });

    expect(copy.id).not.toBe(source.id);
    expect(copy.type).toBe(TaskType.COMPOUND);
    expect(copy.title).toBe('Morning routine (copy)');
    expect(copy.operator).toBe(OperatorType.M_OF_N);
    expect(copy.threshold).toBe(2);

    const copiedChildren = (
      await db.compoundChildren.filter((c) => c.compoundTaskId === copy.id).toArray()
    ).sort((a, b) => a.childIndex - b.childIndex);

    // Deleted source link excluded → 2 children, referencing the SAME child
    // Task ids (shallow), in order.
    expect(copiedChildren.map((c) => c.childTaskId)).toEqual(['childA', 'childB']);
    // No new child Tasks minted — the copy links the originals.
    expect(await db.tasks.get('childA')).toBeTruthy();
    expect(copiedChildren.every((c) => !c.isDeleted)).toBe(true);
  });

  it('throws on a non-compound source', async () => {
    await expect(copyCompound('u1', baseTask({ type: TaskType.NORMAL }))).rejects.toThrow(
      /compound source/i,
    );
  });

  it('throws when a compound source is missing its operator', async () => {
    const malformed = baseTask({ id: 'parent', type: TaskType.COMPOUND, operator: undefined });
    await expect(copyCompound('u1', malformed)).rejects.toThrow(/operator/i);
  });
});
