import type { Page } from '@playwright/test';
import { test, expect, seedBoard, seedTask, seedBoardTask, readBoard } from './_fixtures/bypass';

/** Read a single `boardTasks` row by id via raw IndexedDB (no such helper is
 *  exported by `_fixtures/bypass.ts` yet — mirrors its `readBoard` pattern). */
async function readBoardTask(page: Page, id: string): Promise<Record<string, unknown> | null> {
  return page.evaluate((btId) => {
    return new Promise<Record<string, unknown> | null>((resolve, reject) => {
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const tx = db.transaction(['boardTasks'], 'readonly');
        const req = tx.objectStore('boardTasks').get(btId);
        req.onsuccess = () => {
          db.close();
          resolve((req.result as Record<string, unknown> | undefined) ?? null);
        };
        req.onerror = () => reject(req.error);
      };
    });
  }, id);
}

/**
 * Board Edit redesign slice 3 — the ONE squares editor
 * (`docs/BOARD_EDIT_REDESIGN.md`, plan T3 acceptance list):
 *   (a) tap an empty square → picker → type → match → pick → pencil chip →
 *       Save → reload → placed.
 *   (b) quick-add a brand-new task → Cancel → Discard → the task does not
 *       exist in /tasks.
 *   (c) Replace via picker → Save.
 *   (d) Remove → dashed empty square with no chip → Save.
 *   (e) hold-drag a square to another slot → Save → position persisted; a
 *       locked square does not lift.
 *   (f) Shuffle → count shows "1 edit" → Save → locked squares unchanged.
 *   (g) FREE center → Make it a task square → empty center → add → Save.
 *   (h) a seeded legacy CHOSEN board opens with a locked center, Unlock →
 *       Save → the board row is `none`.
 *   (i) keyboard Alt+Arrow move.
 *   (j) the play mode has no "+" on empty squares.
 *   (k) remove EVERY square → Save → the board renders (empty squares, not
 *       "Loading…" forever) → Edit board → add via tap-empty → Save.
 */

