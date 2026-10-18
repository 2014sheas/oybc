import { describe, expect, it } from 'vitest';
import { TaskType, type BoardTask, type Task } from '@oybc/shared';
import { childLog, childRemove, childToggle, countingLog, type Play, type WriteDeps } from '../squareWrites';

const NOW = '2026-01-01T00:00:00.000Z';
const task = (o: Partial<Task>): Task => ({
  id: 't', userId: 'u', title: 'T', type: TaskType.COUNTING, isCompleted: false, totalCompletions: 0, totalInstances: 1,
  createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false, ...o,
}) as Task;
const bt: BoardTask = { id: 'bt', boardId: 'b', taskId: 'solo', row: 0, col: 0, isCenter: false, createdAt: NOW, updatedAt: NOW, version: 1, isDeleted: false };

interface Held { key: string; delta: number; committed: (r: never) => boolean }

/** A Play whose writes succeed, recording every pending hold the sheet takes. */
function fakePlay(overrides: Partial<Play> = {}): { play: Play; held: Held[]; calls: string[] } {
  const held: Held[] = [];
  const calls: string[] = [];
  const play = {
    isWriting: false, writeSeq: 0, getWriteSeq: () => 0, pendingCounts: {},
    withPending: async (key: string, delta: number, write: () => Promise<unknown>, committed: (r: never) => boolean) => { held.push({ key, delta, committed }); return write(); },
    handleSharedCounterIncrement: async (id: string, amount = 1) => { calls.push(`inc:${id}:${amount}`); return amount; },
    handleSharedCounterDecrement: async (id: string, amount = 1) => { calls.push(`dec:${id}:${amount}`); return amount; },
    undoCounterLog: async (id: string) => { calls.push(`undo:${id}`); return true; },
    logStandaloneCount: async (_id: string, delta: number) => { calls.push(`standalone:${delta}`); return { before: 12, applied: Math.abs(delta) }; },
    handleComplete: async (_id: string, u: { currentCount?: number }) => { calls.push(`complete:${u.currentCount}`); return true; },
    handleCompoundChildIncrement: async (id: string, dir: 1 | -1, amount = 1) => { calls.push(`child:${id}:${dir}:${amount}`); return amount; },
    handleCompoundChildToggle: async () => true,
    ...overrides,
  } as unknown as Play;
  return { play, held, calls };
}

const keyed = (held: Held[]): Array<{ key: string; delta: number }> => held.map(({ key, delta }) => ({ key, delta }));

const deps = (play: Play, o: Partial<WriteDeps> = {}): WriteDeps => ({
  play, quiet: async (w) => { await w(); }, taskMap: {}, sharedCounterSourceIds: new Set(), ...o,
});

describe('countingLog holds a pending count', () => {
  it('a standalone add holds +amount on the task, and its Undo holds the reverse', async () => {
    const { play, held } = fakePlay();
    const r = await countingLog(deps(play), bt, task({ id: 'solo' }), 'add', 5, false);
    expect(keyed(held)).toEqual([{ key: 'solo', delta: 5 }]);
    await r?.undo();
    expect(keyed(held)[1]).toEqual({ key: 'solo', delta: -5 });
  });

  it('a standalone remove holds -amount; Undo holds +applied', async () => {
    const { play, held } = fakePlay();
    const r = await countingLog(deps(play), bt, task({ id: 'solo' }), 'remove', 3, false);
    expect(keyed(held)).toEqual([{ key: 'solo', delta: -3 }]);
    await r?.undo();
    expect(keyed(held)[1]).toEqual({ key: 'solo', delta: 3 });
  });

  it('a linked square holds on its counter ROOT, so every square of that counter moves', async () => {
    const { play, held, calls } = fakePlay();
    const linked = task({ id: 'row', sharedCounterId: 'root' });
    const r = await countingLog(deps(play, { sharedCounterSourceIds: new Set(['root']) }), bt, linked, 'add', 2, false);
    expect(keyed(held)).toEqual([{ key: 'root', delta: 2 }]);
    expect(calls).toEqual(['inc:root:2']);
    await r?.undo();
    expect(keyed(held)[1]).toEqual({ key: 'root', delta: -2 });
    expect(calls).toContain('undo:root');
  });

  it('holds nothing while another write is in flight (the re-entrancy guard)', async () => {
    const { play, held } = fakePlay({ isWriting: true });
    expect(await countingLog(deps(play), bt, task({ id: 'solo' }), 'add', 1, false)).toBeNull();
    expect(keyed(held)).toEqual([]);
  });
});

