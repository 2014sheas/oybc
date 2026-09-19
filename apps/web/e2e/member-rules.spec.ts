import type { Page } from '@playwright/test';
import {
  test,
  expect,
  openCreateHub,
  seedBoard,
  seedBoardTask,
  seedCompoundChild,
  seedTask,
  seedTemplate,
  startOneOffWizard,
} from './_fixtures/bypass';

/**
 * §Member rules (B3, docs/BOARD_SOURCES.md §Member rules) — browser
 * coverage for the four surfaces the rules touch:
 *
 *  1. The expanded source panel's member rows — a counting member pulled
 *     from a BOARD gets a compact target stepper + "of {goal} {unit}"
 *     caption; its dice cycles off → a little → a lot and lights a blue
 *     range line.
 *  2. A compound member's One square / Split up pill — splitting turns one
 *     square into one per part, growing the source's own count; a part can
 *     be excluded (struck + UNDO) and the last one can't.
 *  3. The Preview grid — a varied member previews its ROLLED target, and
 *     Shuffle re-rolls it (the roll is seeded per nonce).
 *  4. Editing a repeating board shows the frame-5a note, and the Counters
 *     hub hides expired per-window derived counters until asked.
 *
 * The arithmetic itself (pro-rating, vary ranges, the plan/mint pipeline)
 * is pinned by cross-platform vectors in `packages/shared` and by Vitest in
 * `src/components/wizard/__tests__/previewDerived.test.ts`; this spec pins
 * the UI wiring only.
 */

// ── Seed ids ────────────────────────────────────────────────────────────────

const SOURCE_BOARD_ID = '70000000-0000-0000-0000-000000000001';
const COUNTER_TASK_ID = '70000000-0000-0000-0000-000000000010';
const COMPOUND_TASK_ID = '70000000-0000-0000-0000-000000000020';
const PART_A_ID = '70000000-0000-0000-0000-000000000021';
const PART_B_ID = '70000000-0000-0000-0000-000000000022';
/** Six filler squares, so the pulled board alone satisfies a 3×3-FREE board. */
const FILLER_IDS = Array.from(
  { length: 6 },
  (_, i) => `70000000-0000-0000-0000-00000000003${i}`,
);

const TEMPLATE_ID = '70000000-0000-0000-0000-000000000040';

const COUNTER_ROOT_ID = '70000000-0000-0000-0000-000000000050';
const LIVE_MEMBER_ID = '70000000-0000-0000-0000-000000000051';
const STALE_MEMBER_ID = '70000000-0000-0000-0000-000000000052';
const COUNTERS_BOARD_ID = '70000000-0000-0000-0000-000000000053';

// Windows are computed from "now" so the seeded board is genuinely live
// whenever the spec runs — a hardcoded past date is swept up by the global
// backstop auto-seal within milliseconds of page load (see
// `repeat-board.spec.ts` for the same note).
const NOW = new Date();
const HOUR_AGO_ISO = new Date(NOW.getTime() - 60 * 60 * 1000).toISOString();
const MONTH_OUT_ISO = new Date(NOW.getTime() + 30 * 24 * 60 * 60 * 1000).toISOString();
const LAST_MONTH_ISO = new Date(NOW.getTime() - 30 * 24 * 60 * 60 * 1000).toISOString();

/**
 * Seed a source BOARD carrying 8 placed squares: one counting task, one
 * two-part compound, and six normal fillers. Eight is exactly
 * `fillableCellCount(3, FREE)`, so pulling it satisfies the capacity gate
 * and "Next" stays enabled all the way to Preview.
 */
