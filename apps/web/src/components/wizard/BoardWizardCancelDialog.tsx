import { useEffect } from 'react';
import styles from './BoardWizardCancelDialog.module.css';

export interface BoardWizardCancelDialogProps {
  isOpen: boolean;
  /** When true, the Save-Draft button is disabled with an inline
   *  tooltip — Step 1 isn't complete enough to persist a draft record
   *  yet (most commonly: empty name). */
  canSaveDraft: boolean;
  /** Reason to surface when `canSaveDraft` is false. */
  saveDraftBlockedReason?: string;
  /** Optional override for the primary-action label. Defaults to
   *  "Save Draft". The draft-resume flow may want "Save Changes". */
  saveDraftLabel?: string;
  onSaveDraft: () => void;
  onDiscard: () => void;
  onKeepEditing: () => void;
}

/**
 * BoardWizardCancelDialog — Three-option prompt shown when the user
 * dismisses the wizard mid-edit. Mirrors iOS's
 * `BoardWizardCancelDialogView`.
 *
 * Options:
 * - **Save Draft / Save Changes** (primary) — persists current state
 *   as a draft Board record and closes the wizard.
 * - **Discard** — drops all unsaved state and closes the wizard.
 * - **Keep Editing** — dismisses the dialog, wizard stays open.
 *
 * The wizard's `BoardWizardPage` decides whether to show this dialog
 * based on `controller.isPristine`.
 */
export function BoardWizardCancelDialog({
  isOpen,
  canSaveDraft,
  saveDraftBlockedReason,
  saveDraftLabel = 'Save Draft',
  onSaveDraft,
  onDiscard,
  onKeepEditing,
}: BoardWizardCancelDialogProps): React.ReactElement | null {
  useEffect(() => {
    if (!isOpen) return;
    function onKey(e: KeyboardEvent): void {
      if (e.key === 'Escape') onKeepEditing();
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [isOpen, onKeepEditing]);

  if (!isOpen) return null;

  return (
    <div
      className={styles.backdrop}
      role="dialog"
      aria-modal="true"
      aria-labelledby="wizard-cancel-title"
      onClick={onKeepEditing}
    >
      <div className={styles.dialog} onClick={(e) => e.stopPropagation()}>
        <h3 id="wizard-cancel-title" className={styles.title}>
          Close this board?
        </h3>
        <p className={styles.body}>
          You've made changes that haven't been saved yet. What would you like to do?
        </p>
        <div className={styles.actions}>
          <button
            type="button"
            className={styles.saveButton}
            onClick={onSaveDraft}
            disabled={!canSaveDraft}
            title={!canSaveDraft ? saveDraftBlockedReason : undefined}
          >
            {saveDraftLabel}
          </button>
          <button
            type="button"
            className={styles.discardButton}
            onClick={onDiscard}
          >
            Discard
          </button>
          <button
            type="button"
            className={styles.keepButton}
            onClick={onKeepEditing}
            autoFocus
          >
            Keep Editing
          </button>
        </div>
      </div>
    </div>
  );
}
