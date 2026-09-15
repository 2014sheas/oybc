import { useEffect, useMemo, useRef, useState } from 'react';
import { Timeframe, type Board, type WeekStartDay } from '@oybc/shared';
import { RisoChip } from '../../components/riso';
import {
  buildPickerPage,
  pickerCopy,
  pickerPageStart,
  pickerTodayLabel,
  stepPickerPage,
  type CoreWindowTile,
  type CoreWindowTileState,
} from './corePickerTiles';
import styles from './CoreWindow.module.css';

export interface CoreWindowPickerPopoverProps {
  timeframe: Timeframe;
  weekStartDay: WeekStartDay;
  /** Core boards for this timeframe keyed by startDate. */
  boardsByStart: ReadonlyMap<string, Board>;
  /** The pager's displayed window start — seeds the initial page. */
  displayedWindowStart: string;
  /** Reference instant for current/past flags. */
  now: Date;
  /** Tile tap — the pager lands on this window (no board row created). */
  onSelect: (windowStart: string) => void;
  onClose: () => void;
}

/** State word shown on a tile ("closed" / "done" / "set up" / …). */
function tileStateText(state: CoreWindowTileState, tile: CoreWindowTile): string {
  switch (state) {
    case 'closed': return 'closed';
    case 'done': return 'done';
    case 'pastEmpty': return 'no board';
    case 'current':
      return tile.progress ? `${tile.progress.done} of ${tile.progress.total}` : 'set up';
    case 'nextEmpty': return 'set up';
    case 'futureEmpty': return '';
    case 'inProgress':
      return tile.progress ? `${tile.progress.done} of ${tile.progress.total}` : 'open';
    case 'draft': return 'draft';
  }
}

const TILE_STATE_CLASS: Record<CoreWindowTileState, string> = {
  closed: styles.tileClosed,
  done: styles.tileDone,
  pastEmpty: styles.tilePastEmpty,
  current: styles.tileCurrent,
  nextEmpty: styles.tileNextEmpty,
  futureEmpty: styles.tileFutureEmpty,
  inProgress: styles.tileInProgress,
  draft: styles.tileDraft,
};

const DAY_HEADS_MONDAY = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
const DAY_HEADS_SUNDAY = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

/**
 * CoreWindowPickerPopover — the 320px window-jump popover anchored under
 * the window chip. Per-timeframe layouts: DAILY = 7-column month
 * calendar with a month stepper; WEEKLY = quarter rows; MONTHLY =
 * 4-column year grid; YEARLY = 4-column decade grid. Tapping a tile
 * dismisses and lands the pager on that window — empty windows show the
 * setup prompt; **no board row is created**. Closes on outside click or
 * Esc. Mirrors the iOS `CoreWindowPickerSheet` (half-sheet).
 */
export function CoreWindowPickerPopover({
  timeframe,
  weekStartDay,
  boardsByStart,
  displayedWindowStart,
  now,
  onSelect,
  onClose,
}: CoreWindowPickerPopoverProps): React.ReactElement {
  const rootRef = useRef<HTMLDivElement | null>(null);
  const [pageDate, setPageDate] = useState<Date>(() =>
    pickerPageStart(timeframe, new Date(displayedWindowStart)),
  );

  const page = useMemo(
    () => buildPickerPage(timeframe, pageDate, boardsByStart, now, weekStartDay),
    [timeframe, pageDate, boardsByStart, now, weekStartDay],
  );
  const copy = pickerCopy(timeframe);

  // Close on outside click / Esc.
  useEffect(() => {
    const onPointerDown = (e: PointerEvent): void => {
      const root = rootRef.current;
      if (root && e.target instanceof Node && !root.contains(e.target)) onClose();
    };
    const onKeyDown = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') onClose();
    };
    // Capture phase so a click on the chip (which toggles) doesn't
    // immediately re-open after the outside-close fires.
    document.addEventListener('pointerdown', onPointerDown, true);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown, true);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [onClose]);

  const gridClass =
    timeframe === Timeframe.DAILY
      ? styles.tileGridDaily
      : timeframe === Timeframe.WEEKLY
        ? styles.tileGridWeekly
        : timeframe === Timeframe.YEARLY
          ? styles.tileGridYearly
          : styles.tileGridMonthly;

  const dayHeads = weekStartDay === 'sunday' ? DAY_HEADS_SUNDAY : DAY_HEADS_MONDAY;

  return (
    <div ref={rootRef} className={styles.popover} role="dialog" aria-label={copy.title}>
      <div className={styles.popoverHead}>
        <div>
          <div className={styles.popoverKicker}>{copy.kicker}</div>
          <div className={styles.popoverTitle}>{copy.title}</div>
        </div>
        <RisoChip on>{page.title}</RisoChip>
      </div>

      <div className={`${styles.tileGrid} ${gridClass}`}>
        {timeframe === Timeframe.DAILY &&
          dayHeads.map((d, i) => (
            <span key={`head-${i}`} className={styles.dayHead} aria-hidden="true">
              {d}
            </span>
          ))}
        {timeframe === Timeframe.DAILY &&
          Array.from({ length: page.leadingBlanks }, (_, i) => (
            <span key={`blank-${i}`} className={`${styles.tile} ${styles.tileBlank}`} aria-hidden="true" />
          ))}
        {page.tiles.map((tile) => {
          const stateText = tileStateText(tile.state, tile);
          return (
            <button
              key={tile.windowStart}
              type="button"
              className={`${styles.tile} ${TILE_STATE_CLASS[tile.state]}`}
              onClick={() => onSelect(tile.windowStart)}
              aria-current={tile.isCurrent ? 'date' : undefined}
            >
              <span className={styles.tileLabel}>{tile.label}</span>
              {tile.state !== 'futureEmpty' && timeframe !== Timeframe.DAILY && (
                <span className={styles.tileState}>
                  <i className={styles.tileDot} aria-hidden="true" />
                  {stateText}
                </span>
              )}
              {timeframe === Timeframe.DAILY && tile.state !== 'futureEmpty' && (
                <span className={styles.tileState}>
                  <i className={styles.tileDot} aria-hidden="true" />
                </span>
              )}
            </button>
          );
        })}
      </div>

      <div className={styles.popoverFooter}>
        <button
          type="button"
          className={styles.popoverFooterBtn}
          onClick={() => setPageDate((d) => stepPickerPage(timeframe, d, -1))}
        >
          ‹ {page.prevTitle}
        </button>
        <button
          type="button"
          className={`${styles.popoverFooterBtn} ${styles.popoverFooterToday}`}
          onClick={() => setPageDate(pickerPageStart(timeframe, now))}
        >
          {pickerTodayLabel(timeframe, now)}
        </button>
        <button
          type="button"
          className={styles.popoverFooterBtn}
          onClick={() => setPageDate((d) => stepPickerPage(timeframe, d, 1))}
        >
          {page.nextTitle} ›
        </button>
      </div>
    </div>
  );
}
