import type { Page } from '@playwright/test';
import {
  test,
  expect,
  openTab,
  seedPool,
  seedTask,
} from './_fixtures/bypass';

/**
 * `useModalA11y` (2026-09 audit, web a11y) — the focus-handoff cases that a
 * string render can't reach:
 *
 *  1. A dialog opened from a `RowContextMenu` item. The item unmounts on
 *     click, so the dialog's render-time opener is gone; the menu hands
 *     focus back to what held it before it opened, and the dialog restores
 *     THAT on close — never <body> (where Escape reaches nothing).
 *  2. The pool editor page's inline delete confirm (the only dialog left
 *     on that page): one Escape closes only the confirm, and focus falls
 *     back into the page even though the "Delete pool" link that opened
 *     the confirm has been unmounted.
 */

const STRETCH_ID = '71000000-0000-0000-0000-000000000001';
const COUNTER_ID = '71000000-0000-0000-0000-000000000002';
const POOL_ID = '71000000-0000-0000-0000-000000000010';

/** Tag name of the focused element (`BODY` when focus has been dropped). */
async function focusedTag(page: Page): Promise<string | undefined> {
  return page.evaluate(() => document.activeElement?.tagName);
}

// NOTE: the review's original repro — right-click a row in the wizard's
// "Add from your library" sheet → a menu item — is unreachable in the UI
// today: `BoardWizardTasksStep` hides the Library entry behind
// `LIBRARY_ENTRY_ENABLED` (owner, 2026-09-17). The same RowContextMenu →
// dialog hand-off is reachable on Counter Detail's "⋯" menu, pinned here.
test.describe('RowContextMenu → dialog — focus is handed back, never dropped', () => {
  test('Counter options → Delete counter… → Escape returns focus to the ⋯ button, not <body>', async ({
    page,
  }) => {
    await seedTask(page, {
      id: COUNTER_ID,
      title: 'Push-ups',
      type: 'counting',
      action: 'Push-ups',
      unit: 'reps',
      maxCount: 100,
      currentCount: 0,
      isCounter: true,
    });
    await page.goto(`/profile/counters/${COUNTER_ID}?__oybc_test_bypass=1`);

    const overflow = page.getByRole('button', { name: 'Counter options' });
    await overflow.click();
    // The clicked menu item unmounts with the menu; RowContextMenu hands
    // focus back to what held it when the menu opened (the ⋯ button).
    await page.getByRole('menuitem', { name: /Delete counter/ }).click();
    await expect(page.getByRole('menu')).toHaveCount(0);

    const confirm = page.getByRole('alertdialog', { name: 'Confirm delete counter' });
    await expect(confirm).toBeVisible();
    await expect(confirm.getByRole('button', { name: 'Cancel', exact: true })).toBeFocused();

    await page.keyboard.press('Escape');
    await expect(confirm).toHaveCount(0);
    await expect(overflow).toBeFocused();
    expect(await focusedTag(page)).not.toBe('BODY');
  });
});

test.describe('Pool editor page — the delete confirm is the one dialog', () => {
  test('Delete pool opens the confirm (focus on Cancel); Escape closes only it; Delete returns to Pools', async ({
    page,
  }) => {
    await seedTask(page, { id: STRETCH_ID, title: 'Stretch', type: 'normal' });
    await seedPool(page, { id: POOL_ID, name: 'Mobility', taskIds: [STRETCH_ID] });

    await page.goto('/boards');
    await openTab(page, 'Tasks');
    await page.getByRole('button', { name: /^Pools · 1/ }).click();
    await page.getByRole('button', { name: 'Edit pool Mobility' }).click();

    // The editor is a page now — no dialog until the delete confirm.
    await expect(page).toHaveURL(new RegExp(`/tasks/pools/${POOL_ID}$`));
    await expect(page.getByRole('dialog')).toHaveCount(0);
    await page.getByRole('button', { name: 'Delete pool' }).click();

    const confirm = page.getByRole('alertdialog', { name: 'Confirm delete pool' });
    await expect(confirm).toBeVisible();
    await expect(confirm.getByRole('button', { name: 'Cancel', exact: true })).toBeFocused();

    await page.keyboard.press('Escape');
    await expect(confirm).toHaveCount(0);
    // Still on the editor page; focus went back to the link that opened the confirm.
    await expect(page).toHaveURL(new RegExp(`/tasks/pools/${POOL_ID}$`));
    await expect(page.getByRole('button', { name: 'Delete pool' })).toBeFocused();

    await page.getByRole('button', { name: 'Delete pool' }).click();
    await page
      .getByRole('alertdialog', { name: 'Confirm delete pool' })
      .getByRole('button', { name: 'Delete', exact: true })
      .click();
    await expect(page).toHaveURL(/\/tasks\?segment=pools$/);
    await expect(page.getByRole('button', { name: 'Edit pool Mobility' })).toHaveCount(0);
  });
});
