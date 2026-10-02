import { describe, expect, it } from 'vitest';
import { CenterSquareType, OperatorType, TaskType, type BoardTask, type Task } from '@oybc/shared';
import { newChildPatch, type TaskEditPatch } from '../../db/taskEditPatch';
import {
  applyOverrideForDisplay,
  overlayStagedCompounds,
  commitReorder,
  deriveCanShuffle,
  deriveCenterCellKeepLocked,
  deriveEditCount,
  isPinnedCenter,
  reorderToSlot,
  seedDraft,
  setCenterFree,
  setCenterTask,
  shuffleCells,
  stageAdd,
  stageKeyboardMove,
  stageRemove,
  stageReplace,
  stageTaskEdit,
  toggleLock,
  type SquaresEditDraftState,
} from '../squaresEditReducer';

/**
 * Board Edit redesign slice 3 (T2) — the pure squares-edit draft reducer.
 * Vitest runs `environment: 'node'` with no React renderer wired in (see
 * `vitest.config.ts`), so `useSquaresEditDraft.ts` itself is untested
 * directly — every transition it delegates to lives here instead, fully
 * framework-free.
 */

function bt(id: string, taskId: string, row: number, col: number, overrides: Partial<BoardTask> = {}): BoardTask {
  return {
    id, boardId: 'board-1', taskId, row, col, isCenter: false,
    createdAt: '', updatedAt: '', version: 1, isDeleted: false,
    ...overrides,
  };
}

describe('seedDraft', () => {
  it('seeds a 3x3 board with the effective lock baseline for a legacy CHOSEN center (D1)', () => {
    const state = seedDraft(
      [bt('bt-a', 'task-a', 0, 0), bt('bt-c', 'task-c', 1, 1, { isCenter: true })],
      CenterSquareType.CHOSEN,
      3,
    );
    const center = state.cells.find((c) => c.cellId === 'bt-c')!;
    // Effectively locked even though the raw BoardTask.isLocked is undefined.
    expect(center.isLocked).toBe(true);
    expect(center.originalLocked).toBe(true);
    const other = state.cells.find((c) => c.cellId === 'bt-a')!;
    expect(other.isLocked).toBe(false);
  });

  it('an explicit isLocked=true row is effectively locked regardless of position', () => {
    const state = seedDraft([bt('bt-a', 'task-a', 0, 0, { isLocked: true })], CenterSquareType.NONE, 3);
    expect(state.cells[0].isLocked).toBe(true);
  });
});

describe('stageAdd / stageReplace / stageRemove', () => {
  const seeded = seedDraft([bt('bt-a', 'task-a', 0, 0)], CenterSquareType.NONE, 3);

  it('stageAdd creates a cell with originalTaskId=null (an ADD, always dirty)', () => {
    const next = stageAdd(seeded, 0, 1, { taskId: 'task-b' });
    const added = next.cells.find((c) => c.row === 0 && c.col === 1)!;
    expect(added.originalTaskId).toBeNull();
    expect(added.taskId).toBe('task-b');
  });

  it('stageReplace changes taskId, keeping the cellId/original baseline', () => {
    const next = stageReplace(seeded, 'bt-a', { taskId: 'task-z' });
    expect(next.cells[0].taskId).toBe('task-z');
    expect(next.cells[0].originalTaskId).toBe('task-a');
  });

  it('stageRemove drops the cell and records it as a removal (existing placement)', () => {
    const next = stageRemove(seeded, 'bt-a');
    expect(next.cells).toHaveLength(0);
    expect(next.removedIds.has('bt-a')).toBe(true);
  });

  it('removing a staged ADD does not count as a removal (never existed live)', () => {
    const withAdd = stageAdd(seeded, 0, 1, { taskId: 'task-b' });
    const addedId = withAdd.cells.find((c) => c.row === 0 && c.col === 1)!.cellId;
    const next = stageRemove(withAdd, addedId);
    expect(next.removedIds.size).toBe(0);
  });
});

