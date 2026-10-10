import { useMemo, useRef, useState } from 'react';
import { TaskType, parseCountInput, resolveCountKind, type Task, type Timeframe } from '@oybc/shared';
import { createTask } from '../../db/operations/tasks';
import { generateUUID, currentTimestamp } from '../../db/utils';
import { RisoButton, RisoIcon, RisoTypeBadge } from '../riso';
import type { PendingTaskPayload } from '../../pages/createPage/useCreateFormState';
import { selectQuickAddMatches } from '../pools/poolEditSheetSelectors';
import { GoalEntry } from '../counters/GoalEntry';
import { KindTag } from '../counters/KindTag';
import {
  buildPendingLinkedCounter,
  counterMatchRowGoal,
  counterMatchRowName,
  isSharedCounterRoot,
} from './quickAddCounterPlacement';
import styles from './WizardQuickAddRow.module.css';

/**
 * Props for WizardQuickAddRow.
 *
 * The presence of `onPendingCreated` implicitly enables deferred-persist
 * mode (same convention as `NewTaskSheet`). When omitted, the task is
 * written to the DB immediately via `createTask`.
 */
export interface WizardQuickAddRowProps {
  /** Authenticated user id. */
  userId: string;
  /** Board timeframe — inherited by the new task so it matches the board's
   *  window. Mirrors the iOS `defaultTimeframe` param on `RisoQuickAddRowView`. */
  currentTimeframe?: Timeframe;
  /** Board start date (ISO8601, local) — inherited by the new task. */
  currentStartDate?: string;
  /** Board end date (ISO8601, local) — inherited by the new task. */
  currentEndDate?: string;
  /** Called when the new task is ready (created or deferred). The wizard
   *  auto-adds the returned task to `selectedTaskIds`. */
  onTaskCreated: (task: Task) => void;
  /**
   * Bug #85 — Deferred-persist callback. When provided, the component
   * builds the task fully in-memory (with `createdInWizard: true`) and
   * fires this alongside `onTaskCreated` without touching the DB. The
   * wizard atomically writes the pending payload when saving the board.
   * Absent for immediate-persist callers (e.g. Tasks-tab quick-add).
   */
  onPendingCreated?: (payload: PendingTaskPayload) => void;
  /**
   * Externally-driven disable (e.g. a parent sheet's save/delete in
   * flight). Defaults to `false` — existing callers are unaffected.
   * Combines with the row's own `isSubmitting` state, which already
   * disables mid-submit regardless of this prop.
   */
  disabled?: boolean;
  /**
   * Library-polling (owner decision 2026-07-21) — OPTIONAL. The browsable
   * task set (C6: excludes wizard-born drafts) to poll as the user types,
   * so they can reuse an existing task instead of creating a duplicate.
   * Must be provided together with `onExistingTaskPicked` to enable the
   * inline matches dropdown; when either is omitted the row behaves
   * exactly as the create-only baseline (no dropdown).
   */
  libraryTasks?: Task[];
  /** Ids to exclude from the dropdown (already selected/added on this
   *  surface). Defaults to empty — only meaningful alongside `libraryTasks`. */
  selectedIds?: Set<string>;
  /**
   * Fired when the user taps a dropdown match to REUSE that existing task
   * instead of creating a new one. The host appends the existing task's id
   * (no DB write here — this row never creates on this path). Clears the
   * input afterward, same as a create.
   */
  onExistingTaskPicked?: (task: Task) => void;
  /**
   * Draft-only submit — OPTIONAL. When provided, Enter / Add hands the
   * trimmed text to this callback (then clears the field) INSTEAD of
   * creating a task: no `createTask`, no pending payload, and
   * `onTaskCreated` / `onPendingCreated` never fire. Used by the compound
   * sub-task editors, which append a draft sub-task that is only written
   * when the edit is saved. Omitted by the wizard / Tasks-tab callers,
   * which keep the create path. iOS twin: `RisoQuickAddRowView.onSubmitText`.
   */
  onSubmitText?: (text: string) => void;
  /**
   * Draft-only submit gate — OPTIONAL, default `true`. `false` disables Add
   * and ignores Enter (the text stays put) while the host's own inputs are
   * incomplete — the compound editor's new Counting sub-task needs a goal
   * and a unit beside the text. iOS twin: `RisoQuickAddRowView.submitTextEnabled`.
   */
  canSubmitText?: boolean;
  /** Mirrors every text change (typing, clears) to the host — a draft-only
   *  host previews / gates on the text. iOS twin: `onTextChange`. */
  onTextChange?: (text: string) => void;
  /** Fixed placeholder instead of the rotating pool (the compound editor's
   *  Counting mode names the field the action: "Do"). */
  placeholder?: string;
  /** Initial field text — the dropdown is text-driven, so a seeded text
   *  renders the populated-dropdown state deterministically (tests only;
   *  iOS twin: `RisoQuickAddRowView(seedText:)`). */
  seedText?: string;
}

