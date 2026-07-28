import { describe, expect, it } from 'vitest';
import { Timeframe } from '@oybc/shared';
import { resolveInitialWizardTimeframe } from '../wizardTimeframeSeed';

/**
 * Covers `resolveInitialWizardTimeframe` — the pure seed-resolution helper
 * extracted from `useBoardWizard`'s `timeframe` state initializer (issue
 * #236). Recurring entry (the Create-hub "recurring" CTA, or editing an
 * existing template) cannot seed `CUSTOM` or `INDEFINITE` — neither has a
 * computed window/cadence for a `RecurringBoardTemplate` — so both must
 * fall back to `DAILY`. Prior to the fix, only `CUSTOM` was excluded, so a
 * user whose default timeframe preference was `INDEFINITE` (or who
 * resumed via a source that resolved to it) landed a recurring entry on an
 * invalid seed timeframe.
 *
 * `useBoardWizard` itself is not exercised here — it's a hook with no
 * DOM/jsdom harness in this repo's deliberately-narrow Vitest setup (see
 * `vitest.config.ts`), so the guard is tested via its extracted pure
 * function rather than `renderHook`.
 */
describe('resolveInitialWizardTimeframe', () => {
  it('falls back to DAILY when recurring entry seeds from CUSTOM', () => {
    expect(
      resolveInitialWizardTimeframe(null, Timeframe.CUSTOM, true),
    ).toBe(Timeframe.DAILY);
  });

  it('falls back to DAILY when recurring entry seeds from INDEFINITE (issue #236)', () => {
    expect(
      resolveInitialWizardTimeframe(null, Timeframe.INDEFINITE, true),
    ).toBe(Timeframe.DAILY);
  });

  it('falls back to DAILY when recurring entry seeds from an explicit INDEFINITE source', () => {
    expect(
      resolveInitialWizardTimeframe(Timeframe.INDEFINITE, Timeframe.DAILY, true),
    ).toBe(Timeframe.DAILY);
  });

  it('coerces a CUSTOM-only default (no explicit source) to INDEFINITE for non-recurring entry', () => {
    expect(
      resolveInitialWizardTimeframe(null, Timeframe.CUSTOM, false),
    ).toBe(Timeframe.INDEFINITE);
  });

  it('keeps an explicitly-CUSTOM source for non-recurring entry (draft/template/prefill dates preserved)', () => {
    expect(
      resolveInitialWizardTimeframe(Timeframe.CUSTOM, Timeframe.DAILY, false),
    ).toBe(Timeframe.CUSTOM);
  });

  it('keeps an explicit INDEFINITE source unchanged for non-recurring entry', () => {
    expect(
      resolveInitialWizardTimeframe(Timeframe.INDEFINITE, Timeframe.DAILY, false),
    ).toBe(Timeframe.INDEFINITE);
  });

  it('passes through non-CUSTOM/INDEFINITE seeds unchanged for both recurring and non-recurring entry', () => {
    expect(
      resolveInitialWizardTimeframe(null, Timeframe.WEEKLY, true),
    ).toBe(Timeframe.WEEKLY);
    expect(
      resolveInitialWizardTimeframe(Timeframe.MONTHLY, Timeframe.DAILY, false),
    ).toBe(Timeframe.MONTHLY);
  });
});