async function seedSourceBoard(page: Page): Promise<void> {
  await seedBoard(page, {
    id: SOURCE_BOARD_ID,
    name: 'Last Week Board',
    boardSize: 3,
    timeframe: 'weekly',
    status: 'active',
    startDate: HOUR_AGO_ISO,
    endDate: MONTH_OUT_ISO,
    centerSquareType: 'none',
  });

  await seedTask(page, {
    id: COUNTER_TASK_ID,
    title: 'Run 30 miles',
    type: 'counting',
    action: 'Run',
    unit: 'miles',
    maxCount: 30,
    currentCount: 0,
  });
  await seedTask(page, { id: PART_A_ID, title: 'Warm up 10 reps', type: 'counting', action: 'Warm up', unit: 'reps', maxCount: 10 });
  await seedTask(page, { id: PART_B_ID, title: 'Cool down 10 reps', type: 'counting', action: 'Cool down', unit: 'reps', maxCount: 10 });
  await seedTask(page, { id: COMPOUND_TASK_ID, title: 'Morning set', type: 'compound' });
  await seedCompoundChild(page, {
    id: `${COMPOUND_TASK_ID}-a`,
    compoundTaskId: COMPOUND_TASK_ID,
    childTaskId: PART_A_ID,
    childIndex: 0,
  });
  await seedCompoundChild(page, {
    id: `${COMPOUND_TASK_ID}-b`,
    compoundTaskId: COMPOUND_TASK_ID,
    childTaskId: PART_B_ID,
    childIndex: 1,
  });
  for (const [i, id] of FILLER_IDS.entries()) {
    await seedTask(page, { id, title: `Filler ${i + 1}`, type: 'normal' });
  }

  const placed = [COUNTER_TASK_ID, COMPOUND_TASK_ID, ...FILLER_IDS];
  for (const [i, taskId] of placed.entries()) {
    await seedBoardTask(page, {
      id: `${SOURCE_BOARD_ID}-bt-${i}`,
      boardId: SOURCE_BOARD_ID,
      taskId,
      row: Math.floor(i / 3),
      col: i % 3,
    });
  }
}

/** Enter the one-off wizard on a Daily 3×3 board and land on the Tasks step. */
async function openTasksStep(page: Page): Promise<void> {
  await openCreateHub(page);
  await startOneOffWizard(page);
  await page.getByLabel(/board name/i).fill('Member Rules Board');
  await page.getByRole('button', { name: '3×3', exact: true }).click();
  await page
    .getByRole('group', { name: 'Timeframe' })
    .getByRole('button', { name: 'Daily', exact: true })
    .click();
  await page.getByRole('button', { name: /^Next/ }).click();
}

/** Pull the seeded source board through the "Add a pool or board" sheet. */
async function pullSourceBoard(page: Page): Promise<void> {
  await page.getByRole('button', { name: 'Add a pool or board' }).click();
  const sheet = page.getByRole('dialog', { name: 'Add a pool or board' });
  await expect(sheet).toBeVisible();
  await sheet.getByRole('button', { name: /^Last Week Board, 8 squares/ }).click();
  await sheet.getByRole('button', { name: 'Done', exact: true }).click();
  await expect(sheet).toBeHidden();
}

