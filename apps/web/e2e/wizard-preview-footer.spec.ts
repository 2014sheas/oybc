import type { Page } from '@playwright/test';
import {
  test,
  expect,
  openCreateHub,
  seedPool,
  seedTask,
  startOneOffWizard,
  startRecurringWizard,
} from './_fixtures/bypass';

/**
 * Wizard Preview step — footer + Rearrange jiggle.
 *
 * 1. The footer carries exactly two buttons: a compact "‹ Back" and ONE
 *    primary (one-off "Activate Board"; recurring "Create Board"). The old
 *    "Save as Draft" button is gone — leaving via Cancel offers the draft
 *    save instead — and the primary never wraps at a 393px phone width.
 * 2. The Rearrange jiggle stops when the user goes back to Preview: no
 *    cell keeps the `.jiggle` class.
 */

const POOL_TASK_IDS = Array.from(
  { length: 8 },
  (_, i) => `dddddddd-0000-0000-0000-00000000000${i}`,
);

/** Seed 8 tasks + one pool holding them — exactly fills a 3×3-FREE board. */
async function seedPoolOfEight(page: Page): Promise<void> {
  for (const [i, id] of POOL_TASK_IDS.entries()) {
    await seedTask(page, { id, title: `Footer Task ${i + 1}`, type: 'normal' });
  }
  await seedPool(page, {
    id: 'eeeeeeee-0000-0000-0000-000000000001',
    name: 'Footer Pool',
    taskIds: POOL_TASK_IDS,
  });
}

/** From the Tasks step, pull the seeded pool and advance to Preview. */
async function pullPoolAndOpenPreview(page: Page): Promise<void> {
  await page.getByRole('button', { name: 'Add from a pool or board' }).click();
  const sheet = page.getByRole('dialog', { name: 'Add from a pool or board' });
  await sheet.getByRole('button', { name: /Footer Pool/ }).click();
  await sheet.getByRole('button', { name: 'Done', exact: true }).click();
  await expect(sheet).toBeHidden();
  await page.getByRole('button', { name: /^Next/ }).click();
}

/** Assert the primary sits on one line: no taller than the Back button. */
async function expectSingleLine(page: Page, primaryName: string): Promise<void> {
  const back = await page.getByRole('button', { name: '‹ Back' }).boundingBox();
  const primary = await page.getByRole('button', { name: primaryName, exact: true }).boundingBox();
  expect(back).not.toBeNull();
  expect(primary).not.toBeNull();
  expect(Math.abs((primary?.height ?? 0) - (back?.height ?? 0))).toBeLessThan(2);
}

test.describe('Wizard Preview step footer', () => {
  test.use({ viewport: { width: 393, height: 852 } });

  test('one-off: ‹ Back + Activate Board only, no wrap; the jiggle stops on leaving Rearrange', async ({
    page,
  }) => {
    await seedPoolOfEight(page);
    await openCreateHub(page);
    await startOneOffWizard(page);
    await page.getByLabel(/board name/i).fill('Footer Test Board');
    await page.getByRole('button', { name: '3×3', exact: true }).click();
    await page
      .getByRole('group', { name: 'Timeframe' })
      .getByRole('button', { name: 'Daily', exact: true })
      .click();
    await page.getByRole('button', { name: /^Next/ }).click();
    await pullPoolAndOpenPreview(page);

    await expect(page.getByRole('button', { name: 'Activate Board', exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: /save as draft/i })).toHaveCount(0);
    await expectSingleLine(page, 'Activate Board');
    await page.screenshot({ path: '.playwright-mcp/wizard-preview-footer-oneoff-393.png' });

    // Rearrange → cells jiggle; back to Preview → none do.
    const mode = page.getByRole('group', { name: 'Board arrangement mode' });
    const jiggling = page.locator('[data-wbcell][class*="jiggle"]');
    await mode.getByRole('button', { name: 'Rearrange', exact: true }).click();
    await expect(jiggling.first()).toBeVisible();
    expect(await jiggling.count()).toBeGreaterThan(0);
    await mode.getByRole('button', { name: 'Preview', exact: true }).click();
    await expect(jiggling).toHaveCount(0);
  });

  test('recurring create: ‹ Back + Create Board only, no wrap', async ({ page }) => {
    await seedPoolOfEight(page);
    await openCreateHub(page);
    await startRecurringWizard(page);
    await page.getByLabel(/board name/i).fill('Footer Repeat Board');
    await page.getByRole('button', { name: '3×3', exact: true }).click();
    await page.getByRole('button', { name: /^Next/ }).click();
    await pullPoolAndOpenPreview(page);

    await expect(page.getByRole('button', { name: 'Create Board', exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: /save as draft/i })).toHaveCount(0);
    await expectSingleLine(page, 'Create Board');
    await page.screenshot({ path: '.playwright-mcp/wizard-preview-footer-recurring-393.png' });
  });
});
