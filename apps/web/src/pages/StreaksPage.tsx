import { useMemo } from 'react';
import { Link } from 'react-router-dom';
import {
  AchievementTrigger,
  BoardStatus,
  Timeframe,
  computeStreak,
  computeLongestStreak,
  compactStreakLabel,
} from '@oybc/shared';
import type { Board } from '@oybc/shared';
import { useAuth } from '../firebase/useAuth';
import { useBoards } from '../hooks/useBoards';
import { usePreferences } from '../hooks/usePreferences';
import { RisoSectionLabel } from '../components/riso';
import { RisoIcon } from '../components/riso/RisoIcon';
import profileStyles from './ProfilePage.module.css';
import styles from './StreaksPage.module.css';

// ─── Supporting value types ────────────────────────────────────────────────────

/** One dot in the 7-day week strip. */
interface WeekDot {
  /** ISO date string for this dot's calendar day (YYYY-MM-DD). */
  date: string;
  /** True when a daily core board was GREENLOGed on this calendar day. */
  isFilled: boolean;
  /** True when this dot represents today. */
  isToday: boolean;
}

/** One row in the GREENLOG history list. */
interface HistoryRow {
  id: string;
  name: string;
  squares: number;
  bingos: number;
  timeframe: Timeframe;
  relativeDate: string;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Returns 7 WeekDot values for the last 7 days (oldest → newest, index 0 =
 * 6 days ago, index 6 = today). A dot is filled when a daily core board was
 * GREENLOGed on that calendar day.
 */
function buildWeekDots(boards: Board[], now: Date): WeekDot[] {
  // Collect days (as YYYY-MM-DD) when a daily core board was GREENLOGed.
  const greenloggedDays = new Set<string>();
  for (const b of boards) {
    if (
      b.isCore &&
      b.timeframe === Timeframe.DAILY &&
      b.status === BoardStatus.COMPLETED &&
      !b.isDeleted &&
      b.completedAt
    ) {
      // `new Date(completedAt)` handles both UTC-Z and local-ISO strings.
      // We want the local calendar day, so we use toLocaleDateString in ISO-like form.
      const d = new Date(b.completedAt);
      if (!Number.isNaN(d.getTime())) {
        // Build YYYY-MM-DD in local time (not UTC).
        const year = d.getFullYear();
        const month = String(d.getMonth() + 1).padStart(2, '0');
        const day = String(d.getDate()).padStart(2, '0');
        greenloggedDays.add(`${year}-${month}-${day}`);
      }
    }
  }

  const todayYear = now.getFullYear();
  const todayMonth = String(now.getMonth() + 1).padStart(2, '0');
  const todayDay = String(now.getDate()).padStart(2, '0');
  const todayStr = `${todayYear}-${todayMonth}-${todayDay}`;

  return Array.from({ length: 7 }, (_, i) => {
    const offset = i - 6; // -6, -5, ..., 0
    const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() + offset);
    const year = d.getFullYear();
    const month = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    const dateStr = `${year}-${month}-${day}`;
    return {
      date: dateStr,
      isFilled: greenloggedDays.has(dateStr),
      isToday: dateStr === todayStr,
    };
  });
}

/**
 * Human-readable relative label for a `completedAt` date: "Today",
 * "Yesterday", or a short date like "May 30".
 */