test.describe('Wizard member rules — the expanded source panel', () => {
  test.beforeEach(async ({ page }) => {
    await seedSourceBoard(page);
  });

  test('a counting member gets the compact stepper + "of N unit" caption, and the dice lights a range line', async ({
    page,
  }) => {
    await openTasksStep(page);
    await pullSourceBoard(page);

    // The source lands as ONE row carrying all 8 squares; expand it.
    const sourceRow = page.getByRole('button', { name: /^Last Week Board, 8 squares/ });
    await expect(sourceRow).toBeVisible();
    await sourceRow.click();
    await expect(sourceRow).toHaveAttribute('aria-expanded', 'true');

    const memberRow = page
      .getByRole('listitem')
      .filter({ hasText: 'Run 30 miles' })
      .first();

    // A one-off board doesn't pro-rate, and nothing has been logged in the
    // source board's window, so the remaining target IS the goal.
    await expect(memberRow.getByRole('textbox', { name: 'Target' })).toHaveValue('30');
    await expect(memberRow.getByText('of 30 miles')).toBeVisible();

    // Dice: off → a little. The accessible name is the STATE (RC1), and a
    // blue range line appears under the row: ±20 % of 30, clamped to the goal.
    const dice = memberRow.getByRole('button', { name: /^Vary: / });
    await expect(dice).toHaveAttribute('aria-label', 'Vary: off');
    await expect(memberRow.getByText('24–30 miles')).toHaveCount(0);
    await dice.click();
    await expect(dice).toHaveAttribute('aria-label', 'Vary: a little');
    await expect(memberRow.getByText('24–30 miles')).toBeVisible();

    // ...and on to "a lot" (±50 %).
    await dice.click();
    await expect(dice).toHaveAttribute('aria-label', 'Vary: a lot');
    await expect(memberRow.getByText('15–30 miles')).toBeVisible();
  });

  test('Split up turns a compound into one square per part; a part can be excluded and undone', async ({
    page,
  }) => {
    await openTasksStep(page);
    await pullSourceBoard(page);

    await page.getByRole('button', { name: /^Last Week Board, 8 squares/ }).click();

    const compoundRow = page
      .getByRole('listitem')
      .filter({ hasText: 'Morning set' })
      .first();
    const squares = compoundRow.getByRole('group', { name: 'Squares for Morning set' });
    await expect(squares).toBeVisible();
    await expect(compoundRow.getByText('1 square', { exact: true })).toBeVisible();
    // The pulled board fills a 3×3-FREE board exactly.
    await expect(page.getByLabel('Capacity 8 of 8 tasks')).toBeVisible();

    // Split up: the note becomes "2 squares" and the board's capacity grows
    // by one — the compound stops contributing itself and contributes its
    // two parts instead.
    await squares.getByRole('button', { name: 'Split up' }).click();
    await expect(compoundRow.getByText('2 squares', { exact: true })).toBeVisible();
    await expect(page.getByLabel('Capacity 9 of 8 tasks')).toBeVisible();

    // Exclude one part: it strikes through, offers UNDO, and capacity drops
    // back. The remaining part carries no ✕ — a split member always
    // contributes at least one square.
    await compoundRow
      .getByRole('button', { name: 'Exclude Warm up 10 reps for this board' })
      .click();
    const undo = compoundRow.getByRole('button', { name: 'Undo excluding Warm up 10 reps' });
    await expect(undo).toBeVisible();
    await expect(compoundRow.getByText('1 square', { exact: true })).toBeVisible();
    await expect(page.getByLabel('Capacity 8 of 8 tasks')).toBeVisible();
    await expect(
      compoundRow.getByRole('button', { name: 'Exclude Cool down 10 reps for this board' }),
    ).toHaveCount(0);

    // UNDO restores it.
    await undo.click();
    await expect(compoundRow.getByText('2 squares', { exact: true })).toBeVisible();
    await expect(page.getByLabel('Capacity 9 of 8 tasks')).toBeVisible();
  });

  test('the Preview grid shows the rolled target, and Shuffle re-rolls it', async ({
    page,
  }) => {
    await openTasksStep(page);
    await pullSourceBoard(page);

    await page.getByRole('button', { name: /^Last Week Board, 8 squares/ }).click();
    const memberRow = page
      .getByRole('listitem')
      .filter({ hasText: 'Run 30 miles' })
      .first();
    await memberRow.getByRole('button', { name: /^Vary: / }).click();
    await expect(memberRow.getByText('24–30 miles')).toBeVisible();

    // On to Preview.
    await page.getByRole('button', { name: /^Next/ }).click();
    const shuffle = page.getByRole('button', { name: 'Shuffle board layout' });
    await expect(shuffle).toBeVisible();

    /** The rolled target currently on the grid, read off the cell's label. */
    const rolledTarget = async (): Promise<string> => {
      const cell = page.getByText(/^Run \d+ miles$/).first();
      await expect(cell).toBeVisible();
      return (await cell.textContent()) ?? '';
    };

    const first = await rolledTarget();
    // Inside the range, and never the un-rolled goal's label by accident —
    // 30 IS in range, so only the range membership is asserted here.
    expect(first).toMatch(/^Run (2[4-9]|30) miles$/);

    // Three Shuffles; the seed changes with the nonce, so at least one of
    // them must land on a different value in a 7-wide range.
    const seen = [first];
    for (let i = 0; i < 3; i += 1) {
      await shuffle.click();
      seen.push(await rolledTarget());
    }
    expect(new Set(seen).size).toBeGreaterThan(1);
    for (const label of seen) expect(label).toMatch(/^Run (2[4-9]|30) miles$/);
  });
});

