import { describe, expect, it } from 'vitest';
import { TaskType, type BoardTask, type Task } from '@oybc/shared';
import { childLog, childRemove, countingLog, type Play, type WriteDeps } from '../squareWrites';

const NOW = '2026-01-01T00:00:00.000Z';
const task = (o: Partial<Task>): Task => ({
  id: 't', userId: 'u', title: 'T', type: TaskType.COUNTING, isCompleted: false, totalCompletions: 0, totalInstances: 1,
  createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false, ...o,
}) as Task;
const bt: BoardTask = { id: 'bt', boardId: 'b', taskId: 'solo', row: 0, col: 0, isCenter: false, createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false };

interface Held { key: string; delta: number }

/** A Play whose writes succeed, recording every pending hold the sheet takes. */
function fakePlay(overrides: Partial<Play> = {}): { play: Play; held: Held[]; calls: string[] } {
  const held: Held[] = [];
  const calls: string[] = [];
  const play = {
    isWriting: false, writeSeq: 0, getWriteSeq: () => 0, pendingCounts: {},
    withPending: async (key: string, delta: number, write: () => Promise<unknown>) => { held.push({ key, delta }); return write(); },
    handleSharedCounterIncrement: async (id: string, amount = 1) => { calls.push(`inc:${id}:${amount}`); return amount; },
    handleSharedCounterDecrement: async (id: string, amount = 1) => { calls.push(`dec:${id}:${amount}`); return amount; },
    undoCounterLog: async (id: string) => { calls.push(`undo:${id}`); },
    logStandaloneCount: async (_id: string, delta: number) => { calls.push(`standalone:${delta}`); return { before: 12, applied: Math.abs(delta) }; },
    handleComplete: async (_id: string, u: { currentCount?: number }) => { calls.push(`complete:${u.currentCount}`); return true; },
    handleCompoundChildIncrement: async (id: string, dir: 1 | -1, amount = 1) => { calls.push(`child:${id}:${dir}:${amount}`); return amount; },
    handleCompoundChildToggle: async () => true,
    ...overrides,
  } as unknown as Play;
  return { play, held, calls };
}

const deps = (play: Play, o: Partial<WriteDeps> = {}): WriteDeps => ({
  play, quiet: async (w) => { await w(); }, taskMap: {}, sharedCounterSourceIds: new Set(), ...o,
});

describe('countingLog holds a pending count', () => {
  it('a standalone add holds +amount on the task, and its Undo holds the reverse', async () => {
    const { play, held } = fakePlay();
    const r = await countingLog(deps(play), bt, task({ id: 'solo' }), 'add', 5, false);
    expect(held).toEqual([{ key: 'solo', delta: 5 }]);
    await r?.undo();
    expect(held[1]).toEqual({ key: 'solo', delta: -5 });
  });

  it('a standalone remove holds -amount; Undo holds +applied', async () => {
    const { play, held } = fakePlay();
    const r = await countingLog(deps(play), bt, task({ id: 'solo' }), 'remove', 3, false);
    expect(held).toEqual([{ key: 'solo', delta: -3 }]);
    await r?.undo();
    expect(held[1]).toEqual({ key: 'solo', delta: 3 });
  });

  it('a linked square holds on its counter ROOT, so every square of that counter moves', async () => {
    const { play, held, calls } = fakePlay();
    const linked = task({ id: 'row', sharedCounterId: 'root' });
    const r = await countingLog(deps(play, { sharedCounterSourceIds: new Set(['root']) }), bt, linked, 'add', 2, false);
    expect(held).toEqual([{ key: 'root', delta: 2 }]);
    expect(calls).toEqual(['inc:root:2']);
    await r?.undo();
    expect(held[1]).toEqual({ key: 'root', delta: -2 });
    expect(calls).toContain('undo:root');
  });

  it('holds nothing while another write is in flight (the re-entrancy guard)', async () => {
    const { play, held } = fakePlay({ isWriting: true });
    expect(await countingLog(deps(play), bt, task({ id: 'solo' }), 'add', 1, false)).toBeNull();
    expect(held).toEqual([]);
  });
});

describe('compound counting child holds a pending count', () => {
  const child = task({ id: 'kid' });

  it('log holds +amount on the child; Undo steps back and holds the reverse', async () => {
    const { play, held, calls } = fakePlay();
    const r = await childLog(deps(play, { taskMap: { kid: child } }), 'kid', 4, false);
    expect(held).toEqual([{ key: 'kid', delta: 4 }]);
    await r?.undo();
    expect(held[1]).toEqual({ key: 'kid', delta: -4 });
    expect(calls).toEqual(['child:kid:1:4', 'child:kid:-1:4']);
  });

  it('remove holds -amount; Undo logs back what was removed', async () => {
    const { play, held, calls } = fakePlay();
    const r = await childRemove(deps(play, { taskMap: { kid: child } }), 'kid', 3);
    expect(held).toEqual([{ key: 'kid', delta: -3 }]);
    await r?.undo();
    expect(held[1]).toEqual({ key: 'kid', delta: 3 });
    expect(calls).toEqual(['child:kid:-1:3', 'child:kid:1:3']);
  });

  it('a linked child holds on its counter root and undoes through the counter', async () => {
    const { play, held, calls } = fakePlay();
    const linked = task({ id: 'kid', sharedCounterId: 'root' });
    const r = await childLog(deps(play, { taskMap: { kid: linked }, sharedCounterSourceIds: new Set(['root']) }), 'kid', 1, false);
    expect(held[0]).toEqual({ key: 'root', delta: 1 });
    await r?.undo();
    expect(held[1]).toEqual({ key: 'root', delta: -1 });
    expect(calls).toContain('undo:root');
  });

  it('a write that applies nothing reports nothing committed', async () => {
    const { play } = fakePlay({ handleCompoundChildIncrement: async () => 0 });
    expect(await childLog(deps(play, { taskMap: { kid: child } }), 'kid', 4, false)).toBeNull();
  });
});
