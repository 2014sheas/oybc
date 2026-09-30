import { test, expect, readUserPreferences } from './_fixtures/bypass';

/**
 * E2E coverage for the Profile reorg PR1 web track
 * (`design_handoff_profile_reorg/README.md` §Screens — Web `/profile/settings`
 * frame `#5b`; `.superpowers/sdd/2026-09-30-profile-reorg/owner-decisions.md`).
 *
 * Covers the new `/profile/settings` and `/profile/help` routes, the Settings
 * pill entry point on `/profile`, and that the moved "Board renewals" toggles
 * (owner decision 3) actually persist to the same `recurring*Enabled` prefs
 * Board settings used to own.
 */
test.describe('Profile → Settings', () => {
  test('Settings pill navigates from Profile to /profile/settings', async ({ page }) => {
    await page.goto('/profile?__oybc_test_bypass=1');
    await expect(page.getByRole('heading', { name: 'Profile' })).toBeVisible();

    await page.getByRole('button', { name: 'Settings' }).click();

    await expect(page).toHaveURL(/\/profile\/settings/);
    await expect(page.getByRole('heading', { name: 'Settings' })).toBeVisible();
  });

  test('Theme segmented control switches the applied theme', async ({ page }) => {
    await page.goto('/profile/settings?__oybc_test_bypass=1');

    const themeGroup = page.getByRole('group', { name: 'Theme' });
    await themeGroup.getByRole('button', { name: 'Dark' }).click();

    await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
    await expect(themeGroup.getByRole('button', { name: 'Dark' })).toHaveAttribute(
      'aria-pressed',
      'true',
    );
  });

  test('Board renewals toggle persists to preferences', async ({ page }) => {
    await page.goto('/profile/settings?__oybc_test_bypass=1');

    await expect(page.getByText('Board renewals')).toBeVisible();
    const dailyToggle = page.locator('#pref-recurringDailyEnabled');

    // Default prefs start all four renewal prompts ON — flip daily OFF.
    await expect(dailyToggle).toBeChecked();
    await dailyToggle.locator('..').click();
    await expect(dailyToggle).not.toBeChecked();

    await expect
      .poll(async () => {
        const prefs = await readUserPreferences(page);
        return prefs?.recurringDailyEnabled;
      })
      .toBe(false);
  });

  test('Account & security row links to /profile/account-security', async ({ page }) => {
    await page.goto('/profile/settings?__oybc_test_bypass=1');

    await page.getByRole('link', { name: /Account & security/ }).click();
    await expect(page).toHaveURL(/\/profile\/account-security/);
  });

  test('Help & getting started shows the placeholder pages', async ({ page }) => {
    await page.goto('/profile/settings?__oybc_test_bypass=1');

    await page.getByRole('link', { name: /Help & getting started/ }).click();
    await expect(page).toHaveURL(/\/profile\/help/);
    await expect(page.getByRole('heading', { name: 'Help' })).toBeVisible();
    await expect(page.getByText('Getting started')).toBeVisible();
    await expect(page.getByText('Contact support')).toBeVisible();
    // Both placeholders read "Coming soon" (owner decisions 1 and 4).
    await expect(page.getByText('Coming soon')).toHaveCount(2);
  });

  test('Sign out opens the confirm modal', async ({ page }) => {
    await page.goto('/profile/settings?__oybc_test_bypass=1');

    await page.getByRole('button', { name: 'Sign Out', exact: true }).click();
    await expect(page.getByRole('dialog', { name: /sign out/i })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Sign out?' })).toBeVisible();

    // Dismiss without actually signing out — this bypass session doesn't
    // hold a real Firebase auth state to sign out of.
    await page.getByRole('button', { name: 'Cancel' }).click();
    await expect(page.getByRole('dialog', { name: /sign out/i })).toBeHidden();
  });
});
