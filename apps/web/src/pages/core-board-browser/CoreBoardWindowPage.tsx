import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Navigate, useNavigate, useParams } from 'react-router-dom';
import {
  AchievementTrigger,
  BoardStatus,
  Timeframe,
  computeStreak,
  getTimeframeBoundaries,
  stepWindow,
  formatTimeframeLabel,
  isTimeframeExpired,
  type WeekStartDay,
} from '@oybc/shared';
import { useAuth } from '../../firebase/useAuth';
import { useBoards } from '../../hooks/useBoards';
import { usePreferences } from '../../hooks';
import { BoardPlaySurface } from '../../components/BoardPlaySurface';
import { DraftResumePrompt } from '../../components/boards/DraftResumePrompt';
import { RisoBadge, RisoIcon } from '../../components/riso';
import { useCoreBoardForWindow } from './useCoreBoardForWindow';
import { useCoreBoardsByStart } from './useCoreBoardsByStart';
import { CoreBoardSetupPrompt } from './CoreBoardSetupPrompt';
import { CoreWindowChip } from './CoreWindowChip';
import { CoreWindowPositionCaption } from './CoreWindowPositionCaption';
import { CoreWindowPickerPopover } from './CoreWindowPickerPopover';
import {
  buildWindowNeighborhood,
  captionSideLabel,
  chipLabelSuffix,
} from './corePickerTiles';
import { compactStreakLabel } from '@oybc/shared';
import play from '../../components/play/Play.module.css';
import styles from './CoreWindow.module.css';

const VALID: ReadonlySet<string> = new Set([
  Timeframe.DAILY, Timeframe.WEEKLY, Timeframe.MONTHLY, Timeframe.YEARLY,
]);

/** Human timeframe word for the streak chip's VoiceOver annotation. */
const STREAK_A11Y_WORDS: Partial<Record<Timeframe, string>> = {
  [Timeframe.DAILY]: 'daily',
  [Timeframe.WEEKLY]: 'weekly',
  [Timeframe.MONTHLY]: 'monthly',
  [Timeframe.YEARLY]: 'yearly',
};

/**
 * CoreBoardBrowserRedirect — the retired `/boards/core/:timeframe`
 * browser route now redirects to today's window in the pager (the
 * picker sheet replaced the vertical browser list).
 */
export function CoreBoardBrowserRedirect(): React.ReactElement {
  const { timeframe: rawTf } = useParams<{ timeframe: string }>();
  const [preferences] = usePreferences();
  if (!rawTf || !VALID.has(rawTf)) return <Navigate to="/boards" replace />;
  const { startDate } = getTimeframeBoundaries(
    rawTf as Timeframe,
    new Date(),
    preferences.weekStartDay,
  );
  return <Navigate to={`/boards/core/${rawTf}/${startDate.slice(0, 10)}`} replace />;
}

/**
 * CoreBoardWindowPage — per-window core-board pager (masthead rework).
 * Route: `/boards/core/:timeframe/:date`. Seeds the current window from
 * `:date` (any date inside the window normalizes to its start).
 *
 * Chrome: a fixed header row (back + **window chip**), everything below
 * as one window card. Stepping: ←/→ keys, horizontal trackpad wheel,
 * and the position caption's side taps — each navigates (replace) to
 * the adjacent window with a card-slide. The chip opens the window
 * picker popover; tapping a tile lands on that window (setup prompt if
 * empty — **no board row is ever created from navigation**).
 */
