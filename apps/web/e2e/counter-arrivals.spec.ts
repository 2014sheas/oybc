import {
  test,
  expect,
  seedBoard,
  seedTask,
  seedBoardTask,
} from './_fixtures/bypass';

/**
 * E2E coverage for Shared Counters P3 — the passive-completion "arrival banner"
 * (docs/SHARED_COUNTERS.md §P3).
 *
 * Scenario: one real activity ("Push-ups") is shared across two boards via a
 * source counting task placed on board A and a DERIVED counting task (linked by
 * `sharedCounterId`, baseline 0) placed on board B. Logging the counter
 * ANYWHERE fans the increment out to every board's square in one transaction
 * (the live `incrementSharedCounter` engine). P3 is the detection + presentation
 * layer on top: on the next open of a board whose shared square filled in from
 * a log made elsewhere, a gold `role="status"` arrival banner appears + the
 * square pulses.
 *
 * The banner is driven by a device-local per-board "last-seen" snapshot in
 * `localStorage` (NOT synced schema): first view seeds the baseline and never
 * fires; a later cross-surface log raises the derived square's displayed count
 * above the baseline, so returning to the board detects the increase.
 *
 * This walks the whole loop against the real UI:
 *   1. First open board B → NO banner (first-ever view seeds the baseline).
 *   2. Log +1 on the Counter Detail page (/profile/counters/:sourceId).
 *   3. Return to board B → gold arrival banner with the doc's copy.
 *   4. ✕ dismisses it.
 *   5. Reopen board B → NO banner (the arrival was acknowledged / re-snapshot).
 */

// Source counting task ("Push-ups") — the shared accumulator; its `currentCount`
// is the counter's lifetime total. Placed on board A.
const SOURCE_TASK_ID = 'ffffffff-0001-0000-0000-000000000001';
// Derived counting task linked to the source via `sharedCounterId`. Placed on
// board B — this is the square that "arrives" when the counter is logged.
const LINKED_TASK_ID = 'ffffffff-0002-0000-0000-000000000002';

const SOURCE_BOARD_ID = 'ffffffff-bbbb-0000-0000-00000000000a';
const TARGET_BOARD_ID = 'ffffffff-bbbb-0000-0000-00000000000b';

const TARGET_BOARD_NAME = 'Weekly Push Board';
const LINKED_TASK_TITLE = 'Push-ups weekly';

// Today/next-week so neither board reads as expired as the calendar advances.
const TODAY = new Date().toISOString().slice(0, 10);
const NEXT_WEEK = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000)
  .toISOString()
  .slice(0, 10);

