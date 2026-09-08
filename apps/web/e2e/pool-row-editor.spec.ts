import {
  test,
  expect,
  openCreateHub,
  seedCompoundChild,
  seedTask,
  startOneOffWizard,
} from './_fixtures/bypass';
import type { Page } from '@playwright/test';

/** Board Sources P4 — hand-add existing library tasks via the "Add from
 *  your library" sheet (source-pulled tasks live inside their source
 *  row's member panel now, without edit pencils — only hand-added rows
 *  are inline-editable). */
async function handAddFromLibrary(page: Page, titles: string[]): Promise<void> {
  await page.getByRole('button', { name: /^Add from your library/ }).click();
  const sheet = page.getByRole('dialog', { name: 'Your library' });
  await expect(sheet).toBeVisible();
  for (const title of titles) {
    // Row buttons carry subtitle/usage text in their accessible name —
    // match on the title substring (titles are unique per test).
    await sheet.getByRole('button', { name: title }).first().click();
  }
  await sheet.getByRole('button', { name: /^Done/ }).click();
  await expect(sheet).toBeHidden();
}

/**
 * Web inline-editing port PR-2 — e2e coverage for the wizard Tasks step's
 * inline `PoolRowEditor` (the ✎ pencil PR-1 stubbed). Covers: opening the
 * editor for a Counting row (edit + save updates the pool-row subtitle +
 * toasts), opening the editor for a Compound row (adds an inline sub-task),
 * Discard-with-Undo (reopens with typing intact), and Remove-with-Undo
 * (restores the row at its original position).
 *
 * Uses the one-off ("Start a one-off board") entry point, 3×3 FREE-center
 * (fillableCellCount = 8) so 8 hand-added tasks exactly satisfy the floor.
 * Board Sources P4: the tasks are HAND-ADDED via the library sheet —
 * source-pulled tasks render inside their source row's member panel and
 * are not inline-editable there.
 */

