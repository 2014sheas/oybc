import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { classifyCounterCreateMatch, generateCounterTaskTitle, type Task } from '@oybc/shared';
import { createCounterTask, promoteTaskToCounter } from '../../db/operations/tasks';
import styles from './CreateCounterSheet.module.css';

export interface CreateCounterSheetProps {
  /** Whether the sheet is open. Renders nothing when false. */
  open: boolean;
  /** Backdrop click / Escape / Cancel. */
  onClose: () => void;
  /** The user's live (non-deleted) task pool — used for dedupe classification. */
  tasks: readonly Task[];
  /** Authenticated user id — owner of the new counter task. */
  userId: string;
  /** Called with the resulting task id after a create or promote succeeds. */
  onCreated: (counterId: string) => void;
}

/**
 * CreateCounterSheet — Counters Hub "+ New counter" modal (Shared Counters
 * P5, PR-2; docs/SHARED_COUNTERS.md §P5).
 *
 * Lets the user type an Action + Unit (+ optional starting count) to create
 * a new goal-less hub-born counter task via `createCounterTask`. Recomputes
 * a dedupe classification per keystroke via `classifyCounterCreateMatch`:
 *
 *   - `established` match → Create is disabled; a card offers "View counter"
 *     (navigates to the existing counter's detail page and closes the sheet).
 *   - `standalone` match → a card offers one-tap "Promote", which flags the
 *     existing standalone counting task as a counter (`promoteTaskToCounter`)
 *     instead of creating a duplicate.
 *   - no match → Create proceeds normally.
 *
 * Modeled on `DeriveCounterModal` (backdrop + `role="dialog"` +
 * Escape-to-cancel `keydown` effect + `stopPropagation` on the inner panel).
 * This is a presentational-ish component that owns its own field state but
 * calls the ops directly (no parent form to lift state into) — the caller
 * (`CountersHubPage`) only supplies `tasks`/`userId` and reacts to
 * `onCreated` (closing the sheet + navigating to the new counter's detail
 * page belongs to the caller per the W3 task contract).
 */