describe('toggleLock / stageTaskEdit', () => {
  it('toggles isLocked on the target cell only', () => {
    const seeded = seedDraft([bt('a', 't-a', 0, 0), bt('b', 't-b', 0, 1)], CenterSquareType.NONE, 3);
    const next = toggleLock(seeded, 'a');
    expect(next.cells.find((c) => c.cellId === 'a')!.isLocked).toBe(true);
    expect(next.cells.find((c) => c.cellId === 'b')!.isLocked).toBe(false);
  });

  it('stageTaskEdit merges into any existing override for the same taskId', () => {
    let state: SquaresEditDraftState = seedDraft([bt('a', 't-a', 0, 0)], CenterSquareType.NONE, 3);
    state = stageTaskEdit(state, 't-a', { title: 'First' });
    state = stageTaskEdit(state, 't-a', { description: 'Second' });
    expect(state.taskOverrides.get('t-a')).toEqual({ title: 'First', description: 'Second' });
  });
});

describe('commitReorder', () => {
  it('maps the new slot order back to row/col by flat index, skipping empty/center slots', () => {
    const seeded = seedDraft([bt('a', 't-a', 0, 0), bt('b', 't-b', 0, 1)], CenterSquareType.NONE, 3);
    // New order: b first (→ 0,0), then a (→ 0,1).
    const newSlots = [
      { cellId: 'b', isCenter: false, isEmpty: false },
      { cellId: 'a', isCenter: false, isEmpty: false },
      { cellId: 'empty-0-2', isCenter: false, isEmpty: true },
    ];
    const next = commitReorder(seeded, newSlots, 3);
    expect(next.cells.find((c) => c.cellId === 'b')).toMatchObject({ row: 0, col: 0 });
    expect(next.cells.find((c) => c.cellId === 'a')).toMatchObject({ row: 0, col: 1 });
  });
});

describe('reorderToSlot', () => {
  it('never moves a fixed (pinned) slot and inserts the drag item before the target, cascading the rest', () => {
    const slots = [
      { cellId: 'locked', isPinned: true },
      { cellId: 'a', isPinned: false },
      { cellId: 'b', isPinned: false },
      { cellId: 'c', isPinned: false },
    ];
    const next = reorderToSlot(slots, 'c', 1);
    // The locked slot never moves.
    expect(next[0].cellId).toBe('locked');
    // c inserted before the (movable) target index 1 → order becomes c, a, b.
    expect(next.map((s) => s.cellId)).toEqual(['locked', 'c', 'a', 'b']);
  });

  it('dropping onto an EMPTY slot is a straight swap; empties never cascade (D7, iOS parity)', () => {
    const slots = [
      { cellId: 'a', isPinned: false, isEmpty: false },
      { cellId: 'b', isPinned: false, isEmpty: false },
      { cellId: 'e', isPinned: false, isEmpty: true },
      { cellId: 'c', isPinned: false, isEmpty: false },
    ];
    expect(reorderToSlot(slots, 'a', 2).map((s) => s.cellId)).toEqual(['e', 'b', 'a', 'c']);
    // Inserting before an occupied slot cascades only the occupied movables.
    expect(reorderToSlot(slots, 'c', 0).map((s) => s.cellId)).toEqual(['c', 'a', 'e', 'b']);
  });

  it('is a no-op when the target slot is itself fixed', () => {
    const slots = [
      { cellId: 'a', isPinned: false },
      { cellId: 'locked', isPinned: true },
    ];
    expect(reorderToSlot(slots, 'a', 1)).toBe(slots);
  });
});

