import { useEffect } from 'react';
import type { Task } from '@oybc/shared';

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
      onClick={onCancel}
      style={{
        position: 'fixed',
        inset: 0,
        zIndex: 1100,
        background: 'rgba(0,0,0,0.5)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          background: 'var(--color-bg-elevated, #1c1c1e)',
          color: 'inherit',
          border: '1px solid rgba(255,255,255,0.1)',
          borderRadius: 12,
          padding: 20,
          minWidth: 320,
          maxWidth: 420,
          boxShadow: '0 12px 40px rgba(0,0,0,0.5)',
        }}
      >
        <h3 style={{ margin: '0 0 12px', fontSize: 17 }}>Derive smaller version</h3>
        <div style={{ marginBottom: 12, fontSize: 14, opacity: 0.75 }}>
          From <strong>{source.title}</strong>
          {source.maxCount != null && (
            <span>
              {' '}
              — {action} {source.maxCount} {unit}
            </span>
          )}
        </div>
        <label style={{ display: 'block', fontSize: 13, marginBottom: 6 }}>
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
          style={{
            width: '100%',
            padding: '8px 10px',
            borderRadius: 6,
            border: '1px solid rgba(255,255,255,0.15)',
            background: 'rgba(255,255,255,0.04)',
            color: 'inherit',
            font: 'inherit',
            boxSizing: 'border-box',
          }}
        />
        {previewTitle && (
          <div style={{ marginTop: 8, fontSize: 12, opacity: 0.6 }}>
            New title: <strong>{previewTitle}</strong>
          </div>
        )}
        {error && (
          <div style={{ marginTop: 8, fontSize: 13, color: '#ff6b6b' }}>{error}</div>
        )}
        <div
          style={{
            marginTop: 16,
            display: 'flex',
            justifyContent: 'flex-end',
            gap: 8,
          }}
        >
          <button
            type="button"
            onClick={onCancel}
            style={{
              padding: '8px 14px',
              borderRadius: 6,
              background: 'transparent',
              border: '1px solid rgba(255,255,255,0.2)',
              color: 'inherit',
              cursor: 'pointer',
              font: 'inherit',
            }}
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={onSave}
            style={{
              padding: '8px 14px',
              borderRadius: 6,
              background: '#0a84ff',
              border: 0,
              color: '#fff',
              cursor: 'pointer',
              font: 'inherit',
              fontWeight: 600,
            }}
          >
            Save
          </button>
        </div>
      </div>
    </div>
  );
}
