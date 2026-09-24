import { useModalA11y } from '../../hooks/useModalA11y';
// Deliberately the counter sheet's module, not a third copy: this dialog is
// the same Riso confirm shape (backdrop scrim → bordered sheet → heading →
// body → Cancel + red destructive action), and the repo already has two
// hand-copied sets of those rules. Reusing keeps them from drifting apart.
// `.deleteButton` is that module's red destructive class.
import styles from '../counters/CounterDeleteConfirmDialog.module.css';

export interface RemoveSourceConfirmDialogProps {
  /** The pulled source's display name — the pool / board the row names. */
  displayName: string;
  /**
   * What the removal costs, from the shared `removeSourceLossSentence`
   * (e.g. `"You'll lose 3 exclusions and 2 member rules."`). The step only
   * opens this dialog when the source carries configuration, so this is
   * never empty.
   */
  lossSentence: string;
  /**
   * True while the wizard is editing an existing REPEATING board
   * (`useBoardWizard.editingTemplateId !== null`) — appends the same
   * "Changes apply from the next board." line `WizardEditModeNote` uses, so
   * the confirm can't read as if it were touching the board already on the
   * Boards tab.
   */
  editingRepeatingBoard: boolean;
  /** Remove the source. */
  onConfirm: () => void;
  /** Cancel / dismiss (backdrop click, Escape, the Cancel button). */
  onCancel: () => void;
}

/**
 * RemoveSourceConfirmDialog — "are you sure?" before the wizard's Tasks step
 * drops a pulled source that carries configuration (owner ruling
 * 2026-09-19: exclusions, member rules, a narrowed range or a flipped
 * squares filter are real work, and a misclick on the row's ✕ was throwing
 * all of it away silently; an UNTOUCHED source still removes instantly and
 * never reaches this dialog).
 *
 * Modeled on `components/counters/CounterDeleteConfirmDialog.tsx` — same
 * `role="alertdialog"` + backdrop-cancels + red destructive confirm, and
 * literally the same CSS module. iOS twin: the `.confirmationDialog` in
 * `BoardWizardTasksStepView.swift` (native two-choice destructive confirm),
 * wording the loss with the SAME shared sentence builder.
 *
 * Focus lands on Cancel when it opens, Escape cancels and Tab stays inside
 * (`useModalA11y`), so the safe choice is always one keystroke away.
 *
 * @param props - See {@link RemoveSourceConfirmDialogProps}.
 * @returns The modal confirm.
 */
export function RemoveSourceConfirmDialog({
  displayName,
  lossSentence,
  editingRepeatingBoard,
  onConfirm,
  onCancel,
}: RemoveSourceConfirmDialogProps): React.ReactElement {
  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({
    open: true,
    onCancel,
    initialFocus: 'cancel',
  });

  return (
    <div className={styles.backdrop} onClick={onCancel}>
      <div
        ref={modalRef}
        className={styles.sheet}
        role="alertdialog"
        {...modalProps}
        aria-label="Confirm remove source"
        data-testid="remove-source-confirm"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className={styles.sheetHeading}>Remove &quot;{displayName}&quot;?</h2>
        <p className={styles.confirmBody}>{lossSentence}</p>
        {editingRepeatingBoard && (
          <p className={styles.derivedNote}>Changes apply from the next board.</p>
        )}

        <div className={styles.sheetActions}>
          <button
            type="button"
            data-modal-cancel
            className={styles.cancelButton}
            onClick={onCancel}
          >
            Cancel
          </button>
          <button type="button" className={styles.deleteButton} onClick={onConfirm}>
            Remove
          </button>
        </div>
      </div>
    </div>
  );
}