describe('stageKeyboardMove (D9)', () => {
  it('never moves a LOCKED source square (reducer backstop, iOS parity)', () => {
    const seeded = seedDraft([bt('a', 't-a', 0, 0, { isLocked: true })], CenterSquareType.NONE, 3);
    const { state, moved, blocked } = stageKeyboardMove(seeded, 'a', 'down', 3);
    expect(moved).toBe(false);
    expect(blocked).toBe('locked');
    expect(state.cells[0]).toMatchObject({ row: 0, col: 0 });
  });

  it('swaps a movable cell with an occupied neighbor', () => {
    const seeded = seedDraft([bt('a', 't-a', 0, 0), bt('b', 't-b', 0, 1)], CenterSquareType.NONE, 3);
    const { state, moved } = stageKeyboardMove(seeded, 'a', 'right', 3);
    expect(moved).toBe(true);
    expect(state.cells.find((c) => c.cellId === 'a')).toMatchObject({ row: 0, col: 1 });
    expect(state.cells.find((c) => c.cellId === 'b')).toMatchObject({ row: 0, col: 0 });
  });

  it('moves into an empty neighbor with no swap partner', () => {
    const seeded = seedDraft([bt('a', 't-a', 0, 0)], CenterSquareType.NONE, 3);
    const { state, moved } = stageKeyboardMove(seeded, 'a', 'down', 3);
    expect(moved).toBe(true);
    expect(state.cells[0]).toMatchObject({ row: 1, col: 0 });
  });

  it('is blocked at the grid bounds', () => {
    const seeded = seedDraft([bt('a', 't-a', 0, 0)], CenterSquareType.NONE, 3);
    const { moved, blocked } = stageKeyboardMove(seeded, 'a', 'up', 3);
    expect(moved).toBe(false);
    expect(blocked).toBe('bounds');
  });

  it('is blocked moving into a locked neighbor', () => {
    const seeded = seedDraft(
      [bt('a', 't-a', 0, 0), bt('locked', 't-b', 0, 1, { isLocked: true })],
      CenterSquareType.NONE,
      3,
    );
    const { moved, blocked } = stageKeyboardMove(seeded, 'a', 'right', 3);
    expect(moved).toBe(false);
    expect(blocked).toBe('locked');
  });

  it('is blocked moving into the pinned FREE center', () => {
    // 3x3, FREE center at (1,1) — a cell at (0,1) moving down would land on it.
    const seeded = seedDraft([bt('a', 't-a', 0, 1)], CenterSquareType.FREE, 3);
    const { moved, blocked } = stageKeyboardMove(seeded, 'a', 'down', 3);
    expect(moved).toBe(false);
    expect(blocked).toBe('locked');
  });
});

describe('shuffleCells (D10)', () => {
  it('never moves a locked cell or the pinned center; preserves the multiset of unfixed values', () => {
    const seeded = seedDraft(
      [
        bt('locked', 't-locked', 0, 0, { isLocked: true }),
        bt('a', 't-a', 0, 1),
        bt('b', 't-b', 0, 2),
        bt('c', 't-c', 2, 2),
      ],
      CenterSquareType.FREE,
      3,
    );
    const rng = (() => {
      let i = 0;
      const seq = [0.9, 0.1, 0.5];
      return () => seq[i++ % seq.length];
    })();
    const next = shuffleCells(seeded, 3, rng);
    expect(next.cells.find((c) => c.cellId === 'locked')).toMatchObject({ row: 0, col: 0 });
    expect(next.shuffled).toBe(true);
    // The center (1,1) is FREE and pinned — no cell can land there.
    expect(next.cells.some((c) => c.row === 1 && c.col === 1)).toBe(false);
    const before = new Set(seeded.cells.filter((c) => !c.isLocked).map((c) => c.cellId));
    const after = new Set(next.cells.filter((c) => !c.isLocked).map((c) => c.cellId));
    expect(after).toEqual(before);
  });
});