export function CoreBoardWindowPage(): React.ReactElement {
  const navigate = useNavigate();
  const { timeframe: rawTf, date: rawDate } = useParams<{ timeframe: string; date: string }>();
  const { user } = useAuth();
  const [preferences] = usePreferences();
  const allBoards = useBoards(user?.id);

  const routeDateOnly = rawDate?.slice(0, 10);
  const isValidDate =
    !!routeDateOnly &&
    /^\d{4}-\d{2}-\d{2}$/.test(routeDateOnly) &&
    !Number.isNaN(new Date(`${routeDateOnly}T12:00:00`).getTime());

  const isValid = !!rawTf && VALID.has(rawTf) && isValidDate;
  const timeframe = (isValid ? rawTf : Timeframe.DAILY) as Timeframe;
  const weekStartDay: WeekStartDay = preferences.weekStartDay;

  const now = useMemo(() => new Date(), []);

  const { startDate: windowStart, endDate: windowEnd } = useMemo(() => {
    // Parse as local noon, not UTC midnight — a date-only ISO string
    // parses as UTC midnight, which shifts the day west of UTC.
    const seed = routeDateOnly ? new Date(`${routeDateOnly}T12:00:00`) : now;
    return getTimeframeBoundaries(timeframe, seed, weekStartDay);
  }, [routeDateOnly, timeframe, weekStartDay, now]);

  const board = useCoreBoardForWindow(user?.id, timeframe, windowStart);
  const boardsByStart = useCoreBoardsByStart(user?.id, timeframe);

  // UI state: picker popover, edit-mode lock, slide direction.
  const [pickerOpen, setPickerOpen] = useState(false);
  const [childEditing, setChildEditing] = useState(false);
  const [slideDir, setSlideDir] = useState<0 | -1 | 1>(0);

  const todayWindowStart = useMemo(
    () => getTimeframeBoundaries(timeframe, now, weekStartDay).startDate,
    [timeframe, now, weekStartDay],
  );

  const neighborhood = useMemo(
    () => buildWindowNeighborhood(timeframe, windowStart, todayWindowStart, boardsByStart, weekStartDay),
    [timeframe, windowStart, todayWindowStart, boardsByStart, weekStartDay],
  );

  const isCurrentWindow = windowStart === todayWindowStart;
  const isPast = isTimeframeExpired(windowEnd, now);

  // Greenlog streak for this timeframe (empty/draft title rows — the
  // filled state's chip is rendered by BoardPlaySurface itself).
  const streakCount = useMemo(
    () => computeStreak(timeframe, AchievementTrigger.GREENLOG, allBoards, weekStartDay, now),
    [timeframe, allBoards, weekStartDay, now],
  );

  const goTo = useCallback(
    (startDate: string, dir: 0 | -1 | 1) => {
      setSlideDir(dir);
      setPickerOpen(false);
      navigate(`/boards/core/${timeframe}/${startDate.slice(0, 10)}`, { replace: true });
    },
    [navigate, timeframe],
  );

  const go = useCallback(
    (offset: -1 | 1) => {
      if (childEditing) return;
      const { startDate } = stepWindow(timeframe, windowStart, offset, weekStartDay);
      goTo(startDate, offset);
    },
    [childEditing, timeframe, windowStart, weekStartDay, goTo],
  );

  // ←/→ keys + horizontal trackpad wheel step the window (spec 3b).
  // Disabled while editing or while the picker is open; ignores keys
  // typed into form fields.
  const wheelAccum = useRef(0);
  const wheelLock = useRef(false);
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent): void => {
      if (childEditing || pickerOpen) return;
      const target = e.target as HTMLElement | null;
      if (target && /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName)) return;
      if (e.key === 'ArrowLeft') go(-1);
      else if (e.key === 'ArrowRight') go(1);
    };
    const onWheel = (e: WheelEvent): void => {
      if (childEditing || pickerOpen) return;
      if (Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return;
      if (wheelLock.current) return;
      wheelAccum.current += e.deltaX;
      if (Math.abs(wheelAccum.current) < 90) return;
      const dir: -1 | 1 = wheelAccum.current > 0 ? 1 : -1;
      wheelAccum.current = 0;
      wheelLock.current = true;
      setTimeout(() => { wheelLock.current = false; }, 500);
      go(dir);
    };
    window.addEventListener('keydown', onKeyDown);
    window.addEventListener('wheel', onWheel, { passive: true });
    return () => {
      window.removeEventListener('keydown', onKeyDown);
      window.removeEventListener('wheel', onWheel);
    };
  }, [go, childEditing, pickerOpen]);

  if (!isValid) return <Navigate to="/boards" replace />;

  const label = formatTimeframeLabel(timeframe, windowStart);
  // No suffix while the board query is still resolving (avoids a
  // "· next" flicker before the row loads).
  const chipLabel =
    board === undefined
      ? label
      : `${label}${chipLabelSuffix(board, isCurrentWindow, isPast)}`;
  const chipA11y = `${label}${isCurrentWindow ? ', current window' : ''}. Opens window picker.`;

  const prevStart = stepWindow(timeframe, windowStart, -1, weekStartDay).startDate;
  const nextStart = stepWindow(timeframe, windowStart, 1, weekStartDay).startDate;

  const picker = pickerOpen ? (
    <CoreWindowPickerPopover
      timeframe={timeframe}
      weekStartDay={weekStartDay}
      boardsByStart={boardsByStart}
      displayedWindowStart={windowStart}
      now={now}
      onSelect={(start) => goTo(start, start > windowStart ? 1 : -1)}
      onClose={() => setPickerOpen(false)}
    />
  ) : null;

  const chip = (
    <span className={styles.chipAnchor}>
      <CoreWindowChip
        label={chipLabel}
        dots={neighborhood}
        open={pickerOpen}
        empty={board === null}
        disabled={childEditing}
        ariaLabel={chipA11y}
        onClick={() => setPickerOpen((o) => !o)}
      />
      {picker}
    </span>
  );

  const backButton = (
    <button type="button" className={play.back} onClick={() => navigate('/boards')}>
      <RisoIcon name="back" size={15} />
      Boards
    </button>
  );

  const caption = (
    <CoreWindowPositionCaption
      prevLabel={captionSideLabel(timeframe, prevStart)}
      nextLabel={captionSideLabel(timeframe, nextStart)}
      dots={neighborhood}
      disabled={childEditing}
      onPrev={() => go(-1)}
      onNext={() => go(1)}
    />
  );

  const streakChip =
    streakCount > 0 ? (
      <span
        className={styles.streakChip}
        aria-label={`${streakCount} ${STREAK_A11Y_WORDS[timeframe] ?? ''} greenlog streak`}
      >
        <RisoIcon name="flame" size={10} aria-hidden="true" />
        {compactStreakLabel(streakCount, timeframe)} streak
      </span>
    ) : null;

  const slideClass = slideDir === 1 ? styles.slideFromRight : slideDir === -1 ? styles.slideFromLeft : '';

  if (board === undefined) {
    return (
      <div className={styles.page}>
        <div className={styles.headerRow}>{backButton}{chip}</div>
        <p className={styles.emptyState}>Loading…</p>
      </div>
    );
  }

  if (board === null) {
    // Empty window: muted title block + dashed frame around the lazy
    // setup prompt. No board row exists (and none is created here).
    return (
      <div className={styles.page}>
        <div className={styles.headerRow}>{backButton}{chip}</div>
        <div key={windowStart} className={slideClass}>
          <div className={styles.titleBlock}>
            <div className={styles.titleKicker}>{timeframe.toUpperCase()} BOARD</div>
            <div className={styles.titleRow}>
              <span className={styles.mutedTitle}>{label}</span>
              {streakChip}
            </div>
          </div>
          <div className={styles.dashedFrame} style={{ marginTop: 14 }}>
            <CoreBoardSetupPrompt
              timeframe={timeframe}
              windowStart={windowStart}
              isPast={isPast}
              onSetUp={() => {
                navigate(`/create?recurringTimeframe=${timeframe}&windowDate=${windowStart.slice(0, 10)}`);
              }}
            />
            {!isCurrentWindow && (
              <span className={styles.frameHint}>
                Swipe back to {captionSideLabel(timeframe, todayWindowStart)} to keep playing
              </span>
            )}
          </div>
          {caption}
        </div>
      </div>
    );
  }

  if (board.status === BoardStatus.DRAFT) {
    // Draft window: DRAFT badge beside the name, dashed frame around the
    // existing resume prompt. Never renders a grid (drafts aren't playable).
    return (
      <div className={styles.page}>
        <div className={styles.headerRow}>{backButton}{chip}</div>
        <div key={windowStart} className={slideClass}>
          <div className={styles.titleBlock}>
            <div className={styles.titleKicker}>{timeframe.toUpperCase()} BOARD</div>
            <div className={styles.titleRow}>
              <span className={`${styles.mutedTitle} ${styles.draftTitle}`}>{board.name}</span>
              <RisoBadge kind="draft">Draft</RisoBadge>
              {streakChip}
            </div>
          </div>
          <div className={styles.dashedFrame} style={{ marginTop: 14 }}>
            <DraftResumePrompt boardId={board.id} boardName={board.name} />
          </div>
          {caption}
        </div>
      </div>
    );
  }

  // Board-integrity PR-5 (Item 6): key by board.id — the pager keeps
  // this component mounted while the date route param swaps, so the
  // surface's local state must not carry across boards. The outer div
  // keys by windowStart to drive the card-slide animation.
  return (
    <div key={windowStart} className={slideClass}>
      <BoardPlaySurface
        key={board.id}
        board={board}
        userId={user?.id}
        header={backButton}
        kickerAccessory={chip}
        boardFooter={caption}
        onEditModeChange={setChildEditing}
      />
    </div>
  );
}
