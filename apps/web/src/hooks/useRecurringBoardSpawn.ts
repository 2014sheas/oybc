import { useEffect, useRef, useState } from 'react';
import {
  findTemplatesPendingSpawn,
  mergeUserPreferences,
  type SpawnPoolFailureReason,
} from '@oybc/shared';
import { db } from '../db/internal';
import {
  spawnTemplateBoard,
  type SpawnResult,
} from '../db/operations/recurringBoardSpawn';

/**
 * Hook that drives Phase 6.2 spawn detection + execution. Mounted by
 * `BoardsPage`; runs once on mount per user. Mirrors Phase 6.1's "lazy
 * detection on app-open" model — the spawn isn't background-scheduled,
 * it fires when the user opens the Boards tab.
 *
 * Returns the most recent batch's results so the Profile
 * recurring-templates page can surface "needs attention" indicators on
 * rows whose spawn was skipped (e.g., a seed task got soft-deleted
 * between save and spawn).
 *
 * Implementation notes:
 *
 * - `findTemplatesPendingSpawn` is structurally idempotent: it filters
 *   out templates whose `lastSpawnedWindowKey` matches the current
 *   window AND whose existing-board lookup hits. So even if the hook
 *   re-mounts (route navigation, fast-refresh) the second pass is a
 *   no-op once the first has written `lastSpawnedWindowKey`.
 *
 * - In-flight guard (`inFlightRef`) blocks re-entry while a batch is
 *   mid-execution. The cleanup `cancelled` flag stops future awaits
 *   from committing to state if the component unmounts.
 */
export interface RecurringSpawnDigest {
  /** Templates whose spawn succeeded in the most-recent pass. */
  succeeded: Array<{ templateId: string; boardId: string }>;
  /**
   * Templates whose spawn was skipped (validation or pool resolution
   * failure). Keyed by template id for O(1) row-level UI lookups.
   */
  attentionByTemplateId: Record<
    string,
    SpawnPoolFailureReason | 'no_pool_tasks_resolved' | 'spawn_failed' | 'source_board_missing'
  >;
}

const EMPTY_DIGEST: RecurringSpawnDigest = {
  succeeded: [],
  attentionByTemplateId: {},
};

export function useRecurringBoardSpawn(
  userId: string | undefined,
): RecurringSpawnDigest {
  const [digest, setDigest] = useState<RecurringSpawnDigest>(EMPTY_DIGEST);
  const inFlightRef = useRef(false);

  useEffect(() => {
    if (!userId) {
      setDigest(EMPTY_DIGEST);
      return;
    }

    let cancelled = false;

    void (async () => {
      if (inFlightRef.current) return;
      inFlightRef.current = true;
      try {
        const [user, userBoards, userTemplates] = await Promise.all([
          db.users.get(userId),
          db.boards
            .filter((b) => b.userId === userId && !b.isDeleted)
            .toArray(),
          db.recurringBoardTemplates
            .filter((t) => t.userId === userId && !t.isDeleted)
            .toArray(),
        ]);

        const prefs = mergeUserPreferences(user?.preferences);
        const pending = findTemplatesPendingSpawn(
          userTemplates,
          userBoards,
          prefs.weekStartDay,
          new Date(),
        );

        if (pending.length === 0) {
          if (!cancelled) setDigest(EMPTY_DIGEST);
          return;
        }

        const results: SpawnResult[] = [];
        for (const spawn of pending) {
          if (cancelled) return;
          try {
            results.push(await spawnTemplateBoard(spawn));
          } catch (err) {
            console.error(
              '[recurring-spawn] spawn failed for template',
              spawn.template.id,
              err,
            );
            // Treat unexpected throws as "needs attention" so the user
            // sees a badge instead of silently-stuck-on-old-window.
            results.push({
              ok: false,
              templateId: spawn.template.id,
              reason: 'spawn_failed',
            });
          }
        }

        if (cancelled) return;

        const succeeded: RecurringSpawnDigest['succeeded'] = [];
        const attentionByTemplateId: RecurringSpawnDigest['attentionByTemplateId'] = {};
        for (const r of results) {
          if (r.ok) {
            succeeded.push({ templateId: r.templateId, boardId: r.boardId });
          } else {
            attentionByTemplateId[r.templateId] = r.reason;
          }
        }
        setDigest({ succeeded, attentionByTemplateId });
      } finally {
        inFlightRef.current = false;
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [userId]);

  return digest;
}
