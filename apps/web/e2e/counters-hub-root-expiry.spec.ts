import type { Page } from '@playwright/test';
import { test, expect, openCreateHub, startOneOffWizard } from './_fixtures/bypass';

/**
 * Regression — owner report 2026-09-30: "counter tasks derived from a larger
 * counter (a MONTHLY counting task broken into a smaller WEEKLY target by
 * pulling the monthly board into a weekly board via the Sources sheet) do
 * not appear in the Shared counters area at all."
 *
 * Root cause: the Counters hub hid expired window-stamped members BEFORE
 * `buildSharedCounterGroups` ran, and a board-born counter is a root only
 * because a live task links to it — so once its only members (last week's
 * derived rows) expired, the root stopped being a root and the whole
 * counter vanished from `/profile/counters` and `/profile`. The rule now
 * lives in the kernel (`memberVisibility`) and runs after root detection.
 *
 * Drives the real UI end to end (wizard → Sources sheet → activate), then
 * reads IndexedDB + the hub / detail / Profile home. The decisive case
 * moves the page clock PAST the weekly's `endDate` — red before the fix.
 */

type Row = Record<string, unknown>;

async function dumpStore(page: Page, store: string): Promise<Row[]> {
  return await page.evaluate(async (s) => {
    return new Promise<Row[]>((resolve, reject) => {
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const req = db.transaction([s], 'readonly').objectStore(s).getAll();
        req.onsuccess = () => {
          db.close();
          resolve(req.result as Row[]);
        };
        req.onerror = () => reject(req.error);
      };
    });
  }, store);
}

/** Tasks step: add the "Run 100 miles" counting task through the special panel. */
async function addCounter(page: Page): Promise<void> {
  await page.getByRole('button', { name: 'Add a counting, compound or achievement task' }).click();
  await page.getByRole('button', { name: 'Counting', exact: true }).click();
  await page.getByRole('textbox', { name: 'Verb*' }).fill('Run');
  await page.getByRole('spinbutton', { name: 'Goal*' }).fill('100');
  await page.getByRole('textbox', { name: 'Counting*' }).fill('miles');
  await page.getByRole('button', { name: 'Add to board ✦' }).click();
}

async function quickAdd(page: Page, titles: string[]): Promise<void> {
  const box = page.getByRole('textbox', { name: 'New normal task title' });
  for (const t of titles) {
    await box.fill(t);
    await box.press('Enter');
    await expect(page.getByText(t, { exact: true }).first()).toBeVisible();
  }
}

async function setup(page: Page, name: string, timeframe: 'Weekly' | 'Monthly'): Promise<void> {
  await page.getByLabel(/board name/i).fill(name);
  await page.getByRole('button', { name: '3×3', exact: true }).click();
  await page.getByRole('group', { name: 'Timeframe' }).getByRole('button', { name: timeframe, exact: true }).click();
  await page.getByRole('button', { name: /^Next/ }).click();
}