describe('setCenterFree / setCenterTask (D16)', () => {
  it('setCenterFree stages the removal of a task at the center and flips the type', () => {
    const seeded = seedDraft([bt('center', 't-c', 1, 1)], CenterSquareType.NONE, 3);
    const next = setCenterFree(seeded, 3);
    expect(next.draftCenterType).toBe(CenterSquareType.FREE);
    expect(next.cells).toHaveLength(0);
    expect(next.removedIds.has('center')).toBe(true);
  });

  it('setCenterTask flips FREE to NONE with an empty (addable) center', () => {
    const seeded = seedDraft([], CenterSquareType.FREE, 3);
    const next = setCenterTask(seeded);
    expect(next.draftCenterType).toBe(CenterSquareType.NONE);
    expect(next.cells).toHaveLength(0);
  });
});

describe('deriveCanShuffle (OQ8)', () => {
  it('is false with fewer than 2 unfixed slots holding a task', () => {
    const seeded = seedDraft([bt('a', 't-a', 0, 0, { isLocked: true }), bt('b', 't-b', 0, 1)], CenterSquareType.NONE, 3);
    expect(deriveCanShuffle(seeded, 3)).toBe(false);
  });

  it('is true with 2+ unfixed slots holding a task', () => {
    const seeded = seedDraft([bt('a', 't-a', 0, 0), bt('b', 't-b', 0, 1)], CenterSquareType.NONE, 3);
    expect(deriveCanShuffle(seeded, 3)).toBe(true);
  });
});

describe('deriveCenterCellKeepLocked', () => {
  it('reads the CURRENT draft lock of whichever cell occupies the center', () => {
    const seeded = seedDraft([bt('center', 't-c', 1, 1)], CenterSquareType.CHOSEN, 3);
    expect(deriveCenterCellKeepLocked(seeded, 3)).toBe(true); // effective-locked at seed
    const unlocked = toggleLock(seeded, 'center');
    expect(deriveCenterCellKeepLocked(unlocked, 3)).toBe(false);
  });

  it('defaults to true (the effective baseline) when the board had no center placement', () => {
    const seeded = seedDraft([], CenterSquareType.NONE, 3);
    expect(deriveCenterCellKeepLocked(seeded, 3)).toBe(true);
  });

  it('follows the ORIGINAL center placement, not whatever cell now sits at the center (iOS parity)', () => {
    // Legacy CHOSEN: unlock the center, move it out, move `x` in, then re-lock
    // the original center elsewhere — keepLocked must be the ORIGINAL row's
    // lock (true), since `normalizeLegacyChosenCenter` writes THAT row.
    let s = seedDraft([bt('center', 't-c', 1, 1), bt('x', 't-x', 0, 0)], CenterSquareType.CHOSEN, 3);
    s = toggleLock(s, 'center');
    s = stageKeyboardMove(s, 'center', 'up', 3).state; // center → (0,1)
    s = stageKeyboardMove(s, 'x', 'right', 3).state; // x (0,0) swaps with center → x at (0,1), center at (0,0)
    s = stageKeyboardMove(s, 'x', 'down', 3).state; // x → (1,1)
    s = toggleLock(s, 'center');
    expect(s.cells.find((c) => c.cellId === 'x')).toMatchObject({ row: 1, col: 1, isLocked: false });
    expect(deriveCenterCellKeepLocked(s, 3)).toBe(true);
  });
});

describe('isPinnedCenter', () => {
  it('is true only for FREE (CHOSEN/NONE are not pinned, D1)', () => {
    expect(isPinnedCenter(CenterSquareType.FREE)).toBe(true);
    expect(isPinnedCenter(CenterSquareType.NONE)).toBe(false);
    expect(isPinnedCenter(CenterSquareType.CHOSEN)).toBe(false);
  });
});

