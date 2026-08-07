import {
  test,
  expect,
  seedBoard,
  seedTask,
  seedBoardTask,
  seedTaskEvent,
} from './_fixtures/bypass';

/**
 * Browser-level coverage for Windowed Completion (docs/WINDOWED_COMPLETION.md,
 * issue #317). The unit matrix (`packages/shared/tests/algorithms/taskEvents.test.ts`
 * + the web `db/operations/__tests__/taskEvent*.test.ts` suites) exhaustively
 * covers `resolveTaskWindowState` / the write choke points in isolation; this
 * spec drives the same semantics through the real UI so a regression in the
 * wiring (grid reads, library reads, the click handlers) is caught visibly,
 * not just at the algorithm layer.
 *
 * Core promise under test: a task's `isCompleted` / `currentCount` fields are
 * LIFETIME caches (read by library surfaces); a live board's grid resolves
 * each square against ITS OWN window (`[board.startDate, ∞)`) via
 * `resolveTaskWindowState` over `taskEvents`, not the cache. A completion (or
 * increment) logged BEFORE a board's window opened must not "bleed" green
 * onto that board, even though the task is genuinely lifetime-complete
 * everywhere else. This is the exact respawn-bleed bug the design doc exists
 * to fix (§Problem #1).
 *
 * Two independent fixtures, seeded once in `beforeEach`:
 *   - A NORMAL task + board — walks complete → reload → un-complete → reload
 *     (§Write paths: appendCompletionEvent / tombstoneWindowCompletions).
 *   - A COUNTING task + board — walks a windowed increment against a
 *     pre-window increment event (§Semantics — counting `windowCount`).
 */

const NORMAL_TASK_ID = 'eeeeeeee-0001-0000-0000-000000000001';
const NORMAL_BOARD_ID = 'eeeeeeee-bbbb-0000-0000-00000000000a';
const NORMAL_BOARD_TASK_ID = 'eeeeeeee-bt00-0000-0000-00000000000a';
const NORMAL_PRE_WINDOW_EVENT_ID = 'eeeeeeee-ev00-0000-0000-00000000000a';

const COUNTING_TASK_ID = 'eeeeeeee-0002-0000-0000-000000000002';
const COUNTING_BOARD_ID = 'eeeeeeee-bbbb-0000-0000-00000000000b';
const COUNTING_BOARD_TASK_ID = 'eeeeeeee-bt00-0000-0000-00000000000b';
const COUNTING_PRE_WINDOW_EVENT_ID = 'eeeeeeee-ev00-0000-0000-00000000000b';

const NORMAL_BOARD_NAME = 'Windowed Weekly Board';
const NORMAL_TASK_TITLE = 'Meditate 10 minutes';
const COUNTING_BOARD_NAME = 'Windowed Counter Board';
const COUNTING_TASK_TITLE = 'Weekly Push-ups';

// Today/next-week so neither seeded board reads as expired as the calendar
// advances (the standing convention across this directory's specs).
const TODAY = new Date().toISOString().slice(0, 10);
const NEXT_WEEK = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000)
  .toISOString()
  .slice(0, 10);
// Ten days before "today" — well before either board's `startDate`, so events
// at this timestamp are unambiguously pre-window.
const PRE_WINDOW_OCCURRED_AT = new Date(
  Date.now() - 10 * 24 * 60 * 60 * 1000,
).toISOString();

