import type { WizardStep } from './useBoardWizard';

/**
 * Board Creation Split (web PR D) — computes which step a resumed draft
 * should open on: Setup (1) when nothing has been selected yet, Tasks/Pool
 * (2) when the selection is below the board's requirement, Preview (3)
 * once it can fill the board. README (design handoff) §Interactions &
 * Behavior / §State Management "Resume-step selection". Completed steps
 * stay reachable via the stepper's existing jump-back behavior regardless
 * of where this lands.
 *
 * Pure so it's independently unit-testable without rendering a hook or
 * touching Dexie — mirrors `wizardTimeframeSeed.ts`'s "keep the pure math
 * in its own leaf module" precedent. iOS twin:
 * `BoardWizardViewModel.resolveDraftInitialStep` (the math half; the
 * DB-lookup half lives in `useResumableDraft`/`resolveRecurringDraftMixTaskIds`
 * on web, mirroring iOS's own `resolvePoolMixHydration` split).
 *
 * @param tasksRequired - The board's fillable-cell count
 *   (`tasksNeededFor(size, centerType)`).
 * @param selectedCount - The draft's resolved selection size: placed
 *   `BoardTask` rows for a one-off draft, or the FULL resolved
 *   `recurringDraftMix` size for a recurring draft (never the placed-row
 *   count, which silently truncates an intentionally overfilled pool).
 */
export function computeDraftInitialStep(tasksRequired: number, selectedCount: number): WizardStep {
  if (selectedCount === 0) return 1;
  if (selectedCount < tasksRequired) return 2;
  return 3;
}
