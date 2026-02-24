import { useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { OperatorType, TaskType, type CompositeTask, type Task } from '@oybc/shared';
import { db } from '../../db/database';
import { PLAYGROUND_USER_ID, SUCCESS_DISMISS_MS } from './playgroundUtils';
import { CountingStepFields } from './CountingStepFields';
import { ProgressStepRow, type StepFormState, createEmptyStep } from './ProgressStepRow';
import styles from './CompositeTaskForm.module.css';

/** Maximum character length for composite task title */
const TITLE_MAX_LENGTH = 200;

// ─── Local form types ─────────────────────────────────────────────────────────

type InlineTaskType = 'normal' | 'counting' | 'progress';

interface ExistingSubtaskItem {
  id: string;
  mode: 'existing';
  selectionType: 'task' | 'composite';
  selectedId: string;
}

interface InlineSubtaskItem {
  id: string;
  mode: 'inline';
  inlineType: InlineTaskType;
  title: string;
  // counting fields
  action: string;
  unit: string;
  maxCountStr: string;
  // progress fields
  steps: StepFormState[];
}

type SubtaskItem = ExistingSubtaskItem | InlineSubtaskItem;

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Generates an ISO8601 timestamp for the current moment.
 *
 * @returns ISO8601 string
 */
function currentTimestamp(): string {
  return new Date().toISOString();
}

/**
 * Returns CSS class for character count based on proximity to limit.
 *
 * @param current - Current character count
 * @param max - Maximum allowed characters
 * @returns CSS class string
 */
function getCharCountClass(current: number, max: number): string {
  if (current > max) return `${styles.charCount} ${styles.charCountError}`;
  if (current >= max * 0.9) return `${styles.charCount} ${styles.charCountWarning}`;
  return styles.charCount;
}

/**
 * Creates a new empty ExistingSubtaskItem with a stable form key.
 *
 * @returns A new ExistingSubtaskItem
 */
function createEmptyExistingSubtask(): ExistingSubtaskItem {
  return {
    id: crypto.randomUUID(),
    mode: 'existing',
    selectionType: 'task',
    selectedId: '',
  };
}

/**
 * Creates a new InlineSubtaskItem with a stable form key and default inline type.
 *
 * @returns A new InlineSubtaskItem
 */
function createEmptyInlineSubtask(): InlineSubtaskItem {
  return {
    id: crypto.randomUUID(),
    mode: 'inline',
    inlineType: 'normal',
    title: '',
    action: '',
    unit: '',
    maxCountStr: '',
    steps: [createEmptyStep()],
  };
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * CompositeTaskForm - Form for creating composite tasks with a flat subtask list.
 *
 * Replaces the recursive TreeNodeBuilder with a depth-1 flat subtask list.
 * Each subtask can reference an existing task or composite task, or create
 * a new task inline (normal, counting, or progress).
 */
export function CompositeTaskForm(): React.ReactElement {
  const [title, setTitle] = useState('');
  const [operator, setOperator] = useState<OperatorType>(OperatorType.AND);
  const [threshold, setThreshold] = useState(2);
  const [subtasks, setSubtasks] = useState<SubtaskItem[]>([]);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  // Reactive live queries
  const allTasks = useLiveQuery(
    () => db.tasks.filter((t) => t.userId === PLAYGROUND_USER_ID && !t.isDeleted).toArray()
  ) ?? [];

  const allCompositeTasks = useLiveQuery(
    () => db.compositeTasks.filter((ct) => ct.userId === PLAYGROUND_USER_ID && !ct.isDeleted).toArray()
  ) ?? [];


  /**
   * Resets the form to its initial empty state.
   */
  function resetForm(): void {
    setTitle('');
    setOperator(OperatorType.AND);
    setThreshold(2);
    setSubtasks([]);
    setErrorMessage(null);
  }

  // ─── Operator helpers ───────────────────────────────────────────────────────

  /**
   * Clamps threshold into [1, subtask count] after a change in subtask list.
   *
   * @param nextSubtasks - The updated subtask list
   * @param currentThreshold - The current threshold value
   * @returns The clamped threshold
   */
  function clampThreshold(nextSubtasks: SubtaskItem[], currentThreshold: number): number {
    const len = nextSubtasks.length;
    if (len === 0) return 1;
    return Math.min(Math.max(1, currentThreshold), len);
  }

  // ─── Subtask mutation helpers ───────────────────────────────────────────────

  function addExistingSubtask(): void {
    const next = [...subtasks, createEmptyExistingSubtask()];
    setSubtasks(next);
    setThreshold(clampThreshold(next, threshold));
  }

  function addInlineSubtask(): void {
    const next = [...subtasks, createEmptyInlineSubtask()];
    setSubtasks(next);
    setThreshold(clampThreshold(next, threshold));
  }

  function removeSubtask(id: string): void {
    const next = subtasks.filter((s) => s.id !== id);
    setSubtasks(next);
    setThreshold(clampThreshold(next, threshold));
  }

  function updateSubtask(id: string, updates: Partial<ExistingSubtaskItem> | Partial<InlineSubtaskItem>): void {
    setSubtasks((prev) =>
      prev.map((s) => (s.id === id ? ({ ...s, ...updates } as SubtaskItem) : s))
    );
  }

  function updateInlineStep(subtaskId: string, stepId: string, field: keyof StepFormState, value: string): void {
    setSubtasks((prev) =>
      prev.map((s) => {
        if (s.id !== subtaskId || s.mode !== 'inline') return s;
        return {
          ...s,
          steps: s.steps.map((step) =>
            step.id === stepId ? { ...step, [field]: value } : step
          ),
        };
      })
    );
  }

  function addStep(subtaskId: string): void {
    setSubtasks((prev) =>
      prev.map((s) => {
        if (s.id !== subtaskId || s.mode !== 'inline') return s;
        return { ...s, steps: [...s.steps, createEmptyStep()] };
      })
    );
  }

  function removeStep(subtaskId: string, stepId: string): void {
    setSubtasks((prev) =>
      prev.map((s) => {
        if (s.id !== subtaskId || s.mode !== 'inline') return s;
        return { ...s, steps: s.steps.filter((step) => step.id !== stepId) };
      })
    );
  }

  // ─── Selection helpers ──────────────────────────────────────────────────────

  /**
   * Returns already-selected IDs (task or composite) to exclude from dropdowns.
   *
   * @param currentId - The ID of the current subtask (excluded from its own dedup check)
   * @returns Set of already-selected IDs
   */
  function getSelectedIds(currentId: string): Set<string> {
    const ids = new Set<string>();
    for (const s of subtasks) {
      if (s.id !== currentId && s.mode === 'existing' && s.selectedId) {
        ids.add(s.selectedId);
      }
    }
    return ids;
  }

  /**
   * Determines selection type (task vs composite) from a selected ID.
   *
   * @param selectedId - The ID to look up
   * @returns 'task' | 'composite'
   */
  function inferSelectionType(selectedId: string): 'task' | 'composite' {
    if (allCompositeTasks.some((ct) => ct.id === selectedId)) return 'composite';
    return 'task';
  }

  // ─── Validation ─────────────────────────────────────────────────────────────

  /**
   * Validates the form and returns an error message, or null if valid.
   *
   * @returns string error or null
   */
  function validate(): string | null {
    const trimmedTitle = title.trim();
    if (trimmedTitle.length === 0) return 'Title is required';
    if (trimmedTitle.length > TITLE_MAX_LENGTH) return `Title must be ${TITLE_MAX_LENGTH} characters or less`;
    if (subtasks.length < 2) return 'At least 2 subtasks are required';

    // Dedup check for existing subtasks
    const existingIds = subtasks
      .filter((s): s is ExistingSubtaskItem => s.mode === 'existing')
      .map((s) => s.selectedId);
    const uniqueIds = new Set(existingIds);
    if (uniqueIds.size < existingIds.length) return 'Duplicate selections are not allowed';

    for (const s of subtasks) {
      if (s.mode === 'existing') {
        if (!s.selectedId) return 'All existing subtasks must have a selection';
      } else {
        if (s.inlineType !== 'counting' && s.title.trim().length === 0) {
          return 'All inline subtask titles are required';
        }
        if (s.inlineType === 'counting') {
          if (!s.action.trim()) return 'Counting subtask requires an action';
          if (!s.unit.trim()) return 'Counting subtask requires a unit';
          const count = parseInt(s.maxCountStr, 10);
          if (isNaN(count) || count < 1) return 'Counting subtask requires a max count of at least 1';
        }
        if (s.inlineType === 'progress' && s.steps.length === 0) {
          return 'Progress subtask requires at least one step';
        }
      }
    }

    if (operator === OperatorType.M_OF_N) {
      if (threshold < 1 || threshold > subtasks.length) {
        return `Threshold must be between 1 and ${subtasks.length}`;
      }
    }

    return null;
  }

  // ─── Submit ─────────────────────────────────────────────────────────────────

  /**
   * Handles form submission:
   * 1. Validates the form
   * 2. Creates any inline tasks
   * 3. Saves composite task + nodes in a single transaction
   * 4. Resets form and shows success message
   */
  async function handleSubmit(e: React.FormEvent): Promise<void> {
    e.preventDefault();
    const validationError = validate();
    if (validationError) {
      setErrorMessage(validationError);
      return;
    }

    setIsSubmitting(true);
    setErrorMessage(null);

    try {
      const now = currentTimestamp();
      const compositeTaskId = crypto.randomUUID();
      const rootNodeId = crypto.randomUUID();

      // Single atomic transaction: inline tasks + composite task + nodes
      const resolvedLeaves: Array<{ taskId?: string; childCompositeTaskId?: string }> = [];

      await db.transaction('rw', [db.tasks, db.taskSteps, db.compositeTasks, db.compositeNodes], async () => {
        // 1. Resolve subtasks — create inline tasks inside the transaction
        for (const subtask of subtasks) {
          if (subtask.mode === 'existing') {
            if (subtask.selectionType === 'task') {
              resolvedLeaves.push({ taskId: subtask.selectedId });
            } else {
              resolvedLeaves.push({ childCompositeTaskId: subtask.selectedId });
            }
          } else {
            // Create inline task
            const newTaskId = crypto.randomUUID();

            if (subtask.inlineType === 'normal') {
              await db.tasks.add({
                id: newTaskId,
                userId: PLAYGROUND_USER_ID,
                title: subtask.title.trim(),
                type: TaskType.NORMAL,
                totalCompletions: 0,
                totalInstances: 0,
                createdAt: now,
                updatedAt: now,
                version: 1,
                isDeleted: false,
              });
            } else if (subtask.inlineType === 'counting') {
              await db.tasks.add({
                id: newTaskId,
                userId: PLAYGROUND_USER_ID,
                title: subtask.title.trim() || `${subtask.action.trim()} ${parseInt(subtask.maxCountStr, 10)} ${subtask.unit.trim()}`,
                type: TaskType.COUNTING,
                action: subtask.action.trim(),
                unit: subtask.unit.trim(),
                maxCount: parseInt(subtask.maxCountStr, 10),
                totalCompletions: 0,
                totalInstances: 0,
                createdAt: now,
                updatedAt: now,
                version: 1,
                isDeleted: false,
              });
            } else {
              // progress
              await db.tasks.add({
                id: newTaskId,
                userId: PLAYGROUND_USER_ID,
                title: subtask.title.trim(),
                type: TaskType.PROGRESS,
                totalCompletions: 0,
                totalInstances: 0,
                createdAt: now,
                updatedAt: now,
                version: 1,
                isDeleted: false,
              });
              for (let i = 0; i < subtask.steps.length; i++) {
                const step = subtask.steps[i];
                await db.taskSteps.add({
                  id: crypto.randomUUID(),
                  taskId: newTaskId,
                  stepIndex: i,
                  title: step.title.trim(),
                  type: step.type === 'counting' ? TaskType.COUNTING : TaskType.NORMAL,
                  action: step.type === 'counting' ? step.action.trim() || undefined : undefined,
                  unit: step.type === 'counting' ? step.unit.trim() || undefined : undefined,
                  maxCount: step.type === 'counting' ? parseInt(step.maxCount, 10) || undefined : undefined,
                  createdAt: now,
                  updatedAt: now,
                  version: 1,
                  isDeleted: false,
                });
              }
            }

            resolvedLeaves.push({ taskId: newTaskId });
          }
        }

        // 2. Composite task record first (nodes FK to this)
        await db.compositeTasks.add({
          id: compositeTaskId,
          userId: PLAYGROUND_USER_ID,
          title: title.trim(),
          description: undefined,
          rootNodeId,
          createdAt: now,
          updatedAt: now,
          version: 1,
          isDeleted: false,
        });

        // 3. Root operator node
        await db.compositeNodes.add({
          id: rootNodeId,
          compositeTaskId,
          parentNodeId: undefined,
          nodeIndex: 0,
          nodeType: 'operator',
          operatorType: operator,
          threshold: operator === OperatorType.M_OF_N ? threshold : undefined,
          taskId: undefined,
          childCompositeTaskId: undefined,
          createdAt: now,
          updatedAt: now,
          version: 1,
          isDeleted: false,
        });

        // 4. Leaf nodes
        for (let i = 0; i < resolvedLeaves.length; i++) {
          await db.compositeNodes.add({
            id: crypto.randomUUID(),
            compositeTaskId,
            parentNodeId: rootNodeId,
            nodeIndex: i,
            nodeType: 'leaf',
            operatorType: undefined,
            threshold: undefined,
            taskId: resolvedLeaves[i].taskId,
            childCompositeTaskId: resolvedLeaves[i].childCompositeTaskId,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false,
          });
        }
      });

      setSuccessMessage('Composite task created!');
      resetForm();
      setTimeout(() => setSuccessMessage(null), SUCCESS_DISMISS_MS);
    } catch (err) {
      setErrorMessage(`Failed: ${err instanceof Error ? err.message : String(err)}`);
    } finally {
      setIsSubmitting(false);
    }
  }

  // ─── Render helpers ─────────────────────────────────────────────────────────

  /**
   * Renders a single subtask card.
   *
   * @param subtask - The subtask item to render
   * @returns JSX element for the subtask card
   */
  function renderSubtask(subtask: SubtaskItem): React.ReactElement {
    const selectedIds = getSelectedIds(subtask.id);

    return (
      <div key={subtask.id} className={styles.subtaskCard}>
        <div className={styles.subtaskCardHeader}>
          <span className={styles.subtaskCardLabel}>
            {subtask.mode === 'existing' ? 'Existing' : 'New Inline Task'}
          </span>
          <button
            type="button"
            className={styles.removeSubtaskButton}
            onClick={() => removeSubtask(subtask.id)}
          >
            Remove
          </button>
        </div>

        {subtask.mode === 'existing' ? (
          <div className={styles.fieldGroup}>
            <label className={styles.label} htmlFor={`subtask-select-${subtask.id}`}>
              Select task or composite task<span className={styles.required}>*</span>
            </label>
            <select
              id={`subtask-select-${subtask.id}`}
              className={styles.selectInput}
              value={subtask.selectedId}
              onChange={(e) => {
                const selectedId = e.target.value;
                updateSubtask(subtask.id, {
                  selectedId,
                  selectionType: inferSelectionType(selectedId),
                });
              }}
            >
              <option value="">— Select —</option>
              {allTasks.filter((t: Task) => !selectedIds.has(t.id)).length > 0 && (
                <optgroup label="Tasks">
                  {allTasks
                    .filter((t: Task) => !selectedIds.has(t.id))
                    .map((t: Task) => (
                      <option key={t.id} value={t.id}>
                        {t.title} ({t.type})
                      </option>
                    ))}
                </optgroup>
              )}
              {allCompositeTasks.filter((ct: CompositeTask) => !selectedIds.has(ct.id)).length > 0 && (
                <optgroup label="Composite Tasks">
                  {allCompositeTasks
                    .filter((ct: CompositeTask) => !selectedIds.has(ct.id))
                    .map((ct: CompositeTask) => (
                      <option key={ct.id} value={ct.id}>
                        {ct.title}
                      </option>
                    ))}
                </optgroup>
              )}
            </select>
            {subtask.selectedId && (
              <span className={styles.selectionBadge}>
                {subtask.selectionType === 'composite' ? 'Composite Task' : 'Task'}
              </span>
            )}
          </div>
        ) : (
          <div className={styles.inlineTaskFields}>
            {/* Inline type picker */}
            <div className={styles.inlineTypePicker}>
              {(['normal', 'counting', 'progress'] as InlineTaskType[]).map((type) => (
                <button
                  key={type}
                  type="button"
                  className={`${styles.inlineTypeButton} ${subtask.inlineType === type ? styles.inlineTypeButtonActive : ''}`}
                  onClick={() => updateSubtask(subtask.id, { inlineType: type })}
                >
                  {type.charAt(0).toUpperCase() + type.slice(1)}
                </button>
              ))}
            </div>

            {/* Title (required for normal + progress; optional auto-label for counting) */}
            <div className={styles.fieldGroup}>
              <label className={styles.label} htmlFor={`subtask-title-${subtask.id}`}>
                Title
                {subtask.inlineType !== 'counting' && <span className={styles.required}>*</span>}
                {subtask.inlineType === 'counting' && (
                  <span className={styles.optionalHint}> (auto-generated if blank)</span>
                )}
              </label>
              <input
                id={`subtask-title-${subtask.id}`}
                type="text"
                className={styles.titleInput}
                value={subtask.title}
                onChange={(e) => updateSubtask(subtask.id, { title: e.target.value })}
                placeholder="Enter task title"
                maxLength={TITLE_MAX_LENGTH + 1}
              />
            </div>

            {/* Counting fields */}
            {subtask.inlineType === 'counting' && (
              <CountingStepFields
                idPrefix={`subtask-${subtask.id}`}
                action={subtask.action}
                maxCount={subtask.maxCountStr}
                unit={subtask.unit}
                onChange={(field, value) => {
                  if (field === 'action') updateSubtask(subtask.id, { action: value });
                  else if (field === 'unit') updateSubtask(subtask.id, { unit: value });
                  else if (field === 'maxCount') updateSubtask(subtask.id, { maxCountStr: value });
                }}
              />
            )}

            {/* Progress step rows */}
            {subtask.inlineType === 'progress' && (
              <div className={styles.stepsContainer}>
                <span className={styles.stepsLabel}>Steps</span>
                {subtask.steps.map((step, idx) => (
                  <ProgressStepRow
                    key={step.id}
                    index={idx}
                    idPrefix={`subtask-${subtask.id}-step-${step.id}`}
                    step={step}
                    canRemove={subtask.steps.length > 1}
                    onFieldChange={(field, value) => updateInlineStep(subtask.id, step.id, field, value)}
                    onRemove={() => removeStep(subtask.id, step.id)}
                  />
                ))}
                <button
                  type="button"
                  className={styles.addStepButton}
                  onClick={() => addStep(subtask.id)}
                >
                  + Add step
                </button>
              </div>
            )}
          </div>
        )}
      </div>
    );
  }

  // ─── JSX ────────────────────────────────────────────────────────────────────

  return (
    <div className={styles.container}>
      <form className={styles.form} onSubmit={handleSubmit}>
        {/* Title */}
        <div className={styles.fieldGroup}>
          <label className={styles.label} htmlFor="composite-task-title">
            Title<span className={styles.required}>*</span>
          </label>
          <input
            id="composite-task-title"
            type="text"
            className={styles.titleInput}
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder="Enter composite task title"
            maxLength={TITLE_MAX_LENGTH + 1}
          />
          <span className={getCharCountClass(title.length, TITLE_MAX_LENGTH)}>
            {title.length}/{TITLE_MAX_LENGTH}
          </span>
        </div>

        {/* Operator selector */}
        <div className={styles.fieldGroup}>
          <span className={styles.label}>Completion rule</span>
          <div className={styles.operatorPicker}>
            <button
              type="button"
              className={`${styles.operatorButton} ${operator === OperatorType.AND ? styles.operatorButtonActive : ''}`}
              onClick={() => setOperator(OperatorType.AND)}
            >
              All of
            </button>
            <button
              type="button"
              className={`${styles.operatorButton} ${operator === OperatorType.OR ? styles.operatorButtonActive : ''}`}
              onClick={() => setOperator(OperatorType.OR)}
            >
              Any of
            </button>
            <button
              type="button"
              className={`${styles.operatorButton} ${operator === OperatorType.M_OF_N ? styles.operatorButtonActive : ''}`}
              onClick={() => setOperator(OperatorType.M_OF_N)}
            >
              At least N of
            </button>
          </div>

          {operator === OperatorType.M_OF_N && (
            <div className={styles.thresholdRow}>
              <button
                type="button"
                className={styles.stepperButton}
                onClick={() => setThreshold((t) => Math.max(1, t - 1))}
                disabled={threshold <= 1}
              >
                −
              </button>
              <span className={styles.thresholdValue}>{threshold}</span>
              <button
                type="button"
                className={styles.stepperButton}
                onClick={() => setThreshold((t) => Math.min(subtasks.length, t + 1))}
                disabled={threshold >= subtasks.length}
              >
                +
              </button>
              <span className={styles.thresholdLabel}>
                of {subtasks.length} subtask{subtasks.length !== 1 ? 's' : ''}
              </span>
            </div>
          )}
        </div>

        {/* Subtask list */}
        <div className={styles.subtaskList}>
          {subtasks.map(renderSubtask)}
        </div>

        {/* Add buttons */}
        <div className={styles.addButtonRow}>
          <button
            type="button"
            className={styles.addButton}
            onClick={addExistingSubtask}
          >
            + Add existing task
          </button>
          <button
            type="button"
            className={styles.addButton}
            onClick={addInlineSubtask}
          >
            + Create new task
          </button>
        </div>

        {/* Error message */}
        {errorMessage && (
          <div className={styles.errorMessage}>{errorMessage}</div>
        )}

        {/* Submit */}
        <button
          type="submit"
          className={styles.submitButton}
          disabled={isSubmitting}
        >
          {isSubmitting ? 'Creating...' : 'Create Composite Task'}
        </button>
      </form>

      {/* Success Message */}
      {successMessage && (
        <div className={styles.successMessage}>{successMessage}</div>
      )}

    </div>
  );
}
