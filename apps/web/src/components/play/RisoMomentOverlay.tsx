import { useMemo } from 'react';
import {
  STREAK_TIMEFRAMES,
  momentCellVisual,
  momentCounterAt,
  momentFinalBeat,
  streakUnitLabel,
  totalLineCount,
  type BoardMomentReplay,
  type BoardSize,
  type MomentKind,
  type Timeframe,
} from '@oybc/shared';
import { useModalA11y } from '../../hooks/useModalA11y';
import { RisoButton, RisoIcon } from '../riso';
import { RisoBoardCell, type BoardCellModel } from '../board/RisoBoardCell';
import { RisoBoardGrid } from '../board/RisoBoardGrid';
import { momentDisplayCell, momentPopPhase } from './boardMomentUi';
import { useMomentReplay } from './useMomentReplay';
import styles from './Moment.module.css';

/**
 * Deterministic confetti pieces scaled by intensity (mirrors the iOS formula:
 * count = 8 + clamp(intensity, 1, 10) x 8). Colours are tokens; each piece keeps
 * a fixed ink-static outline so it reads in both themes.
 */
function buildConfetti(intensity: number) {
  const count = 8 + Math.max(1, Math.min(10, intensity)) * 8;
  const colors = ['var(--riso-gold)', 'var(--riso-red)', 'var(--riso-blue)', 'var(--riso-on-color)'];
  return Array.from({ length: count }, (_, i) => ({
    left: (i * 2.8 + (i % 5) * 3) % 100,
    color: colors[i % 4],
    delay: (i % 9) * 0.18,
    dur: 2.4 + (i % 5) * 0.4,
    size: 8 + (i % 3) * 4,
    rot: i * 40,
  }));
}

const CONFETTI = buildConfetti(7);

export interface RisoMomentOverlayProps {
  kind: MomentKind;
  replay: BoardMomentReplay;
  /** End-state cell models, row-major (one per grid cell). */
  cells: BoardCellModel[];
  boardName: string;
  /** Lines complete on the board (the kicker's "n"). */
  linesCompleted: number;
  /** Timeframe greenlog streak (0 = unknown / none). */
  streak: number;
  timeframe: Timeframe;
  onShare: () => void;
  onBack: () => void;
  onNewBoard: () => void;
}

/**
 * The Bingo / Greenlog moment: a full-screen takeover that replays the board
 * from empty. Every cell's frame is derived from `(beat, replay)` so a re-render
 * never restarts a pop. Dismissed by Back to board / Escape (the field is opaque,
 * there is no tap-to-close).
 */
export function RisoMomentOverlay(p: RisoMomentOverlayProps): React.ReactElement {
  const { kind, replay, cells } = p;
  const isGreen = kind === 'greenlog';
  const finalBeat = momentFinalBeat(replay, kind);
  const { beat, animate } = useMomentReplay(kind, finalBeat);
  const { ref, props: modalProps } = useModalA11y<HTMLDivElement>({ open: true, onCancel: p.onBack, initialFocus: 'cancel' });
  const landing = useMemo(() => new Set(replay.order.map((e) => e.idx)), [replay]);
  const counter = momentCounterAt(beat, replay);
  const showStreak = isGreen && p.streak > 1 && (STREAK_TIMEFRAMES as readonly string[]).includes(p.timeframe);

  const grid = (
    <RisoBoardGrid size={replay.size} cellSize={90} gap={7} frame="moment">
      {cells.map((model, idx) => {
        const visual = momentCellVisual(idx, beat, replay, kind);
        return (
          <RisoBoardCell
            key={model.key}
            cell={momentDisplayCell(model, visual, landing.has(idx))}
            cellSize={90}
            pop={momentPopPhase(visual, animate)}
          />
        );
      })}
    </RisoBoardGrid>
  );

  return (
    <div
      ref={ref}
      className={`${styles.field} ${isGreen ? styles.green : styles.blue}`}
      role="dialog"
      aria-label={`${isGreen ? 'Board complete' : 'Bingo'}, ${p.boardName}`}
      data-moment={kind}
      {...modalProps}
    >
      {isGreen && (
        <div className={styles.confetti} aria-hidden="true">
          {CONFETTI.map((c, i) => (
            <i
              key={i}
              style={{
                left: `${c.left}%`,
                width: c.size,
                height: c.size * 1.4,
                background: c.color,
                transform: `rotate(${c.rot}deg)`,
                ['--dur' as string]: `${c.dur}s`,
                ['--delay' as string]: `${c.delay}s`,
              }}
            />
          ))}
        </div>
      )}
      <div className={styles.inner}>
        {isGreen ? (
          <>
            <div className={styles.topRow}>
              <div className={styles.kicker}>Board complete</div>
              <div className={styles.counterGl}>
                {counter}
                <small>/{replay.totalTasks} squares</small>
              </div>
            </div>
            <div className={styles.titleGl}>GREENLOG!</div>
          </>
        ) : (
          <>
            <div className={styles.kicker}>
              Line complete · {p.linesCompleted} of {totalLineCount(replay.size as BoardSize)}
            </div>
            <div className={styles.headRow}>
              <div className={styles.title}>BINGO!</div>
              <div className={styles.counter}>
                <div className={styles.counterV}>
                  {counter}
                  <small>/{replay.totalTasks}</small>
                </div>
                <div className={styles.counterK}>Squares</div>
              </div>
            </div>
          </>
        )}
        {grid}
        {showStreak && (
          <div className={styles.streakRow}>
            <div className={styles.streak}>
              <RisoIcon name="flame" size={18} aria-hidden="true" />
              <b>{p.streak}</b>
              <span>{streakUnitLabel(p.timeframe)} streak</span>
            </div>
          </div>
        )}
        <div className={styles.actions}>
          <RisoButton
            kind={isGreen ? 'primary' : 'gold'}
            size="large"
            fullWidth
            icon={<RisoIcon name="share" size={16} />}
            onClick={p.onShare}
          >
            {isGreen ? 'Share my board' : 'Share this bingo'}
          </RisoButton>
          {isGreen && (
            <RisoButton kind="neutral" size="large" fullWidth onClick={p.onNewBoard}>
              Start a new board
            </RisoButton>
          )}
          <RisoButton kind={isGreen ? 'ghost' : 'neutral'} size="large" fullWidth onClick={p.onBack} data-modal-cancel>
            Back to board
          </RisoButton>
        </div>
      </div>
    </div>
  );
}
