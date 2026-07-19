import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { classifyCounterCreateMatch, formatCounterName, type Task } from '@oybc/shared';
import { createCounterTask } from '../../db/operations/tasks';
import { RisoButton } from '../riso';
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
  /** Called with the resulting task id after a create succeeds. */
  onCreated: (counterId: string) => void;
}

/** Fallback verb when the "TASK VERB" field is left blank — per the
 *  (verb, noun) identity model, an empty verb submits as "Do". */
const DEFAULT_VERB = 'Do';

/**
 * CreateCounterSheet — Counters Hub "+ New counter" modal (Shared Counters
 * P5, PR-2; R1 counters refresh — "Refining counters" design handoff
 * §Creation Surfaces).
 *
 * Fields follow the (verb, noun) identity model: "WHAT ARE YOU COUNTING?"
 * captures the noun (stored as `unit`), the optional "TASK VERB" captures
 * the verb (stored as `action`, defaulting to "Do" when left blank), and
 * "START FROM" seeds the lifetime total. Recomputes a dedupe classification
 * per keystroke via `classifyCounterCreateMatch`:
 *
 *   - `established` match → Create is disabled; a gold card offers
 *     "Open {CounterName}" (navigates to the existing counter's detail page
 *     and closes the sheet).
 *   - `standalone` match → ignored (R1: the promote-to-counter UI entry
 *     point was removed; `promoteTaskToCounter` itself is untouched — see
 *     CLAUDE.md's Global Constraints). Create proceeds normally.
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
  const [verb, setVerb] = useState('');
  const [noun, setNoun] = useState('');
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
      setVerb('');
      setNoun('');
      setStartingCountStr('');
      setError(null);
      setBusy(false);
    }
  }, [open]);

  const trimmedVerb = verb.trim();
  const trimmedNoun = noun.trim();
  const effectiveVerb = trimmedVerb || DEFAULT_VERB;
  const previewName = trimmedNoun ? formatCounterName(effectiveVerb, trimmedNoun) : '';
  const startFromNum = parseInt(startingCountStr, 10);
  const previewCount = Number.isFinite(startFromNum) && startFromNum > 0 ? startFromNum : 0;

  // Recompute per keystroke, like CountingTemplatePicker's `suggestion` memo.
  const match = useMemo(
    () =>
      trimmedNoun
        ? classifyCounterCreateMatch({ action: effectiveVerb, unit: trimmedNoun }, tasks)
        : null,
    [effectiveVerb, trimmedNoun, tasks],
  );

  if (!open) return null;

  // R1: the promote/standalone card was removed — a `standalone` match no
  // longer blocks or offers anything; only `established` blocks create.
  const canCreate = trimmedNoun !== '' && match?.kind !== 'established' && !busy;

  async function handleCreate(): Promise<void> {
    if (!canCreate) return;
    genRef.current += 1;
    const gen = genRef.current;
    setError(null);
    setBusy(true);
    try {
      const parsed = parseInt(startingCountStr, 10);
      const t = await createCounterTask(userId, {
        action: effectiveVerb,
        unit: trimmedNoun,
        startingCount: parsed || undefined,
      });
      if (genRef.current !== gen) return;
      onCreated(t.id);
    } catch {
      if (genRef.current !== gen) return;
      setError('Could not create counter.');
      setBusy(false);
    }
  }

  function handleOpenCounter(taskId: string): void {
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

        <label className={styles.fieldLabel} htmlFor="create-counter-noun">
          What are you counting?
        </label>
        <input
          id="create-counter-noun"
          type="text"
          autoFocus
          value={noun}
          onChange={(e) => setNoun(e.target.value)}
          placeholder="push-ups"
          className={styles.fieldInput}
        />
        <div className={styles.helperText}>A plural noun — push-ups, pages, miles.</div>

        <label className={styles.fieldLabel} htmlFor="create-counter-verb">
          Task verb (optional)
        </label>
        <input
          id="create-counter-verb"
          type="text"
          value={verb}
          onChange={(e) => setVerb(e.target.value)}
          placeholder="Do"
          className={styles.fieldInput}
        />
        <div className={styles.helperText}>
          Used in task titles — &quot;Do 100 push-ups&quot;. Try &quot;Read&quot; for pages, &quot;Run&quot; for miles.
        </div>

        <label className={styles.fieldLabel} htmlFor="create-counter-starting-count">
          Start from (optional)
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

        {previewName && (
          <div className={styles.previewCard}>
            <div className={styles.previewRow}>
              <span className={styles.previewName}>{previewName}</span>
              <span className={styles.previewCount}>{previewCount.toLocaleString()}</span>
            </div>
            <div className={styles.previewFooter}>
              <span className={styles.previewSub}>
                Tasks that count {trimmedNoun} link up automatically.
              </span>
              <span className={styles.previewAllTime}>All-time</span>
            </div>
          </div>
        )}

        {match?.kind === 'established' && (
          <div className={styles.matchCardEstablished}>
            <p className={styles.matchTitle}>You&apos;re already counting {trimmedNoun}</p>
            <p className={styles.matchSub}>
              {match.lifetime.toLocaleString()} all-time · counting on {match.memberCount} task
              {match.memberCount !== 1 ? 's' : ''}
            </p>
            <button
              type="button"
              className={styles.matchLinkButton}
              onClick={() => handleOpenCounter(match.task.id)}
            >
              Open {formatCounterName(match.task.action, match.task.unit) || match.task.title}
            </button>
          </div>
        )}

        {error && <div className={styles.error}>{error}</div>}

        <div className={styles.actions}>
          <RisoButton kind="ghost" onClick={onClose} disabled={busy}>
            Cancel
          </RisoButton>
          <RisoButton kind="blue" onClick={handleCreate} disabled={!canCreate}>
            Create counter
          </RisoButton>
        </div>
      </div>
    </div>
  );
}
