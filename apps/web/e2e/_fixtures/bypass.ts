import { test as base, type Page } from '@playwright/test';

/**
 * Playwright fixture that auto-engages the dev-only auth bypass.
 *
 * The bypass mechanism lives in `src/firebase/AuthContext.tsx` —
 * see its `isTestBypassActive` doc-comment for the full gating story.
 * Production builds dead-strip the bypass branch entirely.
 *
 * **No DB wipe between tests.** The bypass user is idempotent
 * (`AuthContext.ensureBypassUserRow` uses `put`), and the test cases
 * here are read-only against the bypass user's slice. If a future
 * test mutates state in a way that affects subsequent tests,
 * introduce per-test cleanup either by wiping specific tables via
 * Dexie's API (NOT `indexedDB.deleteDatabase`, which closes the
 * live Dexie connection mid-flight) or by parameterizing the bypass
 * user id via a per-test query param.
 *
 * Usage:
 *
 * ```ts
 * import { test, expect } from './_fixtures/bypass';
 *
 * test('boards page renders empty state', async ({ page }) => {
 *   await page.goto('/');
 *   await expect(page.getByRole('heading', { name: 'Boards' })).toBeVisible();
 * });
 * ```
 *
 * The fixture sets `__oybc_test_bypass=1` via the URL on the first
 * navigation so AuthContext promotes it to sessionStorage; subsequent
 * in-app navigation keeps the bypass live until the browser context
 * tears down (sessionStorage is per-tab).
 */
export const test = base.extend<Record<string, never>>({
  page: async ({ page }, use) => {
    // Surface AuthContext's `[auth-bypass]` error logs in the test
    // runner's stdout when the bootstrap fails. Other console output
    // is intentionally suppressed to keep the test runner output
    // focused.
    page.on('console', (msg) => {
      if (msg.type() === 'error' && msg.text().includes('[auth-bypass]')) {
        console.log(`[browser] ${msg.text()}`);
      }
    });

    // Visit the root with the bypass query param. AuthContext promotes
    // the param to sessionStorage immediately, so any in-app
    // navigation the test does keeps the bypass live.
    await page.goto('/?__oybc_test_bypass=1');
    // `use` here is Playwright's fixture-yield callback
    // (https://playwright.dev/docs/test-fixtures), not a React hook.
    // The naming collision with React's `use` API is unavoidable
    // without breaking from the framework's API.
    // eslint-disable-next-line react-hooks/rules-of-hooks
    await use(page);
  },
});

/** The bypass user's id — exported so tests that seed user-scoped
 *  rows (templates, boards, tasks) can reference it without
 *  duplicating the literal. Mirror of `BYPASS_USER_ID` in
 *  `src/firebase/AuthContext.tsx`. */
export const BYPASS_USER_ID = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

/** Shape of a `RecurringBoardTemplate` row, kept loose (Record-typed)
 *  so this fixture file doesn't import the shared Zod-generated type
 *  (which would pull `@oybc/shared` into the e2e module graph and
 *  trigger a chain of bundler concerns). Tests seed plain objects
 *  that match the schema — the seed function below validates the
 *  required keys. */
export interface SeedTemplate {
  id: string;
  name: string;
  timeframe: 'daily' | 'weekly' | 'monthly' | 'yearly';
  boardSize: 3 | 4 | 5;
  centerSquareType: 'free' | 'custom_free' | 'none';
  centerSquareCustomName?: string;
  isRandomized: boolean;
  seedTaskIds: string[];
  isActive: boolean;
  // Optional sync metadata; sensible defaults filled in below.
  lastSpawnedWindowKey?: string | null;
  createdAt?: string;
  updatedAt?: string;
  version?: number;
  isDeleted?: boolean;
}

/**
 * Inserts a `RecurringBoardTemplate` row directly into Dexie via the
 * raw IndexedDB API. Bypasses the create-input Zod schema (so
 * malformed seed data won't be caught — assert your shape at the
 * call site), but matches the at-rest table layout.
 *
 * Why raw IDB rather than Dexie's API: Dexie's module-level singleton
 * lives in the app bundle, not the test harness; importing it here
 * would re-instantiate the connection in a fresh Dexie context that
 * conflicts with the page's own connection. Raw IDB sidesteps that.
 *
 * The template's `userId` is fixed to `BYPASS_USER_ID` so it appears
 * in the bypass user's slice (matches what `useRecurringBoardTemplates`
 * filters for).
 */
