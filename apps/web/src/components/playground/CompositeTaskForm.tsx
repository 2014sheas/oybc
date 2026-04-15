import { useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { OperatorType, TaskType, generateCounterTaskTitle, type CompositeTask, type Task } from '@oybc/shared';
import { db } from '../../db/database';
import { OperatorSelector } from '../OperatorSelector';
import { CounterStepper } from '../CounterStepper';
import { SubtaskChip } from '../SubtaskChip';
import { PLAYGROUND_USER_ID, SUCCESS_DISMISS_MS, getCharCountClass } from './playgroundUtils';
import { CountingStepFields } from '../CountingStepFields';
import { ProgressStepRow } from '../ProgressStepRow';
import { type StepFormState, createEmptyStep } from '../progressStepUtils';
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
  confirmed: boolean;
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
  confirmed: boolean;
  confirmError?: string;
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
    confirmed: false,
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
    confirmed: false,
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
  const [subtasks, setSubtasks] = useState<SubtaskItem[]>([]);
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

  // ─── Render helpers ─────────────────────────────────────────────────────────

  /**
   * Resolves the display title and badge label for a confirmed subtask chip.
   *
   * @param subtask - The confirmed subtask item
   * @returns title and badge strings
   */
  function getSubtaskDisplayInfo(subtask: SubtaskItem): { title: string; badge: string } {
    if (subtask.mode === 'existing') {
      if (subtask.selectionType === 'task') {
        const task = allTasks.find((t) => t.id === subtask.selectedId);
        return { title: task?.title ?? '?', badge: (task?.type ?? 'task').toUpperCase() };
      }
      const ct = allCompositeTasks.find((c) => c.id === subtask.selectedId);
      return { title: ct?.title ?? '?', badge: 'COMPOSITE' };
    }
    // inline
    const badge = subtask.inlineType.toUpperCase();
    let title: string;
    if (subtask.inlineType === 'counting') {
      title =
        subtask.title.trim() ||
        `${subtask.action.trim()} ${subtask.maxCountStr.trim()} ${subtask.unit.trim()}`.trim();
    } else {
      title = subtask.title.trim();
    }
    return { title: title || 'Untitled', badge };
  }

  /**
   * Attempts to confirm an inline subtask after validating required fields.
   * Sets confirmError on the subtask if validation fails.
   *
   * @param id - Subtask ID to confirm
   */
  function confirmSubtask(id: string): void {
    const subtask = subtasks.find((s) => s.id === id);
    if (!subtask || subtask.mode !== 'inline') return;

    let error: string | undefined;
    if (subtask.inlineType === 'counting') {
      if (
        !subtask.action.trim() ||
        !subtask.unit.trim() ||
        !(parseInt(subtask.maxCountStr, 10) > 0)
      ) {
        error = 'Action, max count, and unit are required';
      }
    } else {
      if (!subtask.title.trim()) {
        error = 'Title is required';
      }
    }

    if (error) {
      updateSubtask(id, { confirmError: error } as Partial<InlineSubtaskItem>);
      return;
    }
    updateSubtask(id, { confirmed: true, confirmError: undefined } as Partial<InlineSubtaskItem>);
  }

  /**
   * Sets a subtask back to unconfirmed (editing) state, clearing any confirm error.
   *
   * @param id - Subtask ID to un-confirm
   */
  function editSubtask(id: string): void {
    setSubtasks((prev) =>
      prev.map((s): SubtaskItem => {
        if (s.id !== id) return s;
        if (s.mode === 'inline') return { ...s, confirmed: false, confirmError: undefined };
        return { ...s, confirmed: false };
      })
    );
  }

  /**
   * Renders a single subtask as either a compact chip (confirmed) or the full edit form.
   *
   * @param subtask - The subtask item to render
   * @returns JSX element for the subtask card
   */
  function renderSubtask(subtask: SubtaskItem): React.ReactElement {
    // Confirmed state: compact chip
    if (subtask.confirmed) {
      const { title, badge } = getSubtaskDisplayInfo(subtask);
      return (
        <SubtaskChip
          key={subtask.id}
          title={title}
          type={badge.toLowerCase()}
          onEdit={() => editSubtask(subtask.id)}
          onRemove={() => removeSubtask(subtask.id)}
        />
      );
    }

    // Editing state: full form
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
                  confirmed: selectedId !== '',
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

            {/* Confirm error */}
            {subtask.confirmError && (
              <span className={styles.fieldError}>{subtask.confirmError}</span>
            )}

            {/* Done button */}
            <button
              type="button"
              className={styles.doneButton}
              onClick={() => confirmSubtask(subtask.id)}
            >
              ✓ Done
            </button>
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
