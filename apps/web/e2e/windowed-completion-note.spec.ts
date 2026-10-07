import { test, expect } from './_fixtures/bypass';

/**
 * E2E guard for the RETIRED Windowed Completion one-time upgrade note.
 *
 * The dismissible "What's new" Boards-tab banner (added in WC PR B, #318) was
 * deliberately removed from BOTH platforms in #447 — a one-time upgrade note is
 * meaningless pre-launch — along with its localStorage key. There is no
 * replacement surface, so this spec pins the removal: even a browser that never
 * dismissed the note (fresh localStorage, including the legacy key cleared)
 * must not see it on the Boards tab.
 */
test.describe('Windowed Completion upgrade note (retired in #447)', () => {
  test('never appears on the Boards tab, even with a never-dismissed localStorage', async ({
    page,
  }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await page.evaluate(() => localStorage.removeItem('oybc.windowedCompletionNoteDismissed.v1'));
    await page.reload();

    // The Boards tab has rendered before we assert the absence.
    await expect(page.getByRole('heading', { name: 'Boards', level: 1 })).toBeVisible();
    await expect(page.getByRole('region', { name: "What's new" })).toHaveCount(0);
    await expect(page.getByRole('button', { name: "Dismiss what's-new note" })).toHaveCount(0);
  });
});
