import {
  test,
  expect,
  seedTemplate,
  clearTemplates,
  openCreateHub,
} from './_fixtures/bypass';

/**
 * E2E coverage for the Phase 6.2 UX rework.
 *
 * Covers the consolidation work — the wizard now hosts both one-off
 * and recurring board creation as a Setup-step toggle, and templates
 * live on a Profile sub-page (not the Create tab).
 *
 * Notably NOT covered here (yet):
 * - End-to-end create-and-spawn flow (requires task seeding + 3 wizard
 *   steps of clicks + assertions on a spawned board appearing). Worth
 *   adding when a test that walks the full happy path catches a real
 *   regression; until then the manual QA in PR #52's test plan
 *   covers it.
 * - Tasks-step pool-flex count suffix ("X / N exact" vs "X / N min")
 *   — needs task seeding too. Add later if the suffix copy regresses.
 */

test.describe('Phase 6.2 rework', () => {
  // The "Make recurring" Setup-step toggle was retired: one-off vs recurring
  // board creation are now two distinct Create-hub entry points ("Start a new
  // board" vs "Create a recurring board"), each opening its own wizard. The
  // load-bearing invariant survives — recurring boards can't use the CUSTOM
  // timeframe — so these two tests now assert it via the two entry points
  // instead of a toggle.

  test('one-off board wizard offers the Custom timeframe', async ({ page }) => {
    await openCreateHub(page);
    await page.getByRole('button', { name: /start a new board/i }).click();
    await expect(page.getByLabel(/board name/i)).toBeVisible();

    // The one-off wizard includes Custom in the timeframe segmented selector.
    await expect(page.getByRole('button', { name: 'Custom', exact: true })).toBeVisible();
  });

  test('recurring board wizard omits the Custom timeframe', async ({ page }) => {
    await openCreateHub(page);
    await page.getByRole('button', { name: /create a recurring board/i }).click();
    await expect(page.getByLabel(/board name/i)).toBeVisible();

    // The recurring wizard exposes Daily/Weekly/Monthly/Yearly but NOT Custom
    // (the recurring schema rejects it — its absence is the affordance).
    await expect(page.getByRole('button', { name: 'Weekly', exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Custom', exact: true })).toHaveCount(0);
  });

  test('Profile templates page renders empty state when no templates exist', async ({ page }) => {
    // Belt: ensure no leftover templates from prior tests in the file.
    await clearTemplates(page);
    // Re-navigate so the live query observer re-fetches — clearing
    // mid-render doesn't always trigger Dexie's observer eagerly.
    await page.goto('/profile/recurring-templates?__oybc_test_bypass=1');

    await expect(
      page.getByRole('heading', { name: /recurring templates/i }),
    ).toBeVisible();
    // Empty-state copy from RecurringTemplatesPage.
    await expect(page.getByText(/no recurring templates yet/i)).toBeVisible();
    // The empty-state body now points at the "Create a recurring board"
    // Create-hub entry point (the retired "Make recurring in setup" toggle).
    await expect(page.getByText(/create a recurring board/i)).toBeVisible();
  });

  test('Profile templates page lists a seeded template + Edit deep-links into the wizard', async ({ page }) => {
    // Seed a template directly into Dexie via the fixture helper,
    // then navigate. Bypasses the create-input Zod schema (so the
    // shape here is the at-rest layout) but matches what the spawn
    // driver expects.
    const templateId = '11111111-2222-3333-4444-555555555555';
    await seedTemplate(page, {
      id: templateId,
      name: 'Daily Workout',
      timeframe: 'daily',
      boardSize: 5,
      centerSquareType: 'free',
      isRandomized: true,
      seedTaskIds: Array.from({ length: 24 }, (_, i) =>
        // 24 task ids that don't need to resolve — Profile-list rendering
        // doesn't need real Tasks; only the spawn driver reads them.
        `aaaaaaaa-aaaa-aaaa-aaaa-${String(i).padStart(12, '0')}`,
      ),
      isActive: true,
    });
    await page.goto('/profile/recurring-templates?__oybc_test_bypass=1');

    // The seeded template's name appears in the row.
    await expect(page.getByText('Daily Workout')).toBeVisible();
    // Active toggle is shown as checked + labeled.
    await expect(
      page.getByRole('checkbox', { name: /(pause|activate) Daily Workout/i }),
    ).toBeVisible();

    // Tap Edit — should navigate to /create with the editTemplate
    // query param. CreateHubPage's useEffect consumes the param and
    // immediately enters wizard mode, then clears the param.
    await page.getByRole('button', { name: 'Edit' }).click();

    // After the consume-and-clear, the URL should be `/create` (no
    // query string). Wait for the wizard to mount + the Board name
    // field to hydrate from the template.
    await expect(page).toHaveURL(/\/create$/);
    const nameInput = page.getByLabel(/board name/i);
    await expect(nameInput).toHaveValue('Daily Workout');

    // Editing a template forces the RECURRING wizard (the retired "Make
    // recurring" toggle is now implied by the entry point): the header reads
    // "Edit recurring board" and Custom is absent from the timeframe selector.
    await expect(page.getByRole('heading', { name: /edit recurring board/i })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Custom', exact: true })).toHaveCount(0);
  });
});
