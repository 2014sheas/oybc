import { describe, expect, it } from 'vitest';
import { OperatorType, TaskType } from '@oybc/shared';
import { compoundSubmitFor, compoundStructureChanged } from '../compoundEditGate';
import { emptyPatch, newChildPatch, type ChildPatch, type TaskEditPatch } from '../../../db/taskEditPatch';

/**
 * The Task Detail sheet only routes through the compound-structure save when
 * the rule / sub-tasks actually changed. A compound whose STORED structure
 * already fails validation (one child left, a stale threshold, zero
 * children) must still be renameable / re-describable via the basic route.
 */

function child(id: string, title: string): ChildPatch {
  return { id, childTaskId: id, title, isCounting: false, childType: TaskType.NORMAL, action: '', goal: '', unit: '', markedDeleted: false };
}

const ONE_CHILD: TaskEditPatch = {
  ...emptyPatch('Workout'),
  operator: OperatorType.AND,
  children: [child('c-1', 'Pushups')],
};

describe('compoundSubmitFor', () => {
  it('omits the structure for a title-only edit of an already-invalid compound', () => {
    // The draft CompoundFields hands back carries the sheet title.
    const draft = { ...ONE_CHILD, title: 'Workout (renamed)' };
    expect(compoundSubmitFor(ONE_CHILD, draft, 'Workout (renamed)')).toBeUndefined();
  });

  it('omits the structure while the draft is still loading', () => {
    expect(compoundSubmitFor(null, null, 'Workout')).toBeUndefined();
  });

  it('submits the structure (titled from the sheet) once a sub-task is added', () => {
    const draft = { ...ONE_CHILD, children: [...ONE_CHILD.children, { ...newChildPatch(false), title: 'Squats' }] };
    const submitted = compoundSubmitFor(ONE_CHILD, draft, '  Leg day ');
    expect(submitted).toBeDefined();
    expect(submitted?.title).toBe('Leg day');
    expect(submitted?.children).toHaveLength(2);
  });

  it('submits the structure when only the rule changed', () => {
    const draft = { ...ONE_CHILD, operator: OperatorType.OR };
    expect(compoundSubmitFor(ONE_CHILD, draft, 'Workout')).toBeDefined();
  });
});

describe('compoundStructureChanged', () => {
  it('ignores the title', () => {
    expect(compoundStructureChanged(ONE_CHILD, { ...ONE_CHILD, title: 'Other' })).toBe(false);
  });

  it('is false until both baseline and draft exist', () => {
    expect(compoundStructureChanged(null, ONE_CHILD)).toBe(false);
    expect(compoundStructureChanged(ONE_CHILD, null)).toBe(false);
  });

  it('sees a sub-task title edit', () => {
    expect(
      compoundStructureChanged(ONE_CHILD, { ...ONE_CHILD, children: [child('c-1', 'Push-ups')] }),
    ).toBe(true);
  });
});
