import { test, expect } from './_fixtures/bypass';

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
 *   - The wizard's Setup step renders when the user taps the Create
 *     CTA — partial coverage of the in-flight Phase 6.2 UX rework
 *     (the recurring toggle isn't on `dev` yet, but will be after
 *     PR #52 merges; one of these tests already verifies the form's
 *     baseline shape so the toggle's addition produces a meaningful
 *     diff in CI).
 */

test.describe('auth-gated routes via bypass', () => {
  test('lands on Boards tab — h1 heading + tab nav both render', async ({ page }) => {
    // The bypass fixture already navigated us to `/`; the Boards tab
    // is the default route per `App.tsx`'s `<Navigate to="/boards">`.
    await expect(page.getByRole('heading', { name: 'Boards', exact: true })).toBeVisible();
    // The tab nav has aria-label="Main navigation" (TabBar.tsx).
    await expect(page.getByRole('navigation', { name: 'Main navigation' })).toBeVisible();
  });

  test('Create tab opens the wizard via Start a new board', async ({ page }) => {
    // Navigate to Create via the tab bar.
    await page.getByRole('link', { name: /create/i }).click();
    await expect(page).toHaveURL(/\/create/);

    // CreateHubBoardCTA renders one of two visual variants — primary
    // (gradient card) or secondary (muted card) — depending on whether
    // pending recurring boards exist above it. Post-Phase-6.2 rework
    // both variants share the same "Start a new board" copy so this
    // selector matches either visual presentation.
    const cta = page.getByRole('button', { name: /start a new board/i });
    await expect(cta).toBeVisible();
    await cta.click();

    // Wizard mounts — Setup step's Board name input is the most stable
    // hook (the field label rarely changes).
    await expect(page.getByLabel(/board name/i)).toBeVisible();
    // The wizard header surfaces "New board" or "Resume draft"; we
    // chose fresh-create so it's "New board".
    await expect(page.getByRole('heading', { name: 'New board', exact: true })).toBeVisible();
  });

  test('Profile tab renders the bypass user identity', async ({ page }) => {
    // The Profile link in TabBar is a `react-router-dom <NavLink>`,
    // which renders as <a>. `getByRole('link', { name: /profile/i })`
    // matches both that link AND any other "profile"-named link on
    // the page (none today, but stay specific). Use the link's
    // `to="/profile"` href for reliability.
    await page.getByRole('link', { name: 'Profile' }).click();
    await expect(page).toHaveURL(/\/profile/);
    // The bypass fixture seeded `email: 'bypass@oybc.local'`. That's
    // a stable primary-key-shaped string distinct from any production
    // sign-in.
    await expect(page.getByText('bypass@oybc.local')).toBeVisible();
  });
});
