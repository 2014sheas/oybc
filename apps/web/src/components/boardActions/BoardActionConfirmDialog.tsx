import { useModalA11y } from '../../hooks/useModalA11y';
import styles from './BoardActionConfirmDialog.module.css';

export interface BoardActionConfirmDialogProps {
  /** Dialog title (e.g. "Archive this board?"). */
  title: string;
  /** Body copy. */
  body: string;
  /** Defaults to "Cancel". */
  cancelLabel?: string;
  /** The affirmative action's label (e.g. "Archive" / "Delete"). */
  confirmLabel: string;
  /** Destructive styling (red confirm button) — Delete uses this; Archive
   *  doesn't (plan D7: Archive keeps its neutral primary styling). */
  destructive?: boolean;
  busy?: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}

/**
 * BoardActionConfirmDialog — generic `.alert`-shaped confirm for Archive /
 * Delete (Board Edit redesign slice 2, plan D7). Modeled on
 * `CounterDeleteConfirmDialog`'s backdrop + `role="alertdialog"` + red
 * destructive confirm pattern. Initial focus always lands on Cancel — the
 * safe choice one keystroke away, matching the iOS `.alert`.
 */
export function BoardActionConfirmDialog({
  title,
  body,
  cancelLabel = 'Cancel',
  confirmLabel,
  destructive = false,
  busy = false,
  onCancel,
  onConfirm,
}: BoardActionConfirmDialogProps): React.ReactElement {
  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({
    open: true,
    onCancel: () => !busy && onCancel(),
    initialFocus: 'cancel',
  });

  return (
    <div className={styles.backdrop} onClick={() => !busy && onCancel()} role="presentation">
      <div
        ref={modalRef}
        className={styles.card}
        role="alertdialog"
        aria-label={title}
        {...modalProps}
        onClick={(e) => e.stopPropagation()}
      >
        <div className={styles.title}>{title}</div>
        <p className={styles.body}>{body}</p>
        <div className={styles.btns}>
          <button
            type="button"
            className={styles.cancelBtn}
            data-modal-cancel
            disabled={busy}
            onClick={onCancel}
          >
            {cancelLabel}
          </button>
          <button
            type="button"
            className={destructive ? styles.destructiveBtn : styles.confirmBtn}
            disabled={busy}
            onClick={onConfirm}
          >
            {busy ? 'Working…' : confirmLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
