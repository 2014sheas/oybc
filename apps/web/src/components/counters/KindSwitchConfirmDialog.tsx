import { useModalA11y } from '../../hooks/useModalA11y';
import type { KindSwitchPreview } from '../../db/operations/countKindSwitch';
import { RisoButton } from '../riso';
import { kindSwitchConfirmLines } from './kindSwitchModel';
import styles from './KindSwitchConfirmDialog.module.css';

export interface KindSwitchConfirmDialogProps {
  /** What the switch changes (title, logged total, linked squares). */
  preview: KindSwitchPreview;
  /** Cancel / dismiss — the kind stays as it was. */
  onCancel: () => void;
  /** Confirm the switch. */
  onConfirm: () => void;
}

/**
 * KindSwitchConfirmDialog — the Continuous → Discrete confirm
 * (docs/COUNTER_KINDS.md §5; handoff "Switch confirm"). Chrome follows
 * `CounterDeleteConfirmDialog` (backdrop + sheet + `role="alertdialog"`,
 * focus lands on Cancel). Swift twin: `KindSwitchConfirmView`.
 */
export function KindSwitchConfirmDialog({
  preview,
  onCancel,
  onConfirm,
}: KindSwitchConfirmDialogProps): React.ReactElement {
  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({ open: true, onCancel, initialFocus: 'cancel' });
  const lines = kindSwitchConfirmLines(preview);
  return (
    <div className={styles.backdrop} onClick={onCancel}>
      <div
        ref={modalRef}
        className={styles.sheet}
        role="alertdialog"
        aria-label={lines.title}
        {...modalProps}
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className={styles.heading}>{lines.title}</h2>
        <div className={styles.rows}>
          {lines.rows.map(([before, after], i) => (
            <div key={i} className={styles.row}>
              <span className={styles.before}>{before}</span>
              <span className={styles.arrow} aria-hidden="true">
                →
              </span>
              <span>{after}</span>
            </div>
          ))}
        </div>
        <p className={styles.body}>{lines.body}</p>
        <div className={styles.actions}>
          <RisoButton kind="ghost" data-modal-cancel onClick={onCancel}>
            Cancel
          </RisoButton>
          <RisoButton kind="blue" onClick={onConfirm}>
            Switch
          </RisoButton>
        </div>
      </div>
    </div>
  );
}