test.describe('Wizard edit mode — the frame-5a note', () => {
  test('editing a repeating board says changes apply from the next board', async ({
    page,
  }) => {
    await seedTemplate(page, {
      id: TEMPLATE_ID,
      name: 'Morning Kickstart',
      timeframe: 'daily',
      boardSize: 3,
      centerSquareType: 'free',
      isRandomized: true,
      seedTaskIds: [],
      isActive: true,
    });

    await page.goto('/profile/board-settings');
    await expect(page.getByText('Morning Kickstart')).toBeVisible();
    await page.getByRole('button', { name: 'Edit tasks', exact: true }).click();

    // The note sits under the stepper and stays there for every step.
    await expect(page.getByText('Changes apply from the next board.')).toBeVisible();
  });
});

test.describe('Counters hub — expired derived counters', () => {
  test('hides an expired per-window derived counter until "Show expired tasks"', async ({
    page,
  }) => {
    await seedBoard(page, {
      id: COUNTERS_BOARD_ID,
      name: 'Counter Board',
      boardSize: 3,
      timeframe: 'daily',
      status: 'active',
      startDate: HOUR_AGO_ISO,
      endDate: MONTH_OUT_ISO,
      centerSquareType: 'none',
    });

    // The root counter — the shared tally every member moves.
    await seedTask(page, {
      id: COUNTER_ROOT_ID,
      title: 'Run miles',
      type: 'counting',
      action: 'Run',
      unit: 'miles',
      currentCount: 12,
      isCounter: true,
    });
    // A live window-stamped derived member...
    await seedTask(page, {
      id: LIVE_MEMBER_ID,
      title: 'Run 5 miles',
      type: 'counting',
      action: 'Run',
      unit: 'miles',
      maxCount: 5,
      sharedCounterId: COUNTER_ROOT_ID,
      createdInWizard: true,
      timeframe: 'daily',
      startDate: HOUR_AGO_ISO,
      endDate: MONTH_OUT_ISO,
    });
    // ...and one whose window closed a month ago.
    await seedTask(page, {
      id: STALE_MEMBER_ID,
      title: 'Run 9 miles',
      type: 'counting',
      action: 'Run',
      unit: 'miles',
      maxCount: 9,
      sharedCounterId: COUNTER_ROOT_ID,
      createdInWizard: true,
      timeframe: 'daily',
      startDate: LAST_MONTH_ISO,
      endDate: LAST_MONTH_ISO,
    });
    await seedBoardTask(page, {
      id: `${COUNTERS_BOARD_ID}-bt-0`,
      boardId: COUNTERS_BOARD_ID,
      taskId: LIVE_MEMBER_ID,
      row: 0,
      col: 0,
    });
    await seedBoardTask(page, {
      id: `${COUNTERS_BOARD_ID}-bt-1`,
      boardId: COUNTERS_BOARD_ID,
      taskId: STALE_MEMBER_ID,
      row: 0,
      col: 1,
    });

    await page.goto('/profile/counters');
    await expect(page.getByRole('heading', { name: 'Counters', level: 1 })).toBeVisible();

    // The ledger card's rows are board · window, so the observable is the
    // footer count: only the LIVE member is counting now.
    await expect(page.getByText('1 task · 1 board')).toBeVisible();

    // Toggle it on — same control and copy as the Tasks tab — and the
    // expired member joins the card.
    await page.getByLabel('Show expired tasks').check();
    await expect(page.getByText('2 tasks · 1 board')).toBeVisible();
    // The setting lives in the URL, so Detail opens with it rather than
    // silently resetting.
    await expect(page).toHaveURL(/showExpired=1/);
  });
});
