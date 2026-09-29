import type { Timeframe } from '@oybc/shared';
import {
  useCoreBoardDefault,
  usePools,
  usePreferences,
  useRecurringBoardTemplates,
  useTemplateRosterHealth,
} from '../../hooks';
import { useTaskLibrary, useBrowsableTasks } from '../../pages/createPage/useTaskLibrary';
import { CoreDefaultsSheet } from '../boardSettings/CoreDefaultsSheet';

export interface CoreDefaultsSheetHostProps {
  userId: string;
  /** The core board's own timeframe — the default row this host edits. */
  timeframe: Timeframe;
  onClose: () => void;
  onSaved: () => void;
}

/**
 * CoreDefaultsSheetHost — the "Core defaults…" menu item's data-loading host
 * (Board Edit redesign slice 2, plan D9). `CoreDefaultsSheet` takes pools /
 * tasks / templates / roster mix / library as props, which the Board
 * Settings page loads today (`BoardSettingsPage.reload()`'s call set) —
 * this host runs the SAME hooks so the sheet can be opened from the play
 * surface's board menu too, without duplicating its data plumbing. Mounted
 * only while the sheet is open (each hook is a live query; unmounting them
 * on close is cheap).
 */
export function CoreDefaultsSheetHost({
  userId,
  timeframe,
  onClose,
  onSaved,
}: CoreDefaultsSheetHostProps): React.ReactElement | null {
  const library = useTaskLibrary(userId);
  const browsableTasks = useBrowsableTasks(library.allTasks, library.childToParents);
  const pools = usePools(userId);
  const templates = useRecurringBoardTemplates(userId);
  const rosterHealth = useTemplateRosterHealth(templates);
  const existingDefault = useCoreBoardDefault(userId, timeframe);
  const [preferences] = usePreferences();

  // Tri-state: wait for the live query to resolve before seeding the sheet's
  // draft state, so a signed-in user with no row yet doesn't briefly flash
  // an empty sheet that then jumps to their real saved defaults.
  if (existingDefault === undefined) return null;

  return (
    <CoreDefaultsSheet
      userId={userId}
      timeframe={timeframe}
      existingDefault={existingDefault ?? undefined}
      preferences={preferences}
      pools={pools}
      templates={templates}
      achievableTaskIdsByTemplateId={rosterHealth?.mixByTemplateId}
      allTasks={library.allTasks}
      browsableTasks={browsableTasks}
      onClose={onClose}
      onSaved={onSaved}
    />
  );
}
