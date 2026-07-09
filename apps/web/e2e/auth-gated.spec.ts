import { test, expect, openTab, openCreateHub } from './_fixtures/bypass';

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

  test('New board opens the wizard via Start a new board', async ({ page }) => {
    // "Create" is no longer a tab; the header "New board" button opens the
    // Create hub, which offers the one-off "Start a new board" CTA.
    await openCreateHub(page);
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
