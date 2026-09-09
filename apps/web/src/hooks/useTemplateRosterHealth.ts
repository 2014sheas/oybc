import { useLiveQuery } from 'dexie-react-hooks';
import type { RecurringBoardTemplate } from '@oybc/shared';
import { fetchTemplateSupplyResolution } from '../db/operations/boardSources';
import {
  computeRosterHealth,
  type RosterHealth,
} from '../components/recurringTemplates/templateHealth';

/**
 * Sources-native roster health for the Board-settings repeating-boards
 * list (loose-ends sweep 2026-09-09). Supersedes the `useTemplateMixes`
 * + `computeTemplateAttention` pair, which resolved via the legacy trio —
 * board-kind sources read as empty there (a board-only repeating board
 * showed a spurious warning and "0 tasks"), and ranges / cap overlap /
 * the counter-family rule were invisible to the counts, previews, and
 * badge.
 *
 * One batched resolution per roster (pools + boards + tasks each fetched
 * once), through the SAME board-supply reader and achievable-size math
 * the spawn pass uses — so the badge is the spawn's static twin,
 * `source_board_missing` included.
 *
 * Returns `undefined` while loading (the tri-state convention).
 */
export function useTemplateRosterHealth(
  templates: RecurringBoardTemplate[],
): RosterHealth | undefined {
  return useLiveQuery(async (): Promise<RosterHealth> => {
    if (templates.length === 0) {
      return { mixByTemplateId: {}, attentionByTemplateId: {} };
    }
    const { byTemplateId, tasksById } = await fetchTemplateSupplyResolution(templates);
    return computeRosterHealth(templates, byTemplateId, tasksById);
  }, [templates]);
}