test.describe('Wizard Tasks step — inline PoolRowEditor (Inline Task Editing PR-2)', () => {
  test('editing a Counting task updates the pool-row subtitle and toasts; editing a Compound task adds an inline sub-task', async ({
    page,
  }) => {
    const countingId = 'aaaaaaaa-1111-0000-0000-000000000001';
    const compoundId = 'aaaaaaaa-1111-0000-0000-000000000002';
    const compoundChildAId = 'aaaaaaaa-1111-0000-0000-000000000003';
    const compoundChildBId = 'aaaaaaaa-1111-0000-0000-000000000004';
    const fillerIds = Array.from(
      { length: 5 },
      (_, i) => `aaaaaaaa-1111-0000-0000-00000000001${i}`,
    );

    await seedTask(page, { id: countingId, title: 'Run 5 km', type: 'counting', action: 'Run', unit: 'km', maxCount: 5 });
    await seedTask(page, { id: compoundChildAId, title: 'Make the bed', type: 'normal' });
    await seedTask(page, { id: compoundChildBId, title: 'Stretch', type: 'normal' });
    await seedTask(page, { id: compoundId, title: 'Morning routine', type: 'compound' });
    await seedCompoundChild(page, { id: 'link-a', compoundTaskId: compoundId, childTaskId: compoundChildAId, childIndex: 0 });
    await seedCompoundChild(page, { id: 'link-b', compoundTaskId: compoundId, childTaskId: compoundChildBId, childIndex: 1 });
    for (const [i, id] of fillerIds.entries()) {
      await seedTask(page, { id, title: `Filler Task ${i + 1}`, type: 'normal' });
    }

    // counting(1) + compound(1) + fillers(5) = 7; need 8, so one more.
    const extraFillerId = 'aaaaaaaa-1111-0000-0000-000000000099';
    await seedTask(page, { id: extraFillerId, title: 'Filler Task 6', type: 'normal' });

    await openCreateHub(page);
    await startOneOffWizard(page);
    await page.getByLabel(/board name/i).fill('Inline Editor Test Board');
    await page.getByRole('button', { name: '3×3', exact: true }).click();
    await page
      .getByRole('group', { name: 'Timeframe' })
      .getByRole('button', { name: 'Daily', exact: true })
      .click();
    await page.getByRole('button', { name: /^Next/ }).click();

    // Hand-add all 8 via the library sheet — satisfies the 3×3 FREE floor.
    await handAddFromLibrary(page, [
      'Run 5 km',
      'Morning routine',
      'Filler Task 1',
      'Filler Task 2',
      'Filler Task 3',
      'Filler Task 4',
      'Filler Task 5',
      'Filler Task 6',
    ]);
    await expect(page.getByLabel('Capacity 8 of 8 tasks')).toBeVisible();

    // ── Counting editor: open, edit the goal, save ──────────────────────
    const countingRow = page.getByRole('listitem').filter({ hasText: 'Run 5 km' });
    await expect(countingRow).toBeVisible();
    await countingRow.getByRole('button', { name: /^Edit Run 5 km$/ }).click();

    const editor = page.locator('li').filter({ hasText: 'EDITING · COUNTING TASK' });
    await expect(editor).toBeVisible();
    await page.waitForTimeout(150);
    await page.screenshot({ path: '.playwright-mcp/pool-row-editor-01-counting-light.png' });

    const goalInput = editor.getByLabel('Goal', { exact: true });
    await goalInput.fill('10');
    await expect(editor.getByText('Reads as: Run — 10 — km')).toBeVisible();
    await editor.getByRole('button', { name: 'Save task' }).click();

    // Toast confirms the stage (not yet persisted).
    await expect(page.getByText(/Staged/)).toBeVisible();

    // The resting row's title AND subtitle now reflect the staged edit
    // immediately — the title re-derives to "Run 10 km" because it still
    // matched its auto-generated form when the editor opened (blanked by
    // `seedPatchForEditor` so it keeps deriving as the goal changes).
    const updatedCountingRow = page.getByRole('listitem').filter({ hasText: 'Run 10 km' });
    await expect(updatedCountingRow).toBeVisible();
    await expect(updatedCountingRow).toContainText('goal 10 km');
    await page.waitForTimeout(6100); // let the toast auto-dismiss before the next screenshot
    await page.screenshot({ path: '.playwright-mcp/pool-row-editor-02-counting-saved.png' });

    // ── Compound editor: open, add an inline sub-task, save ─────────────
    const compoundRow = page.getByRole('listitem').filter({ hasText: 'Morning routine' });
    await compoundRow.getByRole('button', { name: /^Edit Morning routine$/ }).click();

    const compoundEditor = page.locator('li').filter({ hasText: 'EDITING · COMPOUND TASK' });
    await expect(compoundEditor).toBeVisible();
    // Sub-task titles render as input values, not text nodes.
    await expect(compoundEditor.getByLabel('Sub-task 1 title')).toHaveValue('Make the bed');
    await expect(compoundEditor.getByLabel('Sub-task 2 title')).toHaveValue('Stretch');
    await page.waitForTimeout(150);
    await page.screenshot({ path: '.playwright-mcp/pool-row-editor-03-compound-light.png' });

    await compoundEditor.getByRole('button', { name: '+ Normal sub-task' }).click();
    const newSubtaskInput = compoundEditor.getByLabel(/Sub-task 3 title/);
    await newSubtaskInput.fill('Cold rinse');
    await compoundEditor.getByRole('button', { name: 'Save task' }).click();

    const updatedCompoundRow = page.getByRole('listitem').filter({ hasText: 'Morning routine' });
    await expect(updatedCompoundRow).toContainText('3 sub-tasks');

    // ── Discard-with-Undo: reopens the row with the typing intact ───────
    await updatedCompoundRow.getByRole('button', { name: /^Edit Morning routine$/ }).click();
    const reopenedEditor = page.locator('li').filter({ hasText: 'EDITING · COMPOUND TASK' });
    const titleField = reopenedEditor.getByLabel('Task title', { exact: true });
    await titleField.fill('Morning routine (typo)');
    await reopenedEditor.getByRole('button', { name: 'Discard' }).click();
    await expect(page.getByText('Edit discarded')).toBeVisible();
    await page.getByRole('button', { name: 'UNDO' }).click();
    const undoneEditor = page.locator('li').filter({ hasText: 'EDITING · COMPOUND TASK' });
    await expect(undoneEditor.getByLabel('Task title', { exact: true })).toHaveValue('Morning routine (typo)');
    await undoneEditor.getByRole('button', { name: 'Discard' }).click();

    // ── Keyboard: Esc discards, ⌘/Ctrl+Enter saves ───────────────────────
    await updatedCompoundRow.getByRole('button', { name: /^Edit Morning routine$/ }).click();
    const kbEditor = page.locator('li').filter({ hasText: 'EDITING · COMPOUND TASK' });
    await kbEditor.getByLabel('Task title', { exact: true }).fill('Morning routine (esc test)');
    await page.keyboard.press('Escape');
    await expect(page.getByText('Edit discarded')).toBeVisible();
    await expect(kbEditor).toBeHidden();

    await updatedCompoundRow.getByRole('button', { name: /^Edit Morning routine$/ }).click();
    const kbEditor2 = page.locator('li').filter({ hasText: 'EDITING · COMPOUND TASK' });
    await kbEditor2.getByLabel('Task title', { exact: true }).fill('Morning routine (ctrl-enter save)');
    await page.keyboard.press('Control+Enter');
    await expect(page.getByText(/Staged/)).toBeVisible();
    await expect(page.getByRole('listitem').filter({ hasText: 'Morning routine (ctrl-enter save)' })).toBeVisible();

    // ── Remove-with-Undo: restores the row ───────────────────────────────
    const fillerRow = page.getByRole('listitem').filter({ hasText: 'Filler Task 1' });
    await fillerRow.getByRole('button', { name: /Remove Filler Task 1 from board/ }).click();
    await expect(page.getByText('Removed "Filler Task 1"')).toBeVisible();
    await expect(page.getByLabel('Capacity 7 of 8 tasks')).toBeVisible();
    await page.getByRole('button', { name: 'UNDO' }).click();
    await expect(page.getByLabel('Capacity 8 of 8 tasks')).toBeVisible();
    await expect(page.getByRole('listitem').filter({ hasText: 'Filler Task 1' })).toBeVisible();
  });

  test('the counting + compound editors render correctly in dark mode', async ({ page }) => {
    await page.emulateMedia({ colorScheme: 'dark' });

    const countingId = 'bbbbbbbb-1111-0000-0000-000000000001';
    const compoundId = 'bbbbbbbb-1111-0000-0000-000000000002';
    const childId = 'bbbbbbbb-1111-0000-0000-000000000003';
    const child2Id = 'bbbbbbbb-1111-0000-0000-000000000004';
    const fillerIds = Array.from(
      { length: 6 },
      (_, i) => `bbbbbbbb-1111-0000-0000-00000000001${i}`,
    );

    await seedTask(page, { id: countingId, title: 'Read 20 pages', type: 'counting', action: 'Read', unit: 'pages', maxCount: 20 });
    await seedTask(page, { id: childId, title: 'Vacuum', type: 'normal' });
    await seedTask(page, { id: child2Id, title: 'Dust', type: 'normal' });
    await seedTask(page, { id: compoundId, title: 'Clean house', type: 'compound' });
    await seedCompoundChild(page, { id: 'dark-link-a', compoundTaskId: compoundId, childTaskId: childId, childIndex: 0 });
    await seedCompoundChild(page, { id: 'dark-link-b', compoundTaskId: compoundId, childTaskId: child2Id, childIndex: 1 });
    for (const [i, id] of fillerIds.entries()) {
      await seedTask(page, { id, title: `Dark Filler ${i + 1}`, type: 'normal' });
    }
    await openCreateHub(page);
    await startOneOffWizard(page);
    await page.getByLabel(/board name/i).fill('Dark Mode Editor Board');
    await page.getByRole('button', { name: '3×3', exact: true }).click();
    await page
      .getByRole('group', { name: 'Timeframe' })
      .getByRole('button', { name: 'Daily', exact: true })
      .click();
    await page.getByRole('button', { name: /^Next/ }).click();
    await handAddFromLibrary(page, [
      'Read 20 pages',
      'Clean house',
      ...Array.from({ length: 6 }, (_, i) => `Dark Filler ${i + 1}`),
    ]);
    await expect(page.getByLabel('Capacity 8 of 8 tasks')).toBeVisible();

    const countingRow = page.getByRole('listitem').filter({ hasText: 'Read 20 pages' });
    await countingRow.getByRole('button', { name: /^Edit Read 20 pages$/ }).click();
    await expect(page.locator('li').filter({ hasText: 'EDITING · COUNTING TASK' })).toBeVisible();
    await page.waitForTimeout(150);
    await page.screenshot({ path: '.playwright-mcp/pool-row-editor-04-counting-dark.png' });
    await page.getByRole('button', { name: 'Discard' }).click();

    const compoundRow = page.getByRole('listitem').filter({ hasText: 'Clean house' });
    await compoundRow.getByRole('button', { name: /^Edit Clean house$/ }).click();
    await expect(page.locator('li').filter({ hasText: 'EDITING · COMPOUND TASK' })).toBeVisible();
    await page.waitForTimeout(150);
    await page.screenshot({ path: '.playwright-mcp/pool-row-editor-05-compound-dark.png' });
  });
});
