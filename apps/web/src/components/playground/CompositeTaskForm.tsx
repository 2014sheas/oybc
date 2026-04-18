import { useMemo, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { OperatorType, TaskType, generateCounterTaskTitle, type CompositeTask } from '@oybc/shared';
import { db } from '../../db/database';
import { OperatorSelector } from '../OperatorSelector';
import { CounterStepper } from '../CounterStepper';
import { PLAYGROUND_USER_ID, SUCCESS_DISMISS_MS, getCharCountClass } from './playgroundUtils';
import { type StepFormState, createEmptyStep } from '../progressStepUtils';
import { SubtaskCard } from '../compositeWizard/SubtaskCard';
import {
  type SubtaskDraft,
  type ExistingSubtaskDraft,
  type InlineSubtaskDraft,
} from '../compositeWizard/compositeSubtaskDraft';
import styles from './CompositeTaskForm.module.css';

/** Maximum character length for composite task title */
const TITLE_MAX_LENGTH = 200;

// ─── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Generates an ISO8601 timestamp for the current moment.
 *
 * @returns ISO8601 string
 */
function currentTimestamp(): string {
  return new Date().toISOString();
}


/** Creates a new empty existing-mode subtask draft. */
function createEmptyExistingSubtask(): ExistingSubtaskDraft {
  return {
    id: crypto.randomUUID(),
    mode: 'existing',
    selectionType: 'task',
    selectedId: '',
  };
}

/** Creates a new inline-mode subtask draft, defaulted to a Normal task. */
function createEmptyInlineSubtask(): InlineSubtaskDraft {
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
interface CompositeTaskFormProps {
  /** User ID for task ownership. Defaults to playground user when omitted. */
  userId?: string;
  /** Optional callback invoked with the newly created CompositeTask after successful creation */
  onCreated?: (compositeTask: CompositeTask) => void;
}

export function CompositeTaskForm({ userId, onCreated }: CompositeTaskFormProps = {}): React.ReactElement {
  const resolvedUserId = userId ?? PLAYGROUND_USER_ID;
  const [title, setTitle] = useState('');
  const [operator, setOperator] = useState<OperatorType>(OperatorType.AND);
  const [threshold, setThreshold] = useState(2);
  const [subtasks, setSubtasks] = useState<SubtaskDraft[]>([]);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  // Reactive live queries — deps on resolvedUserId so queries refetch when
  // auth loads after initial render.
  const allTasks = useLiveQuery(
    () =>
      db.tasks
        .where('[userId+isDeleted]')
        .equals([resolvedUserId, 0])
        .toArray(),
    [resolvedUserId]
  ) ?? [];

  const allCompositeTasks = useLiveQuery(
    () =>
      db.compositeTasks
        .where('[userId+isDeleted]')
        .equals([resolvedUserId, 0])
        .toArray(),
    [resolvedUserId]
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
  function clampThreshold(nextSubtasks: SubtaskDraft[], currentThreshold: number): number {
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

  function updateSubtask(id: string, updates: Partial<SubtaskDraft>): void {
    setSubtasks((prev) =>
      prev.map((s) => (s.id === id ? ({ ...s, ...updates } as SubtaskDraft) : s))
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

  /** Ids picked by any existing-mode card, memoised for cheap filtering in
   *  every card's dropdown. Only non-empty selections contribute. */
  const allSelectedIds = useMemo(() => {
    const ids = new Set<string>();
    for (const s of subtasks) {
      if (s.mode === 'existing' && s.selectedId) ids.add(s.selectedId);
    }
    return ids;
  }, [subtasks]);

  /** Ids OTHER than the current card — the card excludes its own selected
   *  id so the chosen option doesn't vanish from its own dropdown. */
  function excludedIdsForCard(cardId: string): Set<string> {
    const ids = new Set<string>();
    for (const s of subtasks) {
      if (s.id !== cardId && s.mode === 'existing' && s.selectedId) {
        ids.add(s.selectedId);
      }
    }
    return ids;
  }

  // `allSelectedIds` is kept available for future duplicate-detection UX
  // (e.g. banner messaging); the card-level filter already blocks dup
  // selections at source.
  void allSelectedIds;

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
      .filter((s): s is ExistingSubtaskDraft => s.mode === 'existing')
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
                userId: resolvedUserId,
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
                userId: resolvedUserId,
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
                userId: resolvedUserId,
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
                const stepType = step.type === 'counting' ? TaskType.COUNTING : TaskType.NORMAL;
                const trimmedStepTitle = step.title.trim();
                const trimmedAction = step.type === 'counting' ? step.action.trim() : '';
                const trimmedUnit = step.type === 'counting' ? step.unit.trim() : '';
                const stepMaxCount = step.type === 'counting' ? parseInt(step.maxCount, 10) : undefined;
                // Resolve title: for counting steps with blank title, auto-generate
                const resolvedStepTitle = step.type === 'counting' && !trimmedStepTitle
                  ? generateCounterTaskTitle(trimmedAction, stepMaxCount!, trimmedUnit)
                  : trimmedStepTitle;
                // Create standalone task for each step (matches createTask behavior)
                const stepTaskId = crypto.randomUUID();
                await db.tasks.add({
                  id: stepTaskId,
                  userId: resolvedUserId,
                  title: resolvedStepTitle,
                  type: stepType,
                  action: step.type === 'counting' ? step.action.trim() || undefined : undefined,
                  unit: step.type === 'counting' ? step.unit.trim() || undefined : undefined,
                  maxCount: step.type === 'counting' ? parseInt(step.maxCount, 10) || undefined : undefined,
                  totalCompletions: 0,
                  totalInstances: 0,
                  createdAt: now,
                  updatedAt: now,
                  version: 1,
                  isDeleted: false,
                });
                await db.taskSteps.add({
                  id: crypto.randomUUID(),
                  taskId: newTaskId,
                  stepIndex: i,
                  title: resolvedStepTitle,
                  type: stepType,
                  action: step.type === 'counting' ? trimmedAction || undefined : undefined,
                  unit: step.type === 'counting' ? trimmedUnit || undefined : undefined,
                  maxCount: stepMaxCount,
                  linkedTaskId: stepTaskId,
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
          userId: resolvedUserId,
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
      onCreated?.({
        id: compositeTaskId,
        userId: resolvedUserId,
        title: title.trim(),
        description: undefined,
        rootNodeId,
        createdAt: now,
        updatedAt: now,
        version: 1,
        isDeleted: false,
      });
      resetForm();
      setTimeout(() => setSuccessMessage(null), SUCCESS_DISMISS_MS);
    } catch (err) {
      setErrorMessage(`Failed: ${err instanceof Error ? err.message : String(err)}`);
    } finally {
      setIsSubmitting(false);
    }
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
          <span className={getCharCountClass(title.length, TITLE_MAX_LENGTH, styles)}>
            {title.length}/{TITLE_MAX_LENGTH}
          </span>
        </div>

        {/* Operator selector */}
        <div className={styles.fieldGroup}>
          <span className={styles.label}>Completion rule</span>
          <OperatorSelector
            selectedOperator={operator}
            onOperatorChange={setOperator}
          />

          {operator === OperatorType.M_OF_N && (
            <CounterStepper
              value={threshold}
              min={1}
              max={subtasks.length}
              onChange={setThreshold}
              label={`of ${subtasks.length} subtask${subtasks.length !== 1 ? 's' : ''}`}
            />
          )}
        </div>

        {/* Subtask list */}
        <div className={styles.subtaskList}>
          {subtasks.map((s) => (
            <SubtaskCard
              key={s.id}
              draft={s}
              allTasks={allTasks}
              allCompositeTasks={allCompositeTasks}
              excludedIds={excludedIdsForCard(s.id)}
              onUpdate={(updates) => updateSubtask(s.id, updates)}
              onRemove={() => removeSubtask(s.id)}
              onStepFieldChange={(stepId, field, value) => updateInlineStep(s.id, stepId, field, value)}
              onAddStep={() => addStep(s.id)}
              onRemoveStep={(stepId) => removeStep(s.id, stepId)}
            />
          ))}
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
