import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import {
  CenterSquareType,
  Timeframe,
  type CoreBoardDefault,
  type Pool,
  type RecurringBoardTemplate,
  type SpawnPoolFailureReason,
  type UserPreferences,
} from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import {
  useCoreBoardDefault,
  usePools,
  usePreferences,
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
 * Phase 6.1 recurring-window "prompt me" toggles — independent of the
 * new-board defaults above because these drive the Boards-tab banner, not
 * the new-board form. When enabled, the Boards tab prompts the user to
 * create a board for each new window (daily/weekly/monthly/yearly) on
 * first open inside that window.
 */
const RECURRING_TOGGLES: {
  key: 'recurringDailyEnabled' | 'recurringWeeklyEnabled' | 'recurringMonthlyEnabled' | 'recurringYearlyEnabled';
  label: string;
  timeframe: Timeframe;
}[] = [
  { key: 'recurringDailyEnabled', label: 'Prompt for daily board', timeframe: Timeframe.DAILY },
  { key: 'recurringWeeklyEnabled', label: 'Prompt for weekly board', timeframe: Timeframe.WEEKLY },
  { key: 'recurringMonthlyEnabled', label: 'Prompt for monthly board', timeframe: Timeframe.MONTHLY },
  { key: 'recurringYearlyEnabled', label: 'Prompt for yearly board', timeframe: Timeframe.YEARLY },
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
 *
 * Also absorbs the two sections that used to live on the now-deleted
 * `/profile/board-preferences` sub-page (`BoardPreferencesPage`):
 * "New board defaults" (week-start / board size / timeframe / center square —
 * every field on the new-board form) at the top, and "Recurring board
 * reminders" (the Phase 6.1 prompt-me toggles) at the bottom. Neither is a
 * P7 concept; they're relocated here because the old sub-page was deleted
 * and they otherwise had no other home.
 */
export function BoardSettingsPage(): React.ReactElement {
  const { user } = useAuth();
  const userId = user?.id;

  const [prefs, updatePrefs] = usePreferences();
  const setPref = <K extends keyof UserPreferences>(
    key: K,
    value: UserPreferences[K]
  ): void => {
    updatePrefs({ [key]: value } as Partial<UserPreferences>);
  };

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

      <div className={styles.sectionLabel}>New board defaults</div>
      <div className={styles.card}>
        <div className={styles.settingsRow}>
          <label className={styles.rowLabel} htmlFor="pref-week-start">
            Week starts on
          </label>
          <select
            id="pref-week-start"
            className={styles.select}
            value={prefs.weekStartDay}
            onChange={(e) =>
              setPref('weekStartDay', e.target.value as UserPreferences['weekStartDay'])
            }
          >
            <option value="monday">Monday</option>
            <option value="sunday">Sunday</option>
          </select>
        </div>

        <div className={styles.settingsRow}>
          <label className={styles.rowLabel} htmlFor="pref-board-size">
            Default board size
          </label>
          <select
            id="pref-board-size"
            className={styles.select}
            value={prefs.defaultBoardSize}
            onChange={(e) =>
              setPref(
                'defaultBoardSize',
                Number(e.target.value) as UserPreferences['defaultBoardSize']
              )
            }
          >
            <option value={3}>3 × 3</option>
            <option value={4}>4 × 4</option>
            <option value={5}>5 × 5</option>
          </select>
        </div>

        <div className={styles.settingsRow}>
          <label className={styles.rowLabel} htmlFor="pref-timeframe">
            Default timeframe
          </label>
          <select
            id="pref-timeframe"
            className={styles.select}
            value={prefs.defaultTimeframe}
            onChange={(e) => setPref('defaultTimeframe', e.target.value as Timeframe)}
          >
            <option value={Timeframe.CUSTOM}>Custom</option>
            <option value={Timeframe.DAILY}>Daily</option>
            <option value={Timeframe.WEEKLY}>Weekly</option>
            <option value={Timeframe.MONTHLY}>Monthly</option>
            <option value={Timeframe.YEARLY}>Yearly</option>
          </select>
        </div>

        <div className={styles.settingsRow}>
          <label className={styles.rowLabel} htmlFor="pref-center-type">
            Default center square
          </label>
          <select
            id="pref-center-type"
            className={styles.select}
            value={prefs.defaultCenterType}
            onChange={(e) =>
              setPref(
                'defaultCenterType',
                e.target.value as UserPreferences['defaultCenterType']
              )
            }
          >
            <option value={CenterSquareType.FREE}>Free</option>
            <option value={CenterSquareType.NONE}>None</option>
          </select>
        </div>
      </div>

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

      <div className={styles.sectionLabel}>Recurring board reminders</div>
      <p className={styles.sectionIntro}>
        When enabled, the Boards tab will prompt you to create a board for
        each new window. Detection runs only when you open the app — no
        background notifications.
      </p>
      <div className={styles.card}>
        {RECURRING_TOGGLES.map(({ key, label, timeframe }) => (
          <div className={styles.settingsRow} key={key}>
            <label className={styles.rowLabel} htmlFor={`pref-${key}`}>
              {label}
            </label>
            <label className={styles.toggleSwitch}>
              <input
                id={`pref-${key}`}
                type="checkbox"
                checked={prefs[key]}
                onChange={(e) => setPref(key, e.target.checked)}
              />
              <span className={styles.toggleTrack} />
            </label>
            {prefs[key] && (
              <Link to={`/boards/core/${timeframe}`} className={styles.browseLink}>
                Browse →
              </Link>
            )}
          </div>
        ))}
      </div>

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