function relativeLabel(completedAt: string, now: Date): string {
  const d = new Date(completedAt);
  if (Number.isNaN(d.getTime())) return '';

  const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const yesterdayStart = new Date(todayStart.getTime() - 86_400_000);
  const dStart = new Date(d.getFullYear(), d.getMonth(), d.getDate());

  if (dStart.getTime() === todayStart.getTime()) return 'Today';
  if (dStart.getTime() === yesterdayStart.getTime()) return 'Yesterday';

  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

/**
 * Builds history rows from all completed, non-deleted boards that have a
 * `completedAt` timestamp, sorted newest-first.
 */
function buildHistoryRows(boards: Board[], now: Date): HistoryRow[] {
  return boards
    .filter((b) => b.status === BoardStatus.COMPLETED && !b.isDeleted && !!b.completedAt)
    .map((b) => ({
      board: b,
      completedAt: new Date(b.completedAt!),
    }))
    .filter(({ completedAt }) => !Number.isNaN(completedAt.getTime()))
    .sort((a, b) => b.completedAt.getTime() - a.completedAt.getTime())
    .map(({ board }) => ({
      id: board.id,
      name: board.name,
      squares: board.totalTasks,
      bingos: board.linesCompleted,
      timeframe: board.timeframe,
      relativeDate: relativeLabel(board.completedAt!, now),
    }));
}

/**
 * Returns a CSS background color value for a timeframe pill (mirrors iOS
 * `Timeframe.risoColor`).
 */
function timeframeColor(tf: Timeframe): string {
  switch (tf) {
    case Timeframe.DAILY:      return 'var(--riso-blue)';
    case Timeframe.WEEKLY:     return 'var(--riso-green)';
    case Timeframe.MONTHLY:    return 'var(--riso-red)';
    case Timeframe.YEARLY:     return 'var(--riso-achievement)';
    case Timeframe.CUSTOM:     return 'var(--riso-muted)';
    case Timeframe.INDEFINITE: return 'var(--riso-muted)';
    default:                   return 'var(--riso-muted)';
  }
}

function timeframeLabel(tf: Timeframe): string {
  switch (tf) {
    case Timeframe.DAILY:      return 'Daily';
    case Timeframe.WEEKLY:     return 'Weekly';
    case Timeframe.MONTHLY:    return 'Monthly';
    case Timeframe.YEARLY:     return 'Yearly';
    case Timeframe.CUSTOM:     return 'Custom';
    case Timeframe.INDEFINITE: return 'Ongoing';
    default:                   return 'Board';
  }
}

function keepItAliveNote(currentStreak: number): string {
  if (currentStreak === 0) return 'Complete a daily board to start your streak.';
  if (currentStreak === 1) return 'Off to a great start — come back tomorrow!';
  return 'Great work! Complete today\'s board to keep the chain going.';
}

// ─── Inline SVG helpers (no dep on RisoIcon for filled-style shapes) ──────────

function CheckmarkSvg(): React.ReactElement {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <polyline points="4 12 9 17 20 6" />
    </svg>
  );
}

// ─── StreaksPage ───────────────────────────────────────────────────────────────

/**
 * StreaksPage — "Streaks & history" sub-page under Profile.
 *
 * Mirrors iOS `StreaksView`. Thin container: loads boards via live query,
 * derives all values (current daily-greenlog streak, longest, total GREENLOGs,
 * 7-day week strip, board history) via the shared streaks engine, and renders
 * them as a Riso-styled scrollable page.
 *
 * Derive-not-persist: no new DB table or field. Every value comes from the
 * existing boards table. Route: `/profile/streaks`.
 */
