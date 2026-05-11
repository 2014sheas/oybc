import {
  test,
  expect,
  seedBoard,
  seedTask,
  seedBoardTask,
  seedTemplate,
} from './_fixtures/bypass';

/**
 * E2E coverage for Phase 6.3 — board-completion-as-a-square.
 *
 * Walks the achievement-square config flow:
 *   1. Right-click a cell on a board to open the context menu.
 *   2. Click "Configure as achievement square…" to open the modal.
 *   3. Toggle the cell into achievement-square mode.
 *   4. Pick a mode + (for specific modes) a target.
 *   5. Save → modal dismisses, the cell renders the 🎯 badge.
 *
 * Notably NOT covered (yet):
 * - Cycle-detection error rendering: would require seeding a graph
 *   with an existing achievement-square edge that closes a loop when
 *   the candidate is applied. The cycle-detection algorithm itself
 *   has 12 Jest cases in `cycleDetection.test.ts`; the UI display of
 *   the cyclePath is covered visually by `AchievementSquareConfigSnapshotTests`
 *   on iOS (web has no snapshot harness — known follow-up).
 * - End-to-end derivation: greenlogging the referenced board and
 *   asserting the watcher cell completes. Covered by the algorithm
 *   tests + the manual QA in the PR description.
 */

test.describe('Phase 6.3 achievement square', () => {
  const PARENT_BOARD_ID = '10000000-0000-0000-0000-000000000001';
  const PEER_BOARD_ID = '10000000-0000-0000-0000-000000000002';
  const TASK_ID = '20000000-0000-0000-0000-000000000001';
  const BOARD_TASK_ID = '30000000-0000-0000-0000-000000000001';
  const TEMPLATE_ID = '40000000-0000-0000-0000-000000000001';

  test.beforeEach(async ({ page }) => {
    // Seed minimum state: a parent board with one placed task cell, a
    // peer board for the specific-board picker, and a recurring template
    // for the template picker. Each test below picks which surfaces it
    // exercises; the seeded data is harmless on every test.
    await seedBoard(page, {
      id: PARENT_BOARD_ID,
      name: 'Monthly Goals',
      boardSize: 3,
      timeframe: 'monthly',
      status: 'active',
      startDate: '2026-05-01T00:00:00.000Z',
      endDate: '2026-05-31T23:59:59.000Z',
    });
    await seedBoard(page, {
      id: PEER_BOARD_ID,
      name: 'Daily Wellness',
      boardSize: 5,
      timeframe: 'daily',
      status: 'completed',
      startDate: '2026-05-08T00:00:00.000Z',
      endDate: '2026-05-08T23:59:59.000Z',
    });
    await seedTask(page, {
      id: TASK_ID,
      title: 'Read 30 minutes',
      type: 'normal',
    });
    await seedBoardTask(page, {
      id: BOARD_TASK_ID,
      boardId: PARENT_BOARD_ID,
      taskId: TASK_ID,
      row: 0,
      col: 0,
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

  test('cell context menu surfaces "Configure as achievement square…" entry', async ({ page }) => {
    await page.goto(`/boards/${PARENT_BOARD_ID}?__oybc_test_bypass=1`);

    // Wait for the cell to render. The seeded BoardTask is at (0,0)
    // with a normal task titled "Read 30 minutes".
    const cell = page.getByRole('button', { name: /Read 30 minutes/i });
    await expect(cell).toBeVisible();

    // Right-click triggers the FloatingContextMenu. The "Configure as
    // achievement square…" entry is the Phase 6.3 addition that the
    // rest of the flow depends on.
    await cell.click({ button: 'right' });
    await expect(
      page.getByRole('button', { name: /configure as achievement square/i }),
    ).toBeVisible();
  });

  test('config modal opens with the three-mode selector', async ({ page }) => {
    await page.goto(`/boards/${PARENT_BOARD_ID}?__oybc_test_bypass=1`);
    const cell = page.getByRole('button', { name: /Read 30 minutes/i });
    await cell.click({ button: 'right' });
    await page.getByRole('button', { name: /configure as achievement square/i }).click();

    // The modal mounts with the toggle and (because the cell wasn't an
    // achievement square yet) the mode selector hidden. Enable the
    // toggle to reveal the three modes.
    const dialog = page.getByRole('dialog');
    await expect(dialog).toBeVisible();
    await expect(dialog.getByText(/configure cell/i)).toBeVisible();

    const toggle = dialog.getByRole('checkbox', {
      name: /treat this cell as an achievement square/i,
    });
    await toggle.check();

    // All three modes should be visible after the toggle.
    await expect(dialog.getByText(/count across timeframe/i)).toBeVisible();
    await expect(dialog.getByText(/watch a specific board/i)).toBeVisible();
    await expect(dialog.getByText(/watch a recurring template/i)).toBeVisible();
  });

  test('specific-board mode shows the board picker filtered to non-current boards', async ({ page }) => {
    await page.goto(`/boards/${PARENT_BOARD_ID}?__oybc_test_bypass=1`);
    const cell = page.getByRole('button', { name: /Read 30 minutes/i });
    await cell.click({ button: 'right' });
    await page.getByRole('button', { name: /configure as achievement square/i }).click();

    const dialog = page.getByRole('dialog');
    await dialog.getByRole('checkbox', {
      name: /treat this cell as an achievement square/i,
    }).check();
    await dialog.getByRole('radio', { name: /watch a specific board/i }).check();

    // Picker shows the peer board. The parent (Monthly Goals) is
    // excluded — picking it would be a self-reference, blocked by
    // the modal's filter independent of the cycle-detection check.
    await expect(dialog.getByRole('button', { name: /Daily Wellness/i })).toBeVisible();
    await expect(dialog.getByRole('button', { name: /Monthly Goals/i })).not.toBeVisible();
  });

  test('recurring-template mode shows the template picker', async ({ page }) => {
    await page.goto(`/boards/${PARENT_BOARD_ID}?__oybc_test_bypass=1`);
    const cell = page.getByRole('button', { name: /Read 30 minutes/i });
    await cell.click({ button: 'right' });
    await page.getByRole('button', { name: /configure as achievement square/i }).click();

    const dialog = page.getByRole('dialog');
    await dialog.getByRole('checkbox', {
      name: /treat this cell as an achievement square/i,
    }).check();
    await dialog.getByRole('radio', { name: /watch a recurring template/i }).check();

    // Picker shows the seeded "Leg Day" template. The parent's
    // window (May 2026) has no Leg Day spawns yet so the empty-
    // window warning should ALSO surface after picking it.
    const templateRow = dialog.getByRole('button', { name: /Leg Day/i });
    await expect(templateRow).toBeVisible();
    await templateRow.click();
    await expect(
      dialog.getByText(/no spawns of .* fall inside this board's window/i),
    ).toBeVisible();
  });
});
