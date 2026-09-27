import { BoardStatus } from '@oybc/shared';
import { BoardStatusBadge } from '../BoardStatusBadge';
import styles from '../../pages/BoardPlayPage.module.css';

export interface BoardStatusPillProps {
  status: BoardStatus | string;
  isSealed: boolean;
  isEnded: boolean;
}

/**
 * BoardStatusPill — Board Edit redesign slice 4 (D14): the title-row status
 * pill. CLOSED (sealed) → the existing neutral "Closed" pill; ENDED (window
 * over, not yet closed) → the new gold "Ended" pill; otherwise the ordinary
 * `BoardStatusBadge`. Extracted so `BoardPlaySurface` doesn't grow past its
 * frozen file-size cap (D17).
 */
export function BoardStatusPill({ status, isSealed, isEnded }: BoardStatusPillProps): React.ReactElement {
  if (isSealed) {
    // User-facing label is "Closed" — "sealed" is internal Windowed-
    // Completion vocabulary, never UI copy.
    return <span className={styles.sealedBadge}>Closed</span>;
  }
  if (isEnded) {
    return <span className={styles.endedBadge}>Ended</span>;
  }
  return <BoardStatusBadge status={status} />;
}
