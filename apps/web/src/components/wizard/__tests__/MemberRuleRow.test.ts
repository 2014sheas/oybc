import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import {
  TaskType,
  Timeframe,
  varyRangeLabel,
  type BoardWindow,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import { MemberRuleRow } from '../MemberRuleRow';

/**
 * The member row is the rule-authoring surface of the wizard's expanded
 * source panel (docs/BOARD_SOURCES.md §Member rules; handoff "Expanded
 * source panel" item 3). What these tests pin:
 *
 * - the target stepper shows the PRO-RATED target (a weekly source read
 *   into a daily board), with the "of {goal} {unit}" caption beside it —
 *   the caption never tracks the override (there is no reset affordance);
 * - a POOL member has no window to pro-rate against, so it gets the dice
 *   alone (B3 RC5);
 * - the blue range line is exactly `varyRangeLabel`'s output — a second
 *   formatting of the same range here is how the two drift apart;
 * - the compound shapes: One square (pill + note + ONE dice), Split up
 *   (part lines with per-part dice/✕, excluded part struck + UNDO), and a
 *   childless compound (no toggle at all, B3 RC10).
 *
 * Rendered with `react-dom/server` — no jsdom/RTL harness in this repo
 * (see `BoardSetupForm.test.ts`). Clicks/typing are Playwright's job.
 */

const NOW = '2026-09-18T00:00:00.000Z';

/** The board being assembled: a daily window. */
const DAILY_WINDOW: BoardWindow = {
  timeframe: Timeframe.DAILY,
  startDate: '2026-09-18',
  endDate: '2026-09-18',
};
/** The source board: a weekly window — 7 nominal days to pro-rate over. */
const WEEKLY_SOURCE: BoardWindow = {
  timeframe: Timeframe.WEEKLY,
  startDate: '2026-09-14',
  endDate: '2026-09-20',
};

function makeTask(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: 'user-1',
    title: `Task ${id}`,
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
    ...over,
  };
}

function makeChild(parentId: string, childTaskId: string, childIndex: number): CompoundChild {
  return {
    id: `${parentId}-${childTaskId}`,
    compoundTaskId: parentId,
    childTaskId,
    childIndex,
    createdAt: NOW,
    updatedAt: NOW,
    version: 1,
    isDeleted: false,
  };
}

type Props = Parameters<typeof MemberRuleRow>[0];

function render(over: Partial<Props> & Pick<Props, 'task'>): string {
  const props: Props = {
    taskById: {},
    state: 'included',
    rule: {},
    parts: [],
    fromBoard: true,
    sourceWindow: WEEKLY_SOURCE,
    wizardWindow: DAILY_WINDOW,
    mode: 'recurring',
    onToggleExclude: () => {},
    onSetTarget: () => {},
    onSetVary: () => {},
    onSetSplit: () => {},
    onSetPartExcluded: () => {},
    onSetPartTarget: () => {},
    onSetPartVary: () => {},
    ...over,
  };
  return renderToStaticMarkup(React.createElement(MemberRuleRow, props));
}

/** How many dice the row rendered (each names its own state). */
function diceCount(html: string): number {
  return html.split('aria-label="Vary: ').length - 1;
}

const READING = makeTask('t-read', {
  title: 'Read',
  type: TaskType.COUNTING,
  action: 'Read',
  unit: 'pages',
  maxCount: 35,
});

