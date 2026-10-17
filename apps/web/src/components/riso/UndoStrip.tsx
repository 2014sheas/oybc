import { RisoIcon } from './RisoIcon';
import { RisoUndoPill } from './RisoUndoPill';
import styles from './UndoStrip.module.css';

export interface UndoStripProps {
  /** One line: "Logged +5 pages · Week 42". */
  text: string;
  onUndo: () => void;
  disabled?: boolean;
  /** 12px text, 1.5px keyline — the compound child's unfold. */
  compact?: boolean;
}

/**
 * UndoStrip — the inline confirmation that replaces pick-then-press: a paper-2
 * card with a green check, one text line and an Undo pill. iOS twin:
 * `UndoStrip`.
 *
 * @returns The strip.
 */
export function UndoStrip({ text, onUndo, disabled, compact }: UndoStripProps): React.ReactElement {
  return (
    <div className={`${styles.strip} ${compact ? styles.compact : ''}`} role="status" aria-live="polite">
      <span className={styles.check} aria-hidden="true">
        <RisoIcon name="check" size={14} />
      </span>
      <span className={styles.text}>{text}</span>
      <RisoUndoPill onClick={onUndo} disabled={disabled} />
    </div>
  );
}
