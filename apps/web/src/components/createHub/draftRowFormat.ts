import { formatRecurringCadence, type Board } from '@oybc/shared';

/**
 * Board Creation Split (web PR D) — pure draft-row formatting extracted
 * from `CreateHubDraftsList` so the kind/pill/meta-line logic is
 * independently unit-testable without a DOM/hook-rendering harness (this
 * repo has none — see `wizardTimeframeSeed.ts`'s docstring for the
 * established precedent of pulling render-adjacent pure logic into its own
 * leaf module). Mirrors iOS `DraftRowData.Kind` / `RisoDraftRow.metaText`.
 */

export type DraftKind = 'oneOff' | 'recurring';

/** One-off (red) vs recurring (blue) — drives the row's typed pill, the
 *  meta-line format, and (via `useBoardWizard`'s own hydration) which
 *  wizard mode tapping the row reopens. */
export function draftKind(draft: Pick<Board, 'isRecurringDraft'>): DraftKind {
  return draft.isRecurringDraft === true ? 'recurring' : 'oneOff';
}

/** "ONE-OFF" / "RECURRING" — the typed pill's uppercase label. */
export function draftTypePillLabel(kind: DraftKind): string {
  return kind === 'recurring' ? 'RECURRING' : 'ONE-OFF';
}

/**
 * The drafts-list row's meta line: one-off "4×4 · 9 tasks"; recurring
 * "Every week · 5×5 · 12 tasks" (README §Screens "1. Create hub").
 *
 * @param taskCount - For a one-off draft, the placed `BoardTask` row
 *   count; for a recurring draft, the FULL resolved `recurringDraftMix`
 *   size (never the placed-row count — see `useDraftTaskCount`'s doc).
 */
export function formatDraftMeta(
  draft: Pick<Board, 'boardSize' | 'timeframe' | 'isRecurringDraft'>,
  taskCount: number,
): string {
  const plural = taskCount === 1 ? '' : 's';
  const sizeAndCount = `${draft.boardSize}×${draft.boardSize} · ${taskCount} task${plural}`;
  if (draftKind(draft) !== 'recurring') return sizeAndCount;
  return `${formatRecurringCadence(draft.timeframe)} · ${sizeAndCount}`;
}