/** Stable empty-Set identity for the `selectedIds` default — avoids a new
 *  Set() (and a wasted `libraryMatches` recompute) on every render when a
 *  host omits the prop. */
const EMPTY_SELECTED_IDS: ReadonlySet<string> = new Set();

/** Rotating placeholder pool — mirrors the iOS `RisoQuickAddRowView` suggestions. */
const PLACEHOLDERS = [
  'e.g. Meditate 10 min',
  'e.g. Drink water',
  'e.g. Read 30 min',
  'e.g. Walk the dog',
  'e.g. Stretch',
];

/**
 * WizardQuickAddRow — inline text input for creating a NORMAL task directly
 * from the wizard Tasks step without opening the full New Task modal.
 *
 * Web twin of the iOS `RisoQuickAddRowView`. The full `NewTaskSheet` modal
 * remains for Counting/Compound/Achievement types — this row is additive and
 * handles the common one-field NORMAL case only.
 *
 * Placement: just above the task list, below the filter chips (always
 * visible). Creates the task and auto-selects it into the pool, then
 * resets and keeps focus so the user can type the next task immediately.
 *
 * Deferred-persist is controlled by the presence of `onPendingCreated`:
 * - With `onPendingCreated` → task is built in-memory (`createdInWizard: true`),
 *   no DB write — wizard writes atomically at board-save.
 * - Without `onPendingCreated` → immediate `createTask()` DB write.
 *
 * Library polling (OPTIONAL, owner decision 2026-07-21): when both
 * `libraryTasks` and `onExistingTaskPicked` are provided, typing polls the
 * library via `selectQuickAddMatches` (the pool sheet's own
 * `selectLibraryPickerResults` filter, just capped tighter) and renders an
 * inline dropdown of matches under the field — tapping one reuses that
 * EXISTING task instead of creating a duplicate. The Add button / Enter
 * path is unchanged: it always creates a new Normal task from the typed
 * text. Backward-compatible: omitting the new props (today's callers)
 * renders no dropdown at all.
 *
 * A match row for a shared counter ROOT (docs/SHARED_COUNTER_SETTINGS.md §2;
 * handoff `PlaceFrame.dc.html`) shows the counter's NAME, a dense kind tag and
 * — when the host passed `currentTimeframe` (a board context) — the goal this
 * board will get: "Weekly · 2 books" for a timeframe default, "12 books" for
 * the root's own goal. When no goal resolves at all, the same slot holds an
 * empty kind-aware Goal entry and the "+" stays dimmed until a number is
 * typed; the pick then hands a pending LINKED counting task at that goal to
 * `onPendingCreated` (hosts without it keep the plain row).
 *
 * iOS source: `Views/CreateTab/Components/RisoQuickAddRowView.swift`.
 */
