import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import {
  Timeframe,
  hasExplicitCoreBoardSetup,
  resolveCoreBoardSetupDefaults,
  type CoreBoardDefault,
  type Pool,
  type RecurringBoardTemplate,
  type UserPreferences,
} from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import {
  useCoreBoardDefault,
  usePools,
  usePreferences,
  useRecurringBoardTemplates,
  useTemplateRosterHealth,
} from '../hooks';
import { useTaskLibrary, useBrowsableTasks } from './createPage/useTaskLibrary';
import { applyCoreBoardDefaultPrefill } from './createHub/poolPullLogic';

import { formatDefaultsSummary } from '../components/boardSettings/formatDefaultsSummary';
import { EveryNewBoardCard } from '../components/boardSettings/EveryNewBoardCard';
import { RepeatingBoardRow } from '../components/boardSettings/RepeatingBoardRow';
import { CoreDefaultsSheet } from '../components/boardSettings/CoreDefaultsSheet';
import { RepeatingBoardWizardOverlay } from '../components/boardSettings/RepeatingBoardWizardOverlay';
import styles from './BoardSettingsPage.module.css';

const CORE_TIMEFRAMES: { value: Timeframe; label: string }[] = [
  { value: Timeframe.DAILY, label: 'Daily' },
  { value: Timeframe.WEEKLY, label: 'Weekly' },
  { value: Timeframe.MONTHLY, label: 'Monthly' },
  { value: Timeframe.YEARLY, label: 'Yearly' },
];

