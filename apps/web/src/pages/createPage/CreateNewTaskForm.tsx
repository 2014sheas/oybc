import { useEffect, useMemo, useState } from 'react';
import {
  AchievementTrigger,
  TaskType,
  findLinkableCounter,
  generateCounterTaskTitle,
  type Board,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import { TaskTypeSelector } from '../../components/TaskTypeSelector';
import { CompoundTaskWizard } from '../../components/compoundWizard/CompoundTaskWizard';
import {
  CountingTemplatePicker,
  type LinkedCounterInput,
} from '../../components/wizard/CountingTemplatePicker';
import { useBoards, useRecurringBoardTemplates, useTasks } from '../../hooks';
import { getCharCountClass } from '../../components/playground/playgroundUtils';
import {
  type UseCreateFormState,
  TITLE_MAX_LENGTH,
  DESCRIPTION_MAX_LENGTH,
  ACTION_MAX_LENGTH,
  UNIT_MAX_LENGTH,
} from './useCreateFormState';
import styles from './CreateNewTaskForm.module.css';

// Stable empty fallback for `?? FALLBACK` — see BoardPlayPage.tsx for
// rationale (a fresh `[]` literal on every render defeats useMemo below).
const EMPTY_TASKS = Object.freeze([]) as unknown as Task[];

const TASK_TYPES: { value: TaskType; label: string }[] = [
  { value: TaskType.NORMAL, label: 'Normal' },
  { value: TaskType.COUNTING, label: 'Counting' },
  // Compound opens the wizard (operator + children chosen there).
  { value: TaskType.COMPOUND, label: 'Compound' },
  // Phase 6.3 — Achievement (cross-board watcher).
  { value: TaskType.ACHIEVEMENT, label: 'Achievement' },
];

/**
 * Renders the "Create New" tab: the type selector, per-type form
 * fields, progress steps, and the submit button. Compound selection
 * swaps to `CompoundTaskWizard` (owns its own state). All other state
 * comes from `useCreateFormState` via the `form` prop.
 *
 * Kept as a pure presentation component — no data-layer calls, no
 * DB imports (the `useTasks` live-query hook is fine — it's the same
 * boundary `CountingTemplatePicker`'s `useTaskLibrary` already crosses;
 * neither reaches for a raw Dexie import).
 *
 * The `onCompositeCreated` callback lets the parent decide what to do
 * when a compound is built (typically: flash a success toast directing
 * the user to the Existing Tasks tab).
 */
export interface CreateNewTaskFormProps {
  form: UseCreateFormState;
  userId: string | undefined;
  /** Called with the newly-created compound Task when the user finishes the wizard. */
  onCompositeCreated: (task: Task) => void;
  /** Label for the submit button. Defaults to the legacy pool-flow wording. */
  submitLabel?: string;
  /**
   * R1 counters refresh — called instead of `form.handleSubmit` when the
   * counting-task submit auto-links to a matched counter (exact (verb,
   * noun) pair match, not opted out via "Don't link"). When omitted, the
   * form falls back to a plain (unlinked) create even when a match exists
   * — useful for contexts where linked-counter creation isn't wired yet.
   */
  onCreateLinked?: (input: LinkedCounterInput) => void;
  /**
   * R1 counters refresh (review fix) — unfiltered task pool (persisted +
   * the wizard session's in-memory pending tasks) used only for the
   * counter-link auto-link match. Without this, a counting task created
   * earlier in the same wizard visit (still pending, not yet in `useTasks`)
   * wouldn't be linkable — a same-pair follow-up create would silently
   * duplicate instead of linking (iOS already merges pending tasks into its
   * match pool via `effectiveSuggestionPool`). Defaults to the live
   * `useTasks` pool when omitted (non-wizard hosts, e.g. Tasks-tab), so
   * behavior there is unchanged.
   */
  suggestionPool?: Task[];
}

export function CreateNewTaskForm({
  form,
  userId,
  onCompositeCreated,
  submitLabel = 'Create & Add to Pool',
  onCreateLinked,
  suggestionPool,
}: CreateNewTaskFormProps): React.ReactElement {
  // Phase 6.3 — Workspace lookups for the Achievement-task picker.
  // Both hooks return non-deleted rows for `userId` (or `[]` while
  // auth is loading); the dropdowns render the empty state below
  // when neither list has eligible entries.
  const boards: Board[] = useBoards(userId) ?? [];
  const templates: RecurringBoardTemplate[] = useRecurringBoardTemplates(userId) ?? [];

  // R1 counters refresh — auto-link. `tasks` feeds `findLinkableCounter`
  // (needs the full live pool, same source CountingTemplatePicker's own
  // `useTaskLibrary` reads) and resolves the matched source Task at submit
  // time for `LinkedCounterInput.source`.
  //
  // `suggestionPool` (wizard callers only) additionally merges in this
  // session's pending tasks — falls back to the plain live `tasks` pool
  // when omitted (e.g. Tasks-tab standalone usage) so behavior there is
  // unchanged.
  const tasks = useTasks(userId) ?? EMPTY_TASKS;
  const matchPool = suggestionPool ?? tasks;
  const trimmedAction = form.action.trim();
  const trimmedUnit = form.unit.trim();
  const parsedMaxCount = parseInt(form.maxCountStr, 10);
  const goalValid = Number.isInteger(parsedMaxCount) && parsedMaxCount > 0;

  // "Don't link" opt-out for the current (verb, noun) pair. Resets whenever
  // the pair changes so a fresh pair always starts linked (mirrors the
  // retired suggestion card's per-pair dismiss reset).
  const [linkDisabled, setLinkDisabled] = useState(false);
  useEffect(() => {
    setLinkDisabled(false);
  }, [trimmedAction, trimmedUnit]);

  const counterMatch = useMemo(
    () =>
      form.taskType === TaskType.COUNTING && trimmedAction && trimmedUnit
        ? findLinkableCounter({ action: trimmedAction, unit: trimmedUnit }, matchPool)
        : null,
    [form.taskType, trimmedAction, trimmedUnit, matchPool],
  );

  // Gate on `onCreateLinked` too — without it, submit can't actually honor
  // the link (see `handleFormSubmit`), so the hint must stay hidden rather
  // than promise a linking behavior the caller didn't wire up.
  const linkHint =
    counterMatch && goalValid && onCreateLinked
      ? {
          match: counterMatch,
          goal: parsedMaxCount,
          linked: !linkDisabled,
          onToggle: () => setLinkDisabled((prev) => !prev),
        }
      : null;

  /**
   * Intercepts the native form submit for the auto-link case: when a
   * counting-task create matches an existing counter and hasn't been
   * opted out of, route through `onCreateLinked` (start-fresh baseline —
   * R1's only auto-link mode) instead of `form.handleSubmit`'s plain
   * (unlinked) create. Every other case — including an invalid/blank goal,
   * which `form.handleSubmit`'s own validation already surfaces as a field
   * error — falls through unchanged.
   */
  function handleFormSubmit(e: React.FormEvent): void {
    if (
      form.taskType === TaskType.COUNTING &&
      onCreateLinked &&
      counterMatch &&
      !linkDisabled &&
      goalValid
    ) {
      e.preventDefault();
      const sourceTask = matchPool.find((t) => t.id === counterMatch.counterId);
      if (!sourceTask) {
        // Match resolved from a stale snapshot (e.g. the source was deleted
        // between keystrokes) — fall back to a plain create rather than
        // silently dropping the submit.
        void form.handleSubmit(e);
        return;
      }
      const finalTitle =
        form.title.trim() || generateCounterTaskTitle(trimmedAction, parsedMaxCount, trimmedUnit);
      onCreateLinked({
        source: sourceTask,
        maxCount: parsedMaxCount,
        title: finalTitle,
        baselineMode: 'startFromZero',
        baseline: counterMatch.lifetime,
      });
      return;
    }
    void form.handleSubmit(e);
  }

  return (
    <div className={styles.modeSection}>
      <div className={styles.fieldGroup}>
        <label className={styles.label}>
          Type<span className={styles.required}>*</span>
        </label>
        <TaskTypeSelector
          types={TASK_TYPES}
          selectedType={form.taskType}
          onTypeChange={(value) => form.handleTypeChange(value as TaskType)}
        />
      </div>

      {form.taskType === TaskType.COMPOUND ? (
        <CompoundTaskWizard userId={userId} onCreated={onCompositeCreated} />
      ) : (
        <form className={styles.form} onSubmit={handleFormSubmit}>
          {/* Title */}
          <div className={styles.fieldGroup}>
            <label className={styles.label} htmlFor="create-task-title">
              Title
              {form.taskType !== TaskType.COUNTING && <span className={styles.required}>*</span>}
            </label>
            <input
              id="create-task-title"
              type="text"
              className={`${styles.input} ${form.errors.title ? styles.inputError : ''}`}
              value={form.title}
              onChange={(e) => form.setTitle(e.target.value)}
              placeholder={
                form.taskType === TaskType.COUNTING
                  ? 'Auto-generated if blank (e.g., "Run 26 miles")'
                  : 'Enter task title'
              }
              maxLength={TITLE_MAX_LENGTH + 1}
            />
            <span className={getCharCountClass(form.title.length, TITLE_MAX_LENGTH, styles)}>
              {form.title.length}/{TITLE_MAX_LENGTH}
            </span>
            {form.errors.title && <span className={styles.fieldError}>{form.errors.title}</span>}
          </div>

          {/* Description */}
          <div className={styles.fieldGroup}>
            <label className={styles.label} htmlFor="create-task-description">
              Description
            </label>
            <textarea
              id="create-task-description"
              className={`${styles.input} ${styles.textarea} ${form.errors.description ? styles.inputError : ''}`}
              value={form.description}
              onChange={(e) => form.setDescription(e.target.value)}
              placeholder="Enter task description (optional)"
              maxLength={DESCRIPTION_MAX_LENGTH + 1}
            />
            <span className={getCharCountClass(form.description.length, DESCRIPTION_MAX_LENGTH, styles)}>
              {form.description.length}/{DESCRIPTION_MAX_LENGTH}
            </span>
            {form.errors.description && <span className={styles.fieldError}>{form.errors.description}</span>}
          </div>

          {/* Achievement-task fields (Phase 6.3) */}
          {form.taskType === TaskType.ACHIEVEMENT && (
            <div className={styles.fieldGroup}>
              {/* Explains what makes an Achievement square different: you place
                  it on a board like any square, but it completes itself when the
                  board/template it watches hits the trigger, not by check-off. */}
              <span className={`${styles.helpText} ${styles.helpTextLead}`}>
                An Achievement is an auto-completing square: place it on a board,
                and it completes on its own when the board or repeating board you
                pick below reaches the trigger — instead of you checking it off.
              </span>
              <label className={styles.label}>
                Watch
                <span className={styles.required}>*</span>
              </label>
              <div className={styles.modeSection}>
                <label className={styles.label} style={{ display: 'inline-flex', gap: '0.5rem', alignItems: 'center', marginRight: '1rem', fontWeight: 'normal' }}>
                  <input
                    type="radio"
                    name="create-task-achievement-mode"
                    value="specificBoard"
                    checked={form.achievementMode === 'specificBoard'}
                    onChange={() => form.setAchievementMode('specificBoard')}
                  />
                  Board
                </label>
                <label className={styles.label} style={{ display: 'inline-flex', gap: '0.5rem', alignItems: 'center', fontWeight: 'normal' }}>
                  <input
                    type="radio"
                    name="create-task-achievement-mode"
                    value="recurringTemplate"
                    checked={form.achievementMode === 'recurringTemplate'}
                    onChange={() => form.setAchievementMode('recurringTemplate')}
                  />
                  Repeating board
                </label>
              </div>
              {form.achievementMode === 'specificBoard' ? (
                <select
                  id="create-task-ach-board"
                  className={`${styles.input} ${form.errors.achievementReference ? styles.inputError : ''}`}
                  value={form.achievementReferenceId ?? ''}
                  onChange={(e) =>
                    form.setAchievementReferenceId(e.target.value || null)
                  }
                >
                  <option value="">
                    {boards.length === 0
                      ? 'No boards'
                      : 'Select a board…'}
                  </option>
                  {boards.map((b) => (
                    <option key={b.id} value={b.id}>
                      {b.name}
                    </option>
                  ))}
                </select>
              ) : (
                <select
                  id="create-task-ach-template"
                  className={`${styles.input} ${form.errors.achievementReference ? styles.inputError : ''}`}
                  value={form.achievementReferenceId ?? ''}
                  onChange={(e) =>
                    form.setAchievementReferenceId(e.target.value || null)
                  }
                >
                  <option value="">
                    {templates.length === 0
                      ? 'No repeating boards yet'
                      : 'Select a repeating board…'}
                  </option>
                  {templates.map((t) => (
                    <option key={t.id} value={t.id}>
                      {t.name}
                      {!t.isActive ? ' (paused)' : ''}
                    </option>
                  ))}
                </select>
              )}
              {form.errors.achievementReference && (
                <span className={styles.fieldError}>{form.errors.achievementReference}</span>
              )}

              {/* Trigger picker (Phase 6.3). Domain terms verbatim:
                  "Greenlog" / "Bingo". Default GREENLOG matches the
                  pre-trigger shipped behavior. */}
              <label className={styles.label} style={{ marginTop: '0.75rem' }}>
                Trigger
              </label>
              <div className={styles.modeSection}>
                <label className={styles.label} style={{ display: 'inline-flex', gap: '0.5rem', alignItems: 'center', marginRight: '1rem', fontWeight: 'normal' }}>
                  <input
                    type="radio"
                    name="create-task-achievement-trigger"
                    value={AchievementTrigger.GREENLOG}
                    checked={form.achievementTrigger === AchievementTrigger.GREENLOG}
                    onChange={() => form.setAchievementTrigger(AchievementTrigger.GREENLOG)}
                  />
                  Greenlog
                </label>
                <label className={styles.label} style={{ display: 'inline-flex', gap: '0.5rem', alignItems: 'center', fontWeight: 'normal' }}>
                  <input
                    type="radio"
                    name="create-task-achievement-trigger"
                    value={AchievementTrigger.BINGO}
                    checked={form.achievementTrigger === AchievementTrigger.BINGO}
                    onChange={() => form.setAchievementTrigger(AchievementTrigger.BINGO)}
                  />
                  Bingo
                </label>
              </div>
              <span className={styles.helpText}>
                Greenlog — the whole board is completed. Bingo — any single line
                (row, column, or diagonal).
              </span>

              {/* Count input (template mode only). Specific-board mode
                  is implicitly count=1. */}
              {form.achievementMode === 'recurringTemplate' && (
                <>
                  <label className={styles.label} htmlFor="create-task-ach-count" style={{ marginTop: '0.75rem' }}>
                    Count
                    <span className={styles.required}>*</span>
                  </label>
                  <input
                    id="create-task-ach-count"
                    type="number"
                    min="1"
                    step="1"
                    inputMode="numeric"
                    className={`${styles.input} ${form.errors.requiredCount ? styles.inputError : ''}`}
                    value={form.achievementRequiredCountStr}
                    onChange={(e) => form.setAchievementRequiredCountStr(e.target.value)}
                    placeholder="e.g. 3"
                  />
                  {form.errors.requiredCount && (
                    <span className={styles.fieldError}>{form.errors.requiredCount}</span>
                  )}
                </>
              )}
            </div>
          )}

          {/* Counting fields */}
          {form.taskType === TaskType.COUNTING && (
            <div className={styles.countingFields}>
              {/* "Derive from existing" affordance + auto-link hint — only
                 when userId is resolved. Rendering with `userId === undefined`
                 shows a stale "No counting tasks yet" empty-state during
                 auth load. */}
              {userId != null && (
                <CountingTemplatePicker
                  userId={userId}
                  selectedTemplate={form.deriveFromTask}
                  onSelect={form.applyTemplate}
                  onClear={form.clearTemplate}
                  linkHint={linkHint}
                />
              )}

              <div className={styles.fieldGroup}>
                <label className={styles.label} htmlFor="create-task-action">
                  Verb<span className={styles.required}>*</span>
                </label>
                <input
                  id="create-task-action"
                  type="text"
                  className={`${styles.input} ${form.errors.action ? styles.inputError : ''}`}
                  value={form.action}
                  onChange={(e) => form.setAction(e.target.value)}
                  placeholder="Do"
                  maxLength={ACTION_MAX_LENGTH}
                />
                {form.errors.action && <span className={styles.fieldError}>{form.errors.action}</span>}
              </div>

              <div className={styles.fieldGroup}>
                <label className={styles.label} htmlFor="create-task-maxcount">
                  Goal<span className={styles.required}>*</span>
                </label>
                <input
                  id="create-task-maxcount"
                  type="number"
                  className={`${styles.input} ${form.errors.maxCount ? styles.inputError : ''}`}
                  value={form.maxCountStr}
                  onChange={(e) => form.setMaxCountStr(e.target.value)}
                  placeholder="100"
                  min="1"
                />
                {form.errors.maxCount && <span className={styles.fieldError}>{form.errors.maxCount}</span>}
              </div>

              <div className={styles.fieldGroup}>
                <label className={styles.label} htmlFor="create-task-unit">
                  Counting<span className={styles.required}>*</span>
                </label>
                <input
                  id="create-task-unit"
                  type="text"
                  className={`${styles.input} ${form.errors.unit ? styles.inputError : ''}`}
                  value={form.unit}
                  onChange={(e) => form.setUnit(e.target.value)}
                  placeholder="push-ups"
                  maxLength={UNIT_MAX_LENGTH}
                />
                {form.errors.unit && <span className={styles.fieldError}>{form.errors.unit}</span>}
              </div>

              {goalValid && trimmedAction && trimmedUnit && (
                <div className={styles.titlePreview}>
                  Title:{' '}
                  <strong>{generateCounterTaskTitle(trimmedAction, parsedMaxCount, trimmedUnit)}</strong>
                </div>
              )}
            </div>
          )}

          {form.errors.general && <div className={styles.errorMessage}>{form.errors.general}</div>}

          <button type="submit" className={styles.submitButton} disabled={form.isSubmitting}>
            {form.isSubmitting ? 'Creating...' : submitLabel}
          </button>
        </form>
      )}
    </div>
  );
}
