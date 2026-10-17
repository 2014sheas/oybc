import { describe, expect, it } from 'vitest';
import { TaskType } from '@oybc/shared';
import { buildSquareMenu, menuNextPreset, menuQuickAmount, type MenuChild, type SquareMenuInput } from '../squareMenuItems';

const base: SquareMenuInput = { type: 'normal', title: 'T', closed: false, lateLogRoutable: true, done: false };

/** Items as `label` / `label|meta`, dividers as `---`. */
const lines = (input: Partial<SquareMenuInput>): string[] =>
  buildSquareMenu({ ...base, ...input }).entries.map((e) => (e === 'divider' ? '---' : e.meta ? `${e.label}|${e.meta}` : e.label));

const counting = (o: Partial<NonNullable<SquareMenuInput['counting']>> = {}): SquareMenuInput['counting'] =>
  ({ count: 12, goal: 20, kind: 'discrete', unit: 'pages', ...o });

describe('quick amount + next preset', () => {
  it('standalone with no default → 1; a remembered default wins', () => {
    expect(menuQuickAmount('discrete')).toBe(1);
    expect(menuQuickAmount('discrete', 5)).toBe(5);
    expect(menuQuickAmount('continuous')).toBe(0.5);
    expect(menuQuickAmount('duration')).toBe(15);
  });
  it('next FIXED preset strictly above, none past the last', () => {
    expect(menuNextPreset('discrete', 1)).toBe(10);
    expect(menuNextPreset('discrete', 5)).toBe(10);
    expect(menuNextPreset('discrete', 10)).toBe(25);
    expect(menuNextPreset('discrete', 25)).toBeUndefined();
    expect(menuNextPreset('continuous', 3.1)).toBe(5);
    expect(menuNextPreset('duration', 15)).toBe(30);
  });
});