async function activate(page: Page): Promise<void> {
  await page.getByRole('button', { name: /^Next/ }).click();
  await page.getByRole('button', { name: 'Activate Board', exact: true }).click();
  await page.waitForURL(/\/boards\//);
}

/** A one-off MONTHLY board with the root counter + 7 fillers, activated. */
async function createMonthlyBoard(page: Page): Promise<string> {
  await openCreateHub(page);
  await startOneOffWizard(page);
  await setup(page, 'Month Board', 'Monthly');
  await addCounter(page);
  await quickAdd(page, ['M1', 'M2', 'M3', 'M4', 'M5', 'M6', 'M7']);
  await activate(page);
  const root = (await dumpStore(page, 'tasks')).find((t) => t.title === 'Run 100 miles' && !t.sharedCounterId);
  expect(root, 'root counting task written').toBeTruthy();
  return root!.id as string;
}

/** Tasks step of a weekly board: pull the monthly board via the Sources sheet
 *  and give the counter member an explicit target of 25. */
async function pullMonthly(page: Page): Promise<void> {
  await page.getByRole('button', { name: /^Add from a pool or board/ }).click();
  const sheet = page.getByRole('dialog', { name: 'Add from a pool or board' });
  await expect(sheet).toBeVisible();
  await sheet.getByRole('button', { name: /^Month Board, 8 squares/ }).click();
  await sheet.getByRole('button', { name: 'Done', exact: true }).click();
  await expect(sheet).toBeHidden();
  await page.getByRole('button', { name: /^Month Board, 8 not done/ }).click();
  const memberRow = page.getByTestId('member-row').filter({ hasText: 'Run 100 miles' });
  await memberRow.getByTestId('member-disclosure').click();
  const target = memberRow.getByRole('textbox', { name: 'Target', exact: true });
  await target.fill('25');
  await target.press('Tab');
  await expect(target).toHaveValue('25');
}

/** The Boards-tab path: Weekly core tile → pager's empty window → Set up →
 *  pull the monthly → activate. Returns the weekly board's `endDate`. */
async function createCoreWeeklyFromMonthly(page: Page): Promise<string> {
  await page.goto('/boards');
  await page.getByRole('button', { name: /^Weekly/ }).first().click();
  await page.waitForURL(/\/boards\/core\/weekly\//);
  await page.getByRole('button', { name: /^Set up Week of/ }).click();
  await expect(page.getByText('Core board for')).toBeVisible();
  await page.getByRole('button', { name: '3×3', exact: true }).click();
  await page.getByRole('button', { name: /^Next/ }).click();
  await pullMonthly(page);
  await page.getByRole('button', { name: /^Next/ }).click();
  await page.getByRole('button', { name: /^(Activate|Create) Board$/ }).click();
  await page.waitForURL(/\/boards\//);
  const weekly = (await dumpStore(page, 'boards')).find((b) => b.timeframe === 'weekly' && !b.isDeleted);
  expect(weekly?.endDate, 'weekly board has an endDate').toBeTruthy();
  return weekly!.endDate as string;
}

async function derivedRow(page: Page, rootId: string): Promise<Row> {
  const tasks = await dumpStore(page, 'tasks');
  const derived = tasks.filter((t) => t.sharedCounterId === rootId && !t.isDeleted);
  expect(derived.length, 'window-stamped derived row minted').toBe(1);
  expect(derived[0].startDate, 'derived row startDate').toBeTruthy();
  return derived[0];
}

/** Hub + detail + Profile home all list the counter (and, on detail, the member). */
async function expectCounterEverywhere(page: Page, rootId: string, memberTitle: string | null): Promise<void> {
  await page.goto('/profile/counters');
  await expect(page.getByRole('heading', { name: 'Counters', level: 1 })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Open Run miles counter detail' })).toBeVisible();

  await page.goto(`/profile/counters/${rootId}`);
  await expect(page.getByRole('heading', { name: 'Run miles' })).toBeVisible();
  if (memberTitle) await expect(page.getByText(memberTitle).first()).toBeVisible();

  await page.goto('/profile');
  await expect(page.getByText('One tally, many squares'), 'profile not in empty state').toHaveCount(0);
  await expect(page.getByText('Run miles').first()).toBeVisible();
}

test.describe('Counters hub — a board-born root stays listed when its members expire', () => {
  test.setTimeout(120_000);

  test('a live weekly member (one-off weekly, explicit target) lists under the monthly root', async ({
    page,
  }) => {
    const rootId = await createMonthlyBoard(page);
    await openCreateHub(page);
    await startOneOffWizard(page);
    await setup(page, 'Week Board', 'Weekly');
    await pullMonthly(page);
    await activate(page);

    const d = await derivedRow(page, rootId);
    await expectCounterEverywhere(page, rootId, d.title as string);
  });

  test('core weekly via the Boards tab: the counter survives the monthly ending AND the weekly ending', async ({
    page,
  }) => {
    const rootId = await createMonthlyBoard(page);
    const weeklyEnd = await createCoreWeeklyFromMonthly(page);
    const d = await derivedRow(page, rootId);
    await expectCounterEverywhere(page, rootId, d.title as string);

    // The weekly straddling the month end: after the MONTHLY window closes
    // the root's own endDate is past, but the weekly member is live. The
    // root is never filtered, so this already held before the fix.
    const monthly = (await dumpStore(page, 'boards')).find((b) => b.timeframe === 'monthly' && !b.isDeleted);
    const afterMonthly = new Date(new Date(monthly!.endDate as string).getTime() + 60 * 60 * 1000);
    if (afterMonthly < new Date(weeklyEnd)) {
      await page.clock.install({ time: afterMonthly });
      await expectCounterEverywhere(page, rootId, d.title as string);
    }

    // THE BUG: move the clock PAST the weekly's endDate. The derived row is
    // now expired; before the fix the hub filtered it out before grouping,
    // the root stopped being a root, and the counter vanished from the hub
    // and the Profile home.
    const afterWeekly = new Date(new Date(weeklyEnd).getTime() + 24 * 60 * 60 * 1000);
    await page.clock.install({ time: afterWeekly });

    await page.goto('/profile/counters');
    await expect(page.getByRole('heading', { name: 'Counters', level: 1 })).toBeVisible();
    await expect(
      page.getByRole('button', { name: 'Open Run miles counter detail' }),
      'hub still lists the monthly root after its only member expired',
    ).toBeVisible();
    // The ended weekly row is hidden by default: the card's only member row
    // is the root's own square on the monthly board (that board's status is
    // still `active` — sealing is a separate, lazy pass), so the footer
    // counts one task, and the weekly row is nowhere on the page.
    await expect(page.getByText('1 task · 1 board')).toBeVisible();
    await expect(page.getByText(d.title as string)).toHaveCount(0);

    // …and "Show expired tasks" lists it again. The toggle's state IS the
    // URL (`?showExpired=1`), so drive it through the URL — clicking the
    // controlled checkbox races react-router's transition and is the known
    // flaky step in member-rules.spec.ts's hub test (ROADMAP E7).
    await page.goto('/profile/counters?showExpired=1');
    await expect(page.getByLabel('Show expired tasks')).toBeChecked();
    await expect(page.getByText('2 tasks · 2 boards')).toBeVisible();
    await page.goto(`/profile/counters/${rootId}?showExpired=1`);
    await expect(page.getByRole('heading', { name: 'Run miles' })).toBeVisible();
    await expect(page.getByText(d.title as string).first()).toBeVisible();

    await page.goto('/profile');
    await expect(page.getByText('One tally, many squares'), 'profile block not empty').toHaveCount(0);
    await expect(page.getByText('Run miles').first(), 'profile block still lists the counter').toBeVisible();
  });
});
