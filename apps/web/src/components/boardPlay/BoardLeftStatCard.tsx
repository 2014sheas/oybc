import { getExpiryLabel } from '../../utils/boardDisplayUtils';
import play from '../play/Play.module.css';

export interface BoardLeftStatCardProps {
  isSealed: boolean;
  isEnded: boolean;
  timeframe: string;
  endDate?: string | null;
  /** Pinned render instant for `getExpiryLabel` (shape C — never a fresh clock read). */
  nowPinned: Date;
}

/** "Sep 30" — no year, matching the sealed/ended card's existing format. */
function formatCardDate(iso?: string | null): string {
  if (!iso) return '—';
  return new Date(iso).toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

/**
 * BoardLeftStatCard — Board Edit redesign slice 4 (D14): the play rail's
 * 3rd stat card. CLOSED → "Ended / {date} / permanent record" (existing);
 * ENDED (not yet closed) → "Left / Ended / {date} · still logging"
 * (verbatim handoff copy); otherwise the ordinary expiry countdown. Extracted
 * so `BoardPlaySurface` doesn't grow past its frozen file-size cap (D17).
 */
export function BoardLeftStatCard({
  isSealed,
  isEnded,
  timeframe,
  endDate,
  nowPinned,
}: BoardLeftStatCardProps): React.ReactElement {
  if (isSealed) {
    return (
      <div className={play.stat}>
        <div className={play.statK}>Ended</div>
        <div className={play.statV} style={{ fontSize: '18px' }}>
          {formatCardDate(endDate)}
        </div>
        <div className={play.statSub}>permanent record</div>
      </div>
    );
  }
  if (isEnded) {
    return (
      <div className={play.stat}>
        <div className={play.statK}>Left</div>
        <div className={play.statV} style={{ fontSize: '18px' }}>
          Ended
        </div>
        <div className={play.statSub}>
          {formatCardDate(endDate)} · still logging
        </div>
      </div>
    );
  }
  return (
    <div className={play.stat}>
      <div className={play.statK}>Left</div>
      <div className={play.statV} style={{ fontSize: '18px' }}>
        {getExpiryLabel({ timeframe, endDate: endDate ?? undefined }, nowPinned) || '—'}
      </div>
    </div>
  );
}
