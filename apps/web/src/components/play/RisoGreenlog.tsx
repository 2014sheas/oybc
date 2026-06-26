import type { BoardSize } from '@oybc/shared';
import { getCenterSquareIndex } from '@oybc/shared';
import { RisoButton, RisoIcon } from '../riso';
import styles from './Play.module.css';

/** Deterministic confetti (no Math.random — varies by index). */
const CONFETTI = Array.from({ length: 36 }, (_, i) => {
  const colors = ['#FFC21F', '#EB4D2E', '#2C44C9', '#FBF6EA'];
  return {
    left: (i * 2.8 + (i % 5) * 3) % 100,
    color: colors[i % 4],
    delay: (i % 9) * 0.18,
    dur: 2.4 + (i % 5) * 0.4,
    size: 8 + (i % 3) * 4,
    rot: i * 40,
  };
});

export interface RisoGreenlogProps {
  boardName: string;
  boardSize: BoardSize;
  bingos: number;
  /** Timeframe greenlog streak (incl. this clear). */
  streak: number;
  onShare: () => void;
  onNewBoard: () => void;
  onClose: () => void;
}

/**
 * Greenlog overlay — the board-clear celebration. The page goes GREEN; the
 * poster's squares stay RED (the locked non-negotiable). Confetti + display
 * title + all-red poster + stats + Share / New board CTAs.
 */
export function RisoGreenlog({
  boardName,
  boardSize,
  bingos,
  streak,
  onShare,
  onNewBoard,
  onClose,
}: RisoGreenlogProps): React.ReactElement {
  const centerIndex = getCenterSquareIndex(boardSize);
  const total = boardSize * boardSize;

  return (
    <div className={styles.greenlog} role="dialog" aria-modal="true" aria-label="Board complete">
      <div className={styles.confetti} aria-hidden="true">
        {CONFETTI.map((c, i) => (
          <i
            key={i}
            style={{
              left: `${c.left}%`,
              width: c.size,
              height: c.size * 1.4,
              background: c.color,
              border: '1.5px solid #18120B',
              transform: `rotate(${c.rot}deg)`,
              ['--dur' as string]: `${c.dur}s`,
              ['--delay' as string]: `${c.delay}s`,
            }}
          />
        ))}
      </div>
      <div className={styles.glInner}>
        <div className={styles.glKicker}>Board complete</div>
        <div className={styles.glTitle}>GREENLOG!</div>
        <div className={styles.glPoster} style={{ gridTemplateColumns: `repeat(${boardSize}, 1fr)` }}>
          {Array.from({ length: total }).map((_, i) => (
            <i key={i} className={i === centerIndex ? styles.free : ''} />
          ))}
        </div>
        <div className={styles.glSub}>
          Every single square — slapped. <b>{boardName}</b> crushed. The page goes green; your squares
          stay loud and red.
        </div>
        <div className={styles.glStats}>
          <div className={styles.glStat}>
            <b>
              {total}/{total}
            </b>
            <span>Squares</span>
          </div>
          <div className={styles.glStat}>
            <b>{bingos}</b>
            <span>Bingos</span>
          </div>
          <div className={styles.glStat}>
            <b>{streak}</b>
            <span>Streak</span>
          </div>
        </div>
        <div className={styles.glBtns}>
          <RisoButton kind="primary" size="large" icon={<RisoIcon name="share" size={16} />} onClick={onShare}>
            Share my board
          </RisoButton>
          <RisoButton kind="neutral" size="large" onClick={onNewBoard}>
            Start a new board
          </RisoButton>
        </div>
      </div>
      {/* Allow dismissing to see the cleared board behind. */}
      <button
        type="button"
        onClick={onClose}
        aria-label="Close"
        style={{ position: 'absolute', inset: 0, zIndex: 0, background: 'none', border: 0, cursor: 'default' }}
      />
    </div>
  );
}
