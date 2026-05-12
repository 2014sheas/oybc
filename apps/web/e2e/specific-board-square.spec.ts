import {
  test,
  expect,
  seedBoard,
  seedTemplate,
  BYPASS_USER_ID,
} from './_fixtures/bypass';

/**
 * E2E coverage for Phase 6.3 — ACHIEVEMENT as a TaskType.
 *
 * Walks the task-creator flow that replaces the pre-refactor right-click
 * modal:
 *   1. Navigate to /create (which mounts the unified task creator).
 *   2. Pick "Achievement" from the type segmented control.
 *   3. The watch-mode radio + picker dropdown appear.
 *   4. Pick a board (specific-board mode) OR a recurring template
 *      (recurring-template mode).
 *   5. Submit → task appears in the library.
 *
 * The save path's correctness (mutual exclusion, referenced fields land
 * on Task not BoardTask) is exhaustively unit-tested in Jest. This spec
 * just pins the UI wiring so a change to the form layout, type-tab
 * labels, or picker visibility is caught visibly.
 *
 * Not covered here:
 * - Cycle detection at TASK creation is trivially safe (no parent
 *   boards yet); cycle tests live in cycleDetection.test.ts.
 * - End-to-end derivation (greenlogging the referenced board and
 *   asserting the watcher cell completes) — covered by Jest +
 *   XCTest computeBoardStatsUpdate suites.
 */

