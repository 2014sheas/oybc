import { BoardStatus } from '@oybc/shared';
import { statusLabel } from '../utils/boardDisplayUtils';
import styles from './BoardStatusBadge.module.css';

interface BoardStatusBadgeProps {
  status: BoardStatus | string;
}

/**
 * BoardStatusBadge — Small colored pill showing board status.
 *
 * DRAFT (gray dashed border), ACTIVE (blue filled), COMPLETED (green filled),
 * ARCHIVED (gray filled).
 */
export function BoardStatusBadge({ status }: BoardStatusBadgeProps): React.ReactElement {
  let variant = styles.badgeDraft;
  if (status === BoardStatus.ACTIVE) variant = styles.badgeActive;
  if (status === BoardStatus.COMPLETED) variant = styles.badgeCompleted;
  if (status === BoardStatus.ARCHIVED) variant = styles.badgeArchived;

  return (
    <span className={`${styles.badge} ${variant}`}>
      {statusLabel(status)}
    </span>
  );
}
