import type { BoardSize } from '@oybc/shared';
import { getCenterSquareIndex } from '@oybc/shared';
import { RisoButton, RisoIcon } from '../riso';
import styles from './Play.module.css';

/**
 * Builds a deterministic confetti piece array scaled by celebration intensity.
 *
 * Mirrors the iOS RisoGreenlogOverlay formula exactly:
 *   count = 8 + clamp(intensity, 1, 10) × 8
 *
 * intensity 1  →  16 pieces ("Whisper")
 * intensity 7  →  64 pieces ("Full press", the original burst)
 * intensity 10 →  88 pieces ("Detonate")
 */
function buildConfetti(intensity: number) {
  const clamped = Math.max(1, Math.min(10, intensity));
  const count = 8 + clamped * 8;
  // Riso palette via tokens so the confetti tracks the design system. Gold +
  // on-color are theme-stable; red/blue shift value in dark mode but each piece
  // keeps a fixed ink-static outline, so visibility holds in both themes.
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

export interface RisoGreenlogProps {
  boardName: string;
  boardSize: BoardSize;
  bingos: number;
  /** Timeframe greenlog streak (incl. this clear). */
  streak: number;
  /**
   * Celebration intensity (1–10, default 7). Scales confetti count:
   * count = 8 + intensity × 8 → 16…88 pieces. Mirrors the iOS
   * RisoGreenlogOverlay formula exactly. prefers-reduced-motion: confetti
   * is hidden via CSS regardless of count.
   *
   * No caller currently passes this — it was previously wired to the
   * (now-removed) `UserPreferences.celebrationIntensity` field, which was
   * never meant to be user-configurable. Kept as an optional prop with its
   * default intact rather than hardcoding 7 inline, in case a future
   * caller wants to vary it (e.g. a bigger celebration for a bigger
   * board), but nothing currently supplies a non-default value.
   */
  celebrationIntensity?: number;
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
  celebrationIntensity = 7,
  onShare,
  onNewBoard,
  onClose,
}: RisoGreenlogProps): React.ReactElement {
  const centerIndex = getCenterSquareIndex(boardSize);
  const total = boardSize * boardSize;
  const confetti = buildConfetti(celebrationIntensity);

  return (
    <div className={styles.greenlog} role="dialog" aria-modal="true" aria-label="Board complete">
      <div className={styles.confetti} aria-hidden="true">
        {confetti.map((c, i) => (
          <i
            key={i}
            style={{
              left: `${c.left}%`,
              width: c.size,
              height: c.size * 1.4,
              background: c.color,
              border: '1.5px solid var(--riso-ink-static)',
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