describe('MemberRuleRow — counting member', () => {
  it('pro-rates the target for a board source and captions it with the whole goal', () => {
    const html = render({ task: READING });
    // 35 pages over a weekly source → ceil(35 × 1 ÷ 7) = 5 on a daily board.
    expect(html).toContain('value="5"');
    expect(html).toContain('aria-label="Target"');
    expect(html).toContain('of 35 pages');
    expect(diceCount(html)).toBe(1);
  });

  it('honours a stored override instead of the pro-rated target', () => {
    const html = render({ task: READING, rule: { target: 8 } });
    expect(html).toContain('value="8"');
    // The caption still shows the member's own goal — no reset affordance.
    expect(html).toContain('of 35 pages');
  });

  it('gives a POOL member the dice alone — no stepper, no caption', () => {
    const html = render({ task: READING, fromBoard: false, sourceWindow: undefined });
    expect(html).not.toContain('aria-label="Target"');
    expect(html).not.toContain('of 35 pages');
    expect(diceCount(html)).toBe(1);
  });

  it('shows the shared range label under the row once the dice is on', () => {
    const off = render({ task: READING });
    expect(off).not.toContain('–');

    const little = render({ task: READING, rule: { vary: 1 } });
    expect(little).toContain(varyRangeLabel(5, 1, 35, 'pages') as string);

    const lot = render({ task: READING, rule: { vary: 2 } });
    expect(lot).toContain(varyRangeLabel(5, 2, 35, 'pages') as string);
  });

  it('strikes an excluded member through and offers UNDO', () => {
    const html = render({ task: READING, state: 'excluded' });
    expect(html).toContain('UNDO');
    expect(html).toMatch(/class="[^"]*_struck_/);
  });
});

describe('MemberRuleRow — compound member', () => {
  const RUN = makeTask('t-run', {
    title: 'Run',
    type: TaskType.COUNTING,
    action: 'Run',
    unit: 'm',
    maxCount: 210,
  });
  const STRETCH = makeTask('t-stretch', { title: 'Stretch' });
  const CIRCUIT = makeTask('t-circuit', { title: 'Circuit', type: TaskType.COMPOUND });
  const PARTS = [makeChild(CIRCUIT.id, RUN.id, 0), makeChild(CIRCUIT.id, STRETCH.id, 1)];
  const TASK_BY_ID: Record<string, Task> = { [RUN.id]: RUN, [STRETCH.id]: STRETCH };

  it('offers One square / Split up with the squares note and ONE dice while unsplit', () => {
    const html = render({ task: CIRCUIT, taskById: TASK_BY_ID, parts: PARTS });
    expect(html).toContain('One square');
    expect(html).toContain('Split up');
    expect(html).toContain('2 squares');
    // One dice on the toggle line; the parts have none while unsplit.
    expect(diceCount(html)).toBe(1);
    // Part lines are listed either way, with the counting part's stepper.
    expect(html).toContain('Run');
    expect(html).toContain('Stretch');
    expect(html).toContain('of 210');
  });

  it('moves the dice onto each counting part when split, and offers per-part ✕', () => {
    const html = render({
      task: CIRCUIT,
      taskById: TASK_BY_ID,
      parts: PARTS,
      rule: { split: true },
    });
    // The toggle-line dice disappears; only the counting part keeps one.
    expect(diceCount(html)).toBe(1);
    expect(html).toContain('aria-label="Exclude Run for this board"');
    expect(html).toContain('aria-label="Exclude Stretch for this board"');
    // Only the counting part gets a target stepper.
    expect(html.split('aria-label="Target"').length - 1).toBe(1);
  });

  it('strikes an excluded part through, offers UNDO, and recounts the note', () => {
    const html = render({
      task: CIRCUIT,
      taskById: TASK_BY_ID,
      parts: PARTS,
      rule: { split: true, parts: { [STRETCH.id]: { excluded: true } } },
    });
    expect(html).toContain('1 square');
    expect(html).toContain('aria-label="Undo excluding Stretch"');
    expect(html).not.toContain('aria-label="Exclude Stretch for this board"');
  });

  it('puts a part range line under that part, never on the compound itself', () => {
    const html = render({
      task: CIRCUIT,
      taskById: TASK_BY_ID,
      parts: PARTS,
      rule: { split: true, parts: { [RUN.id]: { vary: 2 } } },
    });
    // 210 over a weekly source → 30 on a daily board; ±50 % of that.
    expect(html).toContain(varyRangeLabel(30, 2, 210, '') as string);
  });

  it('treats a childless compound as a plain member — no toggle', () => {
    const html = render({ task: CIRCUIT, taskById: TASK_BY_ID, parts: [] });
    expect(html).not.toContain('One square');
    expect(html).not.toContain('Split up');
    expect(diceCount(html)).toBe(0);
  });
});