const now = new Date();
const p = (n: number): string => String(n).padStart(2, '0');
const d = `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;
const START = `${d}T00:00:00.000`;
const END = `${d}T23:59:59.999`;

test.describe('Squares editor (a) — tap an empty square opens the picker', () => {
  const BOARD_ID = 'cccccccc-sqed-0001-0000-000000000000';
  const TASK_A = 'cccccccc-sqed-0001-task-000000000001'; // placed
  const TASK_MATCH = 'cccccccc-sqed-0001-task-000000000002'; // library, unplaced

  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: BOARD_ID, name: 'Editor board A', boardSize: 3, timeframe: 'monthly', status: 'active',
      startDate: START, endDate: END, centerSquareType: 'free',
    });
    await seedTask(page, { id: TASK_A, title: 'Morning workout', type: 'normal' });
    await seedBoardTask(page, { id: 'cccccccc-sqed-0001-bt-000000000001', boardId: BOARD_ID, taskId: TASK_A, row: 0, col: 0 });
    await seedTask(page, { id: TASK_MATCH, title: 'Read a library book', type: 'normal' });
  });

  test('type → inline match → pick → pencil chip → Save → reload → placed', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();

    // (2,1) is empty — tap it to open the Add picker directly (D13).
    await page.getByRole('button', { name: /^Empty square, row 3, column 2$/ }).click();
    await expect(page.getByRole('dialog', { name: /Add square/ })).toBeVisible();

    await page.getByLabel('New normal task title').fill('library book');
    await expect(page.getByRole('button', { name: /Read a library book/ })).toBeVisible();
    await page.getByRole('button', { name: /Read a library book/ }).click();

    // The picker closes and the pencil (dirty) chip shows on the new square.
    await expect(page.getByRole('dialog', { name: /Add square/ })).not.toBeVisible();
    await expect(page.getByRole('img', { name: 'Unsaved edit' })).toHaveCount(1);
    await expect(page.getByText(/^1$/).first()).toBeVisible();

    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();

    await page.reload();
    await expect(page.getByText('Editor board A').first()).toBeVisible();
    await expect(page.getByText('Read a library book')).toBeVisible();
  });
});

test.describe('Squares editor (b) — a quick-added task is discarded on Cancel', () => {
  const BOARD_ID = 'cccccccc-sqed-0002-0000-000000000000';
  const TASK_A = 'cccccccc-sqed-0002-task-000000000001';

  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: BOARD_ID, name: 'Editor board B', boardSize: 3, timeframe: 'monthly', status: 'active',
      startDate: START, endDate: END, centerSquareType: 'free',
    });
    await seedTask(page, { id: TASK_A, title: 'Morning workout', type: 'normal' });
    await seedBoardTask(page, { id: 'cccccccc-sqed-0002-bt-000000000001', boardId: BOARD_ID, taskId: TASK_A, row: 0, col: 0 });
  });

  test('Add a brand-new task → Cancel → Discard → the task does not exist in /tasks', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();
    await page.getByRole('button', { name: /^Empty square, row 3, column 2$/ }).click();

    await page.getByLabel('New normal task title').fill('Brand new discarded task');
    await page.getByRole('button', { name: 'Add task' }).click();

    // Staged — visible on the grid, one edit.
    await expect(page.getByText('Brand new discarded task')).toBeVisible();
    await expect(page.getByText(/^1$/).first()).toBeVisible();

    // Cancel → Discard.
    await page.getByRole('button', { name: 'Cancel editing' }).click();
    await page.getByRole('button', { name: 'Discard', exact: true }).click();
    await expect(page.getByRole('button', { name: 'Edit board' })).toBeVisible();

    // The task was never written.
    await page.goto('/tasks');
    await expect(page.getByRole('heading', { name: 'Task library', level: 1 })).toBeVisible();
    await expect(page.getByText('Brand new discarded task')).toHaveCount(0);
  });
});

test.describe('Squares editor (c)/(d) — replace and remove', () => {
  const BOARD_ID = 'cccccccc-sqed-0003-0000-000000000000';
  const TASK_A = 'cccccccc-sqed-0003-task-000000000001'; // to be replaced
  const TASK_B = 'cccccccc-sqed-0003-task-000000000002'; // replacement
  const TASK_C = 'cccccccc-sqed-0003-task-000000000003'; // to be removed

  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: BOARD_ID, name: 'Editor board C', boardSize: 3, timeframe: 'monthly', status: 'active',
      startDate: START, endDate: END, centerSquareType: 'free',
    });
    await seedTask(page, { id: TASK_A, title: 'Outgoing task', type: 'normal' });
    await seedTask(page, { id: TASK_B, title: 'Incoming task', type: 'normal' });
    await seedTask(page, { id: TASK_C, title: 'Task to remove', type: 'normal' });
    await seedBoardTask(page, { id: 'cccccccc-sqed-0003-bt-000000000001', boardId: BOARD_ID, taskId: TASK_A, row: 0, col: 0 });
    await seedBoardTask(page, { id: 'cccccccc-sqed-0003-bt-000000000002', boardId: BOARD_ID, taskId: TASK_C, row: 0, col: 1 });
  });

  test('Replace via the picker, then Save', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();

    await page.getByRole('button', { name: /^Outgoing task$/ }).click();
    await page.getByRole('button', { name: 'Replace task' }).click();
    await expect(page.getByRole('dialog', { name: /Replace square/ })).toBeVisible();

    await page.getByLabel('New normal task title').fill('Incoming');
    await page.getByRole('button', { name: /Incoming task/ }).click();

    await expect(page.getByText('Incoming task')).toBeVisible();
    await expect(page.getByText('Outgoing task')).toHaveCount(0);

    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();
    await page.reload();
    await expect(page.getByText('Incoming task')).toBeVisible();
  });

  test('Remove leaves a dashed empty square with no chip, then Save', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();

    await page.getByRole('button', { name: /^Task to remove$/ }).click();
    await page.getByRole('button', { name: 'Remove from board' }).click();

    await expect(page.getByText('Task to remove')).toHaveCount(0);
    await expect(page.getByRole('img', { name: 'Unsaved edit' })).toHaveCount(0);
    await expect(page.getByText(/^1$/).first()).toBeVisible();

    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();
  });
});

test.describe('Squares editor (e) — hold-drag moves a square; a locked square does not lift', () => {
  const BOARD_ID = 'cccccccc-sqed-0004-0000-000000000000';
  const ids = (n: number) => ({ task: `cccccccc-sqed-0004-task-00000000000${n}`, bt: `cccccccc-sqed-0004-bt-0000000000000${n}` });
  const TITLES = ['A task', 'B task', 'Locked task'];
  const CELLS = [[0, 0], [0, 1], [0, 2]];

  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: BOARD_ID, name: 'Editor board E', boardSize: 3, timeframe: 'monthly', status: 'active',
      startDate: START, endDate: END, centerSquareType: 'free',
    });
    for (let i = 0; i < TITLES.length; i++) {
      await seedTask(page, { id: ids(i).task, title: TITLES[i], type: 'normal' });
      await seedBoardTask(page, {
        id: ids(i).bt, boardId: BOARD_ID, taskId: ids(i).task, row: CELLS[i][0], col: CELLS[i][1],
        ...(i === 2 ? { isLocked: true } : {}),
      });
    }
  });

  test('a hold-drag commits a new position; a locked square never lifts', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();

    const moving = page.locator(`[data-cid="${ids(0).bt}"]`);
    const box = (await moving.boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    // Hold past the 350ms lift timer before moving (D8).
    await page.waitForTimeout(450);
    await page.mouse.move(box.x + box.width * 2.2, box.y + box.height / 2, { steps: 8 });
    await page.mouse.up();

    // The edit counter reflects a moved cell.
    await expect(page.getByText(/^1$/).first()).toBeVisible();
    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();

    const moved = await readBoardTask(page, ids(0).bt);
    expect(moved).not.toBeNull();
    expect([moved?.row, moved?.col]).not.toEqual([0, 0]);
    // The locked square never moved.
    const locked = await readBoardTask(page, ids(2).bt);
    expect([locked?.row, locked?.col]).toEqual([0, 2]);
  });
});

test.describe('Squares editor (f) — Shuffle', () => {
  const BOARD_ID = 'cccccccc-sqed-0005-0000-000000000000';
  const ids = (n: number) => ({ task: `cccccccc-sqed-0005-task-00000000000${n}`, bt: `cccccccc-sqed-0005-bt-0000000000000${n}` });
  const TITLES = ['A task', 'B task', 'C task', 'Locked task'];
  const CELLS = [[0, 0], [0, 1], [1, 0], [2, 2]];

  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: BOARD_ID, name: 'Editor board F', boardSize: 3, timeframe: 'monthly', status: 'active',
      startDate: START, endDate: END, centerSquareType: 'free',
    });
    for (let i = 0; i < TITLES.length; i++) {
      await seedTask(page, { id: ids(i).task, title: TITLES[i], type: 'normal' });
      await seedBoardTask(page, {
        id: ids(i).bt, boardId: BOARD_ID, taskId: ids(i).task, row: CELLS[i][0], col: CELLS[i][1],
        ...(i === 3 ? { isLocked: true } : {}),
      });
    }
  });

  test('Shuffle counts as 1 edit; Save leaves locked squares in place', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();

    await page.getByRole('button', { name: 'Shuffle' }).click();
    await expect(page.getByText(/^1$/).first()).toBeVisible();

    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();

    const lockedBt = await readBoardTask(page, ids(3).bt);
    expect([lockedBt?.row, lockedBt?.col]).toEqual([2, 2]);
  });
});

test.describe('Squares editor (g) — center Free ⇄ task square', () => {
  const BOARD_ID = 'cccccccc-sqed-0006-0000-000000000000';
  const TASK_A = 'cccccccc-sqed-0006-task-000000000001';
  const FILLER = 'cccccccc-sqed-0006-task-000000000002';

  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: BOARD_ID, name: 'Editor board G', boardSize: 3, timeframe: 'monthly', status: 'active',
      startDate: START, endDate: END, centerSquareType: 'free',
    });
    await seedTask(page, { id: TASK_A, title: 'Center task', type: 'normal' });
    // A real placement so the board isn't stuck on "Loading board tasks…"
    // (the grid needs at least one live BoardTask to resolve `sortedBoardTasks`).
    await seedTask(page, { id: FILLER, title: 'Filler task', type: 'normal' });
    await seedBoardTask(page, { id: 'cccccccc-sqed-0006-bt-000000000001', boardId: BOARD_ID, taskId: FILLER, row: 0, col: 0 });
  });

  test('Make it a task square → empty center → add → Save', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();

    await page.getByRole('button', { name: 'Free space' }).click();
    await page.getByRole('button', { name: 'Make it a task square' }).click();

    // The center is now an empty NONE square — tapping it opens the D16
    // dialog ("Add a task…" / "Make it a free space"), not the picker
    // directly (that's reserved for a non-center empty square, D13).
    await page.getByRole('button', { name: /^Empty square, row 2, column 2$/ }).click();
    await page.getByRole('button', { name: 'Add a task…' }).click();
    await page.getByLabel('New normal task title').fill('Center');
    await page.getByRole('button', { name: /Center task/ }).click();

    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();

    const board = await readBoard(page, BOARD_ID);
    expect(board?.centerSquareType).toBe('none');
  });
});

test.describe('Squares editor (h) — legacy CHOSEN center normalizes on Save', () => {
  const BOARD_ID = 'cccccccc-sqed-0007-0000-000000000000';
  const TASK_A = 'cccccccc-sqed-0007-task-000000000001'; // center (chosen)
  const TASK_B = 'cccccccc-sqed-0007-task-000000000002'; // unrelated

  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: BOARD_ID, name: 'Editor board H', boardSize: 3, timeframe: 'monthly', status: 'active',
      startDate: START, endDate: END, centerSquareType: 'chosen',
    });
    await seedTask(page, { id: TASK_A, title: 'Chosen center task', type: 'normal' });
    await seedTask(page, { id: TASK_B, title: 'Other task', type: 'normal' });
    await seedBoardTask(page, { id: 'cccccccc-sqed-0007-bt-000000000001', boardId: BOARD_ID, taskId: TASK_A, row: 1, col: 1, isCenter: true });
    await seedBoardTask(page, { id: 'cccccccc-sqed-0007-bt-000000000002', boardId: BOARD_ID, taskId: TASK_B, row: 0, col: 0 });
  });

  test('opens with a locked center; Unlock → Save → the board row is `none`', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();

    // The legacy CHOSEN center reads as a normal, effectively-locked cell.
    await expect(page.getByRole('img', { name: 'Locked in place' })).toHaveCount(1);

    await page.getByRole('button', { name: /^Chosen center task/ }).click();
    await expect(page.getByRole('button', { name: 'Unlock' })).toBeVisible();
    await page.getByRole('button', { name: 'Unlock' }).click();

    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();

    const board = await readBoard(page, BOARD_ID);
    expect(board?.centerSquareType).toBe('none');
  });
});

test.describe('Squares editor (i) — keyboard Alt+Arrow move', () => {
  const BOARD_ID = 'cccccccc-sqed-0008-0000-000000000000';
  const ids = (n: number) => ({ task: `cccccccc-sqed-0008-task-00000000000${n}`, bt: `cccccccc-sqed-0008-bt-0000000000000${n}` });

  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: BOARD_ID, name: 'Editor board I', boardSize: 3, timeframe: 'monthly', status: 'active',
      startDate: START, endDate: END, centerSquareType: 'free',
    });
    await seedTask(page, { id: ids(0).task, title: 'Keyboard task', type: 'normal' });
    await seedBoardTask(page, { id: ids(0).bt, boardId: BOARD_ID, taskId: ids(0).task, row: 0, col: 0 });
  });

  test('Alt+ArrowRight swaps into the empty neighbor and announces the move', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();

    await page.getByRole('button', { name: /^Keyboard task$/ }).focus();
    await page.keyboard.press('Alt+ArrowRight');

    await expect(page.getByText(/^1$/).first()).toBeVisible();
    await expect(page.getByText(/Moved Keyboard task to row 1, column 2/)).toBeAttached();
  });
});

test.describe('Squares editor (j) — no play-mode "+" on empty squares', () => {
  const BOARD_ID = 'cccccccc-sqed-0009-0000-000000000000';
  const TASK_A = 'cccccccc-sqed-0009-task-000000000001';

  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: BOARD_ID, name: 'Editor board J', boardSize: 3, timeframe: 'monthly', status: 'active',
      startDate: START, endDate: END, centerSquareType: 'free',
    });
    await seedTask(page, { id: TASK_A, title: 'Only task', type: 'normal' });
    await seedBoardTask(page, { id: 'cccccccc-sqed-0009-bt-000000000001', boardId: BOARD_ID, taskId: TASK_A, row: 0, col: 0 });
  });

  test('an empty square in play mode has no "+" affordance', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByText('Editor board J').first()).toBeVisible();
    await expect(page.getByRole('button', { name: 'Add task to this cell' })).toHaveCount(0);
    await expect(page.getByText('+', { exact: true })).toHaveCount(0);
  });
});

test.describe('Squares editor (k) — a board with zero squares still renders', () => {
  const BOARD_ID = 'cccccccc-sqed-0011-0000-000000000000';
  const TASK_A = 'cccccccc-sqed-0011-task-000000000001';
  const TASK_B = 'cccccccc-sqed-0011-task-000000000002'; // library, unplaced

  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: BOARD_ID, name: 'Editor board K', boardSize: 3, timeframe: 'monthly', status: 'active',
      startDate: START, endDate: END, centerSquareType: 'free',
    });
    await seedTask(page, { id: TASK_A, title: 'The only square', type: 'normal' });
    await seedTask(page, { id: TASK_B, title: 'Refill from library', type: 'normal' });
    await seedBoardTask(page, { id: 'cccccccc-sqed-0011-bt-000000000001', boardId: BOARD_ID, taskId: TASK_A, row: 0, col: 0 });
  });

  test('remove every square → Save → empty board renders → add via tap-empty → Save', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();
    await page.getByRole('button', { name: /^The only square$/ }).click();
    await page.getByRole('button', { name: 'Remove from board' }).click();
    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();

    // Zero placements — the board renders its empty grid, never "Loading…".
    await page.reload();
    await expect(page.getByText('Editor board K').first()).toBeVisible();
    await expect(page.getByText(/Loading/)).toHaveCount(0);
    await expect(page.getByText('The only square')).toHaveCount(0);

    // …and it is still editable: Edit board → tap an empty square → add.
    await page.getByRole('button', { name: 'Edit board' }).click();
    await page.getByRole('button', { name: /^Empty square, row 1, column 1$/ }).click();
    await expect(page.getByRole('dialog', { name: /Add square/ })).toBeVisible();
    await page.getByLabel('New normal task title').fill('Refill');
    await page.getByRole('button', { name: /Refill from library/ }).click();
    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();

    await page.reload();
    await expect(page.getByText('Refill from library')).toBeVisible();
  });
});

test.describe('Squares editor (l) — Edit task… turns a plain square into a compound', () => {
  const BOARD_ID = 'cccccccc-sqed-0012-0000-000000000000';
  const TASK_A = 'cccccccc-sqed-0012-task-000000000001';

  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: BOARD_ID, name: 'Editor board L', boardSize: 3, timeframe: 'monthly', status: 'active',
      startDate: START, endDate: END, centerSquareType: 'free',
    });
    await seedTask(page, { id: TASK_A, title: 'Morning routine', type: 'normal' });
    await seedBoardTask(page, { id: 'cccccccc-sqed-0012-bt-000000000001', boardId: BOARD_ID, taskId: TASK_A, row: 0, col: 0 });
  });

  test('type Compound → add two sub-tasks → Done → Save → the square is a compound; reopen shows both parts', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();
    await page.getByRole('button', { name: /^Morning routine$/ }).click();
    await page.getByRole('button', { name: 'Edit task…' }).click();

    const sheet = page.getByRole('dialog', { name: 'Edit task' });
    await sheet.getByRole('button', { name: 'Compound', exact: true }).click();
    // Zero sub-tasks: Done stays disabled. One is enough (2026-10-06).
    await expect(sheet.getByRole('button', { name: 'Done' })).toBeDisabled();
    await sheet.getByLabel('New normal task title').fill('Stretch');
    await sheet.getByLabel('New normal task title').press('Enter');
    await expect(sheet.getByRole('button', { name: 'Done' })).toBeEnabled();
    await sheet.getByLabel('New normal task title').fill('Journal');
    await sheet.getByLabel('New normal task title').press('Enter');
    await expect(sheet.getByLabel('Sub-task 2 title')).toHaveValue('Journal');
    await sheet.getByRole('button', { name: 'Done' }).click();

    // Staged: one edit, the square already shows the compound tag.
    await expect(page.getByRole('img', { name: 'Unsaved edit' })).toHaveCount(1);
    await expect(page.getByText('≡')).toBeVisible();
    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();

    await page.reload();
    await expect(page.getByText('≡')).toBeVisible();

    // Reopen Edit task: the type is fixed and the editor shows both parts.
    await page.getByRole('button', { name: 'Edit board' }).click();
    await page.getByRole('button', { name: /^Morning routine$/ }).click();
    await page.getByRole('button', { name: 'Edit task…' }).click();
    const reopened = page.getByRole('dialog', { name: 'Edit task' });
    await expect(reopened.getByLabel('Sub-task 1 title')).toHaveValue('Stretch');
    await expect(reopened.getByLabel('Sub-task 2 title')).toHaveValue('Journal');
    // The type selector is gone (no "Simple" option) — the compound editor's own
    // "New sub: Normal / Counting" chips are NOT the type selector, so don't
    // assert on "Counting" here: that count is 0 only until the editor mounts.
    await expect(reopened.getByRole('button', { name: 'Simple', exact: true })).toHaveCount(0);
  });
  test('stage Compound → reopen → switch back to Simple → Done → still Simple after Save', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();
    await page.getByRole('button', { name: /^Morning routine$/ }).click();
    await page.getByRole('button', { name: 'Edit task…' }).click();
    const sheet = page.getByRole('dialog', { name: 'Edit task' });
    await sheet.getByRole('button', { name: 'Compound', exact: true }).click();
    await sheet.getByLabel('New normal task title').fill('Stretch');
    await sheet.getByLabel('New normal task title').press('Enter');
    await sheet.getByLabel('New normal task title').fill('Journal');
    await sheet.getByLabel('New normal task title').press('Enter');
    await sheet.getByRole('button', { name: 'Done' }).click();
    await expect(page.getByText('≡')).toBeVisible();

    // Reopen the staged compound: the type control is still a switch (original is Simple).
    await page.getByRole('button', { name: /Morning routine/ }).first().click();
    await page.getByRole('button', { name: 'Edit task…' }).click();
    const reopened = page.getByRole('dialog', { name: 'Edit task' });
    await reopened.getByRole('button', { name: 'Simple', exact: true }).click();
    await reopened.getByRole('button', { name: 'Done' }).click();
    await expect(page.getByText('≡')).toHaveCount(0);

    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();
    await page.reload();
    await expect(page.getByText('≡')).toHaveCount(0);
    await expect(page.getByRole('button', { name: /Morning routine/ })).toBeVisible();
  });
});