export async function seedTemplate(page: Page, template: SeedTemplate): Promise<void> {
  const now = new Date().toISOString();
  const row = {
    userId: BYPASS_USER_ID,
    centerSquareCustomName: undefined,
    lastSpawnedWindowKey: null,
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
    ...template,
  };
  await page.evaluate(async (rowToInsert) => {
    return new Promise<void>((resolve, reject) => {
      // Open the existing `oybc` Dexie database at its current version.
      // We pass no version arg so IDB just opens whatever's there
      // (Dexie has already migrated to v6+ as part of the page mount).
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const tx = db.transaction(['recurringBoardTemplates'], 'readwrite');
        tx.oncomplete = () => {
          db.close();
          resolve();
        };
        tx.onerror = () => reject(tx.error);
        tx.objectStore('recurringBoardTemplates').put(rowToInsert);
      };
    });
  }, row);
}

/**
 * Clears all rows from the `recurringBoardTemplates` table without
 * tearing down the Dexie connection. Use in tests that need a known
 * empty starting state for the templates list.
 */
export async function clearTemplates(page: Page): Promise<void> {
  await page.evaluate(async () => {
    return new Promise<void>((resolve, reject) => {
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const tx = db.transaction(['recurringBoardTemplates'], 'readwrite');
        tx.oncomplete = () => {
          db.close();
          resolve();
        };
        tx.onerror = () => reject(tx.error);
        tx.objectStore('recurringBoardTemplates').clear();
      };
    });
  });
}

// ─── Phase 6.3 — Board / Task / BoardTask seed helpers ──────────────────────
//
// Same raw-IDB pattern as `seedTemplate` above. The Phase 6.3
// achievement-square spec needs a parent board with a placed cell to
// right-click, plus optional peer boards / templates for the modal's
// pickers. Each helper takes a loosely-typed `Record` (avoids pulling
// `@oybc/shared` into the e2e module graph) and writes one row.

export interface SeedBoard {
  id: string;
  name: string;
  boardSize: 3 | 4 | 5;
  timeframe: 'daily' | 'weekly' | 'monthly' | 'yearly' | 'custom';
  status: 'active' | 'completed' | 'archived' | 'draft';
  startDate: string;
  endDate: string;
  centerSquareType?: 'free' | 'custom_free' | 'none' | 'chosen';
  isRandomized?: boolean;
  totalTasks?: number;
  completedTasks?: number;
  linesCompleted?: number;
  completedLineIds?: string[];
  spawnedFromTemplateId?: string;
}

export async function seedBoard(page: Page, board: SeedBoard): Promise<void> {
  const now = new Date().toISOString();
  const row = {
    userId: BYPASS_USER_ID,
    centerSquareType: 'free',
    isRandomized: false,
    totalTasks: board.boardSize * board.boardSize,
    completedTasks: 0,
    linesCompleted: 0,
    completedLineIds: [],
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
    ...board,
  };
  await page.evaluate(async (rowToInsert) => {
    return new Promise<void>((resolve, reject) => {
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const tx = db.transaction(['boards'], 'readwrite');
        tx.oncomplete = () => {
          db.close();
          resolve();
        };
        tx.onerror = () => reject(tx.error);
        tx.objectStore('boards').put(rowToInsert);
      };
    });
  }, row);
}

