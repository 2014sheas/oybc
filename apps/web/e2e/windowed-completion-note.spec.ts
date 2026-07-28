import { test, expect } from './_fixtures/bypass';

/**
 * E2E for the Windowed Completion one-time upgrade note
 * (docs/WINDOWED_COMPLETION.md §What changes visibly at upgrade). The note is a
 * dismissible Boards-tab banner shown exactly once, remembered via localStorage.
 * This is the pragmatic user-visible-flip spec; the unit matrix carries the
 * event/derivation weight.
 */
test.describe('Windowed Completion upgrade note', () => {
  test('appears on the Boards tab, then stays dismissed after "Got it"', async ({ page }) => {
    // Fresh localStorage: the note has never been dismissed.
    await page.goto('/boards?__oybc_test_bypass=1');
    await page.evaluate(() => localStorage.removeItem('oybc.windowedCompletionNoteDismissed.v1'));
    await page.reload();

    const note = page.getByRole('region', { name: "What's new" });
    await expect(note).toBeVisible();
    await expect(note).toContainText('each window');

    // Dismiss — the note disappears and the flag persists.
    await page.getByRole('button', { name: "Dismiss what's-new note" }).click();
    await expect(note).toBeHidden();

    const dismissed = await page.evaluate(() =>
      localStorage.getItem('oybc.windowedCompletionNoteDismissed.v1'),
    );
    expect(dismissed).toBe('1');

    // A reload does NOT bring it back (shown once).
    await page.reload();
    await expect(page.getByRole('region', { name: "What's new" })).toBeHidden();
  });
});
