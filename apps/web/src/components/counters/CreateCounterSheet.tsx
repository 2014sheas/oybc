import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  classifyCounterCreateMatch,
  counterDisplayName,
  counterSettingsDefaults,
  countKindNeedsUnit,
  formatCountForInput,
  formatCountTotal,
  kindPickerLock,
  parseCountInput,
  resolveCountKind,
  storedCounterSettingsFromDraft,
  type CounterGoalTimeframe,
  type CounterSettingsDraft,
  type CountKind,
  type Task,
} from '@oybc/shared';
import { CompoundEditValidationError, saveTaskEdit } from '../../db/operations';
import { createCounterTask } from '../../db/operations/tasks';
import { useModalA11y } from '../../hooks/useModalA11y';
import { RisoButton } from '../riso';
import { DefaultsRow } from './DefaultsRow';
import { defaultsRowGoals, defaultsRowInvalidCells, type DefaultsRowEntered } from './defaultsRowModel';
import { GoalEntry } from './GoalEntry';
import { KindPicker } from './KindPicker';
import { TemplateField } from './TemplateField';
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

/** Zod's cap on a stored counter name. */
export const COUNTER_NAME_MAX_LENGTH = 100;

/** The example counts the value rows render `#N` with (handoff Decision 1). */
const EXAMPLE_COUNTS: Record<CountKind, { singular: number; plural: number }> = {
  discrete: { singular: 1, plural: 12 },
  continuous: { singular: 1, plural: 2.5 },
  duration: { singular: 1, plural: 90 },
};

/** The two required fields' validation copy (the only sentences on the sheet). */
export const NOUN_REQUIRED = "Enter what you're counting.";
export const VERB_REQUIRED = 'Enter a verb.';

/** The optional settings' typed state, with the Defaults cells as field text. */
interface SettingsFields {
  name: string;
  singular: string;
  plural: string;
  goals: DefaultsRowEntered;
}

const EMPTY_SETTINGS: SettingsFields = { name: '', singular: '', plural: '', goals: {} };

/**
 * The typed Defaults text for a root's stored goals, formatted at `kind`.
 *
 * @param goals - The stored goals (positive values only).
 * @param kind - The counter's kind.
 */
function goalsAsText(goals: CounterSettingsDraft['goals'], kind: CountKind): DefaultsRowEntered {
  const out: DefaultsRowEntered = {};
  for (const [t, v] of Object.entries(goals) as [CounterGoalTimeframe, number | null | undefined][]) {
    if (typeof v === 'number') out[t] = formatCountForInput(v, kind);
  }
  return out;
}