export function CreateCounterSheet({
  open,
  onClose,
  tasks,
  userId,
  onCreated,
}: CreateCounterSheetProps): React.ReactElement | null {
  const navigate = useNavigate();
  const genRef = useRef(0);
  const [action, setAction] = useState('');
  const [unit, setUnit] = useState('');
  const [startingCountStr, setStartingCountStr] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // Escape-to-cancel, mirroring DeriveCounterModal. Guard against in-flight ops.
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent): void => {
      if (e.key === 'Escape' && !busy) onClose();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, onClose, busy]);

  // Reset field state each time the sheet (re)opens so a prior session's
  // partial input never bleeds into the next. Increment generation counter
  // to guard stale-request handlers.
  useEffect(() => {
    if (open) {
      genRef.current += 1;
      setAction('');
      setUnit('');
      setStartingCountStr('');
      setError(null);
      setBusy(false);
    }
  }, [open]);

  const trimmedAction = action.trim();
  const trimmedUnit = unit.trim();
  const previewTitle =
    trimmedAction && trimmedUnit
      ? generateCounterTaskTitle(trimmedAction, null, trimmedUnit)
      : '';

  // Recompute per keystroke, like CountingTemplatePicker's `suggestion` memo.
  const match = useMemo(
    () =>
      trimmedAction && trimmedUnit
        ? classifyCounterCreateMatch({ action: trimmedAction, unit: trimmedUnit }, tasks)
        : null,
    [trimmedAction, trimmedUnit, tasks],
  );

  if (!open) return null;

  const canCreate =
    trimmedAction !== '' && trimmedUnit !== '' && match?.kind !== 'established' && !busy;

  async function handleCreate(): Promise<void> {
    if (!canCreate) return;
    genRef.current += 1;
    const gen = genRef.current;
    setError(null);
    setBusy(true);
    try {
      const parsed = parseInt(startingCountStr, 10);
      const t = await createCounterTask(userId, {
        action: trimmedAction,
        unit: trimmedUnit,
        startingCount: parsed || undefined,
      });
      if (genRef.current !== gen) return;
      onCreated(t.id);
    } catch (e) {
      if (genRef.current !== gen) return;
      setError(e instanceof Error ? e.message : 'Could not create counter.');
      setBusy(false);
    }
  }

  async function handlePromote(taskId: string): Promise<void> {
    genRef.current += 1;
    const gen = genRef.current;
    setError(null);
    setBusy(true);
    try {
      const t = await promoteTaskToCounter(taskId);
      if (genRef.current !== gen) return;
      onCreated(t.id);
    } catch (e) {
      if (genRef.current !== gen) return;
      setError(e instanceof Error ? e.message : 'Could not promote to counter.');
      setBusy(false);
    }
  }

  function handleViewCounter(taskId: string): void {
    onClose();
    navigate(`/profile/counters/${taskId}`);
  }

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="New counter"
      className={styles.backdrop}
      onClick={() => !busy && onClose()}
    >
      <div className={styles.dialog} onClick={(e) => e.stopPropagation()}>
        <h3 className={styles.title}>New counter</h3>

        <label className={styles.fieldLabel} htmlFor="create-counter-action">
          Action
        </label>
        <input
          id="create-counter-action"
          type="text"
          autoFocus
          value={action}
          onChange={(e) => setAction(e.target.value)}
          placeholder="Push-ups"
          className={styles.fieldInput}
        />

        <label className={styles.fieldLabel} htmlFor="create-counter-unit">
          Unit
        </label>
        <input
          id="create-counter-unit"
          type="text"
          value={unit}
          onChange={(e) => setUnit(e.target.value)}
          placeholder="reps"
          className={styles.fieldInput}
        />

        <label className={styles.fieldLabel} htmlFor="create-counter-starting-count">
          Starting count (optional)
        </label>
        <input
          id="create-counter-starting-count"
          type="number"
          inputMode="numeric"
          min={0}
          value={startingCountStr}
          onChange={(e) => setStartingCountStr(e.target.value)}
          placeholder="0"
          className={styles.fieldInput}
        />
        <div className={styles.helperText}>Already partway? Seed the lifetime total.</div>

        {previewTitle && (
          <div className={styles.preview}>
            New counter: <strong>{previewTitle}</strong>
          </div>
        )}

        {match?.kind === 'established' && (
          <div className={styles.matchCardEstablished}>
            <p className={styles.matchTitle}>
              You already have a &quot;{(match.task.action ?? '').trim() || match.task.title}&quot;
              counter
            </p>
            <p className={styles.matchSub}>
              {match.lifetime.toLocaleString()} all-time · {match.memberCount} task
              {match.memberCount !== 1 ? 's' : ''}
            </p>
            <button
              type="button"
              className={styles.matchLinkButton}
              onClick={() => handleViewCounter(match.task.id)}
            >
              View counter
            </button>
          </div>
        )}

        {match?.kind === 'standalone' && (
          <div className={styles.matchCardStandalone}>
            <p className={styles.matchTitle}>Make &quot;{match.task.title}&quot; this counter?</p>
            <p className={styles.matchSub}>Keeps its count, goal, and boards.</p>
            <button
              type="button"
              className={styles.matchPromoteButton}
              disabled={busy}
              onClick={() => handlePromote(match.task.id)}
            >
              Promote
            </button>
          </div>
        )}

        {error && <div className={styles.error}>{error}</div>}

        <div className={styles.actions}>
          <button
            type="button"
            onClick={onClose}
            disabled={busy}
            className={styles.cancelButton}
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={handleCreate}
            disabled={!canCreate}
            className={styles.saveButton}
          >
            Create counter
          </button>
        </div>
      </div>
    </div>
  );
}
