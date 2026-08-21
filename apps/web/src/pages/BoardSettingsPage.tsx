import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import {
  Timeframe,
  type CoreBoardDefault,
  type Pool,
  type RecurringBoardTemplate,
  type SpawnPoolFailureReason,
} from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import {
  useCoreBoardDefault,
  usePools,
  useRecurringBoardTemplates,
  useTemplateMixes,
} from '../hooks';
import { useTaskLibrary, useBrowsableTasks } from './createPage/useTaskLibrary';
import { applyCoreBoardDefaultPrefill } from './createHub/poolPullLogic';
import { computeTemplateAttention } from '../components/recurringTemplates/templateHealth';
import { computePoolPreview, type PoolPreview } from '../components/recurringTemplates/poolPreview';
import { RepeatingBoardRow } from '../components/boardSettings/RepeatingBoardRow';
import { CoreDefaultsSheet } from '../components/boardSettings/CoreDefaultsSheet';
import { RosterEditSheet } from '../components/boardSettings/RosterEditSheet';
import styles from './BoardSettingsPage.module.css';

const CORE_TIMEFRAMES: { value: Timeframe; label: string }[] = [
  { value: Timeframe.DAILY, label: 'Daily' },
  { value: Timeframe.WEEKLY, label: 'Weekly' },
  { value: Timeframe.MONTHLY, label: 'Monthly' },
  { value: Timeframe.YEARLY, label: 'Yearly' },
];

/**
 * BoardSettingsPage — /profile/board-settings (Task Pools + Recurring
 * Boards Rework, P7, docs/POOLS_RECURRING.md §Surfaces item 9). Replaces
 * BOTH retired Profile sub-pages — "Recurring templates"
 * (`/profile/recurring-templates`) and "Default pools"
 * (`/profile/default-pools[/:timeframe]`) — with one page:
 *
 * - Per-timeframe core-defaults rows (Daily/Weekly/Monthly/Yearly), each
 *   showing its resolved default tasks (pool tasks ∪ `coreDefaultTaskIds`,
 *   deduped) or "No default tasks" (never "Not set" — copy rule). Tapping
 *   a row opens `CoreDefaultsSheet` for that timeframe.
 * - The repeating-boards roster: EVERY spawn record (active AND paused —
 *   this is the safety net for paused boards, so it must not filter on
 *   `isActive`), reusing the same row/health/pool-preview machinery the
 *   retired templates page used (`RepeatingBoardRow`, `computeTemplateAttention`,
 *   `computePoolPreview`, `useTemplateMixes`). "Edit tasks" opens
 *   `RosterEditSheet` in place instead of navigating to the wizard.
 */