export interface SeedTask {
  id: string;
  title: string;
  type: 'normal' | 'counting' | 'compound' | 'achievement';
  /** Optional task description. Used by description-search tests. */
  description?: string;
  /** Counting-task action verb (e.g. "Run"). */
  action?: string;
  /** Counting-task unit string (e.g. "miles"). */
  unit?: string;
  /** Counting-task target count. */
  maxCount?: number;
  /** Counting-task current progress; used by the "in progress" status
   *  filter and the detail page's progress bar. */
  currentCount?: number;
  /** Compound-task ordering flag — true ⇒ Progress UX, false ⇒ Composite. */
  isOrdered?: boolean;
  /** Mark the task as already completed (global completion state). */
  isCompleted?: boolean;
  /** Phase 6.3 — Achievement-task reference (specific-board mode).
   *  Mutually exclusive with `referencedTemplateId`; only valid when
   *  `type === 'achievement'`. */
  referencedBoardId?: string;
  /** Phase 6.3 — Achievement-task reference (recurring-template mode). */
  referencedTemplateId?: string;
  /** Phase 6.3 — completion trigger (default 'greenlog'). */
  achievementTrigger?: 'bingo' | 'greenlog';
  /** Phase 6.3 — required count of in-window spawns hitting the
   *  trigger. Positive integer; required for template mode. */
  requiredCount?: number;
}

export async function seedTask(page: Page, task: SeedTask): Promise<void> {
  const now = new Date().toISOString();
  const row = {
    userId: BYPASS_USER_ID,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
    ...task,
  };
  await page.evaluate(async (rowToInsert) => {
    return new Promise<void>((resolve, reject) => {
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const tx = db.transaction(['tasks'], 'readwrite');
        tx.oncomplete = () => {
          db.close();
          resolve();
        };
        tx.onerror = () => reject(tx.error);
        tx.objectStore('tasks').put(rowToInsert);
      };
    });
  }, row);
}

export interface SeedBoardTask {
  id: string;
  boardId: string;
  taskId: string;
  row: number;
  col: number;
  isCenter?: boolean;
  // Phase 6.3 — `BoardTask` is now a pure placement record. The
  // achievement-square config moved to `Task` (`type='achievement'`
  // + `referencedBoardId` / `referencedTemplateId` / `achievementTrigger`
  // / `requiredCount`) — see `SeedTask` above.
}

export async function seedBoardTask(page: Page, boardTask: SeedBoardTask): Promise<void> {
  const now = new Date().toISOString();
  const row = {
    isCenter: false,
    createdAt: now,
    updatedAt: now,
    version: 1,
    ...boardTask,
  };
  await page.evaluate(async (rowToInsert) => {
    return new Promise<void>((resolve, reject) => {
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const tx = db.transaction(['boardTasks'], 'readwrite');
        tx.oncomplete = () => {
          db.close();
          resolve();
        };
        tx.onerror = () => reject(tx.error);
        tx.objectStore('boardTasks').put(rowToInsert);
      };
    });
  }, row);
}

export interface SeedCompoundChild {
  id: string;
  compoundTaskId: string;
  childTaskId: string;
  childIndex: number;
}

/**
 * Inserts a `compoundChildren` link row directly via raw IDB. Same
 * pattern as the other seeders. Used to verify the cascade-delete
 * impact preview and the actual link-row soft-delete behavior.
 */
export async function seedCompoundChild(
  page: Page,
  link: SeedCompoundChild,
): Promise<void> {
  const now = new Date().toISOString();
  const row = {
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
    ...link,
  };
  await page.evaluate(async (rowToInsert) => {
    return new Promise<void>((resolve, reject) => {
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const tx = db.transaction(['compoundChildren'], 'readwrite');
        tx.oncomplete = () => {
          db.close();
          resolve();
        };
        tx.onerror = () => reject(tx.error);
        tx.objectStore('compoundChildren').put(rowToInsert);
      };
    });
  }, row);
}

/**
 * Read a `compoundChildren` row by id from IndexedDB. Returns null if
 * not found. Used by cascade-delete tests to assert the soft-delete
 * flag flipped after the cascade.
 */
export async function readCompoundChild(
  page: Page,
  id: string,
): Promise<Record<string, unknown> | null> {
  return await page.evaluate(async (childId) => {
    return new Promise<Record<string, unknown> | null>((resolve, reject) => {
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const tx = db.transaction(['compoundChildren'], 'readonly');
        const req = tx.objectStore('compoundChildren').get(childId);
        req.onsuccess = () => {
          db.close();
          resolve((req.result as Record<string, unknown> | undefined) ?? null);
        };
        req.onerror = () => reject(req.error);
      };
    });
  }, id);
}

export { expect } from '@playwright/test';