test.describe('Shared Counters P3 — arrival banner', () => {
  test.beforeEach(async ({ page }) => {
    // Source counting task — the accumulator. `action + unit` identify the
    // activity; `currentCount` starts at 0 (lifetime total).
    await seedTask(page, {
      id: SOURCE_TASK_ID,
      title: 'Push-ups',
      type: 'counting',
      action: 'Push-ups',
      unit: 'reps',
      maxCount: 100,
      currentCount: 0,
    });
    // Derived counting task linked to the source. `sharedCounterId` makes it a
    // member of the counter's group; baseline 0 ⇒ displayed == lifetime.
    await seedTask(page, {
      id: LINKED_TASK_ID,
      title: LINKED_TASK_TITLE,
      type: 'counting',
      action: 'Push-ups',
      unit: 'reps',
      maxCount: 50,
      currentCount: 0,
      baseline: 0,
      sharedCounterId: SOURCE_TASK_ID,
    });

    // Board A holds the source; board B holds the derived square.
    await seedBoard(page, {
      id: SOURCE_BOARD_ID,
      name: 'Source Board',
      boardSize: 3,
      timeframe: 'weekly',
      status: 'active',
      startDate: TODAY,
      endDate: NEXT_WEEK,
    });
    await seedBoard(page, {
      id: TARGET_BOARD_ID,
      name: TARGET_BOARD_NAME,
      boardSize: 3,
      timeframe: 'weekly',
      status: 'active',
      startDate: TODAY,
      endDate: NEXT_WEEK,
    });
    await seedBoardTask(page, {
      id: 'ffffffff-bt00-0000-0000-00000000000a',
      boardId: SOURCE_BOARD_ID,
      taskId: SOURCE_TASK_ID,
      row: 0,
      col: 0,
    });
    await seedBoardTask(page, {
      id: 'ffffffff-bt00-0000-0000-00000000000b',
      boardId: TARGET_BOARD_ID,
      taskId: LINKED_TASK_ID,
      row: 0,
      col: 0,
    });
  });

  test('logging elsewhere fires the arrival banner on return; ✕ dismisses; first + acknowledged views stay quiet', async ({
    page,
  }) => {
    // ── 1. First open of board B — seeds the last-seen baseline. ──
    // The first-EVER view of a board must never show an arrival banner.
    await page.goto(`/boards/${TARGET_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByRole('heading', { name: TARGET_BOARD_NAME })).toBeVisible();
    // Wait for the derived square to render — proves the play read-model has
    // settled, so `useCounterArrivals` has run its once-per-open detection and
    // written the baseline snapshot before we navigate away.
    await expect(page.getByText(LINKED_TASK_TITLE)).toBeVisible();
    // No banner on first view.
    await expect(page.getByText(/filled in/i)).toHaveCount(0);

    // ── 2. Log +1 on the Counter Detail page (a DIFFERENT surface). ──
    await page.goto(`/profile/counters/${SOURCE_TASK_ID}?__oybc_test_bypass=1`);
    // The "+" stepper is labelled "Add 1 {unit}"; logging runs the live
    // `incrementSharedCounter` engine, fanning the count out to board B's square.
    await page.getByRole('button', { name: /add 1 reps/i }).click();
    // Wait for the lifetime hero to reflect the log (aria-label "{name}: {n} all-time {unit}").
    await expect(page.getByLabel('Push-ups: 1 all-time reps')).toBeVisible();

    // ── 3. Return to board B — the gold arrival banner fires. ──
    await page.goto(`/boards/${TARGET_BOARD_ID}?__oybc_test_bypass=1`);
    const banner = page.getByRole('status').filter({ hasText: /filled in/i });
    await expect(banner).toBeVisible();
    // Copy contract (docs/SHARED_COUNTERS.md §P3, single-square variant): match
    // loosely on the stable substring + the counter name.
    await expect(banner).toContainText(/filled in here from your/i);
    await expect(banner).toContainText('Push-ups');

    // Guard against the occlusion regression this PR fixed: the banner is a
    // `position: fixed` overlay whose `z-index` was trapped inside `AppShell
    // .main`'s stacking context (z-index 1), so it rendered ENTIRELY behind the
    // sticky header — invisible, with an unclickable ✕. Assert the ✕ is the
    // real hit-test target (not a header control) so this can't silently
    // regress. `toBeVisible()` alone would NOT catch it (occlusion isn't a CSS
    // visibility state).
    const dismiss = banner.getByRole('button', { name: 'Dismiss' });
    const dismissHitTest = await dismiss.evaluate((el) => {
      const r = el.getBoundingClientRect();
      const top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
      return top === el || el.contains(top);
    });
    expect(dismissHitTest, 'arrival ✕ must be on top, not occluded by the header').toBe(true);

    // Visual evidence for the review (repo convention: .playwright-mcp/).
    await page.screenshot({ path: '.playwright-mcp/counter-arrival-banner.png' });

    // ── 4. ✕ dismisses the banner (a real click — no `force`). ──
    await dismiss.click();
    await expect(banner).not.toBeVisible();

    // ── 5. Reopen board B — the acknowledged arrival does NOT re-show. ──
    // Detection re-snapshots the baseline at detect time, so the same log never
    // fires twice.
    await page.goto(`/boards/${TARGET_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByRole('heading', { name: TARGET_BOARD_NAME })).toBeVisible();
    await expect(page.getByText(LINKED_TASK_TITLE)).toBeVisible();
    await expect(page.getByText(/filled in/i)).toHaveCount(0);
  });
});