/**
 * BoardSettingsPage — /profile/board-settings. Restructured into three
 * groups (Profile reorg PR3, `design_handoff_profile_reorg/README.md` §4
 * "Board settings" / screenshot `4c-board-settings.png`;
 * `.superpowers/sdd/2026-09-30-profile-reorg/owner-decisions.md` PR3
 * paragraph):
 *
 * 1. **EVERY NEW BOARD** (`EveryNewBoardCard`) — Size / Timeframe / Center
 *    square / Week starts, all writing the SAME `UserPreferences` fields
 *    this page always wrote (previously plain `<select>`s under "New board
 *    defaults"); now `RisoSegmented` rows matching the design.
 * 2. **PRE-FILLED TASKS BY TIMEFRAME** (was "Core-board defaults") —
 *    unchanged behavior, renamed heading only. Per-timeframe core-defaults
 *    rows (Daily/Weekly/Monthly/Yearly), each showing its resolved default
 *    tasks (pool tasks ∪ `coreDefaultTaskIds`, deduped) or "No default
 *    tasks" (never "Not set" — copy rule). Tapping a row opens
 *    `CoreDefaultsSheet` for that timeframe.
 * 3. **REPEATING BOARDS** (was "Repeating boards") — same roster query
 *    (EVERY spawn record, active AND paused — the safety net for paused
 *    boards, so it must not filter on `isActive`), but each row is now a
 *    ONE-LINE compact `RepeatingBoardRow`: name + timeframe badge, a
 *    `{size} board · {n}-task pool · renews {day}`/`… · paused` meta line,
 *    an optional attention badge, a trailing Active/Paused toggle, and a
 *    chevron. Pool-preview chips and the separate "Edit tasks"/"Delete"
 *    buttons are dropped — the whole row opens the editor
 *    (`RepeatingBoardWizardOverlay` wrapping `BoardWizardPage` in
 *    `editingTemplate` mode, unchanged). A trailing "New ›" link opens the
 *    Create hub's repeating-board wizard entry directly
 *    (`/create?newBoard=recurring`, the same top-nav deep link
 *    `AppTopNav`'s "New board" button uses for the one-off variant).
 *
 * Footer helper diverges ONE WORD from the iOS copy: "Renewal reminders
 * are under Settings" (not "Settings › Notifications") — web has no
 * Notifications sub-page; the renewal "prompt me" toggles live directly on
 * `/profile/settings`'s "Board renewals" card (Profile reorg PR1, owner
 * decision 3).
 *
 * Also absorbs "New board defaults" (week-start / board size / timeframe /
 * center square — every field on the new-board form), which used to live
 * on the now-deleted `/profile/board-preferences` sub-page
 * (`BoardPreferencesPage`). Not a P7 concept; relocated here because the old
 * sub-page was deleted and it otherwise had no other home.
 *
 * The Phase 6.1 "Recurring board reminders" prompt-me toggles that used to
 * live at the bottom of this page moved to `/profile/settings` as the
 * "Board renewals" card (Profile reorg PR1, owner decision 3, 2026-09-30) —
 * web has no Notifications sub-page, so they live on Settings instead.
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
  // Loose-ends sweep (2026-09-09) — sources-native roster health: honest
  // achievable counts/previews + the spawn's full attention set
  // (`source_board_missing` included). Replaces the legacy-trio
  // `useTemplateMixes` + `computeTemplateAttention` pair.
  const rosterHealth = useTemplateRosterHealth(templates);
  const templateMixes = rosterHealth?.mixByTemplateId;

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

  const defaultsSummaryByTimeframe = useMemo(() => {
    const out: Partial<Record<Timeframe, string>> = {};
    const rows: [Timeframe, CoreBoardDefault | null | undefined][] = [
      [Timeframe.DAILY, dailyDefault],
      [Timeframe.WEEKLY, weeklyDefault],
      [Timeframe.MONTHLY, monthlyDefault],
      [Timeframe.YEARLY, yearlyDefault],
    ];
    for (const [tf, row] of rows) {
      const resolved = applyCoreBoardDefaultPrefill(
        row?.corePoolIds ?? [],
        row?.coreDefaultTaskIds ?? [],
        poolsById,
        library.taskMap,
      );
      const poolNames = resolved.pulledPoolIds
        .map((id) => poolsById[id]?.name)
        .filter((name): name is string => name != null);
      // T3 — the size/centre suffix appears only when this timeframe
      // explicitly overrides either field; an inheriting row shows no
      // suffix even though it still resolves to a size under the hood.
      const setup = hasExplicitCoreBoardSetup(row) ? resolveCoreBoardSetupDefaults(row, prefs) : undefined;
      out[tf] = formatDefaultsSummary(resolved.selectedTaskIds.size, poolNames, setup);
    }
    return out;
  }, [dailyDefault, weeklyDefault, monthlyDefault, yearlyDefault, poolsById, library.taskMap, prefs]);

  const attentionByTemplateId = rosterHealth?.attentionByTemplateId ?? {};
  const taskCountByTemplateId = useMemo<Record<string, number>>(() => {
    const out: Record<string, number> = {};
    for (const t of templates) {
      out[t.id] = (templateMixes?.[t.id] ?? t.seedTaskIds).length;
    }
    return out;
  }, [templates, templateMixes]);

  const [defaultsSheetTimeframe, setDefaultsSheetTimeframe] = useState<Timeframe | null>(null);
  const [editingTemplate, setEditingTemplate] = useState<RecurringBoardTemplate | null>(null);

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <Link to="/profile" className={styles.backLink}>
          ‹ Profile
        </Link>
        <h1 className={styles.title}>Board settings</h1>
      </header>

      <div className={styles.sectionLabel}>Every new board</div>
      <EveryNewBoardCard preferences={prefs} onChange={setPref} />

      <div className={styles.sectionLabel}>Pre-filled tasks by timeframe</div>
      <div className={styles.card} role="group" aria-label="Pre-filled tasks by timeframe">
        {CORE_TIMEFRAMES.map(({ value, label }) => {
          const summary = defaultsSummaryByTimeframe[value] ?? 'No default tasks';
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

      <div className={styles.sectionHeader}>
        <span className={styles.sectionLabel}>Repeating boards</span>
        <Link
          to="/create?newBoard=recurring"
          className={styles.sectionHeaderLink}
          aria-label="New repeating board"
        >
          New &rsaquo;
        </Link>
      </div>
      {templates.length === 0 ? (
        <div className={styles.emptyState}>
          <p className={styles.emptyTitle}>No repeating boards yet.</p>
          <p className={styles.emptyBody}>
            From the Create tab, tap <strong>&quot;Start a new board&quot;</strong> and choose a
            repeat cadence in Setup.
          </p>
        </div>
      ) : (
        <div className={styles.card}>
          {templates.map((t) => (
            <RepeatingBoardRow
              key={t.id}
              template={t}
              taskCount={taskCountByTemplateId[t.id] ?? t.seedTaskIds.length}
              weekStartDay={prefs.weekStartDay}
              attentionReason={attentionByTemplateId[t.id]}
              onOpen={setEditingTemplate}
            />
          ))}
        </div>
      )}
      <p className={styles.footerHelper}>
        Tap a board to edit its pool and cadence. Renewal reminders are under Settings.
      </p>

      {userId && defaultsSheetTimeframe !== null && (
        <CoreDefaultsSheet
          userId={userId}
          timeframe={defaultsSheetTimeframe}
          existingDefault={coreDefaultByTimeframe[defaultsSheetTimeframe] ?? undefined}
          preferences={prefs}
          pools={pools}
          templates={templates}
          achievableTaskIdsByTemplateId={templateMixes}
          allTasks={library.allTasks}
          browsableTasks={browsableTasks}
          onClose={() => setDefaultsSheetTimeframe(null)}
          onSaved={() => setDefaultsSheetTimeframe(null)}
        />
      )}

      {userId && editingTemplate !== null && (
        <RepeatingBoardWizardOverlay
          userId={userId}
          preferences={prefs}
          template={editingTemplate}
          onClose={() => setEditingTemplate(null)}
        />
      )}
    </div>
  );
}
