import { RisoIcon } from './RisoIcon';
import { RisoTypeBadge, type RisoTaskType } from './RisoTypeBadge';
import styles from './RisoReturnPill.module.css';

export interface RisoReturnPillProps {
  /** The task the sheet swapped away from. */
  title: string;
  type: RisoTaskType;
  onClick: () => void;
}

/**
 * RisoReturnPill — takes the back-chevron slot after an in-sheet task swap:
 * paper-2, 2px keyline, 2px hard shadow · ‹ · type letter · the previous
 * task's name (max 200px, ellipsis). iOS twin: `RisoReturnPill`.
 *
 * @returns The pill button.
 */
export function RisoReturnPill({ title, type, onClick }: RisoReturnPillProps): React.ReactElement {
  return (
    <button type="button" className={styles.pill} aria-label={`Back to ${title}`} onClick={onClick}>
      <span className={styles.chev}>
        <RisoIcon name="back" size={12} />
      </span>
      <RisoTypeBadge type={type} size="small" />
      <span className={styles.name}>{title}</span>
    </button>
  );
}
