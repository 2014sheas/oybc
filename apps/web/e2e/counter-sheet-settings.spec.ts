import { test, expect, readTask, readTaskByTitle, seedTask } from './_fixtures/bypass';

/**
 * docs/SHARED_COUNTER_SETTINGS.md §1 (the UI PR) — the counter sheet's new
 * fields. Create: only noun + verb are required; Name / titles / Defaults
 * show their derived defaults dimmed and store only what was typed (a weekly
 * default derives the other timeframes). Edit: stored values solid, derived
 * ones dimmed; clearing a field stores it absent and the goal-less root's
 * title follows the derived name.
 */

const ROOT = 'f5000000-0000-0000-0000-000000000001';

test.describe('Counter sheet — shared counter settings', () => {
  test('create: required-field validation, dimmed defaults, stores only typed settings', async ({ page }) => {
    await page.goto('/profile/counters?__oybc_test_bypass=1');
    await page.getByRole('button', { name: /New counter/ }).first().click();
    const sheet = page.getByRole('dialog', { name: 'New counter' });
    await expect(sheet).toBeVisible();

    const noun = sheet.getByLabel('What are you counting?');
    const verb = sheet.getByLabel('Task verb', { exact: true });
    const name = sheet.getByRole('textbox', { name: 'Name', exact: true });
    const create = sheet.getByRole('button', { name: 'Create counter' });

    // Nothing typed: the primary is disabled and no error shows yet.
    await expect(create).toBeDisabled();
    await expect(sheet.getByText("Enter what you're counting.")).toHaveCount(0);

    // Edited then emptied → the noun error; an empty verb blurred → the verb error.
    await noun.fill('b');
    await noun.fill('');
    await expect(sheet.getByText("Enter what you're counting.")).toBeVisible();
    await verb.focus();
    await verb.blur();
    await expect(sheet.getByText('Enter a verb.')).toBeVisible();

    await noun.fill('books');
    await verb.fill('Read');
    await expect(sheet.getByText("Enter what you're counting.")).toHaveCount(0);
    await expect(sheet.getByText('Enter a verb.')).toHaveCount(0);
    await expect(create).toBeEnabled();

    // Derived defaults, dimmed: the name and both templates; the Defaults cells empty.
    await expect(name).toHaveValue('Read books');
    await expect(name).toHaveAttribute('data-dim', 'true');
    const singular = sheet.getByRole('textbox', { name: 'Singular title' });
    await expect(singular).toHaveValue('Read #N books');
    await expect(singular).toHaveAttribute('data-dim', 'true');
    await expect(sheet.getByLabel('Singular title renders as')).toHaveText(/Read 1 books/);
    await expect(sheet.getByLabel('Plural title renders as')).toHaveText(/Read 12 books/);
    await expect(sheet.getByLabel('Weekly default')).toHaveValue('');

    // Type a singular template + a weekly default: solid; the other timeframes derive, dimmed.
    await singular.fill('Read #N book');
    await expect(singular).not.toHaveAttribute('data-dim', 'true');
    await expect(sheet.getByLabel('Singular title renders as')).toHaveText(/Read 1 book$/);
    await sheet.getByLabel('Weekly default').fill('2');
    await expect(sheet.getByLabel('Monthly default')).toHaveValue('9');
    await expect(sheet.getByLabel('Yearly default')).toHaveValue('105');
    await expect(sheet.getByLabel('Daily default')).toHaveValue('1');

    await create.click();
    await expect(sheet).toHaveCount(0);

    const saved = await readTaskByTitle(page, 'Read books');
    expect(saved).toMatchObject({ action: 'Read', unit: 'books', isCounter: true, titleTemplateSingular: 'Read #N book', timeframeGoals: { weekly: 2 } });
    // Untyped fields stay absent (D3) — the name and the plural template were never stored.
    expect(saved).not.toHaveProperty('counterName');
    expect(saved).not.toHaveProperty('titleTemplatePlural');
  });

  test('edit: stored solid, derived dimmed; clearing the name stores it absent and the title follows', async ({ page }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await seedTask(page, {
      id: ROOT, title: 'Books', type: 'counting', action: 'Read', unit: 'books', isCounter: true, currentCount: 0,
      counterName: 'Books', titleTemplateSingular: 'Read #N book', timeframeGoals: { weekly: 2 },
    });
    await page.goto(`/profile/counters/${ROOT}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Counter options' }).click();
    await page.getByRole('menuitem', { name: /Edit counter…/ }).click();
    const sheet = page.getByRole('dialog', { name: 'Edit counter' });
    await expect(sheet).toBeVisible();

    const name = sheet.getByRole('textbox', { name: 'Name', exact: true });
    await expect(name).toHaveValue('Books');
    await expect(name).not.toHaveAttribute('data-dim', 'true');
    await expect(sheet.getByRole('textbox', { name: 'Singular title' })).toHaveValue('Read #N book');
    await expect(sheet.getByRole('textbox', { name: 'Singular title' })).not.toHaveAttribute('data-dim', 'true');
    await expect(sheet.getByRole('textbox', { name: 'Plural title' })).toHaveValue('Read #N books');
    await expect(sheet.getByRole('textbox', { name: 'Plural title' })).toHaveAttribute('data-dim', 'true');
    await expect(sheet.getByLabel('Weekly default')).toHaveValue('2');
    await expect(sheet.getByLabel('Monthly default')).toHaveValue('9');
    await expect(sheet.getByText('Start from')).toHaveCount(0);

    // Clear the name → back to the dimmed derived name; a typed plural goes solid.
    await name.fill('');
    await expect(name).toHaveValue('Read books');
    await expect(name).toHaveAttribute('data-dim', 'true');
    await sheet.getByRole('textbox', { name: 'Plural title' }).fill('Read #N novels');
    await sheet.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(sheet).toHaveCount(0);

    await expect.poll(async () => readTask(page, ROOT)).toMatchObject({ title: 'Read books', titleTemplatePlural: 'Read #N novels', timeframeGoals: { weekly: 2 } });
    expect(await readTask(page, ROOT)).not.toHaveProperty('counterName');
  });
});