describe('hold menu vocabulary', () => {
  it('Normal', () => {
    expect(lines({})).toEqual(['Mark done', '---', 'Details', 'Open in library']);
    expect(lines({ done: true })).toEqual(['Mark not done', '---', 'Details', 'Open in library']);
    expect(buildSquareMenu(base).meta).toBe('Not done');
    expect(buildSquareMenu({ ...base, done: true }).meta).toBe('Done');
  });

  it('Normal: un-completing is disabled only when a sealed window holds it', () => {
    const [first] = buildSquareMenu({ ...base, done: true, uncompleteBlocked: true }).entries;
    expect(first).toMatchObject({ label: 'Mark not done', disabled: true });
    expect(buildSquareMenu({ ...base, uncompleteBlocked: true }).entries[0]).not.toMatchObject({ disabled: true });
    // Still loading (undefined) reads as blocked until the seal check resolves.
    expect(buildSquareMenu({ ...base, done: true }).entries[0]).toMatchObject({ disabled: true });
    expect(buildSquareMenu({ ...base, done: true, uncompleteBlocked: false }).entries[0]).not.toMatchObject({ disabled: true });
  });

  it('Counting: quick, next preset, other, remove, details, library', () => {
    expect(lines({ type: 'counting', counting: counting({ defaultAmount: 5 }) })).toEqual([
      'Log +5 pages', 'Log +10 pages', 'Log other amount…', '---', 'Remove pages…', '---', 'Details', 'Open in library',
    ]);
    expect(buildSquareMenu({ ...base, type: 'counting', counting: counting() }).meta).toBe('12 / 20');
  });

  it('Counting: no default → +1; the last preset omits the next item; duration carries no unit', () => {
    expect(lines({ type: 'counting', counting: counting() })[0]).toBe('Log +1 pages');
    expect(lines({ type: 'counting', counting: counting({ defaultAmount: 25 }) })).not.toContain('Log +50 pages');
    expect(lines({ type: 'counting', counting: counting({ defaultAmount: 25 }) }).filter((l) => l.startsWith('Log +'))).toEqual(['Log +25 pages']);
    const d = lines({ type: 'counting', counting: counting({ kind: 'duration', unit: '', count: 270, goal: 630 }) });
    expect(d.slice(0, 2)).toEqual(['Log +15m', 'Log +30m']);
    expect(d).toContain('Remove…');
  });

  it('Counting: Remove is disabled at zero; the first item is the write that logs', () => {
    const m = buildSquareMenu({ ...base, type: 'counting', counting: counting({ count: 0 }) });
    expect(m.entries.find((e) => e !== 'divider' && e.id === 'remove')).toMatchObject({ disabled: true });
    expect(m.entries[0]).toMatchObject({ id: 'log', write: true });
    // Only the sheet-opening entries stay enabled while busy: they are not writes.
    expect(m.entries.find((e) => e !== 'divider' && e.id === 'logOther')).toMatchObject({ write: false });
    expect(m.entries.find((e) => e !== 'divider' && e.id === 'remove')).toMatchObject({ write: false });
  });

  const kid = (id: string, o: Partial<MenuChild> = {}): MenuChild => ({ id, title: id, type: TaskType.NORMAL, isCompleted: false, ...o });
  const countKid = (id: string, o: Partial<MenuChild> = {}): MenuChild =>
    kid(id, { type: TaskType.COUNTING, count: { kind: 'discrete', unit: 'pages', defaultAmount: 5 }, ...o });

  it('Compound: complete next sub-task names the child; counting-only → Log + · child', () => {
    expect(lines({ type: 'compound', compound: { children: [kid('Walk', { isCompleted: true }), kid('Stretch'), countKid('Read')] } })).toEqual([
      'Complete next sub-task|Stretch', 'All sub-tasks…|1 / 3', '---', 'Open in library',
    ]);
    expect(lines({ type: 'compound', compound: { children: [kid('Walk', { isCompleted: true }), countKid('Read')] } })).toEqual([
      'Log +5 pages · Read', 'All sub-tasks…|1 / 2', '---', 'Open in library',
    ]);
  });

  it('Compound: nothing open leaves only the checklist and library', () => {
    expect(lines({ type: 'compound', compound: { children: [kid('Walk', { isCompleted: true })] } })).toEqual(['All sub-tasks…|1 / 1', '---', 'Open in library']);
    expect(buildSquareMenu({ ...base, type: 'compound', compound: { children: [kid('a'), kid('b')] } }).meta).toBe('0 / 2');
  });

  it('Achievement: Open ‹board› only for a single watched board', () => {
    expect(lines({ type: 'achievement', watchedBoardName: 'October' })).toEqual(['Open October', '---', 'Details', 'Open in library']);
    expect(lines({ type: 'achievement', watchedBoardName: null })).toEqual(['Details', 'Open in library']);
    expect(buildSquareMenu({ ...base, type: 'achievement' }).meta).toBe('Watching');
  });
});

describe('closed board collapse', () => {
  it('every write item becomes one gold "Late log…" with a lock', () => {
    const closed = { closed: true };
    expect(lines({ ...closed })).toEqual(['Late log…', '---', 'Details', 'Open in library']);
    expect(lines({ ...closed, type: 'counting', counting: counting({ defaultAmount: 5 }) })).toEqual(['Late log…', '---', 'Details', 'Open in library']);
    expect(lines({ ...closed, type: 'compound', compound: { children: [{ id: 'a', title: 'a', type: TaskType.NORMAL, isCompleted: false }] } }))
      .toEqual(['Late log…', '---', 'All sub-tasks…|0 / 1', '---', 'Open in library']);
    expect(buildSquareMenu({ ...base, closed: true }).entries[0]).toMatchObject({ icon: 'lock', write: false });
  });
  it('without a late-log route the write items simply vanish', () => {
    expect(lines({ closed: true, lateLogRoutable: false })).toEqual(['Details', 'Open in library']);
    expect(lines({ closed: true, lateLogRoutable: false, type: 'achievement', watchedBoardName: 'October' })).toEqual(['Open October', '---', 'Details', 'Open in library']);
  });
  it('an achievement keeps Open ‹board› on a closed board', () => {
    expect(lines({ closed: true, lateLogRoutable: false, type: 'achievement', watchedBoardName: 'October' })[0]).toBe('Open October');
  });
});
