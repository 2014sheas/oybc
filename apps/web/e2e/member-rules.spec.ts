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
 *     from a BOARD gets a compact target stepper carrying its goal as a
 *     suffix inside the pill (B3.1: the controls live behind a per-row
 *     disclosure, opened first); its dice cycles off → a little → a lot
 *     and lights a blue range line.
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

const REPEATING_BOARD_ID = '70000000-0000-0000-0000-000000000040';

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

/**
 * Pull the seeded source board through the "Add from a pool or board" sheet.
 *
 * Two different subtitles, deliberately: the SHEET row is
 * filter-independent ("8 squares · 0 done", straight off
 * `fetchSourceSheetBoardEntries`), while the PULLED row reads "8 not done"
 * — a newly minted BOARD source starts on the "Not done yet" filter (owner
 * directive 2026-09-19, `newSourceFilter`), and `buildSubtitle` switches
 * phrasing on that filter. Nothing in this fixture is complete, so the
 * count is 8 either way.
 */
async function pullSourceBoard(page: Page): Promise<void> {
  await page.getByRole('button', { name: 'Add from a pool or board' }).click();
  const sheet = page.getByRole('dialog', { name: 'Add from a pool or board' });
  await expect(sheet).toBeVisible();
  await sheet.getByRole('button', { name: /^Last Week Board, 8 squares/ }).click();
  await sheet.getByRole('button', { name: 'Done', exact: true }).click();
  await expect(sheet).toBeHidden();
}