test.describe('Phase 6.3 achievement task creator', () => {
  const PEER_BOARD_ID = '10000000-0000-0000-0000-000000000002';
  const TEMPLATE_ID = '40000000-0000-0000-0000-000000000001';

  test.beforeEach(async ({ page }) => {
    // Seed a peer board + a recurring template so the pickers render
    // non-empty for the Achievement mode.
    await seedBoard(page, {
      id: PEER_BOARD_ID,
      name: 'Daily Wellness',
      boardSize: 5,
      timeframe: 'daily',
      status: 'completed',
      startDate: '2026-05-08T00:00:00.000Z',
      endDate: '2026-05-08T23:59:59.000Z',
    });
    await seedTemplate(page, {
      id: TEMPLATE_ID,
      name: 'Leg Day',
      timeframe: 'weekly',
      boardSize: 5,
      centerSquareType: 'free',
      isRandomized: true,
      seedTaskIds: Array.from({ length: 24 }, (_, i) =>
        `aaaaaaaa-aaaa-aaaa-aaaa-${String(i).padStart(12, '0')}`,
      ),
      isActive: true,
    });
  });

  test('task type selector includes "Achievement" alongside Normal/Counting/Progress/Composite', async ({ page }) => {
    await page.goto('/create?__oybc_test_bypass=1');
    // The Create page mounts the task-creator form below the wizard
    // launcher. Wait for the "Achievement" type button to appear in
    // the TaskTypeSelector.
    await expect(page.getByRole('button', { name: /^Achievement$/ })).toBeVisible();
  });

  test('selecting Achievement reveals the watch-mode radio + board picker', async ({ page }) => {
    await page.goto('/create?__oybc_test_bypass=1');
    await page.getByRole('button', { name: /^Achievement$/ }).click();

    // Watch-mode radios appear after the type switch.
    await expect(page.getByRole('radio', { name: /^Board$/i })).toBeVisible();
    await expect(page.getByRole('radio', { name: /^Template$/i })).toBeVisible();

    // Default mode is `specificBoard` — the board <select> should be visible.
    const boardSelect = page.locator('#create-task-ach-board');
    await expect(boardSelect).toBeVisible();
    // Picker contains the seeded peer board.
    await expect(boardSelect.locator('option', { hasText: /Daily Wellness/ })).toHaveCount(1);
  });

  test('switching mode to "recurring template" swaps the picker', async ({ page }) => {
    await page.goto('/create?__oybc_test_bypass=1');
    await page.getByRole('button', { name: /^Achievement$/ }).click();
    await page.getByRole('radio', { name: /^Template$/i }).check();

    // The board <select> goes away, the template <select> appears.
    await expect(page.locator('#create-task-ach-board')).toBeHidden();
    const tplSelect = page.locator('#create-task-ach-template');
    await expect(tplSelect).toBeVisible();
    await expect(tplSelect.locator('option', { hasText: /Leg Day/ })).toHaveCount(1);
  });

  test('submit without a reference selection surfaces validation error', async ({ page }) => {
    await page.goto('/create?__oybc_test_bypass=1');
    await page.getByRole('button', { name: /^Achievement$/ }).click();
    // Fill title, leave the picker empty.
    await page.getByPlaceholder(/enter task title/i).fill('Watch wellness');
    // The /create hub mounts CreateNewTaskForm via CreateHubQuickAdd, which
    // overrides the submit label to "Add to library" (Vs the legacy
    // "Create & Add to Pool"). Target both labels so this spec stays valid
    // whether the hub or the wizard's NewTaskSheet hosts the form.
    await page.getByRole('button', { name: /Add to library|Create & Add to Pool/i }).click();
    await expect(page.getByText(/Pick a board to watch/i)).toBeVisible();
  });

  test('full happy path: pick a board, submit, task lands in the workspace', async ({ page }) => {
    await page.goto('/create?__oybc_test_bypass=1');
    await page.getByRole('button', { name: /^Achievement$/ }).click();
    await page.getByPlaceholder(/enter task title/i).fill('Watch Daily Wellness');
    await page.locator('#create-task-ach-board').selectOption(PEER_BOARD_ID);
    // The /create hub mounts CreateNewTaskForm via CreateHubQuickAdd, which
    // overrides the submit label to "Add to library" (Vs the legacy
    // "Create & Add to Pool"). Target both labels so this spec stays valid
    // whether the hub or the wizard's NewTaskSheet hosts the form.
    await page.getByRole('button', { name: /Add to library|Create & Add to Pool/i }).click();

    // After submit, the form resets — the title field is empty again.
    await expect(page.getByPlaceholder(/enter task title/i)).toHaveValue('');

    // Verify the Task landed in Dexie. We re-open the connection and look
    // up the new row by title; the assertion is that exactly one task
    // matches and its type is ACHIEVEMENT + referencedBoardId is the
    // peer board id. Also verify the trigger defaults to 'greenlog'
    // (the form's default radio state).
    const result = await page.evaluate(async ({ userId }) => {
      return new Promise<{ count: number; type?: string; refBoard?: string; trigger?: string; requiredCount?: number }>((resolve, reject) => {
        const openReq = indexedDB.open('oybc');
        openReq.onerror = () => reject(openReq.error);
        openReq.onsuccess = () => {
          const db = openReq.result;
          const tx = db.transaction(['tasks'], 'readonly');
          const store = tx.objectStore('tasks');
          const req = store.getAll();
          req.onsuccess = () => {
            const matches = (req.result as Array<Record<string, unknown>>).filter(
              (t) =>
                t.userId === userId &&
                t.title === 'Watch Daily Wellness' &&
                !t.isDeleted,
            );
            db.close();
            if (matches.length === 0) {
              resolve({ count: 0 });
              return;
            }
            const m = matches[0];
            resolve({
              count: matches.length,
              type: m.type as string,
              refBoard: m.referencedBoardId as string,
              trigger: m.achievementTrigger as string,
              requiredCount: m.requiredCount as number | undefined,
            });
          };
          req.onerror = () => reject(req.error);
        };
      });
    }, { userId: BYPASS_USER_ID });

    expect(result.count).toBe(1);
    expect(result.type).toBe('achievement');
    expect(result.refBoard).toBe(PEER_BOARD_ID);
    // Default trigger is GREENLOG; specific-board mode ignores requiredCount.
    expect(result.trigger).toBe('greenlog');
    expect(result.requiredCount).toBeUndefined();
  });

  test('recurring-template mode requires a count + persists trigger & count', async ({ page }) => {
    await page.goto('/create?__oybc_test_bypass=1');
    await page.getByRole('button', { name: /^Achievement$/ }).click();
    await page.getByRole('radio', { name: /^Template$/i }).check();
    await page.getByPlaceholder(/enter task title/i).fill('3 Leg Days a month');
    await page.locator('#create-task-ach-template').selectOption(TEMPLATE_ID);
    // Flip the trigger to BINGO to verify the form serializes it.
    await page.getByRole('radio', { name: /^Bingo$/i }).check();

    // Submitting without a count should surface the validation error.
    await page.getByRole('button', { name: /Add to library|Create & Add to Pool/i }).click();
    await expect(page.getByText(/Count is required/i)).toBeVisible();

    // Fill the count and submit.
    await page.locator('#create-task-ach-count').fill('3');
    await page.getByRole('button', { name: /Add to library|Create & Add to Pool/i }).click();

    // After submit, the form resets — title cleared.
    await expect(page.getByPlaceholder(/enter task title/i)).toHaveValue('');

    // Read back the persisted Task and assert the trigger + count
    // landed correctly.
    const result = await page.evaluate(async ({ userId }) => {
      return new Promise<{ count: number; type?: string; refTemplate?: string; trigger?: string; requiredCount?: number }>((resolve, reject) => {
        const openReq = indexedDB.open('oybc');
        openReq.onerror = () => reject(openReq.error);
        openReq.onsuccess = () => {
          const db = openReq.result;
          const tx = db.transaction(['tasks'], 'readonly');
          const store = tx.objectStore('tasks');
          const req = store.getAll();
          req.onsuccess = () => {
            const matches = (req.result as Array<Record<string, unknown>>).filter(
              (t) =>
                t.userId === userId &&
                t.title === '3 Leg Days a month' &&
                !t.isDeleted,
            );
            db.close();
            if (matches.length === 0) {
              resolve({ count: 0 });
              return;
            }
            const m = matches[0];
            resolve({
              count: matches.length,
              type: m.type as string,
              refTemplate: m.referencedTemplateId as string,
              trigger: m.achievementTrigger as string,
              requiredCount: m.requiredCount as number,
            });
          };
          req.onerror = () => reject(req.error);
        };
      });
    }, { userId: BYPASS_USER_ID });

    expect(result.count).toBe(1);
    expect(result.type).toBe('achievement');
    expect(result.refTemplate).toBe(TEMPLATE_ID);
    expect(result.trigger).toBe('bingo');
    expect(result.requiredCount).toBe(3);
  });
});
