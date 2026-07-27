import {
  test,
  expect,
  seedBoard,
  seedTask,
  seedBoardTask,
  seedTaskEvent,
} from './_fixtures/bypass';

/**
 * bugfix/edit-preserves-board-window — the exact user-visible bug: Board-Edit
 * Save used to rewrite `startDate` on EVERY save, silently re-windowing the
 * board and wiping completions logged before the edit day. This spec drives
 * the real UI end to end: seed a board whose window opened several days ago
 * with a completion logged inside that window (but before "today"), open it
 * (green square), enter Edit mode, change ONLY the name, Save, and assert
 * the square is STILL green — the fixed `BoardEditPanel` omits the date
 * fields from the patch for a metadata-only save, so the stored window (and
 * the completion event inside it) survives.
 *
 * Complements the vitest coverage in
 * `src/db/operations/__tests__/boardEditWindowPreservation.test.ts` (which
 * pins the DB-operation-level mechanics, including the PRE-FIX shape and the
 * deliberate-timeframe-change re-window case) by proving the wiring through
 * the actual panel component and Save button.
 *
 * ── BLOCKED by a separate, pre-existing, unrelated Critical bug ─────────────
 *
 * This test currently fails BEFORE it can even exercise the window-
 * preservation fix: clicking "Save changes" throws
 * `PrematureCommitError: Transaction committed too early` for EVERY
 * Board-Edit save (even this test's name-only edit), so the panel never
 * exits edit mode and the post-save assertions never run.
 *
 * Root cause: `updateBoardAndCascade` (apps/web/src/db/operations/boards.ts:100)
 * does `const { CenterSquareType } = await import('@oybc/shared');` as its
 * very first line, UNCONDITIONALLY. `@oybc/shared` is already statically
 * imported elsewhere in the same file — this dynamic import exists for no
 * apparent reason (no comment explains it) — but `await`-ing a native,
 * non-Dexie-tracked Promise breaks Dexie's transaction PSD (zone) tracking
 * whenever this function runs INSIDE an already-open ambient transaction.
 * That is exactly how the real Save flow always calls it:
 * `commitSquareEdits` (apps/web/src/hooks/useBoardPlay.ts:612-659) wraps
 * the ENTIRE Save — including the metadata patch — in one outer
 * `db.transaction(...)`, and calls `updateBoardAndCascade(boardId,
 * metadataPatch)` as its LAST step (line 656), nested inside that
 * transaction. By the time the dynamic import resolves, Dexie has already
 * auto-committed the ambient transaction, so the subsequent
 * `db.boards.get(boardId)` / `updateBoard(...)` calls inside
 * `updateBoardAndCascade` throw.
 *
 * Confirmed root cause directly: temporarily replacing the dynamic import
 * with a static one (`import { CenterSquareType } from '@oybc/shared'` at
 * the top of boards.ts, deleting the `await import(...)` line) makes this
 * exact test pass end-to-end. Reverted before committing — production
 * source is frozen for this task; not fixed here, only pinned.
 *
 * This is UNRELATED to the board-window fix under test (`boards.ts` is
 * untouched by this branch's diff — `git diff --stat` confirms only
 * `BoardEditPanel.tsx` changed) and predates it (the dynamic import has
 * been there since commit 77ed41ac, 2026-06-06). It went uncaught because
 * this is the FIRST browser-level (Playwright) test to ever click
 * "Save changes" on `BoardEditPanel` — no prior e2e spec exercised it. The
 * existing vitest atomicity coverage
 * (`src/db/operations/__tests__/boardEditSaveAtomicity.test.ts`) does NOT
 * catch it either: it composes the identical nested-call shape
 * (`updateBoardAndCascade` called from inside an outer `db.transaction`)
 * and passes cleanly under fake-indexeddb + Node — that harness doesn't
 * reproduce the real-browser Promise/PSD-zone timing that trips this up.
 *
 * BOTH bugs were fixed in this same branch (window preservation in
 * `BoardEditPanel.tsx`; the dynamic import hoisted static in `boards.ts`),
 * so this spec now PASSES and proves both end-to-end: the Save completes at
 * all (no PrematureCommitError), and the rename leaves the backdated
 * completion green (the window survived). It was originally landed as
 * `test.fail()` while the import bug blocked it; that marker was removed
 * when the fix landed.
 */

