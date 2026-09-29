import {
  resolveCoreBoardSetupDefaults,
  type CoreBoardSetupDefaults,
  type CoreBoardSetupOverrides,
  type CoreBoardSetupPrefs,
} from '@oybc/shared';

/**
 * T2 (docs/POOLS_RECURRING.md §Per-timeframe size + centre) — decides
 * whether the wizard's one-shot CoreBoardDefault prefill effect
 * (`useBoardWizard.ts`) should apply a resolved size/centre, and what to
 * apply. Pure so it's independently unit-testable without rendering the
 * hook — mirrors `wizardTimeframeSeed.ts`'s pattern (the hook
 * transitively initializes Firebase Auth at module load, which a bare
 * `.test.ts` import of `useBoardWizard.ts` would trip on CI, per that
 * file's own doc comment).
 *
 * Returns `null` when the caller already changed size/centre while the
 * row was loading (`userTouchedSetup`, set by the wizard's `setSize` /
 * `setCenterType`) — the prefill must never stomp that. Otherwise
 * resolves the timeframe's row override (or inherits prefs) via the one
 * shared resolver both wizards use.
 *
 * @param coreBoardDefault - The timeframe's `CoreBoardDefault` row (or its
 *   override pair); `null`/`undefined` = no row = inherit prefs.
 * @param preferences - The user's global size + centre defaults.
 * @param userTouchedSetup - Whether the user already changed size/centre
 *   via the wizard's exposed setters before this resolved.
 * @returns The setup to apply, or `null` to skip applying anything.
 */
export function resolveCoreSetupPrefill(
  coreBoardDefault: CoreBoardSetupOverrides | null | undefined,
  preferences: CoreBoardSetupPrefs,
  userTouchedSetup: boolean,
): CoreBoardSetupDefaults | null {
  if (userTouchedSetup) return null;
  return resolveCoreBoardSetupDefaults(coreBoardDefault, preferences);
}
