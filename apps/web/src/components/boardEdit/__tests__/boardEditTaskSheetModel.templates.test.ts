import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { buildSheetOverride, seedSheetTitle, type SheetInput } from '../boardEditTaskSheetModel';
import { planKindSwitchPreview } from '../../../db/operations/countKindSwitch';
import { applyPatchToTask, seedPatchForEditor } from '../../../db/taskEditPatch';

/**
 * docs/SHARED_COUNTER_SETTINGS.md §1b hand-off (PR 2): copy-side titles read
 * the counter ROOT's templates — a title rendered from them is auto (seeds
 * blank, follows a goal or kind change), a custom one stays.
 */

const root = { titleTemplateSingular: 'Read #N book', titleTemplatePlural: 'Read #N novels' };
/** A per-board copy of the "Read" counter, titled from the root's template. */
const copy = {
  id: 'cp',
  type: TaskType.COUNTING,
  title: 'Read 5 novels',
  action: 'Read',
  unit: 'books',
  maxCount: 5,
  sharedCounterId: 'root',
} as Task;
const input = (o: Partial<SheetInput>): SheetInput => ({
  original: copy,
  selected: TaskType.COUNTING,
  title: '',
  action: 'Read',
  goalStr: '3',
  unit: 'books',
  countKind: 'discrete',
  compoundDraft: null,
  compoundBaseline: null,
  rootSettings: root,
  ...o,
});

describe('Board Edit sheet — copy titles through the root templates', () => {
  it('a template-rendered copy title seeds blank (auto)', () => {
    expect(seedSheetTitle(copy, root)).toBe('');
  });
  it('without the root it reads as custom (the PR 1 gap this closes)', () => {
    expect(seedSheetTitle(copy)).toBe('Read 5 novels');
  });
  it('a custom copy title seeds verbatim', () => {
    expect(seedSheetTitle({ ...copy, title: 'My novels' }, root)).toBe('My novels');
  });
  it('a goal change re-renders the blank title through the template', () => {
    expect(buildSheetOverride(input({ goalStr: '3' })).title).toBe('Read 3 novels');
    expect(buildSheetOverride(input({ goalStr: '1' })).title).toBe('Read 1 book');
  });
  it('a typed custom title is kept', () => {
    expect(buildSheetOverride(input({ title: 'Books!' })).title).toBe('Books!');
  });
});

describe('kind switch preview — through the root templates', () => {
  const rootTask = {
    ...copy,
    id: 'root',
    sharedCounterId: undefined,
    title: 'Run 2.5 laps',
    action: 'Run',
    unit: 'km',
    maxCount: 2.5,
    countKind: 'continuous',
    titleTemplatePlural: 'Run #N laps',
  } as Task;
  it('an auto (template) title follows the rounding', () => {
    expect(planKindSwitchPreview(rootTask, 'discrete', 0)?.titleAfter).toBe('Run 3 laps');
  });
  it('a copy previews through the root settings passed in', () => {
    const c = { ...rootTask, id: 'c', titleTemplatePlural: undefined, sharedCounterId: 'root' } as Task;
    expect(planKindSwitchPreview(c, 'discrete', 0, { titleTemplatePlural: 'Run #N laps' })?.titleAfter).toBe('Run 3 laps');
    expect(planKindSwitchPreview(c, 'discrete', 0)?.titleAfter).toBe('Run 2.5 laps');
  });
});

describe('task edit patch — a root with templates', () => {
  const r = { ...copy, id: 'root', sharedCounterId: undefined, ...root } as Task;
  it('seeds a template-rendered title blank and re-renders it on a goal change', () => {
    const seeded = seedPatchForEditor(r);
    expect(seeded.title).toBe('');
    expect(applyPatchToTask({ ...seeded, goal: '8' }, r).title).toBe('Read 8 novels');
  });
});
