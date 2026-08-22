import { test, expect, openTab, openCreateHub, startOneOffWizard } from './_fixtures/bypass';

/**
 * E2E coverage for auth-gated routes via the dev-only auth bypass
 * (see `e2e/_fixtures/bypass.ts`). Each test starts with a wiped
 * Dexie + a freshly-inserted bypass user, so assertions can rely on
 * deterministic empty-state UI as the starting point.
 *
 * What this validates today:
 *
 *   - The bypass mechanism itself: AuthGate renders children rather
 *     than the sign-in form, with no Firebase calls in flight.
 *   - The Boards / Create / Profile tabs all reach an interactive
 *     state from a clean Dexie.
 *   - Board Creation Split (web PR C): the header "New board" button
 *     deep-links straight into the mode-locked ONE-OFF wizard, and the
 *     Create hub's own RED CTA reaches the same wizard.
 */

test.describe('auth-gated routes via bypass', () => {
  test('Boards tab renders the h1 heading + the Primary tab nav', async ({ page }) => {
    // Post-Riso the app boots to `/home` (App.tsx `<Navigate to="/home">`),
    // not `/boards`; the primary tabs are BUTTONS in `<nav aria-label="Primary">`
    // (the old bottom `TabBar` with aria-label="Main navigation" is gone).
    await openTab(page, 'Boards');
    await expect(page).toHaveURL(/\/boards/);
    // The Boards screen's h1 is "All boards" (the Riso billboard header).
    await expect(page.getByRole('heading', { name: 'All boards', level: 1 })).toBeVisible();
    await expect(page.getByRole('navigation', { name: 'Primary' })).toBeVisible();
  });

  test('header "New board" button opens the one-off wizard directly', async ({ page }) => {
    // "Create" is no longer a tab; the header "New board" button
    // deep-links straight into the mode-locked ONE-OFF wizard
    // (`/create?newBoard=one-off`), skipping the hub landing entirely
    // (Board Creation Split, web PR C).
    await page.getByRole('banner').getByRole('button', { name: 'New board' }).click();
    await expect(page).toHaveURL(/\/create/);

    // Wizard mounts — Setup step's Board name input is the most stable
    // hook (the field label rarely changes).
    await expect(page.getByLabel(/board name/i)).toBeVisible();
    // The kicker (not the H2, which now reads the step name "Setup")
    // carries the fresh one-off mode label.
    await expect(page.getByText(/new one-off board/i)).toBeVisible();
  });

  test('Create hub renders both mode-locked CTAs, and the one-off card opens its wizard', async ({ page }) => {
    await openCreateHub(page);
    await expect(page).toHaveURL(/\/create/);

    // Board Creation Split (web PR C) — two mode-locked cards, always
    // shown together at full strength.
    await expect(page.getByRole('button', { name: /start a one-off board/i })).toBeVisible();
    await expect(page.getByRole('button', { name: /start a recurring board/i })).toBeVisible();

    await startOneOffWizard(page);

    await expect(page.getByLabel(/board name/i)).toBeVisible();
    await expect(page.getByText(/new one-off board/i)).toBeVisible();
  });

  test('You tab renders the bypass user identity', async ({ page }) => {
    // "Profile" is now the "You" primary tab (mapped to `/profile`). Scope
    // to the Primary nav so we hit the tab, not the sibling "You" avatar
    // button in the header.
    await openTab(page, 'You');
    await expect(page).toHaveURL(/\/profile/);
    // The bypass fixture seeded `email: 'bypass@oybc.local'`. That's
    // a stable primary-key-shaped string distinct from any production
    // sign-in.
    await expect(page.getByText('bypass@oybc.local')).toBeVisible();
  });
});
