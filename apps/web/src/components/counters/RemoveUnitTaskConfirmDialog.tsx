import { useModalA11y } from '../../hooks/useModalA11y';
import { removeConfirmBody, removeConfirmTitle } from './countsTowardLabels';
import styles from './CounterDeleteConfirmDialog.module.css';

export interface RemoveUnitTaskConfirmDialogProps {
  /** The counter's display name. */
  counterName: string;
  /** The unit task's title. */
  taskTitle: string;
  /** The lineage's live credits on the counter (≥ 1 — the dialog only opens then). */
  credits: number;
  /** True while the remove write is in flight. */
  busy: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

/**
 * Confirm for removing a unit task that has credits: the task stays in the
 * library, its credits on the counter are withdrawn. Shares
 * `CounterDeleteConfirmDialog`'s shell styling. iOS twin: the system alert
 * in `CountsTowardSectionView`.
 */
export function RemoveUnitTaskConfirmDialog({ counterName, taskTitle, credits, busy, onConfirm, onCancel }: RemoveUnitTaskConfirmDialogProps): React.ReactElement {
  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({
    open: true,
    onCancel: () => {
      if (!busy) onCancel();
    },
    initialFocus: 'cancel',
  });
  return (
    <div className={styles.backdrop} onClick={() => !busy && onCancel()}>
      <div ref={modalRef} className={styles.sheet} role="alertdialog" aria-label={removeConfirmTitle(counterName)} {...modalProps} onClick={(e) => e.stopPropagation()}>
        <h2 className={styles.sheetHeading}>{removeConfirmTitle(counterName)}</h2>
        <p className={styles.confirmBody}>{removeConfirmBody(taskTitle, credits, counterName)}</p>
        <div className={styles.sheetActions}>
          <button type="button" className={styles.cancelButton} data-modal-cancel disabled={busy} onClick={onCancel}>
            Cancel
          </button>
          <button type="button" className={styles.deleteButton} disabled={busy} onClick={onConfirm}>
            Remove
          </button>
        </div>
      </div>
    </div>
  );
}
