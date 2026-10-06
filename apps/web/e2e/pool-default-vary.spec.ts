import type { Page } from '@playwright/test';
import {
  test,
  expect,
  openCreateHub,
  openTab,
  seedPool,
  seedTask,
  startOneOffWizard,
} from './_fixtures/bypass';

/**
 * Pool-level default vary (docs/BOARD_SOURCES.md §Pool-level defaults):
 * a counting task's dice set in the POOL editor is inherited LIVE by every
 * board that pulls the pool — pulling stores no rule on the source; the
 * Sources-sheet member row, Preview and Create all resolve the dice from the
 * pool. It is overridable to an explicit off per board, and honoured at
 * Create. `varyRange` is symmetric (± around the target, no ceiling at the
 * goal — fixed 2026-10-06), so "a little" on a goal of 10 rolls inside 8–12.
 */

const POOL_ID = '73000000-0000-0000-0000-000000000001';
const COUNTER_ID = '73000000-0000-0000-0000-000000000010';
const FILLER_IDS = Array.from({ length: 7 }, (_, i) => `73000000-0000-0000-0000-00000000002${i}`);

async function seedPoolWithCounter(page: Page): Promise<void> {
  await seedTask(page, {
    id: COUNTER_ID,
    title: 'Run 10 miles',
    type: 'counting',
    action: 'Run',
    unit: 'miles',
    maxCount: 10,
    currentCount: 0,
  });
  for (const [i, id] of FILLER_IDS.entries()) {
    await seedTask(page, { id, title: `Filler ${i + 1}`, type: 'normal' });
  }
  await seedPool(page, { id: POOL_ID, name: 'Runner pool', taskIds: [COUNTER_ID, ...FILLER_IDS] });
}

/** Tasks → Pools → open the pool → dice to "a little" → Save. */
async function setPoolDiceALittle(page: Page): Promise<void> {
  await page.goto('/boards');
  await openTab(page, 'Tasks');
  await page.getByRole('button', { name: /^Pools · / }).click();
  await page.getByRole('button', { name: 'Edit pool Runner pool' }).click();
  const dice = page.getByRole('button', { name: /^Vary: / });
  await expect(dice).toHaveAttribute('aria-label', 'Vary: off');
  await dice.click();
  await expect(dice).toHaveAttribute('aria-label', 'Vary: a little');
  await page.waitForTimeout(200);
  await page.screenshot({ path: '.playwright-mcp/pool-default-vary-editor.png' });
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(page).toHaveURL(/\/tasks\?segment=pools$/);
}

/** One-off wizard → Tasks step → pull the pool; returns the member row, expanded. */
async function pullPoolAndExpand(page: Page) {
  await openCreateHub(page);
  await startOneOffWizard(page);
  await page.getByLabel(/board name/i).fill('Default vary board');
  await page.getByRole('button', { name: '3×3', exact: true }).click();
  await page
    .getByRole('group', { name: 'Timeframe' })
    .getByRole('button', { name: 'Daily', exact: true })
    .click();
  await page.getByRole('button', { name: /^Next/ }).click();
  await page.getByRole('button', { name: 'Add from a pool or board' }).click();
  const sheet = page.getByRole('dialog', { name: 'Add from a pool or board' });
  await sheet.getByRole('button', { name: /Runner pool/ }).click();
  await sheet.getByRole('button', { name: 'Done', exact: true }).click();
  await expect(sheet).toBeHidden();
  await page.getByRole('button', { name: /^Runner pool, 8 tasks/ }).click();
  const memberRow = page.getByTestId('member-row').filter({ hasText: 'Run 10 miles' });
  await memberRow.getByTestId('member-disclosure').click();
  return memberRow;
}

/** Every live "Run …" counter (the seeded root + any per-board copy): id → goal. */
async function runnerTasks(page: Page): Promise<Array<{ id: string; maxCount: number }>> {
  return await page.evaluate(async () => {
    return new Promise<Array<{ id: string; maxCount: number }>>((resolve, reject) => {
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const req = db.transaction(['tasks'], 'readonly').objectStore('tasks').getAll();
        req.onsuccess = () => {
          db.close();
          resolve(
            (req.result as Array<Record<string, unknown>>)
              .filter((t) => t.action === 'Run' && !t.isDeleted)
              .map((t) => ({ id: t.id as string, maxCount: t.maxCount as number })),
          );
        };
        req.onerror = () => reject(req.error);
      };
    });
  });
}

/** The task ids placed on every live board (board_tasks rows). */
async function placedTaskIds(page: Page): Promise<string[]> {
  return await page.evaluate(async () => {
    return new Promise<string[]>((resolve, reject) => {
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const req = db.transaction(['boardTasks'], 'readonly').objectStore('boardTasks').getAll();
        req.onsuccess = () => {
          db.close();
          resolve(
            (req.result as Array<Record<string, unknown>>)
              .filter((bt) => !bt.isDeleted)
              .map((bt) => bt.taskId as string),
          );
        };
        req.onerror = () => reject(req.error);
      };
    });
  });
}

test.describe('Pool-level default vary', () => {
  test('explicit off on the Sources sheet is honoured: the placed goal is exactly 10', async ({ page }) => {
    await seedPoolWithCounter(page);
    await setPoolDiceALittle(page);

    const memberRow = await pullPoolAndExpand(page);
    const dice = memberRow.getByRole('button', { name: /^Vary: / });
    await expect(dice).toHaveAttribute('aria-label', 'Vary: a little');
    await page.waitForTimeout(200);
    await page.screenshot({ path: '.playwright-mcp/pool-default-vary-sheet.png' });

    // a little -> a lot -> off.
    await dice.click();
    await dice.click();
    await expect(dice).toHaveAttribute('aria-label', 'Vary: off');

    await page.getByRole('button', { name: /^Next/ }).click();
    await expect(page.getByText('Run 10 miles').first()).toBeVisible();
    await page.getByRole('button', { name: 'Activate Board' }).click();
    await expect(page).toHaveURL(/\/boards/);
    await expect.poll(async () => (await placedTaskIds(page)).length).toBeGreaterThan(0);
    // Explicit off = NO derived copy: the seeded counter itself is placed,
    // at its own goal, and it is the only "Run" task in the library.
    expect(await placedTaskIds(page)).toContain(COUNTER_ID);
    expect(await runnerTasks(page)).toEqual([{ id: COUNTER_ID, maxCount: 10 }]);
  });

  test('left inherited (the LIVE pool default), the placed goal is within 8-12', async ({ page }) => {
    await seedPoolWithCounter(page);
    await setPoolDiceALittle(page);

    const memberRow = await pullPoolAndExpand(page);
    await expect(memberRow.getByRole('button', { name: /^Vary: / })).toHaveAttribute(
      'aria-label',
      'Vary: a little',
    );

    await page.getByRole('button', { name: /^Next/ }).click();
    const cell = page.getByText(/^Run \d+ miles$/).first();
    await expect(cell).toBeVisible();
    const previewGoal = Number(/\d+/.exec((await cell.textContent()) ?? '')![0]);
    expect(previewGoal).toBeGreaterThanOrEqual(8);
    expect(previewGoal).toBeLessThanOrEqual(12);

    await page.getByRole('button', { name: 'Activate Board' }).click();
    await expect(page).toHaveURL(/\/boards/);
    await expect.poll(async () => (await placedTaskIds(page)).length).toBeGreaterThan(0);
    for (const { maxCount } of await runnerTasks(page)) {
      expect(maxCount).toBeGreaterThanOrEqual(8);
      expect(maxCount).toBeLessThanOrEqual(12);
    }
  });
});
