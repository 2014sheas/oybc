import { useMemo } from 'react';
import { Navigate, useNavigate, useParams } from 'react-router-dom';
import {
  AchievementTrigger,
  Timeframe,
  computeStreak,
  getTimeframeBoundaries,
  stepWindow,
  formatTimeframeLabel,
  isTimeframeExpired,
} from '@oybc/shared';
import { useAuth } from '../../firebase/useAuth';
import { useBoards } from '../../hooks/useBoards';
import { usePreferences } from '../../hooks';
import { BoardPlaySurface } from '../../components/BoardPlaySurface';
import { useCoreBoardForWindow } from './useCoreBoardForWindow';
import { CoreBoardWindowBar } from './CoreBoardWindowBar';
import { CoreBoardSetupPrompt } from './CoreBoardSetupPrompt';
import styles from './CoreBoardBrowserPage.module.css';

const VALID: ReadonlySet<string> = new Set([
  Timeframe.DAILY, Timeframe.WEEKLY, Timeframe.MONTHLY, Timeframe.YEARLY,
]);

/**
 * CoreBoardWindowPage — per-window core-board pager. Route:
 * `/boards/core/:timeframe/:date`. Seeds the current window from `:date`
 * (any date inside the window normalizes to its start). Prev/next navigate
 * (replace) to the adjacent window — the component stays mounted, the board
 * lookup re-fires reactively. Board exists → `BoardPlaySurface`; none →
 * `CoreBoardSetupPrompt`. The `≡ List` button opens the full browser.
 */
export function CoreBoardWindowPage(): React.ReactElement {
  const navigate = useNavigate();
  const { timeframe: rawTf, date: rawDate } = useParams<{ timeframe: string; date: string }>();
  const { user } = useAuth();
  const [preferences] = usePreferences();
  // Load all boards for the streak computation — `useBoards` is a live
  // query that updates reactively when boards change.
  const allBoards = useBoards(user?.id);

  const routeDateOnly = rawDate?.slice(0, 10);
  const isValidDate =
    !!routeDateOnly &&
    /^\d{4}-\d{2}-\d{2}$/.test(routeDateOnly) &&
    !Number.isNaN(new Date(`${routeDateOnly}T12:00:00`).getTime());

  const isValid = !!rawTf && VALID.has(rawTf) && isValidDate;
  const timeframe = (isValid ? rawTf : Timeframe.DAILY) as Timeframe;

  const now = useMemo(() => new Date(), []);

  const { startDate: windowStart, endDate: windowEnd } = useMemo(() => {
    // Parse as local noon, not UTC midnight. A date-only ISO string
    // ("YYYY-MM-DD") is specified to parse as UTC midnight, which shifts
    // the calendar day backwards for users west of UTC (e.g. LA sees
    // "2026-05-21" as May 20 @ 17:00 PDT). Appending T12:00:00 forces a
    // local parse and noon safely avoids any DST-midnight edge cases.
    const seed = routeDateOnly ? new Date(`${routeDateOnly}T12:00:00`) : now;
    return getTimeframeBoundaries(timeframe, seed, preferences.weekStartDay);
  }, [routeDateOnly, timeframe, preferences.weekStartDay, now]);

  const board = useCoreBoardForWindow(user?.id, timeframe, windowStart);

  // Greenlog streak for this timeframe — shown in the window bar chip.
  // Only recurrable timeframes have streaks; CUSTOM has no cadence.
  const streakCount = useMemo(
    () =>
      computeStreak(
        timeframe,
        AchievementTrigger.GREENLOG,
        allBoards,
        preferences.weekStartDay,
        now,
      ),
    [timeframe, allBoards, preferences.weekStartDay, now],
  );

  const go = (offset: -1 | 1) => {
    const { startDate } = stepWindow(timeframe, windowStart, offset, preferences.weekStartDay);
    navigate(`/boards/core/${timeframe}/${startDate.slice(0, 10)}`, { replace: true });
  };

  const handleSetUp = () => {
    const dateOnly = windowStart.slice(0, 10);
    navigate(`/create?recurringTimeframe=${timeframe}&windowDate=${dateOnly}`);
  };

  if (!isValid) return <Navigate to="/boards" replace />;

  const label = formatTimeframeLabel(timeframe, windowStart);
  const isPast = isTimeframeExpired(windowEnd, now);
  const bar = (
    <CoreBoardWindowBar
      label={label}
      onPrev={() => go(-1)}
      onNext={() => go(1)}
      onOpenList={() => navigate(`/boards/core/${timeframe}`)}
      streakCount={streakCount}
      timeframe={timeframe}
    />
  );

  if (board === undefined) {
    return <div className={styles.page}>{bar}<p className={styles.emptyState}>Loading…</p></div>;
  }
  if (board === null) {
    return (
      <div className={styles.page}>
        {bar}
        <CoreBoardSetupPrompt timeframe={timeframe} windowStart={windowStart} isPast={isPast} onSetUp={handleSetUp} />
      </div>
    );
  }
  return <BoardPlaySurface board={board} userId={user?.id} header={bar} allowEdit={false} />;
}
