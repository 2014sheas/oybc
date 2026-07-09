import {
  test,
  expect,
  seedBoard,
  openCreateHub,
} from './_fixtures/bypass';

/**
 * E2E coverage for the Create-tab hub-shell behaviours that aren't
 * already covered by `recurring-rework.spec.ts` (template editing) or
 * `auth-gated.spec.ts` (fresh-wizard entry).
 *
 * Currently:
 * - Draft resume: tapping a DRAFT board from the hub mounts the wizard
 *   hydrated from that draft. Directly exercises `useResumableDraft`
 *   (web) and the parallel `loadDraftAndEnterWizard` path on iOS — the
 *   only `fetchBoardTasks` call that the hub container still owns.
 *
 * The "recurringTimeframe URL deep-link" path (`useRecurringTimeframeParam`)
 * is not yet covered automatically; it's exercised manually via the
 * Boards-tab banner click + by the in-app toggle test in
 * `recurring-rework.spec.ts`. Add a test here when that path regresses.
 */

test.describe('Create hub', () => {
  test('tapping a draft from the hub resumes the wizard hydrated from that draft', async ({ page }) => {
    // Seed a draft board for the bypass user. Status='draft' is what
    // `useDrafts` filters for; the rest of the fields are whatever the
    // wizard's hydration reads.
    const draftId = 'cccccccc-1111-2222-3333-444444444444';
    await seedBoard(page, {
      id: draftId,
      name: 'My Drafted Board',
      boardSize: 5,
      timeframe: 'weekly',
      status: 'draft',
      // Start/end dates are required for non-custom timeframes; values
      // here don't matter for resume-hydration, only for activation.
      startDate: '2026-05-11',
      endDate: '2026-05-17',
      centerSquareType: 'free',
      isRandomized: false,
    });

    // Open the Create hub (header "New board") so `useDrafts`'s live-query
    // observer picks up the seeded row. The bypass fixture already promoted
    // the session-storage flag during the root visit, so the in-app
    // navigation keeps the bypass live.
    await openCreateHub(page);

    // The Drafts section is rendered conditionally (`drafts.length > 0`).
    // Assert it shows up, then locate the specific draft's row via its
    // aria-label, which embeds the board name + geometry.
    const draftRow = page.getByRole('button', { name: /resume "my drafted board"/i });
    await expect(draftRow).toBeVisible();

    // Tap the row. `useResumableDraft` fetches `boardTasks` (empty in
    // this seeded case — no placed cells), then `CreateHubPage` flips
    // mode to `wizard` with the hydrated draft payload.
    await draftRow.click();

    // The wizard mounts. Its setup-step header reads "Resume draft"
    // (vs. "New board" in fresh-create mode) — that's the load-bearing
    // signal that the draft path took.
    await expect(page.getByRole('heading', { name: /resume draft/i })).toBeVisible();

    // Board-name field hydrated from the draft. Confirms the draft
    // payload actually threaded through `useResumableDraft` →
    // setMode({ kind: 'wizard', draft }) → `BoardWizardViewModel`'s
    // hydration init. A regression that drops the payload mid-flight
    // would show up as the placeholder/empty input here.
    const nameInput = page.getByLabel(/board name/i);
    await expect(nameInput).toHaveValue('My Drafted Board');
  });
});