describe('shuffled flag (D11 — "false when positions return to baseline")', () => {
  it('clears once a later move returns every cell to baseline, so later hold-moves count per cell', () => {
    const seeded = seedDraft([bt('a', 't-a', 0, 0), bt('b', 't-b', 0, 2)], CenterSquareType.NONE, 3);
    const shuffled = shuffleCells(seeded, 3, () => 0);
    expect(shuffled.shuffled).toBe(true);
    const baselineSlots = Array.from({ length: 9 }, (_, i) =>
      i === 0 ? { cellId: 'a', isCenter: false, isEmpty: false }
        : i === 2 ? { cellId: 'b', isCenter: false, isEmpty: false }
          : { cellId: `empty-${i}`, isCenter: false, isEmpty: true },
    );
    const restored = commitReorder(shuffled, baselineSlots, 3);
    expect(restored.shuffled).toBe(false);
    let s = stageKeyboardMove(restored, 'a', 'down', 3).state;
    s = stageKeyboardMove(s, 'b', 'down', 3).state;
    expect(deriveEditCount({ state: s, boardCenterType: CenterSquareType.NONE })).toBe(2);
  });
});

describe('deriveEditCount (D11)', () => {
  it('an untouched legacy CHOSEN board has a baseline of 0 (D1)', () => {
    const seeded = seedDraft([bt('center', 't-c', 1, 1)], CenterSquareType.CHOSEN, 3);
    expect(deriveEditCount({ state: seeded, boardCenterType: CenterSquareType.CHOSEN })).toBe(0);
  });

  it('add / remove / center-toggle each count as one edit', () => {
    const seeded = seedDraft([bt('a', 't-a', 0, 0)], CenterSquareType.NONE, 3);

    const added = stageAdd(seeded, 0, 1, { taskId: 't-b' });
    expect(deriveEditCount({ state: added, boardCenterType: CenterSquareType.NONE })).toBe(1);

    const removed = stageRemove(seeded, 'a');
    expect(deriveEditCount({ state: removed, boardCenterType: CenterSquareType.NONE })).toBe(1);

    const centered = setCenterFree(seeded, 3);
    expect(deriveEditCount({ state: centered, boardCenterType: CenterSquareType.NONE })).toBe(1);
  });

  it('Free toggle with a task at the center is ONE edit — the implied removal folds in (D11, iOS parity)', () => {
    const seeded = seedDraft([bt('center', 't-c', 1, 1)], CenterSquareType.NONE, 3);
    const next = setCenterFree(seeded, 3);
    // The removal IS still staged (Save tombstones the placement) …
    expect([...next.removedIds]).toEqual(['center']);
    // … but D11: "The center Free ⇄ task toggle is ONE edit, even though Free
    // drops the center placement." ONE user action → ONE edit.
    expect(deriveEditCount({ state: next, boardCenterType: CenterSquareType.NONE })).toBe(1);
  });

  it('a plain Remove of the center task (no Free toggle) still counts as a removal', () => {
    const seeded = seedDraft([bt('center', 't-c', 1, 1)], CenterSquareType.NONE, 3);
    const removed = stageRemove(seeded, 'center');
    expect(deriveEditCount({ state: removed, boardCenterType: CenterSquareType.NONE })).toBe(1);
  });

  it('locking a staged ADD is part of the one add edit, not a second edit (iOS parity)', () => {
    const seeded = seedDraft([], CenterSquareType.NONE, 3);
    const added = stageAdd(seeded, 0, 0, { taskId: 't-new' });
    const locked = toggleLock(added, added.cells[0].cellId);
    expect(deriveEditCount({ state: locked, boardCenterType: CenterSquareType.NONE })).toBe(1);
  });

  it('Shuffle counts as ONE edit; reverting every cell to baseline goes back to 0', () => {
    const seeded = seedDraft([bt('a', 't-a', 0, 0), bt('b', 't-b', 0, 2)], CenterSquareType.NONE, 3);
    // rng ≡ 0 deterministically rotates the unfixed slots, so something moves.
    const shuffled = shuffleCells(seeded, 3, () => 0);
    expect(shuffled.cells.some((c) => c.row !== c.originalRow || c.col !== c.originalCol)).toBe(true);
    expect(deriveEditCount({ state: shuffled, boardCenterType: CenterSquareType.NONE })).toBe(1);
    // Manually restore every cell to its original position: back to 0 even
    // though `shuffled` stays true (the formula gates on movedCount, not the flag).
    const restored: SquaresEditDraftState = {
      ...shuffled,
      cells: shuffled.cells.map((c) => ({ ...c, row: c.originalRow, col: c.originalCol })),
    };
    expect(deriveEditCount({ state: restored, boardCenterType: CenterSquareType.NONE })).toBe(0);
  });
});

