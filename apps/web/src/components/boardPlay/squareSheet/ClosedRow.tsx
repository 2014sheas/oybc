import { RisoButton, RisoIcon } from '../../riso';
import styles from './SquareSheet.module.css';

export interface ClosedRowProps {
  /** "Closed Oct 11". */
  label: string;
  /** Absent when the square has nothing to late-log (achievement, hub-linked counter). */
  onLateLog?: () => void;
}

/**
 * The closed-board row that replaces chips / checkboxes / Remove: lock icon ·
 * "Closed ‹date›" · a small neutral `Late log…` button.
 *
 * @returns The row.
 */
export function ClosedRow({ label, onLateLog }: ClosedRowProps): React.ReactElement {
  return (
    <div className={styles.closedRow}>
      <span className={styles.closedLock}>
        <RisoIcon name="lock" size={14} aria-hidden="true" />
      </span>
      <span className={styles.closedText}>{label}</span>
      {onLateLog && (
        <RisoButton size="small" onClick={onLateLog}>
          Late log…
        </RisoButton>
      )}
    </div>
  );
}
