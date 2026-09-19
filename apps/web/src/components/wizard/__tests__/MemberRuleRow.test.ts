import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import {
  TaskType,
  Timeframe,
  countingSummary,
  varyRangeLabel,
  type BoardWindow,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import { MemberRuleRow } from '../MemberRuleRow';

/**
 * The member row is the rule-authoring surface of the wizard's expanded
 * source panel (docs/BOARD_SOURCES.md §Member rules + §Member row at phone
 * width).
 *
 * **What these tests can and cannot see.** Since B3.1 the row opens
 * COLLAPSED: a counting or compound member shows `badge · title · summary
 * chip · chevron · ✕` and renders its controls only once the disclosure is
 * opened. There is no DOM harness here — `apps/web/vitest.config.ts` is
 * `environment: 'node'` on purpose, so these tests render to a STRING and
 * cannot click. Everything below therefore pins the COLLAPSED row, which
 * is where the interesting new decisions live:
 *
 * - the chip is the row's current answer — the pro-rated target for a
 *   board source, the un-pro-rated goal for a pool one, `varyRangeLabel`'s
 *   exact string once the dice is lit, `splitSquaresNote`'s for a compound;
 * - a chip that would only restate an auto-generated counting title
 *   (`vary == 0 && target == goal`) is SUPPRESSED entirely;
 * - which rows are expandable at all: a normal / achievement / childless
 *   compound member, and every excluded or filtered-done member, keep the
 *   pre-B3.1 single line with no disclosure (ruling C2).
 *
 * The expanded layout itself (stepper + suffix, dice, inline range, split
 * toggle, part lines) is covered by `e2e/member-rules.spec.ts`, which can
 * actually open the disclosure. Adding jsdom/RTL to unit-test it here is a
 * separate infra decision (ROADMAP E3), deliberately not taken on a layout
 * change.
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

/** Whether the row offers a disclosure (i.e. has controls to reveal). */
function hasDisclosure(html: string): boolean {
  return html.includes('data-testid="member-disclosure"');
}

const READING = makeTask('t-read', {
  title: 'Read',
  type: TaskType.COUNTING,
  action: 'Read',
  unit: 'pages',
  maxCount: 35,
});

describe('MemberRuleRow — collapsed by default', () => {
  it('starts collapsed, showing the summary chip instead of the controls', () => {
    const html = render({ task: READING });
    // The chip carries the answer…
    expect(html).toContain('5 pages');
    // …and not one of the controls it stands in for is in the markup.
    expect(html).not.toContain('aria-label="Target"');
    expect(diceCount(html)).toBe(0);
    expect(html).not.toContain('data-testid="stepper-suffix"');
  });

  it('marks the collapsed disclosure as not expanded', () => {
    const html = render({ task: READING });
    expect(hasDisclosure(html)).toBe(true);
    expect(html).toContain('aria-expanded="false"');
  });

  it('gives a plain normal member no disclosure at all', () => {
    const html = render({ task: makeTask('t-plain', { title: 'Stretch' }) });
    expect(hasDisclosure(html)).toBe(false);
    // …and no chip: there is no rule to summarise.
    expect(html).toMatch(/class="[^"]*_exclude_/);
    expect(html).not.toMatch(/class="[^"]*_chip_/);
  });

  it('keeps its trailing ✕ out of the disclosure button', () => {
    const html = render({ task: READING });
    // The ✕ is a SIBLING of the disclosure, never nested inside it —
    // a button inside a button is invalid and swallows the inner click.
    const disclosureStart = html.indexOf('data-testid="member-disclosure"');
    // Guard the slice below: a -1 here would make `inside` empty and every
    // `not.toContain` under it pass for the wrong reason.
    expect(disclosureStart).not.toBe(-1);
    const disclosureEnd = html.indexOf('</button>', disclosureStart);
    const inside = html.slice(disclosureStart, disclosureEnd);
    expect(inside).not.toContain('aria-label="Exclude Read for this board"');
    expect(html).toContain('aria-label="Exclude Read for this board"');
  });
});

describe('MemberRuleRow — counting chip', () => {
  it('chips the PRO-RATED target for a board source, not the goal', () => {
    const html = render({ task: READING });
    // 35 pages over a weekly source → ceil(35 × 1 ÷ 7) = 5 on a daily board.
    expect(html).toContain('5 pages');
    expect(html).not.toContain('35 pages');
    expect(html).toContain(countingSummary(5, 0, 35, 'pages')?.text as string);
  });

  it('chips a stored override instead of the pro-rated target', () => {
    const html = render({ task: READING, rule: { target: 8 } });
    expect(html).toContain('8 pages');
    expect(html).not.toContain('5 pages');
  });

  it('does not pro-rate a POOL member — it has no source window', () => {
    // A pool member sits at its full goal, so with the dice lit its range
    // is the goal's, not the daily-pro-rated 5's.
    const html = render({ task: READING, fromBoard: false, sourceWindow: undefined, rule: { vary: 1 } });
    expect(html).toContain('28–35 pages');
    expect(html).toContain(varyRangeLabel(35, 1, 35, 'pages') as string);
    expect(html).not.toContain('4–6 pages');
  });

  it('suppresses a chip that would only restate the title', () => {
    // vary off AND target === goal — the counting title is auto-generated
    // from action + goal + unit, so the chip would say the goal twice.
    const html = render({ task: READING, fromBoard: false, sourceWindow: undefined });
    expect(html).not.toMatch(/class="[^"]*_chip_/);
    expect(html).not.toContain('35 pages');
    // …but the row is still expandable — it has a dice to reveal.
    expect(hasDisclosure(html)).toBe(true);
  });

  it('chips the shared range label once the dice is on', () => {
    const off = render({ task: READING });
    expect(off).not.toContain('–');

    // Both the literal AND the shared helper, so a format change in
    // `varyRangeLabel` can't slide both sides together.
    const little = render({ task: READING, rule: { vary: 1 } });
    expect(little).toContain('4–6 pages');
    expect(little).toContain(varyRangeLabel(5, 1, 35, 'pages') as string);
    // A lit dice colours the chip blue; an unlit one leaves it muted.
    expect(little).toMatch(/class="[^"]*_chipVarying_/);

    const lot = render({ task: READING, rule: { vary: 2 } });
    expect(lot).toContain('3–8 pages');
    expect(lot).toContain(varyRangeLabel(5, 2, 35, 'pages') as string);

    expect(off).not.toMatch(/class="[^"]*_chipVarying_/);
  });
});

