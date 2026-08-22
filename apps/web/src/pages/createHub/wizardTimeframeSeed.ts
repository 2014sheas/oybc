import { Timeframe } from '@oybc/shared';

/**
 * Resolves the wizard's initial `timeframe` state from the seed sources
 * (draft / template / prefill / user default), applying the recurring-seed
 * coercion rules. Pure so it's independently unit-testable without
 * rendering the hook.
 *
 * Lives in its own module (not useBoardWizard.ts) so the unit test's
 * import graph stays free of firebase/config — the hook transitively
 * initializes Firebase Auth at module load, which throws
 * auth/invalid-api-key on CI where no .env.local exists. (Learned the
 * hard way: PR #280's CI failure.)
 *
 * - Board Creation Split (web PR C) — `isFreshRecurringFromHub` short-
 *   circuits to `WEEKLY` unconditionally, ignoring `defaultTimeframe`
 *   entirely: a fresh wizard launched from the recurring hub card seeds a
 *   default cadence rather than resolving the one-off preference (which
 *   may be CUSTOM/INDEFINITE — not valid cadences anyway). Mirrors iOS
 *   `BoardWizardViewModel.init`'s `self.timeframe = .weekly` branch. Does
 *   NOT apply when a draft/template/prefill supplies an explicit source
 *   (those still go through the coercion rules below) — callers only pass
 *   `true` for a truly fresh recurring session.
 * - Recurring entry (`initialIsRecurring`) can't seed `CUSTOM` or
 *   `INDEFINITE` (neither has a computed window/cadence) — falls back to
 *   `DAILY`, mirroring the `setTimeframe` setter's guard in
 *   useBoardWizard (`isRecurring && (t === CUSTOM || t === INDEFINITE)`).
 * - Non-recurring entry whose timeframe comes ONLY from the CUSTOM default
 *   (no explicit source) opens as ongoing (`INDEFINITE`) rather than
 *   `CUSTOM` with empty dates. An explicitly-CUSTOM draft/template/prefill
 *   keeps its dates.
 */
export function resolveInitialWizardTimeframe(
  explicitSource: Timeframe | null,
  defaultTimeframe: Timeframe,
  initialIsRecurring: boolean,
  isFreshRecurringFromHub = false,
): Timeframe {
  if (isFreshRecurringFromHub) return Timeframe.WEEKLY;
  const seed = explicitSource ?? defaultTimeframe;
  if (
    initialIsRecurring &&
    (seed === Timeframe.CUSTOM || seed === Timeframe.INDEFINITE)
  ) {
    return Timeframe.DAILY;
  }
  if (!initialIsRecurring && seed === Timeframe.CUSTOM && explicitSource === null) {
    return Timeframe.INDEFINITE;
  }
  return seed;
}