export function WizardQuickAddRow({
  userId,
  currentTimeframe,
  currentStartDate,
  currentEndDate,
  onTaskCreated,
  onPendingCreated,
  disabled = false,
  libraryTasks,
  selectedIds,
  onExistingTaskPicked,
  onSubmitText,
  canSubmitText = true,
  onTextChange,
  placeholder: fixedPlaceholder,
  seedText = '',
}: WizardQuickAddRowProps): React.ReactElement {
  const [text, setText] = useState(seedText);
  const [placeholderIndex, setPlaceholderIndex] = useState(0);
  const [isSubmitting, setIsSubmitting] = useState(false);
  /** The Goal entry's text per no-default counter row (keyed by task id). */
  const [rowGoalText, setRowGoalText] = useState<Record<string, string>>({});
  const inputRef = useRef<HTMLInputElement>(null);

  const trimmed = text.trim();
  const canSubmit = trimmed.length > 0 && !isSubmitting && !disabled && canSubmitText;
  const placeholder = fixedPlaceholder ?? PLACEHOLDERS[placeholderIndex % PLACEHOLDERS.length];
  const deferPersist = onPendingCreated !== undefined;

  /** Sets the field's text and mirrors it to the host. */
  function updateText(next: string): void {
    setText(next);
    onTextChange?.(next);
  }

  // Library-poll matches — only computed when both polling props are
  // present. `selectQuickAddMatches` reuses `selectLibraryPickerResults`
  // (title-contains, case-insensitive, excludes `selectedIds`) verbatim,
  // just capped for the inline dropdown.
  const pollingEnabled = libraryTasks !== undefined && onExistingTaskPicked !== undefined;
  const libraryMatches = useMemo<Task[]>(() => {
    if (!pollingEnabled || trimmed === '') return [];
    return selectQuickAddMatches(libraryTasks!, selectedIds ?? EMPTY_SELECTED_IDS, trimmed);
  }, [pollingEnabled, libraryTasks, selectedIds, trimmed]);
  // Text-driven (not focus-gated) to match the app's existing inline
  // autocomplete convention (RisoCompoundFieldsView) and iOS's twin — an
  // in-flow suggestion list, so there's no floating overlay to dismiss on
  // blur; it hides when the field clears or a match/create resets it.
  const showDropdown = pollingEnabled && trimmed !== '' && libraryMatches.length > 0;

  function handleExistingPicked(task: Task): void {
    onExistingTaskPicked!(task);
    // Clear + refocus, same reset as a create — hides the dropdown since
    // it requires non-empty text.
    updateText('');
    inputRef.current?.focus();
  }

  /**
   * The no-default counter row's "+": the typed goal becomes a pending LINKED
   * counting task (minted into this board's copy at persist / Save). Nothing
   * is written to the counter root.
   */
  function handleCounterGoalPicked(root: Task, goal: number): void {
    const payload = buildPendingLinkedCounter(root, goal, userId, generateUUID(), currentTimestamp());
    onTaskCreated(payload.task);
    onPendingCreated!(payload);
    setRowGoalText((m) => ({ ...m, [root.id]: '' }));
    updateText('');
    inputRef.current?.focus();
  }

  /** The dropdown row for one match — a counter root gets the name · kind tag · goal slot. */
  function renderMatchRow(task: Task): React.ReactElement {
    const counterRow = isSharedCounterRoot(task) && currentTimeframe !== undefined;
    if (!counterRow) {
      return (
        <button type="button" className={styles.dropdownRowButton} onClick={() => handleExistingPicked(task)}>
          <RisoTypeBadge type={task.type} />
          <span className={styles.dropdownRowTitle}>{task.title || '(untitled task)'}</span>
          <RisoIcon name="plus" size={14} />
        </button>
      );
    }
    const name = counterMatchRowName(task);
    const kind = resolveCountKind(task);
    const slot = counterMatchRowGoal(task, currentTimeframe!);
    const needsGoal = slot === null && onPendingCreated !== undefined;
    if (!needsGoal) {
      return (
        <button type="button" className={styles.dropdownRowButton} onClick={() => handleExistingPicked(task)}>
          <RisoTypeBadge type={task.type} />
          <span className={styles.dropdownRowMain}>
            <span className={styles.dropdownRowTitle}>{name}</span>
            <KindTag kind={kind} dense />
          </span>
          {slot && (
            <span className={styles.rowGoal}>
              {slot.prefix}
              <span className={styles.rowGoalValue}>{slot.value}</span>
            </span>
          )}
          <RisoIcon name="plus" size={14} />
        </button>
      );
    }
    const goalText = rowGoalText[task.id] ?? '';
    const goal = parseCountInput(goalText, kind);
    const valid = goal !== null && goal > 0;
    return (
      <div className={styles.dropdownRowStatic} role="group" aria-label={`${name}, goal for this board`}>
        <RisoTypeBadge type={task.type} />
        <span className={styles.dropdownRowMain}>
          <span className={styles.dropdownRowTitle}>{name}</span>
          <KindTag kind={kind} dense />
        </span>
        <span className={styles.rowGoalEntry}>
          <GoalEntry
            kind={kind}
            aria-label={`Goal for ${name}`}
            value={goalText}
            onChange={(next) => setRowGoalText((m) => ({ ...m, [task.id]: next }))}
            placeholder="Goal"
            suffix={task.unit ?? undefined}
            invalid={goalText.trim() !== '' && !valid}
            onEnter={() => valid && handleCounterGoalPicked(task, goal!)}
            dense
          />
        </span>
        <button
          type="button"
          className={styles.rowPlusButton}
          aria-label={`Add ${name}`}
          disabled={!valid}
          onClick={() => valid && handleCounterGoalPicked(task, goal!)}
        >
          <RisoIcon name="plus" size={14} />
        </button>
      </div>
    );
  }

  async function handleSubmit(): Promise<void> {
    if (!canSubmit) return;
    if (onSubmitText !== undefined) {
      // Draft-only host: hand over the text, reset exactly like a create.
      onSubmitText(trimmed);
      updateText('');
      setPlaceholderIndex((i) => i + 1);
      inputRef.current?.focus();
      return;
    }
    setIsSubmitting(true);
    try {
      let newTask: Task;

      if (deferPersist) {
        // ── Deferred-persist path (Bug #85) ────────────────────────────────
        // Build the task fully in memory. The wizard writes it atomically
        // alongside the board row at final board-save. Matches the NORMAL
        // branch in useCreateFormState's deferred path.
        const now = currentTimestamp();
        newTask = {
          id: generateUUID(),
          userId,
          title: trimmed,
          type: TaskType.NORMAL,
          isCompleted: false,
          totalCompletions: 0,
          totalInstances: 0,
          createdAt: now,
          updatedAt: now,
          version: 1,
          isDeleted: false,
          timeframe: currentTimeframe,
          startDate: currentStartDate,
          endDate: currentEndDate,
          // Wizard-born: hidden from library-browse until the board goes
          // active. Mirrors iOS CreateFormViewModel deferred path.
          createdInWizard: true,
        };
        const payload: PendingTaskPayload = {
          task: newTask,
          childTasks: [],
          childLinks: [],
        };
        onTaskCreated(newTask);
        onPendingCreated!(payload);
      } else {
        // ── Immediate-persist path ──────────────────────────────────────────
        newTask = await createTask(userId, {
          title: trimmed,
          type: TaskType.NORMAL,
          timeframe: currentTimeframe,
          startDate: currentStartDate,
          endDate: currentEndDate,
        });
        onTaskCreated(newTask);
      }

      // Reset and rotate placeholder — keep focus for rapid entry.
      updateText('');
      setPlaceholderIndex((i) => i + 1);
      inputRef.current?.focus();
    } catch {
      // Swallow silently — same pattern as the iOS `RisoQuickAddRowView`
      // which relies on the DB throwing only on programming errors (not
      // transient network failures, since the DB is local-first). The
      // NewTaskSheet modal can be used as a fallback if the quick-add
      // ever hits an unrecoverable error.
    } finally {
      setIsSubmitting(false);
    }
  }

  function handleKeyDown(e: React.KeyboardEvent<HTMLInputElement>): void {
    if (e.key === 'Enter') {
      e.preventDefault();
      // Draft-only hosts (compound editors) sit inside an editor whose
      // ⌘↵ saves: an Enter on a row holding text must not also reach it,
      // or the save runs on the pre-append draft (whether the text appends
      // now or is still waiting on its goal / unit). An empty row still
      // lets ⌘↵ through to save. The wizard never passes `onSubmitText`.
      if (onSubmitText !== undefined && trimmed.length > 0) e.stopPropagation();
      void handleSubmit();
    }
  }

  return (
    <div className={styles.wrap}>
      <div className={styles.row}>
        <input
          ref={inputRef}
          type="text"
          className={styles.input}
          placeholder={placeholder}
          value={text}
          onChange={(e) => updateText(e.target.value)}
          onKeyDown={handleKeyDown}
          aria-label="New normal task title"
          autoComplete="off"
          spellCheck
          disabled={isSubmitting || disabled}
        />
        <RisoButton
          kind="primary"
          size="small"
          onClick={() => void handleSubmit()}
          disabled={!canSubmit}
          aria-label="Add task"
          style={{ opacity: canSubmit ? 1 : 0.45, pointerEvents: canSubmit ? undefined : 'none' }}
        >
          Add
        </RisoButton>
      </div>

      {/* Library-poll dropdown — OPTIONAL (only when `libraryTasks` +
          `onExistingTaskPicked` are both passed by the host). Mirrors the
          iOS `RisoCompoundFieldsView.subAutocompleteDropdown` precedent's
          shape; row style matches the pool sheet's library-reuse picker
          row (`RisoTypeBadge` + title + plus icon). */}
      {showDropdown && (
        <ul className={styles.dropdownList} aria-label="Matching library tasks">
          {libraryMatches.map((task) => (
            <li key={task.id} className={styles.dropdownItem}>
              {renderMatchRow(task)}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