describe('MemberRuleRow — a member that is off the board', () => {
  it('strikes an excluded member through and offers UNDO', () => {
    const html = render({ task: READING, state: 'excluded' });
    expect(html).toContain('UNDO');
    expect(html).toMatch(/class="[^"]*_struck_/);
  });

  it('drops the disclosure and the chip once the member is off the board', () => {
    // Ruling C2: an excluded / filtered-done member renders exactly what
    // it did before B3.1 — one line, an inline control, nothing to reveal.
    const excluded = render({ task: READING, state: 'excluded', rule: { vary: 1 } });
    expect(hasDisclosure(excluded)).toBe(false);
    expect(excluded).not.toMatch(/class="[^"]*_chip_/);
    expect(excluded).not.toContain('aria-label="Target"');
    expect(excluded).not.toContain('aria-label="Vary: ');
    expect(excluded).not.toContain('4–6 pages');

    const filtered = render({ task: READING, state: 'filteredDone' });
    expect(hasDisclosure(filtered)).toBe(false);
    expect(filtered).not.toMatch(/class="[^"]*_chip_/);
    expect(filtered).toMatch(/class="[^"]*_doneCheck_/);
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

  it('chips "1 square" while unsplit and hides the toggle behind the disclosure', () => {
    const html = render({ task: CIRCUIT, taskById: TASK_BY_ID, parts: PARTS });
    expect(hasDisclosure(html)).toBe(true);
    // One square puts the WHOLE compound on as one square — the chip must
    // not contradict the segment that is selected underneath.
    expect(html).toContain('1 square');
    expect(html).not.toContain('2 squares');
    // The toggle and the part lines are not rendered until it is opened.
    expect(html).not.toContain('One square');
    expect(html).not.toContain('Split up');
    expect(html).not.toContain('Stretch');
    expect(diceCount(html)).toBe(0);
  });

  it('chips the square COUNT once split', () => {
    const html = render({
      task: CIRCUIT,
      taskById: TASK_BY_ID,
      parts: PARTS,
      rule: { split: true },
    });
    expect(html).toContain('2 squares');
    // …and stops saying the One-square answer, which is what it said a
    // moment ago — the chip is the row's CURRENT answer, not a label.
    expect(html).not.toContain('1 square');
  });

  it('recounts the chip when a part is excluded', () => {
    const html = render({
      task: CIRCUIT,
      taskById: TASK_BY_ID,
      parts: PARTS,
      rule: { split: true, parts: { [STRETCH.id]: { excluded: true } } },
    });
    expect(html).toContain('1 square');
    expect(html).not.toContain('2 squares');
  });

  it("never lets a PART's dice colour the member's own chip", () => {
    // While split the dice lives on the parts, so the member-level chip
    // reports squares in muted ink however the parts are set.
    const html = render({
      task: CIRCUIT,
      taskById: TASK_BY_ID,
      parts: PARTS,
      rule: { split: true, parts: { [RUN.id]: { vary: 2 } } },
    });
    expect(html).toContain('2 squares');
    expect(html).not.toMatch(/class="[^"]*_chipVarying_/);
    expect(html).not.toContain('–');
  });

  it("lights the chip while One square, where the member's own dice rolls", () => {
    const html = render({
      task: CIRCUIT,
      taskById: TASK_BY_ID,
      parts: PARTS,
      rule: { vary: 1 },
    });
    expect(html).toContain('1 square');
    expect(html).toMatch(/class="[^"]*_chipVarying_/);
  });

  it('gives a filtered-done compound no disclosure and no chip', () => {
    const html = render({
      task: CIRCUIT,
      taskById: TASK_BY_ID,
      parts: PARTS,
      state: 'filteredDone',
    });
    // Anchor first: the row DID render, as its pre-B3.1 single line with
    // the dimmed ✓ inline. Without this the three negatives below would
    // all hold against a component that rendered nothing at all.
    expect(html).toContain('Circuit');
    expect(html).toMatch(/class="[^"]*_doneCheck_/);
    expect(hasDisclosure(html)).toBe(false);
    expect(html).not.toMatch(/class="[^"]*_chip_/);
    expect(html).not.toContain('1 square');
  });

  it('treats a childless compound as a plain member — no disclosure, no chip', () => {
    const html = render({ task: CIRCUIT, taskById: TASK_BY_ID, parts: [] });
    // Anchor first (see above): an INCLUDED plain member renders its title
    // and its inline ✕, so the negatives below mean "no disclosure" rather
    // than "no output".
    expect(html).toContain('Circuit');
    expect(html).toMatch(/class="[^"]*_exclude_/);
    expect(hasDisclosure(html)).toBe(false);
    expect(html).not.toMatch(/class="[^"]*_chip_/);
    expect(html).not.toContain('One square');
  });
});