export function BoardSettingsPage(): React.ReactElement {
  const { user } = useAuth();
  const userId = user?.id;

  const library = useTaskLibrary(userId);
  const browsableTasks = useBrowsableTasks(library.allTasks, library.childToParents);
  const pools = usePools(userId);
  const templates = useRecurringBoardTemplates(userId);
  const templateMixes = useTemplateMixes(templates);

  const dailyDefault = useCoreBoardDefault(userId, Timeframe.DAILY);
  const weeklyDefault = useCoreBoardDefault(userId, Timeframe.WEEKLY);
  const monthlyDefault = useCoreBoardDefault(userId, Timeframe.MONTHLY);
  const yearlyDefault = useCoreBoardDefault(userId, Timeframe.YEARLY);
  const coreDefaultByTimeframe: Partial<Record<Timeframe, CoreBoardDefault | null | undefined>> = {
    [Timeframe.DAILY]: dailyDefault,
    [Timeframe.WEEKLY]: weeklyDefault,
    [Timeframe.MONTHLY]: monthlyDefault,
    [Timeframe.YEARLY]: yearlyDefault,
  };

  const poolsById = useMemo(() => {
    const m: Record<string, Pool> = {};
    for (const p of pools) m[p.id] = p;
    return m;
  }, [pools]);

  const defaultsPreviewByTimeframe = useMemo(() => {
    const out: Partial<Record<Timeframe, PoolPreview>> = {};
    const rows: [Timeframe, CoreBoardDefault | null | undefined][] = [
      [Timeframe.DAILY, dailyDefault],
      [Timeframe.WEEKLY, weeklyDefault],
      [Timeframe.MONTHLY, monthlyDefault],
      [Timeframe.YEARLY, yearlyDefault],
    ];
    for (const [tf, row] of rows) {
      if (!row) continue;
      const resolved = applyCoreBoardDefaultPrefill(
        row.corePoolIds,
        row.coreDefaultTaskIds,
        poolsById,
        library.taskMap,
      );
      out[tf] = computePoolPreview(Array.from(resolved.selectedTaskIds), library.taskMap);
    }
    return out;
  }, [dailyDefault, weeklyDefault, monthlyDefault, yearlyDefault, poolsById, library.taskMap]);

  const attentionByTemplateId = useMemo<Record<string, SpawnPoolFailureReason>>(
    () => computeTemplateAttention(templates, templateMixes ?? {}, library.taskMap),
    [templates, templateMixes, library.taskMap],
  );
  const poolPreviewByTemplateId = useMemo<Record<string, PoolPreview>>(() => {
    const out: Record<string, PoolPreview> = {};
    for (const t of templates) {
      const mixTaskIds = templateMixes?.[t.id] ?? t.seedTaskIds;
      out[t.id] = computePoolPreview(mixTaskIds, library.taskMap);
    }
    return out;
  }, [templates, templateMixes, library.taskMap]);
  const taskCountByTemplateId = useMemo<Record<string, number>>(() => {
    const out: Record<string, number> = {};
    for (const t of templates) {
      out[t.id] = (templateMixes?.[t.id] ?? t.seedTaskIds).length;
    }
    return out;
  }, [templates, templateMixes]);

  const [defaultsSheetTimeframe, setDefaultsSheetTimeframe] = useState<Timeframe | null>(null);
  const [rosterEditTemplate, setRosterEditTemplate] = useState<RecurringBoardTemplate | null>(null);

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <Link to="/profile" className={styles.backLink}>
          ‹ Profile
        </Link>
        <h1 className={styles.title}>Board settings</h1>
      </header>

      <div className={styles.sectionLabel}>Core-board defaults</div>
      <div className={styles.card}>
        {CORE_TIMEFRAMES.map(({ value, label }) => {
          const preview = defaultsPreviewByTimeframe[value];
          const summary =
            !preview || (preview.titles.length === 0 && preview.overflow === 0)
              ? 'No default tasks'
              : preview.overflow > 0
                ? `${preview.titles.join(', ')} +${preview.overflow} more`
                : preview.titles.join(', ');
          return (
            <button
              key={value}
              type="button"
              className={styles.row}
              onClick={() => setDefaultsSheetTimeframe(value)}
            >
              <span className={styles.rowLabel}>{label}</span>
              <span className={styles.rowSummary}>{summary}</span>
              <span className={styles.rowArrow}>&rarr;</span>
            </button>
          );
        })}
      </div>

      <div className={styles.sectionLabel}>Repeating boards</div>
      {templates.length === 0 ? (
        <div className={styles.emptyState}>
          <p className={styles.emptyTitle}>No repeating boards yet.</p>
          <p className={styles.emptyBody}>
            From the Create tab, tap <strong>&quot;Start a new board&quot;</strong> and choose a
            repeat cadence in Setup.
          </p>
        </div>
      ) : (
        <div className={styles.list}>
          {templates.map((t) => (
            <RepeatingBoardRow
              key={t.id}
              template={t}
              taskCount={taskCountByTemplateId[t.id] ?? t.seedTaskIds.length}
              attentionReason={attentionByTemplateId[t.id]}
              poolPreview={poolPreviewByTemplateId[t.id]?.titles}
              poolPreviewOverflow={poolPreviewByTemplateId[t.id]?.overflow}
              onEditTasks={setRosterEditTemplate}
            />
          ))}
        </div>
      )}

      {userId && defaultsSheetTimeframe !== null && (
        <CoreDefaultsSheet
          userId={userId}
          timeframe={defaultsSheetTimeframe}
          existingDefault={coreDefaultByTimeframe[defaultsSheetTimeframe] ?? undefined}
          pools={pools}
          templates={templates}
          allTasks={library.allTasks}
          browsableTasks={browsableTasks}
          onClose={() => setDefaultsSheetTimeframe(null)}
          onSaved={() => setDefaultsSheetTimeframe(null)}
        />
      )}

      {userId && rosterEditTemplate !== null && (
        <RosterEditSheet
          userId={userId}
          template={rosterEditTemplate}
          pools={pools}
          templates={templates}
          allTasks={library.allTasks}
          browsableTasks={browsableTasks}
          onClose={() => setRosterEditTemplate(null)}
          onSaved={() => setRosterEditTemplate(null)}
        />
      )}
    </div>
  );
}
