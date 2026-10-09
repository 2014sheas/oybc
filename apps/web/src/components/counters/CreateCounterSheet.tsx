import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  classifyCounterCreateMatch,
  formatCounterName,
  countKindNeedsUnit,
  formatCountForInput,
  formatCountTotal,
  kindPickerLock,
  parseCountInput,
  resolveCountKind,
  type CountKind,
  type Task,
} from '@oybc/shared';
import { CompoundEditValidationError, saveTaskEdit } from '../../db/operations';
import { createCounterTask } from '../../db/operations/tasks';
import { useModalA11y } from '../../hooks/useModalA11y';
import { RisoButton } from '../riso';
import { GoalEntry } from './GoalEntry';
import { KindPicker } from './KindPicker';
import {
  counterEditDedupePool,
  counterEditIdentityChanged,
  counterEditSubmit,
  seedCounterEditDraft,
} from './counterEditModel';
import { useKindSwitchRequest } from './useKindSwitchRequest';
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
  onCreated?: (counterId: string) => void;
  /**
   * EDIT mode: the counter's ROOT task. The sheet opens as "Edit counter"
   * prefilled from it (no "Start from"), and Save writes through
   * `saveTaskEdit` — the Task Detail write.
   */
  root?: Task | null;
  /** Called after an edit-mode save succeeds. */
  onSaved?: () => void;
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
 *
 * EDIT mode (`root` set — Counter Detail "Edit counter…"): a counter is
 * edited through THIS sheet, never the task editor. Same fields, prefilled
 * (`counterEditModel`); the kind picker carries the edit locks and the
 * shared Continuous → Discrete confirm (`useKindSwitchRequest`); a rename
 * checks the dedupe pool minus the counter's own family; Save →
 * `saveTaskEdit(root.id, counterEditSubmit(…))`.
 */
