import { test, expect, readCoreBoardDefault } from './_fixtures/bypass';

/**
 * Per-timeframe core-board default size + centre (T3/T4,
 * docs/POOLS_RECURRING.md §Per-timeframe size + centre, owner-decided
 * 2026-09-29). Covers the BOARD section of `CoreDefaultsSheet`:
 *
 *   1. Setting an explicit override (Daily → 3×3, no free space) saves
 *      it, the Board-settings summary line grows the "3×3 · no free
 *      space" suffix, and the wizard's core setup step (reached via the
 *      Boards-tab pager's "Set up" deep link, `/create?recurringTimeframe=…`)
 *      prefills from it.
 *   2. Clearing back to inherit ("Use new-board default") deletes both
 *      keys (never stores `null` — the sync-clearable-fields contract)
 *      and the wizard falls back to the global new-board default
 *      (5×5 / free space — `DEFAULT_USER_PREFERENCES`).
 *   3. An even size (Weekly → 4×4) hides the Free-space control entirely
 *      and stores an explicit `none` (mirrors the wizard's own coercion).
 *
 * The bypass user carries no `CoreBoardDefault` rows at test start, so
 * every timeframe begins fully inheriting.
 */

async function openDefaultsSheet(
  page: import('@playwright/test').Page,
  timeframeLabel: string,
): Promise<import('@playwright/test').Locator> {
  await page.goto('/profile/board-settings?__oybc_test_bypass=1');
  // Scoped to the "Pre-filled tasks by timeframe" group (Profile reorg
  // PR3) — the "EVERY NEW BOARD" card above it now ALSO has a Timeframe
  // segmented row with a bare "Daily"/"Weekly"/etc. button, which would
  // otherwise collide with a page-wide `/^Daily/` match.
  await page
    .getByRole('group', { name: 'Pre-filled tasks by timeframe' })
    .getByRole('button', { name: new RegExp(`^${timeframeLabel}`) })
    .click();
  const sheet = page.getByRole('dialog', { name: `${timeframeLabel} defaults` });
  await expect(sheet).toBeVisible();
  return sheet;
}

