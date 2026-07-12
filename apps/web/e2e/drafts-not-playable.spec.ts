import {
  test,
  expect,
  seedBoard,
  seedTask,
  seedBoardTask,
} from './_fixtures/bypass';

/**
 * E2E coverage for C6-A1b (issue #313) — "drafts are never playable" web
 * parity with iOS. The production behavior itself shipped in PR #211
 * (`19f9eb6`, "feat(web): drafts never playable — parity with iOS A1b"):
 * every entry point that could open a DRAFT board now routes to the wizard
 * resume flow (`/create?resumeDraft=<id>`) instead of the play page, and
 * `BoardPlayPage` guards direct URLs with a `DraftResumePrompt`. That PR
 * shipped without e2e coverage — this spec closes that gap.
 *
 * iOS reference (behavior mirrored here):
 * - `BoardListView.swift` — draft filter cards + draft core-grid slots route
 *   to `onResumeDraft` instead of pushing `BoardPlayView`.
 * - `BoardPlayView.swift` (`draftResumeSection`, ~L1091-1115) — "This board
 *   is still a draft." / "Finish setting it up in the wizard — drafts
 *   aren't playable until you complete them." / "Resume draft" button.
 *   Web's `DraftResumePrompt` uses this copy verbatim.
 *
 * Scenarios:
 *   1. A DRAFT board's card on the Boards list routes to the wizard
 *      (not `/boards/:id`) — the wizard header reads "Resume draft".
 *   2. Direct navigation to `/boards/:draftId` renders the `DraftResumePrompt`
 *      guard (never the bingo grid); its button also resumes the wizard.
 *   3. An ACTIVE board is unaffected — it still opens as a playable grid.
 */

const DRAFT_BOARD_ID = 'dddddddd-bbbb-0000-0000-000000000001';
const ACTIVE_BOARD_ID = 'dddddddd-bbbb-0000-0000-000000000002';
const ACTIVE_TASK_ID = 'dddddddd-task-0000-0000-000000000001';
const ACTIVE_BOARD_TASK_ID = 'dddddddd-bt00-0000-0000-000000000001';

const DRAFT_BOARD_NAME = 'Untitled Weekly Draft';
const ACTIVE_BOARD_NAME = 'Live Weekly Board';
const ACTIVE_TASK_TITLE = 'Read for 20 minutes';

const today = new Date();
const isoDay = (d: Date): string => d.toISOString().slice(0, 10);
const TODAY = isoDay(today);
const NEXT_WEEK = isoDay(new Date(today.getTime() + 7 * 24 * 60 * 60 * 1000));

test.describe('Drafts are never playable (web parity A1b, issue #313)', () => {
  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: DRAFT_BOARD_ID,
      name: DRAFT_BOARD_NAME,
      boardSize: 3,
      timeframe: 'weekly',
      status: 'draft',
      startDate: TODAY,
      endDate: NEXT_WEEK,
    });

    await seedBoard(page, {
      id: ACTIVE_BOARD_ID,
      name: ACTIVE_BOARD_NAME,
      boardSize: 3,
      timeframe: 'weekly',
      status: 'active',
      startDate: TODAY,
      endDate: NEXT_WEEK,
    });
    await seedTask(page, {
      id: ACTIVE_TASK_ID,
      title: ACTIVE_TASK_TITLE,
      type: 'normal',
    });
    await seedBoardTask(page, {
      id: ACTIVE_BOARD_TASK_ID,
      boardId: ACTIVE_BOARD_ID,
      taskId: ACTIVE_TASK_ID,
      row: 0,
      col: 0,
    });
  });

  test('draft board card on the Boards list resumes the wizard, never the play page', async ({
    page,
  }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await expect(page.getByRole('heading', { name: 'All boards', level: 1 })).toBeVisible();

    // Default filter is Active — switch to All (or Draft) to reveal the card.
    await page.getByRole('button', { name: 'All', exact: true }).click();
    await expect(page.getByText(DRAFT_BOARD_NAME)).toBeVisible();

    await page.getByText(DRAFT_BOARD_NAME).click();

    // Lands on the wizard's resume-draft entry, not `/boards/:id`.
    await expect(page).toHaveURL(/\/create(\?|$)/);
    await expect(page).not.toHaveURL(new RegExp(`/boards/${DRAFT_BOARD_ID}`));
    await expect(page.getByRole('heading', { name: 'Resume draft' })).toBeVisible();
  });

  test('direct URL to a draft board renders the resume prompt, never the grid', async ({
    page,
  }) => {
    await page.goto(`/boards/${DRAFT_BOARD_ID}?__oybc_test_bypass=1`);

    // The guard's copy — verbatim parity with iOS `draftResumeSection`.
    await expect(page.getByRole('heading', { name: DRAFT_BOARD_NAME })).toBeVisible();
    await expect(page.getByText('This board is still a draft.')).toBeVisible();
    await expect(
      page.getByText(/drafts aren.t playable until you complete them/i),
    ).toBeVisible();

    // Never the playable grid: no cell-edit affordances from BoardPlaySurface.
    await expect(page.getByLabel('Add task to this cell')).toHaveCount(0);

    // The button resumes the wizard.
    await page.getByRole('button', { name: 'Resume draft' }).click();
    await expect(page).toHaveURL(/\/create(\?|$)/);
    await expect(page.getByRole('heading', { name: 'Resume draft' })).toBeVisible();
  });

  test('an active board still opens as a playable grid', async ({ page }) => {
    await page.goto(`/boards/${ACTIVE_BOARD_ID}?__oybc_test_bypass=1`);

    await expect(page.getByRole('heading', { name: ACTIVE_BOARD_NAME })).toBeVisible();
    // The placed task renders on the real grid — proves BoardPlaySurface (not
    // the draft guard) is mounted.
    await expect(page.getByText(ACTIVE_TASK_TITLE)).toBeVisible();
    await expect(page.getByText('This board is still a draft.')).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Resume draft' })).toHaveCount(0);
  });
});