describe('compound counting child holds a pending count', () => {
  const child = task({ id: 'kid' });

  it('log holds +amount on the child; Undo steps back and holds the reverse', async () => {
    const { play, held, calls } = fakePlay();
    const r = await childLog(deps(play, { taskMap: { kid: child } }), 'kid', 4, false);
    expect(keyed(held)).toEqual([{ key: 'kid', delta: 4 }]);
    await r?.undo();
    expect(keyed(held)[1]).toEqual({ key: 'kid', delta: -4 });
    expect(calls).toEqual(['child:kid:1:4', 'child:kid:-1:4']);
  });

  it('remove holds -amount; Undo logs back what was removed', async () => {
    const { play, held, calls } = fakePlay();
    const r = await childRemove(deps(play, { taskMap: { kid: child } }), 'kid', 3);
    expect(keyed(held)).toEqual([{ key: 'kid', delta: -3 }]);
    await r?.undo();
    expect(keyed(held)[1]).toEqual({ key: 'kid', delta: 3 });
    expect(calls).toEqual(['child:kid:-1:3', 'child:kid:1:3']);
  });

  it('a linked child holds on its counter root and undoes through the counter', async () => {
    const { play, held, calls } = fakePlay();
    const linked = task({ id: 'kid', sharedCounterId: 'root' });
    const r = await childLog(deps(play, { taskMap: { kid: linked }, sharedCounterSourceIds: new Set(['root']) }), 'kid', 1, false);
    expect(keyed(held)[0]).toEqual({ key: 'root', delta: 1 });
    await r?.undo();
    expect(keyed(held)[1]).toEqual({ key: 'root', delta: -1 });
    expect(calls).toContain('undo:root');
  });

  it('a write that applies nothing reports nothing committed', async () => {
    const { play } = fakePlay({ handleCompoundChildIncrement: async () => 0 });
    expect(await childLog(deps(play, { taskMap: { kid: child } }), 'kid', 4, false)).toBeNull();
  });
});

/** The predicate each hold passes decides whether its pending count is kept or rolled back. */
describe('committed predicates', () => {
  const ok = (h: Held, result: unknown): boolean => (h.committed as (r: unknown) => boolean)(result);

  it('a shared log / removal commits only when an amount was applied', async () => {
    const { play, held } = fakePlay();
    await countingLog(deps(play, { sharedCounterSourceIds: new Set(['root']) }), bt, task({ id: 'row', sharedCounterId: 'root' }), 'add', 2, false);
    expect(ok(held[0], 2)).toBe(true);
    expect(ok(held[0], 0)).toBe(false);
  });

  it('a standalone log commits unless the write reported nothing (null)', async () => {
    const { play, held } = fakePlay();
    await countingLog(deps(play), bt, task({ id: 'solo' }), 'add', 5, false);
    expect(ok(held[0], { before: 12, applied: 5 })).toBe(true);
    expect(ok(held[0], null)).toBe(false);
  });

  it('a counter Undo commits only when something was reversed (nothing to undo rolls the count back)', async () => {
    const { play, held } = fakePlay();
    const linked = task({ id: 'row', sharedCounterId: 'root' });
    const r = await countingLog(deps(play, { sharedCounterSourceIds: new Set(['root']) }), bt, linked, 'add', 2, false);
    await r?.undo();
    expect(ok(held[1], true)).toBe(true);
    expect(ok(held[1], false)).toBe(false);
  });

  it('a standalone Undo commits only when the restore write committed', async () => {
    const { play, held } = fakePlay();
    const r = await countingLog(deps(play), bt, task({ id: 'solo' }), 'add', 5, false);
    await r?.undo();
    expect(ok(held[1], true)).toBe(true);
    expect(ok(held[1], false)).toBe(false);
  });

  it('a child step commits only when an amount was applied; its Undo likewise', async () => {
    const { play, held } = fakePlay();
    const r = await childLog(deps(play, { taskMap: { kid: task({ id: 'kid' }) } }), 'kid', 4, false);
    await r?.undo();
    expect(ok(held[0], 4)).toBe(true);
    expect(ok(held[0], 0)).toBe(false);
    expect(ok(held[1], true)).toBe(true);
    expect(ok(held[1], false)).toBe(false);
  });

  it('a linked child Undo goes through the counter and commits only when it reversed something', async () => {
    const { play, held } = fakePlay();
    const linked = task({ id: 'kid', sharedCounterId: 'root' });
    const r = await childLog(deps(play, { taskMap: { kid: linked }, sharedCounterSourceIds: new Set(['root']) }), 'kid', 1, false);
    await r?.undo();
    expect(ok(held[1], true)).toBe(true);
    expect(ok(held[1], false)).toBe(false);
  });
});

describe('childToggle (C8)', () => {
  it('its Undo runs QUIET like the forward write, so it never raises the credited toast', async () => {
    const quietDepth: number[] = [];
    let depth = 0;
    const toggles: Array<[string, boolean | undefined, number]> = [];
    const { play } = fakePlay({
      handleCompoundChildToggle: (async (id: string, to?: boolean) => { toggles.push([id, to, depth]); return to ?? true; }) as Play['handleCompoundChildToggle'],
    });
    const d = deps(play, { quiet: async (w) => { depth += 1; quietDepth.push(depth); try { await w(); } finally { depth -= 1; } } });

    const r = await childToggle(d, 'kid');
    expect(r?.to).toBe(true);
    expect(await r?.undo()).toBe(true);
    // forward toggle (undefined target) and the reversal (to=false) both ran inside `quiet`
    expect(toggles).toEqual([['kid', undefined, 1], ['kid', false, 1]]);
    expect(quietDepth).toEqual([1, 1]);
  });

  it('an Undo the hook refused (null) reports false', async () => {
    let n = 0;
    const { play } = fakePlay({ handleCompoundChildToggle: (async () => (n++ === 0 ? true : null)) as Play['handleCompoundChildToggle'] });
    const r = await childToggle(deps(play), 'kid');
    expect(await r?.undo()).toBe(false);
  });
});
