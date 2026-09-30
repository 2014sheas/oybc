import { useModalA11y } from '../../hooks/useModalA11y';
// Same Riso confirm shape as `RemoveSourceConfirmDialog` (backdrop scrim →
// bordered sheet → heading → body → Cancel + red destructive action), and
// deliberately the same CSS module rather than a third copy of those rules.
import styles from '../counters/CounterDeleteConfirmDialog.module.css';

export interface DeleteRepeatingBoardConfirmDialogProps {
  /** The repeating board's stored name (the template's, not the session's
   *  possibly-edited draft name). */
  boardName: string;
  /** True while the soft-delete is in flight — disables both actions so a
   *  second click can't fire a duplicate delete. */
  busy: boolean;
  /** Confirm — the wizard runs `deleteEditedRecurringTemplate` then closes. */
  onConfirm: () => void;
  /** Cancel / dismiss (backdrop click, Escape, the Cancel button). */
  onCancel: () => void;
}

/**
 * DeleteRepeatingBoardConfirmDialog — "are you sure?" before the wizard's
 * edit mode deletes the repeating board it is editing (Profile reorg PR3:
 * Delete left the Board-settings roster row and now lives in the editor).
 *
 * Copy is the roster row's old confirm, minus the "template"/"spawned"
 * vocabulary that copy rule forbids in UI (Board Creation Split). iOS twin:
 * the `.alert` in `BoardWizardView.swift` — same title, body and buttons.
 *
 * Focus lands on Cancel when it opens, Escape cancels and Tab stays inside
 * (`useModalA11y`), so the safe choice is always one keystroke away.
 *
 * @param props - See {@link DeleteRepeatingBoardConfirmDialogProps}.
 * @returns The modal confirm.
 */
export function DeleteRepeatingBoardConfirmDialog({
  boardName,
  busy,
  onConfirm,
  onCancel,
}: DeleteRepeatingBoardConfirmDialogProps): React.ReactElement {
  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({
    open: true,
    onCancel: () => {
      if (!busy) onCancel();
    },
    initialFocus: 'cancel',
  });

  return (
    <div className={styles.backdrop} onClick={() => !busy && onCancel()}>
      <div
        ref={modalRef}
        className={styles.sheet}
        role="alertdialog"
        {...modalProps}
        aria-label="Confirm delete repeating board"
        data-testid="delete-repeating-board-confirm"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className={styles.sheetHeading}>Delete &quot;{boardName}&quot;?</h2>
        <p className={styles.confirmBody}>Boards already created from it will not be deleted.</p>

        <div className={styles.sheetActions}>
          <button
            type="button"
            data-modal-cancel
            className={styles.cancelButton}
            onClick={onCancel}
            disabled={busy}
          >
            Cancel
          </button>
          <button
            type="button"
            className={styles.deleteButton}
            onClick={onConfirm}
            disabled={busy}
          >
            {busy ? 'Deleting…' : 'Delete'}
          </button>
        </div>
      </div>
    </div>
  );
}