/**
 * CreateCounterSheet — the ONE counter editor (Counters Hub "+ New counter";
 * Counter Detail "Edit counter…"). Design handoff `CounterSheet.dc.html`
 * (docs/SHARED_COUNTER_SETTINGS.md §1): **Name · Kind · What are you
 * counting? · Task verb · Singular title · Plural title · Defaults · Start
 * from (create only)**.
 *
 * Only the noun (stored as `unit`) and the verb (stored as `action`) are
 * required — inline validation under each, the primary button disabled while
 * either is empty. Every optional field (Name, the two `#N` templates, each
 * Defaults cell) follows one rule: blank = unset = the generator default shown
 * DIMMED as real text to type over; typing makes it solid and stores it;
 * clearing returns it to the default and stores absent (D3 — the defaults are
 * never backfilled, and a typed value equal to the default is stored absent so
 * it keeps deriving live). The defaults derive from the sheet's LIVE verb /
 * noun / kind (`counterSettingsDefaults`), never the stored root.
 *
 * Dedupe (`classifyCounterCreateMatch`) runs per keystroke once both required
 * fields hold text: an `established` match disables the primary and offers
 * "Open {name}"; edit mode checks only a rename, against everything but the
 * counter's own family.
 *
 * A modal sheet (backdrop + `role="dialog"` + Escape + Tab trap). Owns its
 * field state and calls the ops directly; the caller reacts to `onCreated` /
 * `onSaved` (closing + navigation belong to the caller).
 *
 * EDIT mode (`root` set): the same fields prefilled (`counterEditModel`); the
 * kind picker carries the edit locks and the shared Continuous → Discrete
 * confirm (`useKindSwitchRequest`); Save → `saveTaskEdit(root.id,
 * counterEditSubmit(…))`, which writes only the settings that changed.
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
  const [settings, setSettings] = useState<SettingsFields>(() =>
    seed ? { ...seed.settings, goals: goalsAsText(seed.settings.goals, seed.kind) } : EMPTY_SETTINGS,
  );
  const [startingCountStr, setStartingCountStr] = useState('');
  const [touched, setTouched] = useState<{ noun: boolean; verb: boolean }>({ noun: false, verb: false });
  const [submitAttempted, setSubmitAttempted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // aria-modal, Escape → cancel, Tab trap, focus restore (the first field
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
      setCountKind(fresh?.kind ?? 'discrete');
      setSettings(fresh ? { ...fresh.settings, goals: goalsAsText(fresh.settings.goals, fresh.kind) } : EMPTY_SETTINGS);
      setStartingCountStr('');
      setTouched({ noun: false, verb: false });
      setSubmitAttempted(false);
      setError(null);
      setBusy(false);
    }
    // Re-seed per open / per root identity only — a live refresh of the root
    // while the sheet is open must not clobber the user's typing.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, root?.id]);

  const trimmedVerb = verb.trim();
  const trimmedNoun = noun.trim();
  // The noun stays optional for an existing Duration root (it may have no unit).
  const nounRequired = root ? countKindNeedsUnit(countKind) : true;
  const nounMissing = nounRequired && trimmedNoun === '';
  const verbMissing = trimmedVerb === '';
  const showNounError = nounMissing && (touched.noun || submitAttempted);
  const showVerbError = verbMissing && (touched.verb || submitAttempted);

  const context = { action: trimmedVerb, unit: trimmedNoun, countKind };
  const draft: CounterSettingsDraft = {
    name: settings.name,
    singular: settings.singular,
    plural: settings.plural,
    goals: defaultsRowGoals(settings.goals, countKind),
  };
  const defaults = counterSettingsDefaults(context, draft);
  const goalsInvalid = defaultsRowInvalidCells(settings.goals, countKind).length > 0;

  const startFromEmpty = startingCountStr.trim() === '';
  const startFromNum = parseCountInput(startingCountStr, countKind, { allowZero: true });
  const startFromInvalid = !startFromEmpty && startFromNum === null;

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
    if (next !== countKind) {
      setStartingCountStr('');
      setSettings((s) => ({ ...s, goals: {} }));
    }
    setCountKind(next);
  }

  // Recompute per keystroke, like CountingTemplatePicker's `suggestion` memo.
  // Edit mode checks only a rename, against everything but the counter's family.
  const renamed = root ? counterEditIdentityChanged(root, { verb, noun }) : true;
  const match = useMemo(
    () =>
      trimmedNoun && trimmedVerb && renamed
        ? classifyCounterCreateMatch(
            { action: trimmedVerb, unit: trimmedNoun },
            root ? counterEditDedupePool(root, tasks) : tasks,
          )
        : null,
    [trimmedVerb, trimmedNoun, tasks, root, renamed],
  );

  if (!open) return null;

  const fieldsValid = !nounMissing && !verbMissing && !goalsInvalid && match?.kind !== 'established' && !busy;
  const canCreate = fieldsValid && !startFromInvalid;
  const canSave = fieldsValid;

  /** Marks a required field touched once it has been edited then emptied. */
  function trackEmptied(field: 'noun' | 'verb', before: string, after: string): void {
    if (before.trim() !== '' && after.trim() === '') setTouched((t) => ({ ...t, [field]: true }));
  }

  async function handleSave(): Promise<void> {
    setSubmitAttempted(true);
    if (!root || !canSave) return;
    genRef.current += 1;
    const gen = genRef.current;
    setError(null);
    setBusy(true);
    try {
      await saveTaskEdit(root.id, counterEditSubmit(root, { verb, noun, kind: countKind, settings: draft }));
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
    setSubmitAttempted(true);
    if (!canCreate) return;
    genRef.current += 1;
    const gen = genRef.current;
    setError(null);
    setBusy(true);
    try {
      const t = await createCounterTask(userId, {
        action: trimmedVerb,
        unit: trimmedNoun,
        startingCount: startFromNum ?? undefined,
        countKind,
        settings: storedCounterSettingsFromDraft(context, draft),
      });
      if (genRef.current !== gen) return;
      onCreated?.(t.id);
    } catch {
      if (genRef.current !== gen) return;
      setError('Could not create counter.');
      setBusy(false);
    }
  }

  function handleSubmitKey(e: React.KeyboardEvent<HTMLInputElement>): void {
    if (e.key !== 'Enter') return;
    e.preventDefault();
    void (root ? handleSave() : handleCreate());
  }

  function handleOpenCounter(taskId: string): void {
    onClose();
    navigate(`/profile/counters/${taskId}`);
  }

  const nameDim = settings.name.trim() === '';
  const examples = EXAMPLE_COUNTS[countKind];
  // The dimmed defaults appear once there is something to derive them from
  // (handoff: a name needs the noun; a template needs the verb and, unless
  // Duration, the noun) — never a bare " #N ".
  const derivedName = trimmedNoun !== '' ? defaults.name : '';
  const templatesReady = trimmedVerb !== '' && (trimmedNoun !== '' || !countKindNeedsUnit(countKind));
  const derivedSingular = templatesReady ? defaults.singular : '';
  const derivedPlural = templatesReady ? defaults.plural : '';

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

        <label className={`${styles.fieldLabel} ${styles.fieldLabelFirst}`} htmlFor="create-counter-name">
          Name
        </label>
        <input
          id="create-counter-name"
          type="text"
          maxLength={COUNTER_NAME_MAX_LENGTH}
          value={nameDim ? derivedName : settings.name}
          onChange={(e) => setSettings((s) => ({ ...s, name: e.target.value }))}
          onKeyDown={handleSubmitKey}
          className={`${styles.fieldInput} ${nameDim ? styles.dim : ''}`}
          data-dim={nameDim || undefined}
        />

        <span className={styles.fieldLabel}>Kind</span>
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
          onChange={(e) => {
            trackEmptied('noun', noun, e.target.value);
            setNoun(e.target.value);
          }}
          onBlur={() => trimmedNoun === '' && setTouched((t) => ({ ...t, noun: true }))}
          onKeyDown={handleSubmitKey}
          placeholder="push-ups"
          aria-invalid={showNounError || undefined}
          className={`${styles.fieldInput} ${showNounError ? styles.fieldInvalid : ''}`}
        />
        {showNounError && <div className={styles.fieldError}>{NOUN_REQUIRED}</div>}

        <label className={styles.fieldLabel} htmlFor="create-counter-verb">
          Task verb
        </label>
        <input
          id="create-counter-verb"
          type="text"
          value={verb}
          onChange={(e) => {
            trackEmptied('verb', verb, e.target.value);
            setVerb(e.target.value);
          }}
          onBlur={() => trimmedVerb === '' && setTouched((t) => ({ ...t, verb: true }))}
          onKeyDown={handleSubmitKey}
          placeholder="Read"
          aria-invalid={showVerbError || undefined}
          className={`${styles.fieldInput} ${showVerbError ? styles.fieldInvalid : ''}`}
        />
        {showVerbError && <div className={styles.fieldError}>{VERB_REQUIRED}</div>}

        <div className={styles.block}>
          <TemplateField
            label="Singular title"
            id="create-counter-singular"
            value={settings.singular}
            onChange={(v) => setSettings((s) => ({ ...s, singular: v }))}
            derived={derivedSingular}
            kind={countKind}
            exampleCount={examples.singular}
          />
        </div>
        <div className={styles.block}>
          <TemplateField
            label="Plural title"
            id="create-counter-plural"
            value={settings.plural}
            onChange={(v) => setSettings((s) => ({ ...s, plural: v }))}
            derived={derivedPlural}
            kind={countKind}
            exampleCount={examples.plural}
          />
        </div>
        <div className={styles.block}>
          <DefaultsRow
            kind={countKind}
            unit={trimmedNoun}
            entered={settings.goals}
            onChange={(t, text) => setSettings((s) => ({ ...s, goals: { ...s.goals, [t]: text } }))}
            derived={defaults.goals}
            idPrefix="create-counter-default"
          />
        </div>

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
              Open {counterDisplayName(match.task)}
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
