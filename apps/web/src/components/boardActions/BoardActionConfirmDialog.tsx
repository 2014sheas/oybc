import { useModalA11y } from '../../hooks/useModalA11y';
import styles from './BoardActionConfirmDialog.module.css';

export interface BoardActionConfirmDialogProps {
  /** Dialog title (e.g. "Archive this board?"). */
  title: string;
  /** Body copy. */
  body: string;
  /** Defaults to "Cancel". `null` renders a single-button NOTICE (e.g. the
   *  D11 "Board closed" alert): the confirm button is then the only — and
   *  the focused — control, and backdrop / Escape run `onCancel`. */
  cancelLabel?: string | null;
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
 * safe choice one keystroke away, matching the iOS `.alert`. With
 * `cancelLabel={null}` it is a one-button notice (the iOS `.alert` with a
 * lone OK) — used for "Board closed" and Archive/Delete failures.
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
          {cancelLabel !== null && (
            <button
              type="button"
              className={styles.cancelBtn}
              data-modal-cancel
              disabled={busy}
              onClick={onCancel}
            >
              {cancelLabel}
            </button>
          )}
          <button
            type="button"
            className={destructive ? styles.destructiveBtn : styles.confirmBtn}
            // A notice's lone button is also its safe default (initial focus).
            data-modal-cancel={cancelLabel === null ? true : undefined}
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
