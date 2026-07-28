import { useEffect } from 'react';
import { generateCounterTaskTitle, type Task } from '@oybc/shared';
import { RisoButton } from '../riso';
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
 * on counting tasks. Single field for the new goal; the source's verb and
 * counted noun are inherited so the user only enters the scaled-down
 * target. R1 counters refresh — "Refining counters" design handoff
 * §Creation Surfaces: retitled "Smaller version", copy from Global
 * Constraints, RisoButton footer.
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
      ? generateCounterTaskTitle(action, previewMax, unit)
      : '';

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Smaller version"
      className={styles.backdrop}
      onClick={onCancel}
    >
      <div
        className={styles.dialog}
        onClick={(e) => e.stopPropagation()}
      >
        <h3 className={styles.title}>Smaller version</h3>
        <div className={styles.sourceHint}>
          From <strong>{source.title}</strong> — same counter, lower goal.
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
            New task: <strong>{previewTitle}</strong> — still counts {unit}.
          </div>
        )}
        {error && (
          <div className={styles.error}>{error}</div>
        )}
        <div className={styles.actions}>
          <RisoButton kind="ghost" onClick={onCancel}>
            Cancel
          </RisoButton>
          <RisoButton kind="blue" onClick={onSave}>
            Create
          </RisoButton>
        </div>
      </div>
    </div>
  );
}
