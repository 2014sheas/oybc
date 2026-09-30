import { useMemo } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import type { Task, TaskEvent } from '@oybc/shared';
import { db } from '../db/internal';
import { useAuth } from '../firebase/useAuth';
import { useBoards } from './useBoards';
import { useTasks } from './useTasks';
import { usePreferences } from './usePreferences';
import { useRecurringBoardTemplates } from './useRecurringBoardTemplates';
import { useSharedCounterGroups } from './useSharedCounterGroups';
import {
  buildBoardSettingsTileSummary,
  buildStreakTileData,
  selectRecentCounters,
  type BoardSettingsTileSummary,
  type ProfileHomeCounterRow,
  type StreakTileData,
} from '../pages/profileHome';

/** Everything the new Profile home (`pages/ProfilePage.tsx`) renders,
 *  reactive over live Dexie queries. See `pages/profileHome.ts` for the pure
 *  derivations this composes. */
export interface ProfileHomeData {
  boardSettings: BoardSettingsTileSummary;
  streak: StreakTileData;
  /** Up to 2 counters, most recently logged first. */
  recentCounters: ProfileHomeCounterRow[];
  /** Total shared-counter count, for the "All {n} ›" header link. */
  totalCounterCount: number;
}

/**
 * useProfileHome — the read-model hook behind the Profile home tiles +
 * Shared counters block (Profile reorg PR2). Composes existing live-query
 * hooks (`useBoards`, `useTasks`, `usePreferences`, `useRecurringBoardTemplates`,
 * `useSharedCounterGroups`) plus one small raw query for the counters'
 * source-task increment events (needed for `selectLastIncrementEntry`
 * recency ordering — a different slice than `useSharedCounterGroups`'
 * internal window-resolution event fetch, so it isn't already exposed).
 *
 * No new persisted state — every value is derived from data the app already
 * stores (`docs/PROFILE reorg spec §State`: "No new persisted state").
 */
export function useProfileHome(): ProfileHomeData {
  const { user } = useAuth();
  const userId = user?.id;

  const boards = useBoards(userId);
  const tasksResult = useTasks(userId);
  const [prefs] = usePreferences();
  const templates = useRecurringBoardTemplates(userId);
  const groups = useSharedCounterGroups(userId);

  const tasksById = useMemo(() => {
    const map = new Map<string, Task>();
    for (const t of tasksResult ?? []) map.set(t.id, t);
    return map;
  }, [tasksResult]);

  const sourceIds = useMemo(() => groups.map((g) => g.counterId), [groups]);

  // The events feeding `selectLastIncrementEntry` recency ordering + the
  // "logged X" label — a source-task-only query (roots own every event),
  // indexed on `taskId` like `useSharedCounterGroups`' own event fetch.
  const eventsBySourceId = useLiveQuery(
    async (): Promise<Record<string, TaskEvent[]>> => {
      if (sourceIds.length === 0) return {};
      const out: Record<string, TaskEvent[]> = {};
      for (const e of await db.taskEvents.where('taskId').anyOf(sourceIds).toArray()) {
        if (!e.isDeleted) (out[e.taskId] ??= []).push(e);
      }
      return out;
    },
    [sourceIds],
    {},
  );

  const now = useMemo(() => new Date(), []);

  const boardSettings = useMemo(
    () => buildBoardSettingsTileSummary(prefs, templates.length),
    [prefs, templates.length],
  );

  const streak = useMemo(() => buildStreakTileData(boards, prefs.weekStartDay, now), [boards, prefs.weekStartDay, now]);

  const recentCounters = useMemo(
    () => selectRecentCounters(groups, tasksById, eventsBySourceId ?? {}, 2),
    [groups, tasksById, eventsBySourceId],
  );

  return {
    boardSettings,
    streak,
    recentCounters,
    totalCounterCount: groups.length,
  };
}