export function CreateCounterSheet({
  open,
  onClose,
  tasks,
  userId,
  onCreated,
  root = null,
  onSaved,
}: CreateCounterSheetProps): React.ReactElement | null {
  const navigate = useNavigate();
  const genRef = useRef(0);
  const seed = root ? seedCounterEditDraft(root) : null;
  const [verb, setVerb] = useState(seed?.verb ?? '');
  const [noun, setNoun] = useState(seed?.noun ?? '');
  const [countKind, setCountKind] = useState<CountKind>(seed?.kind ?? 'discrete');
  const [startingCountStr, setStartingCountStr] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // aria-modal, Escape → cancel, Tab trap, focus restore (the noun field
  // keeps its autoFocus). Guard against in-flight ops.
  const { ref: modalRef, props: modalProps } = useModalA11y<HTMLDivElement>({
    open,
    onCancel: () => {
      if (!busy) onClose();
    },
  });

  // Reset field state each time the sheet (re)opens so a prior session's
  // partial input never bleeds into the next. Increment generation counter
  // to guard stale-request handlers.
  useEffect(() => {
    if (open) {
      genRef.current += 1;
      const fresh = root ? seedCounterEditDraft(root) : null;
      setVerb(fresh?.verb ?? '');
      setNoun(fresh?.noun ?? '');
      setStartingCountStr('');
      setCountKind(fresh?.kind ?? 'discrete');
      setError(null);
      setBusy(false);
    }
    // Re-seed per open / per root identity only — a live refresh of the root
    // while the sheet is open must not clobber the user's typing.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, root?.id]);

  const trimmedVerb = verb.trim();
  const trimmedNoun = noun.trim();
  const effectiveVerb = trimmedVerb || DEFAULT_VERB;
  const previewName = trimmedNoun ? formatCounterName(effectiveVerb, trimmedNoun) : '';
  const startFromEmpty = startingCountStr.trim() === '';
  const startFromNum = parseCountInput(startingCountStr, countKind, { allowZero: true });
  const startFromInvalid = !startFromEmpty && startFromNum === null;
  const previewCount = startFromNum ?? 0;

  // Edit mode: the shared confirm seam (Continuous → Discrete previews the draft).
  const { requestKind, dialog: kindDialog } = useKindSwitchRequest({
    subject: { ...(root ?? ({} as Task)), action: verb, unit: noun, countKind },
    kind: countKind,
    goalText: root?.maxCount != null ? formatCountForInput(root.maxCount, countKind) : '',
    setKind: setCountKind,
    onSwitched: (k) => setCountKind(k),
  });

  function handleKindChange(next: CountKind): void {
    // The field grammar differs per kind (decimal / h:m) — a stale entry would mis-parse.
    if (next !== countKind) setStartingCountStr('');
    setCountKind(next);
  }

  // Recompute per keystroke, like CountingTemplatePicker's `suggestion` memo.
  // Edit mode checks only a rename, against everything but the counter's family.
  const renamed = root ? counterEditIdentityChanged(root, { verb, noun, kind: countKind }) : true;
  const match = useMemo(
    () =>
      trimmedNoun && renamed
        ? classifyCounterCreateMatch(
            { action: effectiveVerb, unit: trimmedNoun },
            root ? counterEditDedupePool(root, tasks) : tasks,
          )
        : null,
    [effectiveVerb, trimmedNoun, tasks, root, renamed],
  );

  if (!open) return null;

  // R1: the promote/standalone card was removed — a `standalone` match no
  // longer blocks or offers anything; only `established` blocks create.
  const canCreate = trimmedNoun !== '' && match?.kind !== 'established' && !startFromInvalid && !busy;
  // A Duration counter's noun is optional in edit (a board-born root has no unit).
  const canSave =
    (trimmedNoun !== '' || !countKindNeedsUnit(countKind)) && match?.kind !== 'established' && !busy;

  async function handleSave(): Promise<void> {
    if (!root || !canSave) return;
    genRef.current += 1;
    const gen = genRef.current;
    setError(null);
    setBusy(true);
    try {
      await saveTaskEdit(root.id, counterEditSubmit(root, { verb, noun, kind: countKind }));
      if (genRef.current !== gen) return;
      setBusy(false);
      onSaved?.();
    } catch (e) {
      if (genRef.current !== gen) return;
      setError(e instanceof CompoundEditValidationError ? e.message : 'Could not save counter.');
      setBusy(false);
    }
  }

  async function handleCreate(): Promise<void> {
    if (!canCreate) return;
    genRef.current += 1;
    const gen = genRef.current;
    setError(null);
    setBusy(true);
    try {
      const t = await createCounterTask(userId, {
        action: effectiveVerb,
        unit: trimmedNoun,
        startingCount: startFromNum ?? undefined,
        countKind,
      });
      if (genRef.current !== gen) return;
      onCreated?.(t.id);
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
      ref={modalRef}
      role="dialog"
      aria-label={root ? 'Edit counter' : 'New counter'}
      {...modalProps}
      className={styles.backdrop}
      onClick={() => !busy && onClose()}
    >
      <div className={styles.dialog} onClick={(e) => e.stopPropagation()}>
        <h3 className={styles.title}>{root ? 'Edit counter' : 'New counter'}</h3>

        <span className={`${styles.fieldLabel} ${styles.fieldLabelFirst}`}>Kind</span>
        {root ? (
          <KindPicker value={countKind} lock={kindPickerLock('edit', resolveCountKind(root))} onChange={requestKind} />
        ) : (
          <KindPicker value={countKind} lock="none" onChange={handleKindChange} />
        )}

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

        {!root && (
          <>
            <label className={styles.fieldLabel} htmlFor="create-counter-starting-count">
              Start from (optional)
            </label>
            <GoalEntry
              kind={countKind}
              id="create-counter-starting-count"
              aria-label="Start from"
              value={startingCountStr}
              onChange={setStartingCountStr}
              placeholder="0"
              invalid={startFromInvalid}
              dense
            />
          </>
        )}

        {previewName && (
          <div className={styles.previewCard}>
            <div className={styles.previewRow}>
              <span className={styles.previewName}>{previewName}</span>
              <span className={styles.previewCount}>
                {formatCountTotal(root ? (root.currentCount ?? 0) : previewCount, countKind)}
              </span>
            </div>
            <div className={styles.previewFooter}>
              <span className={styles.previewAllTime}>All-time</span>
            </div>
          </div>
        )}

        {match?.kind === 'established' && (
          <div className={styles.matchCardEstablished}>
            <p className={styles.matchTitle}>You&apos;re already counting {trimmedNoun}</p>
            <p className={styles.matchSub}>
              {formatCountTotal(match.lifetime, resolveCountKind(match.task))} all-time · counting on {match.memberCount} task
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
          {root ? (
            <RisoButton kind="blue" onClick={handleSave} disabled={!canSave}>
              Save
            </RisoButton>
          ) : (
            <RisoButton kind="blue" onClick={handleCreate} disabled={!canCreate}>
              Create counter
            </RisoButton>
          )}
        </div>
        {kindDialog}
      </div>
    </div>
  );
}