test.describe('Wizard member rules — the expanded source panel', () => {
  test.beforeEach(async ({ page }) => {
    await seedSourceBoard(page);
  });

  test('a counting member gets the compact stepper carrying its goal suffix, and the dice lights a range line', async ({
    page,
  }) => {
    await openTasksStep(page);
    await pullSourceBoard(page);

    // The source lands as ONE row carrying all 8 squares; expand it.
    const sourceRow = page.getByRole('button', { name: /^Last Week Board, 8 not done/ });
    await expect(sourceRow).toBeVisible();
    await sourceRow.click();
    await expect(sourceRow).toHaveAttribute('aria-expanded', 'true');

    // `member-row` — NOT `getByRole('listitem')`: the source card is itself
    // an `<li>` wrapping every member row, so a listitem filter resolves the
    // card and a strict locator inside it sees three steppers and two dice.
    const memberRow = page.getByTestId('member-row').filter({ hasText: 'Run 30 miles' });
    // B3.1: rule controls live behind a per-row disclosure; open it first.
    await memberRow.getByTestId('member-disclosure').click();

    // Owner ruling 2026-09-21: a one-off board pro-rates too. Nothing has
    // been logged in the source board's window, so the remaining amount is
    // the whole goal — and a WEEKLY source pulled onto this DAILY board
    // scales it to ceil(30 × 1 / 7) = 5. The GOAL (not the target) rides
    // inside the stepper pill's suffix (B3.1) — the standalone "of N unit"
    // caption is retired — so the suffix still reads 30.
    // `getByRole('textbox', …)`, never `getByLabel('Target')`: `getByLabel`
    // matches an accessible name by case-insensitive SUBSTRING, and the
    // compact stepper labels three elements "Decrease target" / "Target" /
    // "Increase target" (`CounterStepper.tsx`), so the label form resolves
    // to three and throws strict-mode. Role narrows to the field and
    // `exact` pins the whole string.
    await expect(
      memberRow.getByRole('textbox', { name: 'Target', exact: true }),
    ).toHaveValue('5');
    await expect(memberRow.getByTestId('stepper-suffix')).toHaveText('/ 30 miles');

    // Dice: off → a little. The accessible name is the STATE (RC1), and a
    // blue range line appears under the row: ±20 % of the TARGET 5 (not the
    // goal) → [round(4), round(6)] = 4–6.
    const dice = memberRow.getByRole('button', { name: /^Vary: / });
    await expect(dice).toHaveAttribute('aria-label', 'Vary: off');
    await expect(memberRow.getByText('4–6 miles')).toHaveCount(0);
    await dice.click();
    await expect(dice).toHaveAttribute('aria-label', 'Vary: a little');
    await expect(memberRow.getByText('4–6 miles')).toBeVisible();

    // ...and on to "a lot" (±50 % of 5, rounded half-up → 3–8).
    await dice.click();
    await expect(dice).toHaveAttribute('aria-label', 'Vary: a lot');
    await expect(memberRow.getByText('3–8 miles')).toBeVisible();
  });

  test('Split up turns a compound into one square per part; a part can be excluded and undone', async ({
    page,
  }) => {
    await openTasksStep(page);
    await pullSourceBoard(page);

    await page.getByRole('button', { name: /^Last Week Board, 8 not done/ }).click();

    const compoundRow = page.getByTestId('member-row').filter({ hasText: 'Morning set' });

    // Collapsed: a compound's summary chip is NEVER suppressed (unlike a
    // counting member's — compoundSummary), so "1 square" is visible before
    // the row is ever expanded. Assert the collapsed chip here rather than
    // a control that doesn't exist yet — a better assertion than driving
    // the (now-hidden) Split pill directly.
    await expect(compoundRow.getByText('1 square', { exact: true })).toBeVisible();
    // The pulled board fills a 3×3-FREE board exactly.
    await expect(page.getByLabel('Capacity 8 of 8 tasks')).toBeVisible();

    // B3.1: rule controls live behind a per-row disclosure; open it to
    // reach the One square / Split up pill.
    await compoundRow.getByTestId('member-disclosure').click();
    const squares = compoundRow.getByRole('group', { name: 'Squares for Morning set' });
    await expect(squares).toBeVisible();

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

    await page.getByRole('button', { name: /^Last Week Board, 8 not done/ }).click();
    const memberRow = page.getByTestId('member-row').filter({ hasText: 'Run 30 miles' });
    // B3.1: rule controls live behind a per-row disclosure; open it first.
    await memberRow.getByTestId('member-disclosure').click();
    await memberRow.getByRole('button', { name: /^Vary: / }).click();
    await expect(memberRow.getByText('4–6 miles')).toBeVisible();

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
    // Inside the rolled range [4, 6] around the pro-rated target 5 — and
    // therefore never the un-pro-rated goal's "Run 30 miles" label.
    expect(first).toMatch(/^Run [4-6] miles$/);

    // Three Shuffles; the seed changes with the nonce, and the nonce
    // sequence is deterministic (0, 1, 2, 3 → 6, 5, 4, 6 over this range),
    // so at least one of them lands on a different value.
    const seen = [first];
    for (let i = 0; i < 3; i += 1) {
      await shuffle.click();
      seen.push(await rolledTarget());
    }
    expect(new Set(seen).size).toBeGreaterThan(1);
    for (const label of seen) expect(label).toMatch(/^Run [4-6] miles$/);
  });

  test('a member row expands when tapped in the empty space after a short title', async ({
    page,
  }) => {
    // Setup: reach the Tasks step with the source board pulled — verbatim,
    // same fixture task titles as the specs above. Not a second setup path.
    await openTasksStep(page);
    await pullSourceBoard(page);
    await page.getByRole('button', { name: /^Last Week Board, 8 not done/ }).click();

    // Pre-flight ruling C3: reuse the existing "Run 30 miles" fixture row
    // rather than inventing a short-titled task. The ruling under test is
    // "the whole row rect is the hit area", which a trailing-edge click
    // proves at ANY title length.
    const memberRow = page.getByTestId('member-row').filter({ hasText: 'Run 30 miles' });
    const disclosure = memberRow.getByTestId('member-disclosure');
    const box = (await disclosure.boundingBox())!;
    // Click near the trailing edge of the disclosure, well past the title's
    // text, but inside the 39px gutter reserved for the ✕
    // (`.disclosure { padding-right: 39px }`; 42px is the unrelated
    // `min-height` row floor — don't conflate the two).
    await page.mouse.click(box.x + box.width - 8, box.y + box.height / 2);
    // Role + exact name, not `getByLabel('Target')` — see the note on the
    // "compact stepper" spec above.
    await expect(
      memberRow.getByRole('textbox', { name: 'Target', exact: true }),
    ).toBeVisible();
  });

  test('a split compound hides the ✕ on the last included part rather than disabling it', async ({
    page,
  }) => {
    await openTasksStep(page);
    await pullSourceBoard(page);
    await page.getByRole('button', { name: /^Last Week Board, 8 not done/ }).click();

    const row = page.getByTestId('member-row').filter({ hasText: 'Morning set' });
    await row.getByTestId('member-disclosure').click();
    await row.getByRole('button', { name: 'Split up' }).click();

    // Scoped to the two PART names, not `/^Exclude /` — the member's own ✕
    // ("Exclude Morning set for this board") renders unconditionally
    // whenever the row is expandable (it has no `split` gating), so an
    // unscoped exclude-button count on the row would include it and throw
    // off both counts below. Follows the exact-name pattern the sibling
    // "Split up turns a compound..." spec already uses.
    const partExcludes = row.getByRole('button', {
      name: /^Exclude (Warm up 10 reps|Cool down 10 reps) for this board/,
    });

    // Both parts offer a ✕ while more than one is included.
    await expect(partExcludes).toHaveCount(2);

    // A PART's range line renders under that part, never on the compound
    // (docs/BOARD_SOURCES.md §Member rules, the "never on the compound
    // itself" clause). The unit-test that used to guard this was dropped
    // in the B3.1 rework; the iOS `testMemberRowCompoundSplitUpWith
    // ExcludedPartExpanded` baseline is the primary guard, this is the
    // web-side one. Split mode gives each counting part its own dice (the
    // member's own is hidden), so the first is "Warm up 10 reps"'s.
    await row.getByRole('button', { name: /^Vary: / }).first().click();
    // The part pro-rates like any board-pulled counting member (owner ruling
    // 2026-09-21): a weekly 10-rep part onto this DAILY board targets
    // ceil(10 × 1 / 7) = 2, whose ±20 % band rounds to [2, 2]. A COLLAPSED
    // band renders as the single value (owner ruling 2026-09-22 —
    // `varyRangeLabel`), so the line reads "2", not "2–2" (parts render the
    // range without a unit). The assertion below is STRUCTURAL — where the
    // range renders, not how wide it is — so the collapsed band does not
    // weaken it. Exact text "2" is unique inside this row: the two part
    // steppers hold their value in an <input>, not as text, and their
    // captions read "of 10".
    const partRange = row.getByText('2', { exact: true });
    await expect(partRange).toHaveCount(1);
    // Structural, not merely "it is somewhere in the row": the range's own
    // parent block also carries the part's name (`.part` wraps `.partLine`
    // + `.rangeLine`). A member-level range would sit in `.controlsLine`
    // instead, whose siblings are the One square / Split up pill and the
    // squares note — never a part name.
    await expect(
      partRange.locator('xpath=..').getByText('Warm up 10 reps', { exact: true }),
    ).toHaveCount(1);

    // Exclude one: the survivor's ✕ is GONE (hidden, not inert — an inert ✕
    // reads as a broken toggle), and the excluded part shows a part-scale
    // UNDO. Excluding a part never changes the compound MEMBER's own
    // board-inclusion state, so its ✕ stays put throughout — outside this
    // scoped count either way.
    await row.getByRole('button', { name: 'Exclude Warm up 10 reps for this board' }).click();
    await expect(partExcludes).toHaveCount(0);
    const partUndo = row.getByRole('button', { name: /^Undo excluding / });
    await expect(partUndo).toHaveCount(1);

    // PART scale, not member scale (`.partUndo` vs `.undo` in
    // MemberRuleRow.module.css) — this guard exists because someone once
    // shipped the control at the wrong size, so assert the class the
    // styling implies rather than just the control's presence. `.partUndo`
    // is a filled 1.5px-bordered pill (riso-paper-2 background); the
    // member-scale `.undo` is a bare 2px outline with no fill.
    await expect(partUndo).toHaveCSS('border-top-width', '1.5px');
    await expect(partUndo).not.toHaveCSS('background-color', 'rgba(0, 0, 0, 0)');
  });

  test('an expanded counting row exposes the stepper suffix, dice, and inline range (the only web coverage since B3.1)', async ({
    page,
  }) => {
    await openTasksStep(page);
    await pullSourceBoard(page);
    await page.getByRole('button', { name: /^Last Week Board, 8 not done/ }).click();

    const row = page.getByTestId('member-row').filter({ hasText: 'Run 30 miles' });
    await row.getByTestId('member-disclosure').click();
    // Role + exact name, not `getByLabel('Target')` — see the note on the
    // "compact stepper" spec above.
    await expect(row.getByRole('textbox', { name: 'Target', exact: true })).toBeVisible();
    await expect(row.getByTestId('stepper-suffix')).toHaveText('/ 30 miles');
    await expect(row.getByLabel(/^Vary: /)).toBeVisible();
  });

  test('every member row measures the same height, whether expandable, plain, or excluded', async ({
    page,
  }) => {
    await openTasksStep(page);
    await pullSourceBoard(page);
    await page.getByRole('button', { name: /^Last Week Board, 8 not done/ }).click();

    // Exclude a plain filler row to get the UNDO-pill state into the mix.
    // Every row here stays COLLAPSED: expanding the counting or compound
    // row would legitimately grow it past this floor with its second line
    // — the assertion is about the shared 42px floor, not about what an
    // expanded row measures.
    const fillerRow = page.getByTestId('member-row').filter({ hasText: 'Filler 1' });
    await fillerRow.getByRole('button', { name: 'Exclude Filler 1 for this board' }).click();
    await expect(fillerRow.getByRole('button', { name: 'Undo excluding Filler 1' })).toBeVisible();

    // Measure the row's INNER line, not the `<li>`: the 42px floor lives on
    // `.disclosure` / `.staticLine` (MemberRuleRow.module.css), while the
    // `<li>` adds a 1.5px `border-top` that `.row:first-child` does not
    // have — so measuring the `<li>` compares 42 against 43.5 and a
    // CORRECT implementation fails. Every row renders exactly one of the
    // two shapes, so the union locator is one element per row.
    const lines = page.locator(
      '[data-testid="member-disclosure"], [data-testid="member-static-line"]',
    );
    // Guard the locator itself: if a future row grew a third shape, the
    // sample would silently shrink and the uniqueness check would pass on
    // a subset rather than on the panel.
    await expect(lines).toHaveCount(await page.getByTestId('member-row').count());

    // Fixture panel spans the states that differ: two expandable rows
    // (counting + compound), five remaining plain rows, and this one
    // excluded row — a single-state panel would pass trivially.
    const heights = await lines.evaluateAll((els) =>
      els.map((el) => Math.round(el.getBoundingClientRect().height)),
    );
    expect(new Set(heights).size).toBe(1);
  });
});

test.describe('Wizard edit mode — the frame-5a note', () => {
  test('editing a repeating board says changes apply from the next board', async ({
    page,
  }) => {
    await seedTemplate(page, {
      id: REPEATING_BOARD_ID,
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