describe('compound overrides (Board Edit — edit / convert to compound)', () => {
  const patch = (titles: string[], over: Partial<TaskEditPatch> = {}): TaskEditPatch => ({
    title: 'Combo', action: '', goal: '', unit: '',
    children: titles.map((t) => ({ ...newChildPatch(false), title: t })),
    operator: OperatorType.AND,
    ...over,
  });
  const base: Task = {
    id: 't1', userId: 'u', title: 'Walk', type: TaskType.NORMAL,
    isCompleted: false, totalCompletions: 0, totalInstances: 0,
    createdAt: '', updatedAt: '', version: 1, isDeleted: false,
  };

  it('stageTaskEdit merges plain fields and REPLACES `compound` wholesale', () => {
    const s0 = seedDraft([bt('bt-a', 'task-a', 0, 0)], CenterSquareType.NONE, 3);
    const s1 = stageTaskEdit(s0, 'task-a', { title: 'A', type: TaskType.COMPOUND, compound: patch(['x', 'y', 'z']) });
    const s2 = stageTaskEdit(s1, 'task-a', { compound: patch(['only']) });
    const o = s2.taskOverrides.get('task-a')!;
    expect(o.title).toBe('A');
    expect(o.type).toBe(TaskType.COMPOUND);
    expect(o.compound!.children.map((c) => c.title)).toEqual(['only']);
  });

  it('a later override without compound keeps the staged compound', () => {
    const s0 = seedDraft([bt('bt-a', 'task-a', 0, 0)], CenterSquareType.NONE, 3);
    const s1 = stageTaskEdit(s0, 'task-a', { type: TaskType.COMPOUND, compound: patch(['x', 'y']) });
    const s2 = stageTaskEdit(s1, 'task-a', { title: 'Renamed' });
    expect(s2.taskOverrides.get('task-a')!.compound!.children).toHaveLength(2);
  });

  it('applyOverrideForDisplay shows the type switch and the staged compound rule/title', () => {
    const shown = applyOverrideForDisplay(base, {
      type: TaskType.COMPOUND,
      compound: patch(['x', 'y'], { title: 'Combo', operator: OperatorType.OR }),
    });
    expect(shown).toMatchObject({ type: TaskType.COMPOUND, title: 'Combo', operator: OperatorType.OR });
    expect(applyOverrideForDisplay(base, undefined)).toBe(base);
  });

  it('overlayStagedCompounds renders a converted task as a compound with placeholder children', () => {
    const o = new Map([['t1', { type: TaskType.COMPOUND, compound: patch(['x', 'y']) }]]);
    const { tasks, children } = overlayStagedCompounds(o, { t1: base }, {}, 'u');
    expect(children.t1).toHaveLength(2);
    for (const link of children.t1) expect(tasks[link.childTaskId]?.title).toBeTruthy();
    expect(children.t1.map((l) => tasks[l.childTaskId].title)).toEqual(['x', 'y']);
  });

  it('overlayStagedCompounds is a no-op without staged compounds', () => {
    const tasks = { t1: base };
    const out = overlayStagedCompounds(new Map([['t1', { title: 'x' }]]), tasks, {}, 'u');
    expect(out.tasks).toBe(tasks);
  });

  it('the dirty edit count is keyed on override presence (a compound override counts as one edit)', () => {
    const s0 = seedDraft([bt('bt-a', 'task-a', 0, 0)], CenterSquareType.NONE, 3);
    const s1 = stageTaskEdit(s0, 'task-a', { type: TaskType.COMPOUND, compound: patch(['x', 'y']) });
    expect(deriveEditCount({ state: s1, boardCenterType: CenterSquareType.NONE })).toBe(1);
  });
});