export function StreaksPage(): React.ReactElement {
  const { user } = useAuth();
  const [prefs] = usePreferences();
  const boards = useBoards(user?.id);
  // Frozen at mount (empty deps). "Today/Yesterday" labels and the week strip
  // won't re-anchor if the page is left open across midnight — an accepted
  // trade-off for a profile sub-page (mirrors CoreBoardWindowPage's frozen
  // `now`); a midnight-tick interval would be disproportionate here.
  const now = useMemo(() => new Date(), []);

  // Derived values — all computed from boards (same pattern as iOS loadData).
  const currentStreak = useMemo(
    () => computeStreak(Timeframe.DAILY, AchievementTrigger.GREENLOG, boards, prefs.weekStartDay, now),
    [boards, prefs.weekStartDay, now]
  );

  const longestStreak = useMemo(
    () => computeLongestStreak(Timeframe.DAILY, boards, prefs.weekStartDay, now),
    [boards, prefs.weekStartDay, now]
  );

  const greenlogCount = useMemo(
    () => boards.filter((b) => b.status === BoardStatus.COMPLETED && !b.isDeleted).length,
    [boards]
  );

  const weekDots = useMemo(() => buildWeekDots(boards, now), [boards, now]);
  const historyRows = useMemo(() => buildHistoryRows(boards, now), [boards, now]);

  return (
    <div className={styles.container}>
      {/* Sub-page header (back link + title) — reuses ProfilePage.module.css pattern */}
      <div className={profileStyles.subPageHeader}>
        <Link to="/profile" className={profileStyles.backLink} aria-label="Back to Profile">
          &larr;
        </Link>
        <h1 className={profileStyles.header}>Streaks</h1>
      </div>

      {/* Section label */}
      <RisoSectionLabel>Your rhythm</RisoSectionLabel>

      {/* 1. Hero card — gold fill, daily greenlog streak */}
      <div className={styles.heroCard} aria-label={`Daily streak: ${currentStreak} day${currentStreak === 1 ? '' : 's'}`}>
        <div className={styles.heroInner}>
          <div className={styles.heroRow}>
            {/* Flame medallion */}
            <div className={styles.flameBadge} aria-hidden="true">
              <RisoIcon name="flame" size={22} />
            </div>

            {/* Streak number + unit */}
            <div className={styles.heroNumbers}>
              <span className={styles.heroCount}>{currentStreak}</span>
              <span className={styles.heroUnit}>day streak</span>
            </div>
          </div>
        </div>

        {/* 7-day week strip */}
        <div className={styles.weekStrip} role="list" aria-label="Last 7 days">
          {weekDots.map((dot) => {
            const dotClass = [
              styles.weekDot,
              dot.isFilled ? styles.weekDotFilled : styles.weekDotEmpty,
              dot.isToday ? styles.weekDotToday : '',
            ]
              .filter(Boolean)
              .join(' ');

            const a11yLabel = dot.isFilled
              ? 'Completed'
              : dot.isToday
              ? 'Today — not yet'
              : 'Missed';

            return (
              <div
                key={dot.date}
                className={dotClass}
                role="listitem"
                aria-label={a11yLabel}
              >
                {dot.isFilled && (
                  <svg className={styles.weekDotCheck} viewBox="0 0 24 24" aria-hidden="true">
                    <polyline points="4 12 9 17 20 6" />
                  </svg>
                )}
              </div>
            );
          })}
        </div>

        {/* Keep-alive note */}
        <p className={styles.keepNote}>{keepItAliveNote(currentStreak)}</p>
      </div>

      {/* 2. Stat trio — Current / Longest / GREENLOGs */}
      <div className={styles.statTrio}>
        <div className={styles.statCard} aria-label={`Current: ${currentStreak} days`}>
          <span className={styles.statValue}>{compactStreakLabel(currentStreak, Timeframe.DAILY)}</span>
          <span className={styles.statLabel}>Current</span>
        </div>
        <div className={styles.statCard} aria-label={`Longest: ${longestStreak} days`}>
          <span className={styles.statValue}>
            {longestStreak === 0 ? '–' : compactStreakLabel(longestStreak, Timeframe.DAILY)}
          </span>
          <span className={styles.statLabel}>Longest</span>
        </div>
        <div className={styles.statCard} aria-label={`Total GREENLOGs: ${greenlogCount}`}>
          <span className={styles.statValue}>{greenlogCount}</span>
          <span className={styles.statLabel}>GREENLOGs</span>
        </div>
      </div>

      {/* Section label */}
      <RisoSectionLabel>Greenlog history</RisoSectionLabel>

      {/* 3. History list */}
      {historyRows.length === 0 ? (
        <div className={styles.emptyHistory}>
          <span className={styles.emptyIcon} aria-hidden="true">✓</span>
          <p className={styles.emptyPrimary}>No completed boards yet</p>
          <p className={styles.emptySub}>
            Complete all tasks on any board to add it here.
          </p>
        </div>
      ) : (
        <div className={styles.historyCard}>
          {historyRows.map((row) => (
            <div
              key={row.id}
              className={styles.historyRow}
              aria-label={`${row.name}, ${row.squares} squares, ${row.bingos} bingos, ${row.relativeDate}`}
            >
              {/* Green check badge */}
              <div className={styles.historyCheck} aria-hidden="true">
                <CheckmarkSvg />
              </div>

              {/* Name + meta */}
              <div className={styles.historyMeta}>
                <div className={styles.historyName}>{row.name}</div>
                <div className={styles.historySub}>
                  {row.squares} squares · {row.bingos} bingo{row.bingos === 1 ? '' : 's'}
                </div>
              </div>

              {/* Timeframe pill + date */}
              <div className={styles.historyRight}>
                <span
                  className={styles.timeframePill}
                  style={{ backgroundColor: timeframeColor(row.timeframe) }}
                >
                  {timeframeLabel(row.timeframe)}
                </span>
                <span className={styles.historyDate}>{row.relativeDate}</span>
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Footer hint */}
      <p className={styles.footerHint}>
        Every cleared board lands here. Keep the chain going.
      </p>
    </div>
  );
}
