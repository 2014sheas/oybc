import { useEffect } from 'react';
import type { Task } from '@oybc/shared';
import styles from './DeriveCounterModal.module.css';

interface DeriveCounterModalProps {
  /** Counting Task being derived from. */
  source: Task;
  /** Current value of the maxCount input field. */
  maxCountInput: string;
  /** Called when the user types in the maxCount input. */
  onMaxCountChange: (v: string) => void;
  /** Validation error message, or null. */
  error: string | null;
  /** Backdrop click / Escape / Cancel. */
  onCancel: () => void;
  /** Save button / Enter key. Caller validates + persists. */
  onSave: () => void;
}

/**
 * Minimal modal for the "Derive smaller version…" context-menu action
 * on counting tasks. Single field for the new `maxCount`; the source's
 * `action` and `unit` are inherited so the user only enters the
 * scaled-down target.
 *
 * Backdrop click + Escape dismiss; Enter submits. Caller owns state +
 * persistence (this is a presentational component).
 */
export function DeriveCounterModal({
  source,
  maxCountInput,
  onMaxCountChange,
  error,
  onCancel,
  onSave,
}: DeriveCounterModalProps): React.ReactElement {
  useEffect(() => {
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') onCancel();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [onCancel]);

  const action = (source.action ?? '').trim();
  const unit = (source.unit ?? '').trim();
  const previewMax = parseInt(maxCountInput.trim(), 10);
  const previewTitle =
    Number.isFinite(previewMax) && previewMax > 0
      ? `${action} ${previewMax} ${unit}`
      : '';

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Derive smaller counter"
      className={styles.backdrop}
      onClick={onCancel}
    >
      <div
        className={styles.dialog}
        onClick={(e) => e.stopPropagation()}
      >
        <h3 className={styles.title}>Derive smaller version</h3>
        <div className={styles.sourceHint}>
          From <strong>{source.title}</strong>
          {source.maxCount != null && (
            <span>
              {' '}
              — {action} {source.maxCount} {unit}
            </span>
          )}
        </div>
        <label className={styles.fieldLabel}>
          New goal
        </label>
        <input
          type="number"
          autoFocus
          inputMode="numeric"
          min={1}
          value={maxCountInput}
          onChange={(e) => onMaxCountChange(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') onSave();
          }}
          className={styles.fieldInput}
        />
        {previewTitle && (
          <div className={styles.preview}>
            New title: <strong>{previewTitle}</strong>
          </div>
        )}
        {error && (
          <div className={styles.error}>{error}</div>
        )}
        <div className={styles.actions}>
          <button
            type="button"
            onClick={onCancel}
            className={styles.cancelButton}
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={onSave}
            className={styles.saveButton}
          >
            Save
          </button>
        </div>
      </div>
    </div>
  );
}