test.describe('Windowed Completion (issue #317)', () => {
  test.beforeEach(async ({ page }) => {
    // ── NORMAL-task fixture ──────────────────────────────────────────────
    // Lifetime-complete (the cache says so everywhere) but its only
    // completion event predates the board's window — the bleed-green case.
    await seedTask(page, {
      id: NORMAL_TASK_ID,
      title: NORMAL_TASK_TITLE,
      type: 'normal',
      isCompleted: true,
    });
    await seedTaskEvent(page, {
      id: NORMAL_PRE_WINDOW_EVENT_ID,
      taskId: NORMAL_TASK_ID,
      kind: 'completion',
      occurredAt: PRE_WINDOW_OCCURRED_AT,
    });
    await seedBoard(page, {
      id: NORMAL_BOARD_ID,
      name: NORMAL_BOARD_NAME,
      boardSize: 3,
      timeframe: 'weekly',
      status: 'active',
      startDate: TODAY,
      endDate: NEXT_WEEK,
      completedTasks: 0,
      // 'none' — a FREE center auto-completes in the derivation
      // pass (`derivationPass.ts` center auto-fill), which would make the
      // Squares stat's arithmetic depend on the center square too. 'none'
      // keeps the stat a clean function of just the one seeded task.
      centerSquareType: 'none',
    });
    await seedBoardTask(page, {
      id: NORMAL_BOARD_TASK_ID,
      boardId: NORMAL_BOARD_ID,
      taskId: NORMAL_TASK_ID,
      row: 0,
      col: 0,
    });

    // ── COUNTING-task fixture ────────────────────────────────────────────
    // Lifetime total is 5 (one pre-window increment); the board's window has
    // seen none of it yet.
    await seedTask(page, {
      id: COUNTING_TASK_ID,
      title: COUNTING_TASK_TITLE,
      type: 'counting',
      action: 'Push-ups',
      unit: 'reps',
      maxCount: 10,
      currentCount: 5,
    });
    await seedTaskEvent(page, {
      id: COUNTING_PRE_WINDOW_EVENT_ID,
      taskId: COUNTING_TASK_ID,
      kind: 'increment',
      delta: 5,
      occurredAt: PRE_WINDOW_OCCURRED_AT,
    });
    await seedBoard(page, {
      id: COUNTING_BOARD_ID,
      name: COUNTING_BOARD_NAME,
      boardSize: 3,
      timeframe: 'weekly',
      status: 'active',
      startDate: TODAY,
      endDate: NEXT_WEEK,
      centerSquareType: 'none',
    });
    await seedBoardTask(page, {
      id: COUNTING_BOARD_TASK_ID,
      boardId: COUNTING_BOARD_ID,
      taskId: COUNTING_TASK_ID,
      row: 0,
      col: 0,
    });
  });

  test('the bleed-green kill: pre-window completion renders grey on the board while the library stays lifetime-complete; complete/un-complete via the UI round-trips through a reload', async ({
    page,
  }) => {
    // ── 1. Open the board — the square is INCOMPLETE despite the lifetime cache. ──
    await page.goto(`/boards/${NORMAL_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByRole('heading', { name: NORMAL_BOARD_NAME })).toBeVisible();

    const square = page.getByRole('button', { name: NORMAL_TASK_TITLE });
    await expect(square).toBeVisible();
    await expect(square).toHaveAttribute('aria-pressed', 'false');
    await expect(page.getByText('0/9')).toBeVisible();

    // The Tasks-tab library row for the SAME task still reads lifetime-complete —
    // both true simultaneously is the design's core promise.
    await page.goto('/tasks?__oybc_test_bypass=1');
    await expect(page.getByRole('heading', { name: 'Task library', level: 1 })).toBeVisible();
    const libraryRow = page.getByRole('button', { name: `Open ${NORMAL_TASK_TITLE} details` });
    await expect(libraryRow).toContainText('Completed');

    // Visual evidence for review: incomplete board + lifetime-complete library
    // disagreeing on purpose (repo convention: .playwright-mcp/).
    await page.screenshot({ path: '.playwright-mcp/windowed-completion.png' });

    // ── 2. Complete via the UI — green + board stats increment. ──
    await page.goto(`/boards/${NORMAL_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(square).toHaveAttribute('aria-pressed', 'false');
    await square.click();
    await expect(square).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByText('1/9')).toBeVisible();

    // Reload — the in-window completion event persisted; still green.
    await page.reload();
    await expect(page.getByRole('heading', { name: NORMAL_BOARD_NAME })).toBeVisible();
    await expect(square).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByText('1/9')).toBeVisible();

    // ── 3. Un-complete via the UI — grey again; the pre-window event survives. ──
    await square.click();
    await expect(square).toHaveAttribute('aria-pressed', 'false');
    await expect(page.getByText('0/9')).toBeVisible();

    // Reload — still grey on the board (window-scoped tombstone only removed
    // the in-window event this test added; the pre-window event was never
    // touched, since tombstoning only reaches events >= the board's startDate).
    await page.reload();
    await expect(page.getByRole('heading', { name: NORMAL_BOARD_NAME })).toBeVisible();
    await expect(square).toHaveAttribute('aria-pressed', 'false');

    // The library still reads lifetime-complete — the surviving pre-window
    // event keeps the recomputed lifetime cache `isCompleted: true`.
    await page.goto('/tasks?__oybc_test_bypass=1');
    await expect(libraryRow).toContainText('Completed');
  });

  test('counting task: a windowed increment via the UI reflects only in-window progress while the library shows the lifetime total', async ({
    page,
  }) => {
    await page.goto(`/boards/${COUNTING_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByRole('heading', { name: COUNTING_BOARD_NAME })).toBeVisible();

    // Windowed count is 0/10 — the pre-window +5 increment doesn't count here.
    const counterSquare = page.getByRole('button', { name: COUNTING_TASK_TITLE });
    await expect(counterSquare).toBeVisible();
    await expect(counterSquare).toContainText('0/10');

    // Tap increments the window by 1 (the standalone-counter tap path).
    await counterSquare.click();
    await expect(counterSquare).toContainText('1/10');

    // Reload — the increment event persisted; window count survives.
    await page.reload();
    await expect(page.getByRole('heading', { name: COUNTING_BOARD_NAME })).toBeVisible();
    await expect(page.getByRole('button', { name: COUNTING_TASK_TITLE })).toContainText('1/10');

    // The library shows the LIFETIME total (5 pre-window + 1 windowed = 6),
    // not the windowed count — the same square legitimately disagrees with
    // its own library row.
    await page.goto('/tasks?__oybc_test_bypass=1');
    const libraryRow = page.getByRole('button', { name: `Open ${COUNTING_TASK_TITLE} details` });
    await expect(libraryRow).toContainText('6 / 10');
  });
});