test.describe('Per-timeframe core-board default size + centre', () => {
  test('Daily 3×3/no-free-space: saves, summarizes, prefills the wizard; clearing restores the global default', async ({
    page,
  }) => {
    const sheet = await openDefaultsSheet(page, 'Daily');

    // BOARD section: size segmented defaults to the RESOLVED (inherited)
    // value — 5×5 (DEFAULT_USER_PREFERENCES) — with the muted inherit note.
    const sizeGroup = sheet.getByRole('group', { name: 'Board size' });
    await expect(sizeGroup.getByRole('button', { name: '5×5', exact: true })).toHaveAttribute(
      'aria-pressed',
      'true',
    );
    // ONE 'Default' badge for the whole BOARD section (iOS parity) — shown only while
    // neither size nor centre is explicit.
    await expect(sheet.getByText('Default', { exact: true })).toHaveCount(1);

    // Pick 3×3, then turn OFF the inherited Free space (odd board, so the
    // toggle is visible and starts checked — the global default is FREE).
    // The checkbox itself is visually hidden (the styled track is the
    // visible affordance), so assert its `checked` state directly and
    // interact via its associated `<label>` text (native label-click
    // semantics) rather than Playwright's visibility-gated `.uncheck()`.
    await sizeGroup.getByRole('button', { name: '3×3', exact: true }).click();
    const freeSpaceCheckbox = sheet.locator('#core-defaults-free-space');
    const freeSpaceLabel = sheet.getByText('Free space', { exact: true });
    await expect(freeSpaceCheckbox).toBeChecked();
    await freeSpaceLabel.click();
    await expect(freeSpaceCheckbox).not.toBeChecked();

    // Both fields are now explicit — the inherit notes are gone and the
    // "Use new-board default" clear link appears.
    await expect(sheet.getByText('Default', { exact: true })).toHaveCount(0);
    const clearLink = sheet.getByRole('button', { name: 'Use new-board default', exact: true });
    await expect(clearLink).toBeVisible();

    await sheet.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(sheet).toBeHidden();

    // Board-settings summary line grows the size/centre suffix.
    const prefilledTasksGroup = page.getByRole('group', { name: 'Pre-filled tasks by timeframe' });
    await expect(prefilledTasksGroup.getByRole('button', { name: /^Daily/ })).toContainText(
      '3×3 · no free space',
    );

    // At-rest: both fields stored as explicit values (never inferred).
    const savedRow = await readCoreBoardDefault(page, 'daily');
    expect(savedRow).not.toBeNull();
    expect((savedRow as Record<string, unknown>).defaultBoardSize).toBe(3);
    expect((savedRow as Record<string, unknown>).defaultCenterType).toBe('none');

    // The wizard's core setup step (Boards-tab pager's "Set up" deep link)
    // prefills from the saved override: 3×3 selected, centre "None".
    await page.goto('/create?recurringTimeframe=daily&__oybc_test_bypass=1');
    await expect(page.getByText('Core board for')).toBeVisible();
    await expect(page.getByRole('button', { name: '3×3', exact: true })).toHaveAttribute(
      'aria-pressed',
      'true',
    );
    await expect(page.locator('#bw-center-type')).toHaveValue('none');

    // Back to settings: clear the override back to inherit.
    const sheet2 = await openDefaultsSheet(page, 'Daily');
    await expect(
      sheet2.getByRole('group', { name: 'Board size' }).getByRole('button', { name: '3×3', exact: true }),
    ).toHaveAttribute('aria-pressed', 'true');
    await sheet2.getByRole('button', { name: 'Use new-board default', exact: true }).click();
    await expect(sheet2.getByText('Default', { exact: true })).toHaveCount(1);
    await sheet2.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(sheet2).toBeHidden();

    // Summary line drops the suffix entirely (no explicit override left).
    const dailyRowText = await page
      .getByRole('group', { name: 'Pre-filled tasks by timeframe' })
      .getByRole('button', { name: /^Daily/ })
      .innerText();
    expect(dailyRowText).not.toMatch(/\d×\d/);

    // At-rest: both keys deleted (absent), never stored as `null` — the
    // clearable-fields sync contract (docs/POOLS_RECURRING.md).
    const clearedRow = await readCoreBoardDefault(page, 'daily');
    expect(clearedRow).not.toBeNull();
    expect(Object.prototype.hasOwnProperty.call(clearedRow as object, 'defaultBoardSize')).toBe(false);
    expect(Object.prototype.hasOwnProperty.call(clearedRow as object, 'defaultCenterType')).toBe(false);

    // The wizard now falls back to the global new-board default (5×5 / free).
    await page.goto('/create?recurringTimeframe=daily&__oybc_test_bypass=1');
    await expect(page.getByText('Core board for')).toBeVisible();
    await expect(page.getByRole('button', { name: '5×5', exact: true })).toHaveAttribute(
      'aria-pressed',
      'true',
    );
    await expect(page.locator('#bw-center-type')).toHaveValue('free');
  });

  test('Weekly 4×4: hides the Free-space control and stores an explicit "none"', async ({ page }) => {
    const sheet = await openDefaultsSheet(page, 'Weekly');

    const sizeGroup = sheet.getByRole('group', { name: 'Board size' });
    await expect(sheet.getByText('Free space', { exact: true })).toBeVisible(); // 5×5 default is odd

    await sizeGroup.getByRole('button', { name: '4×4', exact: true }).click();
    await expect(sheet.getByText('Free space', { exact: true })).toHaveCount(0);

    await sheet.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(sheet).toBeHidden();

    // Even sizes show no free-space wording in the summary suffix.
    const weeklyRowText = await page
      .getByRole('group', { name: 'Pre-filled tasks by timeframe' })
      .getByRole('button', { name: /^Weekly/ })
      .innerText();
    expect(weeklyRowText).toContain('4×4');
    expect(weeklyRowText).not.toMatch(/free space/);

    const savedRow = await readCoreBoardDefault(page, 'weekly');
    expect(savedRow).not.toBeNull();
    expect((savedRow as Record<string, unknown>).defaultBoardSize).toBe(4);
    expect((savedRow as Record<string, unknown>).defaultCenterType).toBe('none');
  });
});
