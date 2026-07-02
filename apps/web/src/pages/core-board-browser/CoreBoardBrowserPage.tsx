import { useEffect, useMemo, useRef } from 'react';
import { Navigate, useNavigate, useParams } from 'react-router-dom';
import { Timeframe, toLocalISO } from '@oybc/shared';
import { useAuth } from '../../firebase/useAuth';
import { usePreferences } from '../../hooks';
import { deleteBoard } from '../../db/operations/boards';
import { useCoreBoardBrowser } from './useCoreBoardBrowser';
import { CoreBoardWindowCell } from './CoreBoardWindowCell';
import styles from './CoreBoardBrowserPage.module.css';

const TIMEFRAME_TITLE: Record<Timeframe, string> = {
  [Timeframe.DAILY]: 'Daily',
  [Timeframe.WEEKLY]: 'Weekly',
  [Timeframe.MONTHLY]: 'Monthly',
  [Timeframe.YEARLY]: 'Yearly',
  [Timeframe.CUSTOM]: 'Custom', // route-validated out; never reached
  [Timeframe.INDEFINITE]: 'Ongoing', // route-validated out; never reached
};

const VALID_BROWSER_TIMEFRAMES: ReadonlySet<string> = new Set([
  Timeframe.DAILY,
  Timeframe.WEEKLY,
  Timeframe.MONTHLY,
  Timeframe.YEARLY,
]);

/**
 * CoreBoardBrowserPage — per-timeframe browser. Route:
 * `/boards/core/:timeframe` (`daily | weekly | monthly | yearly`).
 *
 * Vertical list of calendar windows for one timeframe. Past windows
 * with an existing core board are rendered via `BoardListItem` and
 * tap into `BoardPlayPage`; empty windows render a Create CTA that
 * deep-links into the wizard with `?recurringTimeframe=...&windowDate=YYYY-MM-DD`
 * so the spawned board matches the picked window.
 *
 * Infinite scroll in both directions via IntersectionObserver
 * sentinels at the top and bottom of the list. Initial load is ±10
 * windows around the current one; each sentinel hit appends or
 * prepends 10 more.
 */
export function CoreBoardBrowserPage(): React.ReactElement {
  const navigate = useNavigate();
  const { timeframe: rawTimeframe } = useParams<{ timeframe: string }>();
  const { user } = useAuth();
  const [preferences] = usePreferences();

  // Hooks must run unconditionally — defer the validity check to JSX
  // (same Rules-of-Hooks pattern `DefaultPoolEditorPage` uses).
  const isValidTimeframe = !!rawTimeframe && VALID_BROWSER_TIMEFRAMES.has(rawTimeframe);
  const timeframe = (isValidTimeframe ? rawTimeframe : Timeframe.DAILY) as Timeframe;

  const browser = useCoreBoardBrowser({
    userId: user?.id,
    timeframe,
    weekStartDay: preferences.weekStartDay,
  });

  const earlierSentinelRef = useRef<HTMLDivElement | null>(null);
  const laterSentinelRef = useRef<HTMLDivElement | null>(null);
  const currentRowRef = useRef<HTMLDivElement | null>(null);

  // Scroll-into-view the current window on first render so the user
  // lands oriented around "now" rather than at the oldest cell.
  //
  // React Router reuses the same component instance when only the
  // `:timeframe` param changes (Daily → Weekly), so we reset the
  // one-shot flag whenever `timeframe` changes — otherwise the user
  // navigates to Weekly and lands at whatever scroll position the
  // Daily browser was left at.
  const didInitialScroll = useRef(false);
  useEffect(() => {
    didInitialScroll.current = false;
  }, [timeframe]);
  useEffect(() => {
    if (didInitialScroll.current) return;
    if (browser.currentIndex < 0) return;
    currentRowRef.current?.scrollIntoView({ block: 'center' });
    didInitialScroll.current = true;
  }, [browser.currentIndex]);

  // Sentinel-driven pagination. IntersectionObserver fires whenever
  // either sentinel enters the viewport (rootMargin lets us pre-load
  // a screen ahead so the user doesn't see a stall).
  //
  // Destructured up here so the deps array references the stable
  // callbacks directly — `[browser.loadEarlier, browser.loadLater]`
  // would trip `react-hooks/exhaustive-deps` since it can't see that
  // those are `useCallback`-stable across renders of the hook.
  const { loadEarlier, loadLater } = browser;
  useEffect(() => {
    const earlier = earlierSentinelRef.current;
    const later = laterSentinelRef.current;
    if (!earlier || !later) return;
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          if (entry.target === earlier) loadEarlier();
          if (entry.target === later) loadLater();
        }
      },
      { rootMargin: '400px' },
    );
    observer.observe(earlier);
    observer.observe(later);
    return () => observer.disconnect();
  }, [loadEarlier, loadLater]);

  const handleOpenBoard = useMemo(
    () => (boardId: string) => navigate(`/boards/${boardId}`),
    [navigate],
  );

  const handleCreate = useMemo(
    () => (windowStart: Date, tf: Timeframe) => {
      // Pass the local Y-M-D so the wizard interprets it in the
      // device's timezone (same defensive pattern `useRecurringTimeframeParam`
      // uses on the receiving end). `toLocalISO` gives a full datetime;
      // slice the date portion off so the URL stays short and stable.
      const dateOnly = toLocalISO(windowStart).slice(0, 10);
      navigate(`/create?recurringTimeframe=${tf}&windowDate=${dateOnly}`);
    },
    [navigate],
  );

  const handleDeleteBoard = useMemo(
    () => async (boardId: string) => {
      await deleteBoard(boardId);
    },
    [],
  );

  // Draft boards in the browser navigate to the wizard resume flow instead
  // of the play page (mirrors iOS CoreBoardBrowserPage onResumeDraft wiring).
  const handleResumeDraft = useMemo(
    () => (boardId: string) => navigate(`/create?resumeDraft=${boardId}`),
    [navigate],
  );

  if (!isValidTimeframe) {
    return <Navigate to="/boards" replace />;
  }

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <button
          type="button"
          className={styles.backLink}
          onClick={() => navigate('/boards')}
        >
          ‹ Boards
        </button>
        <h1 className={styles.title}>{TIMEFRAME_TITLE[timeframe]} browser</h1>
        <p className={styles.subtitle}>
          Tap any window to view, create, or backfill a core board.
        </p>
      </header>

      <div className={styles.list} aria-label={`${TIMEFRAME_TITLE[timeframe]} core board windows`}>
        <div
          ref={earlierSentinelRef}
          className={styles.sentinel}
          aria-hidden="true"
        />
        {browser.cells.map((cell) => (
          <div
            key={cell.windowStart}
            ref={cell.isCurrentWindow ? currentRowRef : undefined}
          >
            <CoreBoardWindowCell
              cell={cell}
              timeframe={timeframe}
              onOpenBoard={handleOpenBoard}
              onCreate={handleCreate}
              onDeleteBoard={handleDeleteBoard}
              onResumeDraft={handleResumeDraft}
            />
          </div>
        ))}
        <div
          ref={laterSentinelRef}
          className={styles.sentinel}
          aria-hidden="true"
        />
      </div>
    </div>
  );
}
