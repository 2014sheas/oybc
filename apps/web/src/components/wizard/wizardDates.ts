/**
 * wizardDates.ts — the wizard's start/end-date resolution, split out of
 * `wizardPersist.ts` so `previewDerived.ts` (B3 RC6) can resolve the
 * prospective board's window without importing the persist module that
 * imports IT back. Pure: a controller in, ISO strings (or an error) out.
 *
 * Re-exported from `wizardPersist.ts` — existing callers are unchanged.
 */

import { Timeframe, getTimeframeBoundaries, toLocalISO } from '@oybc/shared';
import type { BoardWizardController } from '../../pages/createHub/useBoardWizard';

/** Resolved `startDate` / `endDate` ISO strings, or an error to surface.
 *  `endDate` is undefined for INDEFINITE (ongoing) boards. */
export type ResolvedDates =
  | { startDate: string; endDate?: string }
  | { error: string };

/**
 * Resolves start/end ISO timestamps for the new/updated board record.
 * Matches the semantics the legacy Create tab's `BoardCreatorPanel` used so the wizard
 * produces dates indistinguishable from the legacy panel's output.
 *
 * @param controller  Wizard state.
 * @param now         Reference date for non-CUSTOM windows. Defaults to
 *   `new Date()`. The core-board browser passes a future date here so a
 *   banner-launched "Plan ahead" flow spawns the window the user picked
 *   instead of always landing on today's window.
 */
export function resolveWizardDates(
  controller: BoardWizardController,
  now: Date = new Date(),
): ResolvedDates {
  // Indefinite (ongoing) boards have no deadline. Honor the chosen Start date
  // (the Custom section's Start picker is shown for ongoing boards too) — it's
  // the creation anchor + achievement-window lower bound; fall back to today
  // when unset. endDate stays undefined so the board carries no deadline.
  if (controller.timeframe === Timeframe.INDEFINITE) {
    let start: Date;
    if (controller.customStartDate) {
      const [sy, sm, sd] = controller.customStartDate.split('-').map(Number);
      start = new Date(sy, sm - 1, sd, 0, 0, 0, 0);
    } else {
      start = new Date(now);
      start.setHours(0, 0, 0, 0);
    }
    return { startDate: toLocalISO(start), endDate: undefined };
  }
  if (controller.timeframe !== Timeframe.CUSTOM) {
    const b = getTimeframeBoundaries(
      controller.timeframe,
      now,
      controller.weekStartDay,
    );
    return { startDate: b.startDate, endDate: b.endDate };
  }
  if (!controller.customStartDate || !controller.customEndDate) {
    return { error: 'Pick a start and end date.' };
  }
  // Parse YYYY-MM-DD manually to avoid UTC shift from `new Date('YYYY-MM-DD')`.
  const [sy, sm, sd] = controller.customStartDate.split('-').map(Number);
  const [ey, em, ed] = controller.customEndDate.split('-').map(Number);
  const start = new Date(sy, sm - 1, sd, 0, 0, 0, 0);
  const end = new Date(ey, em - 1, ed, 23, 59, 59, 999);
  if (end.getTime() < start.getTime()) {
    return { error: 'End date must be on or after the start date.' };
  }
  return { startDate: toLocalISO(start), endDate: toLocalISO(end) };
}