const BOARD_ID = 'ffffffff-bbbb-0000-0000-00000000000a';
const BOARD_TASK_ID = 'ffffffff-bt00-0000-0000-00000000000a';
const TASK_ID = 'ffffffff-0001-0000-0000-000000000001';
const EVENT_ID = 'ffffffff-ev00-0000-0000-00000000000a';

const BOARD_NAME = 'Weekly Chores';
const RENAMED_BOARD_NAME = 'Weekly Chores (renamed)';
const TASK_TITLE = 'Water the plants';

// Window opened 5 days ago so the board is a real, in-progress weekly board;
// completed 2 days ago — safely inside the window, but before "today" (the
// exact instant the old buggy code re-anchored `startDate` to on every save).
const FIVE_DAYS_AGO = new Date(Date.now() - 5 * 24 * 60 * 60 * 1000)
  .toISOString()
  .slice(0, 10);
const NEXT_WEEK = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000)
  .toISOString()
  .slice(0, 10);
const TWO_DAYS_AGO = new Date(
  Date.now() - 2 * 24 * 60 * 60 * 1000,
).toISOString();

test.describe('Board-Edit preserves the board window (bugfix/edit-preserves-board-window)', () => {
  test.beforeEach(async ({ page }) => {
    await seedTask(page, {
      id: TASK_ID,
      title: TASK_TITLE,
      type: 'normal',
      isCompleted: true,
    });
    await seedTaskEvent(page, {
      id: EVENT_ID,
      taskId: TASK_ID,
      kind: 'completion',
      occurredAt: TWO_DAYS_AGO,
    });
    await seedBoard(page, {
      id: BOARD_ID,
      name: BOARD_NAME,
      boardSize: 3,
      timeframe: 'weekly',
      status: 'active',
      startDate: FIVE_DAYS_AGO,
      endDate: NEXT_WEEK,
      completedTasks: 1,
      centerSquareType: 'none',
    });
    await seedBoardTask(page, {
      id: BOARD_TASK_ID,
      boardId: BOARD_ID,
      taskId: TASK_ID,
      row: 0,
      col: 0,
    });
  });

  test('renaming a board via Edit -> Save keeps a backdated completion green', async ({
    page,
  }) => {
    // ── 1. Open the board — the square is green from the in-window completion. ──
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByRole('heading', { name: BOARD_NAME })).toBeVisible();

    const square = page.getByRole('button', { name: TASK_TITLE });
    await expect(square).toBeVisible();
    await expect(square).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByText('1/9')).toBeVisible();

    await page.screenshot({ path: '.playwright-mcp/edit-window-01.png' });

    // ── 2. Enter Edit mode, change ONLY the name, Save. ──
    await page.getByRole('button', { name: 'Edit board' }).click();
    const nameInput = page.locator('#bw-board-name');
    await expect(nameInput).toHaveValue(BOARD_NAME);
    await nameInput.fill(RENAMED_BOARD_NAME);

    const saveButton = page.getByRole('button', { name: 'Save changes' });
    await expect(saveButton).toBeEnabled();
    await saveButton.click();

    // Edit mode exits back to the normal play rail on a successful save.
    await expect(page.getByRole('heading', { name: RENAMED_BOARD_NAME })).toBeVisible();

    // ── 3. THE BUG: the square must still be green — the window (and the ──
    //        backdated completion inside it) must have survived the save.
    await expect(square).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByText('1/9')).toBeVisible();

    // Reload to prove it's a real persisted DB state, not stale React state.
    await page.reload();
    await expect(page.getByRole('heading', { name: RENAMED_BOARD_NAME })).toBeVisible();
    await expect(square).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByText('1/9')).toBeVisible();

    await page.screenshot({ path: '.playwright-mcp/edit-window-02.png' });
  });
});
