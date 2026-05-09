import {
  test,
  expect,
  seedTemplate,
  clearTemplates,
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
  test('Setup-step toggle reveals pool strategy + hides Custom timeframe', async ({ page }) => {
    // Open the wizard via the Create-tab CTA. Same matcher as the
    // baseline auth-gated test (handles both primary and secondary
    // CTA copy depending on whether pending recurring boards exist).
    await page.getByRole('link', { name: /create/i }).click();
    await page.getByRole('button', { name: /start a new board/i }).click();
    await expect(page.getByLabel(/board name/i)).toBeVisible();

    // Initial state: Custom is in the timeframe segmented selector,
    // pool-strategy radio is NOT visible.
    const timeframeCustom = page.getByRole('button', { name: 'Custom', exact: true });
    await expect(timeframeCustom).toBeVisible();
    await expect(page.getByText(/use every task/i)).not.toBeVisible();

    // Flip the "Make recurring" toggle. The label is rendered inside a
    // <label> wrapping the checkbox, so we click the checkbox by name.
    const toggle = page.getByRole('checkbox', { name: /make recurring/i });
    await toggle.check();
    await expect(toggle).toBeChecked();

    // Pool-strategy radio appears (matches the strategy hint copy
    // from BoardSetupForm — "Pool size must equal" / "Pool can be
    // larger").
    await expect(page.getByText(/use every task/i)).toBeVisible();
    await expect(page.getByText(/random subset/i)).toBeVisible();

    // Custom timeframe option disappears from the segmented selector
    // (the recurring schema rejects it). The hint copy explaining
    // why surfaces too.
    await expect(timeframeCustom).not.toBeVisible();
    await expect(
      page.getByText(/recurring boards use computed windows/i),
    ).toBeVisible();
  });

  test('Setup-step toggle off restores Custom timeframe', async ({ page }) => {
    await page.getByRole('link', { name: /create/i }).click();
    await page.getByRole('button', { name: /start a new board/i }).click();

    const toggle = page.getByRole('checkbox', { name: /make recurring/i });
    await toggle.check();
    await expect(page.getByRole('button', { name: 'Custom', exact: true })).not.toBeVisible();

    // Toggle off — Custom returns and the pool-strategy radio hides.
    await toggle.uncheck();
    await expect(toggle).not.toBeChecked();
    await expect(page.getByRole('button', { name: 'Custom', exact: true })).toBeVisible();
    await expect(page.getByText(/use every task/i)).not.toBeVisible();
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
    // The empty-state body explains the wizard-toggle entry-point.
    await expect(page.getByText(/toggle.*make recurring.*setup step/i)).toBeVisible();
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
      poolStrategy: 'all',
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

    // The Recurring toggle is forced ON because we're editing a template.
    await expect(page.getByRole('checkbox', { name: /make recurring/i })).toBeChecked();
  });
});
