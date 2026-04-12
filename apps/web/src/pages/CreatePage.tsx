import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  TaskType,
  generateCounterTaskTitle,
  type Task,
  type TaskStep,
  type CompositeTask,
  type CompositeNode,
} from '@oybc/shared';
import { useAuth } from '../firebase/AuthContext';
import { useTasks } from '../hooks';
import { useCompositeTasks } from '../hooks/useCompositeTasks';
import { db } from '../db/database';
import { createTask, linkTaskStep } from '../db/operations/tasks';
import { FilterTabs } from '../components/FilterTabs';
import { TaskTypeSelector } from '../components/TaskTypeSelector';
import { TypeBadge } from '../components/TypeBadge';
import { PoolItem } from '../components/PoolItem';
import { ProgressStepRow, type StepFormState, createEmptyStep } from '../components/ProgressStepRow';
import { CountingDerivationPanel } from '../components/CountingDerivationPanel';
import { ProgressDerivationPanel } from '../components/ProgressDerivationPanel';
import { CompositeDerivationPanel } from '../components/CompositeDerivationPanel';
import { CompositeTaskForm } from '../components/playground/CompositeTaskForm';
import { BoardCreatorPanel, type PoolEntry } from '../components/BoardCreatorPanel';
import { getCharCountClass } from '../components/playground/playgroundUtils';
import styles from './CreatePage.module.css';

// ─── Constants ────────────────────────────────────────────────────────────────

const TITLE_MAX_LENGTH = 200;
const DESCRIPTION_MAX_LENGTH = 1000;
const ACTION_MAX_LENGTH = 50;
const UNIT_MAX_LENGTH = 50;
const STEP_TITLE_MAX_LENGTH = 200;
const SUCCESS_DISMISS_MS = 3000;

const COMPOSITE_TYPE = 'composite' as const;
type TaskTypeOrComposite = TaskType | typeof COMPOSITE_TYPE;

type Mode = 'create' | 'existing';

// ─── Validation ──────────────────────────────────────────────────────────────

interface FormErrors {
  title?: string;
  description?: string;
  action?: string;
  unit?: string;
  maxCount?: string;
  steps?: Record<string, { title?: string; action?: string; unit?: string; maxCount?: string }>;
  general?: string;
}

const MODE_TABS: { value: Mode; label: string }[] = [
  { value: 'create', label: 'Create New' },
  { value: 'existing', label: 'Existing Tasks' },
];

const TASK_TYPES: { value: TaskTypeOrComposite; label: string }[] = [
  { value: TaskType.NORMAL, label: 'Normal' },
  { value: TaskType.COUNTING, label: 'Counting' },
  { value: TaskType.PROGRESS, label: 'Progress' },
  { value: COMPOSITE_TYPE, label: 'Composite' },
];

const EXISTING_FILTER_TABS: { value: 'all' | TaskTypeOrComposite; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: TaskType.NORMAL, label: 'Normal' },
  { value: TaskType.COUNTING, label: 'Counting' },
  { value: TaskType.PROGRESS, label: 'Progress' },
  { value: COMPOSITE_TYPE, label: 'Composite' },
];

/**
 * Validates the task creation form.
 *
 * @param type - The task type selected
 * @param title - The task title
 * @param description - The optional task description
 * @param action - Action for counting tasks
 * @param unit - Unit for counting tasks
 * @param maxCountStr - Max count string for counting tasks
 * @param steps - Steps for progress tasks
 * @returns Object containing any validation errors
 */
function validateForm(
  type: TaskType,
  title: string,
  description: string,
  action: string,
  unit: string,
  maxCountStr: string,
  steps: StepFormState[]
): FormErrors {
  const errors: FormErrors = {};

  const trimmedTitle = title.trim();
  if (type !== TaskType.COUNTING && trimmedTitle.length === 0) {
    errors.title = 'Title is required';
  } else if (trimmedTitle.length > TITLE_MAX_LENGTH) {
    errors.title = `Title must be ${TITLE_MAX_LENGTH} characters or less`;
  }

  if (description.length > DESCRIPTION_MAX_LENGTH) {
    errors.description = `Description must be ${DESCRIPTION_MAX_LENGTH} characters or less`;
  }

  if (type === TaskType.COUNTING) {
    if (action.trim().length === 0) {
      errors.action = 'Action is required';
    } else if (action.trim().length > ACTION_MAX_LENGTH) {
      errors.action = `Action must be ${ACTION_MAX_LENGTH} characters or less`;
    }

    if (unit.trim().length === 0) {
      errors.unit = 'Unit is required';
    } else if (unit.trim().length > UNIT_MAX_LENGTH) {
      errors.unit = `Unit must be ${UNIT_MAX_LENGTH} characters or less`;
    }

    if (maxCountStr.trim().length === 0) {
      errors.maxCount = 'Max count is required';
    } else {
      const parsed = parseInt(maxCountStr, 10);
      if (isNaN(parsed) || parsed <= 0) {
        errors.maxCount = 'Max count must be a positive integer';
      }
    }
  }

  if (type === TaskType.PROGRESS) {
    const stepErrors: FormErrors['steps'] = {};
    let hasStepErrors = false;

    for (const step of steps) {
      const errs: { title?: string; action?: string; unit?: string; maxCount?: string } = {};

      const trimmedStepTitle = step.title.trim();
      if (step.type !== 'counting' && trimmedStepTitle.length === 0) {
        errs.title = 'Step title is required';
      } else if (trimmedStepTitle.length > STEP_TITLE_MAX_LENGTH) {
        errs.title = `Step title must be ${STEP_TITLE_MAX_LENGTH} characters or less`;
      }

      if (step.type === 'counting') {
        if (step.action.trim().length === 0) {
          errs.action = 'Action is required for counting steps';
        } else if (step.action.trim().length > ACTION_MAX_LENGTH) {
          errs.action = `Action must be ${ACTION_MAX_LENGTH} characters or less`;
        }

        if (step.unit.trim().length === 0) {
          errs.unit = 'Unit is required for counting steps';
        } else if (step.unit.trim().length > UNIT_MAX_LENGTH) {
          errs.unit = `Unit must be ${UNIT_MAX_LENGTH} characters or less`;
        }

        if (step.maxCount.trim().length === 0) {
          errs.maxCount = 'Max count is required for counting steps';
        } else {
          const parsed = parseInt(step.maxCount, 10);
          if (isNaN(parsed) || parsed <= 0) {
            errs.maxCount = 'Max count must be a positive number';
          }
        }
      }

      if (Object.keys(errs).length > 0) {
        stepErrors![step.id] = errs;
        hasStepErrors = true;
      }
    }

    if (hasStepErrors) {
      errors.steps = stepErrors;
    }
  }

  return errors;
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * CreatePage — Production task pool builder + board creation.
 *
 * Two-tab interface:
 * - Create New: form for Normal/Counting/Progress/Composite tasks, auto-added to pool
 * - Existing Tasks: filterable task library with derivation panels
 *
 * Board Task Pool is always visible at the bottom. When pool has enough tasks,
 * BoardCreatorPanel lets the user configure and create a board, then navigates
 * to the board play view.
 */
export function CreatePage(): React.ReactElement {
  const { user } = useAuth();
  const navigate = useNavigate();
  const userId = user?.id;

  // ── Mode state ──────────────────────────────────────────────────────────
  const [mode, setMode] = useState<Mode>('create');

  // ── Create tab state ────────────────────────────────────────────────────
  const [taskType, setTaskType] = useState<TaskTypeOrComposite>(TaskType.NORMAL);
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [action, setAction] = useState('');
  const [unit, setUnit] = useState('');
  const [maxCountStr, setMaxCountStr] = useState('');
  const [steps, setSteps] = useState<StepFormState[]>([createEmptyStep()]);
  const [errors, setErrors] = useState<FormErrors>({});
  const [isSubmitting, setIsSubmitting] = useState(false);

  // ── Existing Tasks tab state ────────────────────────────────────────────
  const [existingFilter, setExistingFilter] = useState<'all' | TaskTypeOrComposite>('all');
  const [expandedTaskId, setExpandedTaskId] = useState<string | null>(null);
  const [partialCount, setPartialCount] = useState('');
  const [isCreating, setIsCreating] = useState(false);

  // ── Pool state ──────────────────────────────────────────────────────────
  const [boardPool, setBoardPool] = useState<PoolEntry[]>([]);
  const [creationSuccess, setCreationSuccess] = useState<string | null>(null);

  // ── Reactive data ───────────────────────────────────────────────────────

  const allTasks = useTasks(userId) ?? [];
  const allCompositeTasks = useCompositeTasks(userId) ?? [];

  // Scope composite nodes to the current user's composite tasks. CompositeNode
  // has no userId of its own, so we restrict by compositeTaskId set.
  const compositeIds = allCompositeTasks.map((ct) => ct.id);
  const allCompositeNodes =
    useLiveQuery(
      async () => {
        if (compositeIds.length === 0) return [] as CompositeNode[];
        return db.compositeNodes
          .where('compositeTaskId')
          .anyOf(compositeIds)
          .and((n: CompositeNode) => !n.isDeleted)
          .toArray();
      },
      [compositeIds.join(',')]
    ) ?? [];

  // Scope task steps to the current user's tasks. TaskStep has no userId, so we
  // restrict by taskId set.
  const userTaskIds = allTasks.map((t) => t.id);
  const allTaskSteps: TaskStep[] =
    useLiveQuery(
      async () => {
        if (userTaskIds.length === 0) return [] as TaskStep[];
        return db.taskSteps
          .where('taskId')
          .anyOf(userTaskIds)
          .and((s: TaskStep) => !s.isDeleted)
          .toArray();
      },
      [userTaskIds.join(',')]
    ) ?? [];

  // ── Lookup maps ─────────────────────────────────────────────────────────

  const taskMap: Record<string, Task> = {};
  for (const t of allTasks) taskMap[t.id] = t;

  const compositeTaskMap: Record<string, CompositeTask> = {};
  for (const ct of allCompositeTasks) compositeTaskMap[ct.id] = ct;

  // ── Filtered lists ──────────────────────────────────────────────────────

  const filteredTasks: Task[] =
    existingFilter === 'all'
      ? allTasks
      : existingFilter === COMPOSITE_TYPE
        ? []
        : allTasks.filter((t: Task) => t.type === existingFilter);

  const filteredCompositeTasks: CompositeTask[] =
    existingFilter === 'all' || existingFilter === COMPOSITE_TYPE ? allCompositeTasks : [];

  // ── Pool helpers ────────────────────────────────────────────────────────

  // Track the pending success-dismiss timer so a rapid sequence of success
  // messages doesn't let an earlier timer clear a newer message, and so we
  // can clean up on unmount.
  const successTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    return () => {
      if (successTimerRef.current) clearTimeout(successTimerRef.current);
    };
  }, []);

  function showSuccess(message: string): void {
    setCreationSuccess(message);
    if (successTimerRef.current) clearTimeout(successTimerRef.current);
    successTimerRef.current = setTimeout(() => {
      setCreationSuccess(null);
      successTimerRef.current = null;
    }, SUCCESS_DISMISS_MS);
  }

  function addToPool(entry: PoolEntry): void {
    setBoardPool((prev) => {
      if (prev.some((e) => e.taskId === entry.taskId)) return prev;
      return [...prev, entry];
    });
  }

  function removeFromPool(taskId: string): void {
    setBoardPool((prev) => prev.filter((e) => e.taskId !== taskId));
  }

  function isInPool(taskId: string): boolean {
    return boardPool.some((e) => e.taskId === taskId);
  }

  // ── Create tab helpers ──────────────────────────────────────────────────

  function resetCreateForm(): void {
    setTaskType(TaskType.NORMAL);
    setTitle('');
    setDescription('');
    setAction('');
    setUnit('');
    setMaxCountStr('');
    setSteps([createEmptyStep()]);
    setErrors({});
  }

  function handleTypeChange(newType: TaskTypeOrComposite): void {
    setTaskType(newType);
    setErrors((prev) => ({
      ...prev,
      action: undefined,
      unit: undefined,
      maxCount: undefined,
      steps: undefined,
    }));
  }

  function updateStep(stepId: string, field: keyof StepFormState, value: string): void {
    setSteps((prev) =>
      prev.map((s) => (s.id === stepId ? { ...s, [field]: value } : s))
    );
    if (errors.steps?.[stepId]) {
      setErrors((prev) => {
        const newStepErrors = { ...prev.steps };
        if (newStepErrors[stepId]) {
          newStepErrors[stepId] = { ...newStepErrors[stepId], [field]: undefined };
          if (Object.values(newStepErrors[stepId]).every((v) => v === undefined)) {
            delete newStepErrors[stepId];
          }
        }
        const hasStepErrors = Object.keys(newStepErrors).length > 0;
        return { ...prev, steps: hasStepErrors ? newStepErrors : undefined };
      });
    }
  }

  function addStep(): void {
    setSteps((prev) => [...prev, createEmptyStep()]);
  }

  function removeStep(stepId: string): void {
    if (steps.length <= 1) return;
    setSteps((prev) => prev.filter((s) => s.id !== stepId));
    if (errors.steps?.[stepId]) {
      setErrors((prev) => {
        const newStepErrors = { ...prev.steps };
        delete newStepErrors[stepId];
        const hasStepErrors = Object.keys(newStepErrors).length > 0;
        return { ...prev, steps: hasStepErrors ? newStepErrors : undefined };
      });
    }
  }

  async function handleSubmit(e: React.FormEvent): Promise<void> {
    e.preventDefault();

    if (taskType === COMPOSITE_TYPE || !userId) return;

    const validationErrors = validateForm(taskType, title, description, action, unit, maxCountStr, steps);
    setErrors(validationErrors);

    if (Object.keys(validationErrors).length > 0) return;

    setIsSubmitting(true);

    try {
      let newTask: Task;

      if (taskType === TaskType.NORMAL) {
        newTask = await createTask(userId, {
          title: title.trim(),
          description: description.trim() || undefined,
          type: TaskType.NORMAL,
        });
      } else if (taskType === TaskType.COUNTING) {
        const parsedMaxCount = parseInt(maxCountStr, 10);
        const resolvedTitle = generateCounterTaskTitle(
          action.trim(),
          parsedMaxCount,
          unit.trim(),
          title.trim() || undefined
        );
        newTask = await createTask(userId, {
          title: resolvedTitle,
          description: description.trim() || undefined,
          type: TaskType.COUNTING,
          action: action.trim(),
          unit: unit.trim(),
          maxCount: parsedMaxCount,
        });
      } else {
        newTask = await createTask(userId, {
          title: title.trim(),
          description: description.trim() || undefined,
          type: TaskType.PROGRESS,
          steps: steps.map((s) => {
            const trimmedStepTitle = s.title.trim();
            const trimmedAction = s.action.trim();
            const trimmedUnit = s.unit.trim();
            const maxCount = parseInt(s.maxCount, 10);
            const resolvedStepTitle =
              s.type === 'counting'
                ? generateCounterTaskTitle(trimmedAction, maxCount, trimmedUnit, trimmedStepTitle || undefined)
                : trimmedStepTitle;
            return {
              title: resolvedStepTitle,
              type: s.type === 'counting' ? TaskType.COUNTING : TaskType.NORMAL,
              ...(s.type === 'counting'
                ? { action: trimmedAction, unit: trimmedUnit, maxCount }
                : {}),
            };
          }),
        });
      }

      addToPool({ taskId: newTask.id, title: newTask.title, type: newTask.type });
      resetCreateForm();
      showSuccess(`Created & added to pool: "${newTask.title}"`);
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Unknown error occurred';
      setErrors((prev) => ({ ...prev, general: errorMessage }));
    } finally {
      setIsSubmitting(false);
    }
  }

  // ── Existing Tasks tab helpers ──────────────────────────────────────────

  function toggleExpand(id: string): void {
    setExpandedTaskId((prev) => (prev === id ? null : id));
    setPartialCount('');
  }

  function canDerive(taskType_: string): boolean {
    return taskType_ === TaskType.COUNTING || taskType_ === TaskType.PROGRESS || taskType_ === 'composite';
  }

  function handleExistingFilterChange(newFilter: 'all' | TaskTypeOrComposite): void {
    setExistingFilter(newFilter);
    setPartialCount('');

    if (expandedTaskId) {
      const task = taskMap[expandedTaskId];
      const composite = compositeTaskMap[expandedTaskId];

      if (task) {
        const nowVisible = newFilter === 'all' || task.type === newFilter;
        if (!nowVisible) setExpandedTaskId(null);
      } else if (composite) {
        const nowVisible = newFilter === 'all' || newFilter === COMPOSITE_TYPE;
        if (!nowVisible) setExpandedTaskId(null);
      }
    }
  }

  async function handleCreateCountingSubtask(task: Task, count: number): Promise<void> {
    if (!userId) return;
    setIsCreating(true);
    try {
      const newTask = await createTask(userId, {
        type: TaskType.COUNTING,
        title: generateCounterTaskTitle(task.action!, count, task.unit!),
        description: `Subtask of "${task.title}"`,
        action: task.action!,
        unit: task.unit!,
        maxCount: count,
      });
      addToPool({ taskId: newTask.id, title: newTask.title, type: newTask.type });
      showSuccess(`Added to board pool: "${newTask.title}"`);
      setPartialCount('');
    } catch (err) {
      console.error('Failed to create subtask:', err);
    } finally {
      setIsCreating(false);
    }
  }

  async function handleExtractStep(step: TaskStep): Promise<void> {
    if (!userId) return;

    if (step.linkedTaskId) {
      const linkedTask = taskMap[step.linkedTaskId];
      if (linkedTask) {
        addToPool({ taskId: linkedTask.id, title: linkedTask.title, type: linkedTask.type });
        showSuccess(`Added to board pool: "${linkedTask.title}"`);
      }
      return;
    }

    setIsCreating(true);
    try {
      const isCountingStep =
        step.type === TaskType.COUNTING &&
        step.action !== undefined &&
        step.unit !== undefined &&
        step.maxCount !== undefined;

      const newTask = await createTask(userId, {
        type: isCountingStep ? TaskType.COUNTING : TaskType.NORMAL,
        title: isCountingStep
          ? generateCounterTaskTitle(step.action!, step.maxCount!, step.unit!)
          : step.title,
        description:
          step.title !==
          (isCountingStep
            ? generateCounterTaskTitle(step.action!, step.maxCount!, step.unit!)
            : step.title)
            ? step.title
            : undefined,
        action: isCountingStep ? step.action! : undefined,
        unit: isCountingStep ? step.unit! : undefined,
        maxCount: isCountingStep ? step.maxCount! : undefined,
      });

      // Link the step → new task atomically (transaction + sync queue) so
      // the linkedTaskId change is durable and replicates to other devices.
      await linkTaskStep(step.id, newTask.id);

      addToPool({ taskId: newTask.id, title: newTask.title, type: newTask.type });
      showSuccess(`Added to board pool: "${newTask.title}"`);
    } catch (err) {
      console.error('Failed to extract step:', err);
    } finally {
      setIsCreating(false);
    }
  }

  // ── Render: inline derivation panels ────────────────────────────────────

  function renderInlineTaskPanel(task: Task): React.ReactElement {
    return (
      <div className={styles.inlinePanel}>
        <div className={styles.panelAddRow}>
          <span className={styles.panelAddLabel}>{task.title}</span>
          {isInPool(task.id) ? (
            <span className={styles.inPoolBadge}>In Pool</span>
          ) : (
            <button
              type="button"
              className={styles.addButton}
              onClick={() => {
                addToPool({ taskId: task.id, title: task.title, type: task.type });
                showSuccess(`Added to board pool: "${task.title}"`);
              }}
            >
              Add to Pool
            </button>
          )}
        </div>

        {task.type === TaskType.COUNTING && (
          <>
            <div className={styles.panelDivider} />
            <span className={styles.panelSectionLabel}>Or derive a subtask:</span>
            <CountingDerivationPanel
              task={task}
              partialCount={partialCount}
              onPartialCountChange={setPartialCount}
              onCreateSubtask={handleCreateCountingSubtask}
              isCreating={isCreating}
            />
          </>
        )}
        {task.type === TaskType.PROGRESS && (
          <>
            <div className={styles.panelDivider} />
            <span className={styles.panelSectionLabel}>Or extract steps:</span>
            <ProgressDerivationPanel
              taskId={task.id}
              onExtractStep={handleExtractStep}
              onAddStepToPool={(step: TaskStep) => {
                if (step.linkedTaskId) {
                  const linkedTask = taskMap[step.linkedTaskId];
                  if (linkedTask) {
                    addToPool({ taskId: linkedTask.id, title: linkedTask.title, type: linkedTask.type });
                    showSuccess(`Added to board pool: "${linkedTask.title}"`);
                  }
                }
              }}
              isCreating={isCreating}
              isInPool={isInPool}
            />
          </>
        )}
      </div>
    );
  }

  function renderInlineCompositePanel(ct: CompositeTask): React.ReactElement {
    return (
      <div className={styles.inlinePanel}>
        <span className={styles.panelSectionLabel}>Add individual subtasks to the pool:</span>
        <CompositeDerivationPanel
          compositeTask={ct}
          allNodes={allCompositeNodes}
          taskMap={taskMap}
          compositeTaskMap={compositeTaskMap}
          onAddLeafToPool={(taskId_: string, leafTitle: string, type: string) => {
            addToPool({ taskId: taskId_, title: leafTitle, type });
            showSuccess(`Added to board pool: "${leafTitle}"`);
          }}
          isInPool={isInPool}
        />
      </div>
    );
  }

  // ── Render ──────────────────────────────────────────────────────────────

  return (
    <div className={styles.container}>
      <h1 className={styles.header}>Create</h1>

      {/* Success message */}
      {creationSuccess && <div className={styles.successMessage}>{creationSuccess}</div>}

      {/* Mode tabs */}
      <div className={styles.modeTabRow}>
        <FilterTabs
          tabs={MODE_TABS}
          activeTab={mode}
          onTabChange={(value) => setMode(value as Mode)}
        />
        {boardPool.length > 0 && (
          <button
            type="button"
            className={styles.poolChip}
            onClick={() => {
              document.getElementById('create-board-task-pool')?.scrollIntoView({ behavior: 'smooth' });
            }}
          >
            Pool: {boardPool.length}
          </button>
        )}
      </div>

      {/* ── Create New tab ── */}
      {mode === 'create' && (
        <div className={styles.modeSection}>
          <div className={styles.fieldGroup}>
            <label className={styles.label}>
              Type<span className={styles.required}>*</span>
            </label>
            <TaskTypeSelector
              types={TASK_TYPES}
              selectedType={taskType}
              onTypeChange={(value) => handleTypeChange(value as TaskTypeOrComposite)}
            />
          </div>

          {taskType === COMPOSITE_TYPE ? (
            <CompositeTaskForm
              userId={userId}
              onCreated={(ct: CompositeTask) => {
                // Composites aren't added directly to the board pool — BoardTask.taskId
                // references the tasks table, not compositeTasks. Users add the
                // composite's individual leaf/subtasks via the Existing Tasks tab.
                showSuccess(`Created composite "${ct.title}". Add its subtasks from Existing Tasks.`);
              }}
            />
          ) : (
            <form className={styles.form} onSubmit={handleSubmit}>
              {/* Title */}
              <div className={styles.fieldGroup}>
                <label className={styles.label} htmlFor="create-task-title">
                  Title
                  {taskType !== TaskType.COUNTING && <span className={styles.required}>*</span>}
                </label>
                <input
                  id="create-task-title"
                  type="text"
                  className={`${styles.input} ${errors.title ? styles.inputError : ''}`}
                  value={title}
                  onChange={(e) => {
                    setTitle(e.target.value);
                    if (errors.title) setErrors((prev) => ({ ...prev, title: undefined }));
                  }}
                  placeholder={
                    taskType === TaskType.COUNTING
                      ? 'Auto-generated if blank (e.g., "Run 26 miles")'
                      : 'Enter task title'
                  }
                  maxLength={TITLE_MAX_LENGTH + 1}
                />
                <span className={getCharCountClass(title.length, TITLE_MAX_LENGTH, styles)}>
                  {title.length}/{TITLE_MAX_LENGTH}
                </span>
                {errors.title && <span className={styles.fieldError}>{errors.title}</span>}
              </div>

              {/* Description */}
              <div className={styles.fieldGroup}>
                <label className={styles.label} htmlFor="create-task-description">
                  Description
                </label>
                <textarea
                  id="create-task-description"
                  className={`${styles.input} ${styles.textarea} ${errors.description ? styles.inputError : ''}`}
                  value={description}
                  onChange={(e) => {
                    setDescription(e.target.value);
                    if (errors.description) setErrors((prev) => ({ ...prev, description: undefined }));
                  }}
                  placeholder="Enter task description (optional)"
                  maxLength={DESCRIPTION_MAX_LENGTH + 1}
                />
                <span className={getCharCountClass(description.length, DESCRIPTION_MAX_LENGTH, styles)}>
                  {description.length}/{DESCRIPTION_MAX_LENGTH}
                </span>
                {errors.description && <span className={styles.fieldError}>{errors.description}</span>}
              </div>

              {/* Counting fields */}
              {taskType === TaskType.COUNTING && (
                <div className={styles.countingFields}>
                  <div className={styles.fieldGroup}>
                    <label className={styles.label} htmlFor="create-task-action">
                      Action<span className={styles.required}>*</span>
                    </label>
                    <input
                      id="create-task-action"
                      type="text"
                      className={`${styles.input} ${errors.action ? styles.inputError : ''}`}
                      value={action}
                      onChange={(e) => {
                        setAction(e.target.value);
                        if (errors.action) setErrors((prev) => ({ ...prev, action: undefined }));
                      }}
                      placeholder='e.g., "Run"'
                      maxLength={ACTION_MAX_LENGTH}
                    />
                    {errors.action && <span className={styles.fieldError}>{errors.action}</span>}
                  </div>

                  <div className={styles.fieldGroup}>
                    <label className={styles.label} htmlFor="create-task-maxcount">
                      Max Count<span className={styles.required}>*</span>
                    </label>
                    <input
                      id="create-task-maxcount"
                      type="number"
                      className={`${styles.input} ${errors.maxCount ? styles.inputError : ''}`}
                      value={maxCountStr}
                      onChange={(e) => {
                        setMaxCountStr(e.target.value);
                        if (errors.maxCount) setErrors((prev) => ({ ...prev, maxCount: undefined }));
                      }}
                      placeholder="e.g., 26"
                      min="1"
                    />
                    {errors.maxCount && <span className={styles.fieldError}>{errors.maxCount}</span>}
                  </div>

                  <div className={styles.fieldGroup}>
                    <label className={styles.label} htmlFor="create-task-unit">
                      Unit<span className={styles.required}>*</span>
                    </label>
                    <input
                      id="create-task-unit"
                      type="text"
                      className={`${styles.input} ${errors.unit ? styles.inputError : ''}`}
                      value={unit}
                      onChange={(e) => {
                        setUnit(e.target.value);
                        if (errors.unit) setErrors((prev) => ({ ...prev, unit: undefined }));
                      }}
                      placeholder='e.g., "miles"'
                      maxLength={UNIT_MAX_LENGTH}
                    />
                    {errors.unit && <span className={styles.fieldError}>{errors.unit}</span>}
                  </div>
                </div>
              )}

              {/* Progress steps */}
              {taskType === TaskType.PROGRESS && (
                <div className={styles.stepsSection}>
                  <span className={styles.stepsHeader}>Steps</span>
                  <div className={styles.stepsList}>
                    {steps.map((step, index) => (
                      <ProgressStepRow
                        key={step.id}
                        index={index}
                        idPrefix={`create-step-${step.id}`}
                        step={step}
                        errors={errors.steps?.[step.id]}
                        canRemove={steps.length > 1}
                        stepTitleMaxLength={STEP_TITLE_MAX_LENGTH}
                        onFieldChange={(field, value) => updateStep(step.id, field, value)}
                        onRemove={() => removeStep(step.id)}
                      />
                    ))}
                  </div>
                  <button type="button" className={styles.addStepButton} onClick={addStep}>
                    + Add Step
                  </button>
                </div>
              )}

              {errors.general && <div className={styles.errorMessage}>{errors.general}</div>}

              <button type="submit" className={styles.submitButton} disabled={isSubmitting}>
                {isSubmitting ? 'Creating...' : 'Create & Add to Pool'}
              </button>
            </form>
          )}
        </div>
      )}

      {/* ── Existing Tasks tab ── */}
      {mode === 'existing' && (
        <div className={styles.modeSection}>
          <FilterTabs
            tabs={EXISTING_FILTER_TABS}
            activeTab={existingFilter}
            onTabChange={(value) => handleExistingFilterChange(value as 'all' | TaskTypeOrComposite)}
          />

          {filteredTasks.length === 0 && filteredCompositeTasks.length === 0 ? (
            <p className={styles.emptyState}>
              No tasks found. Create tasks using the Create New tab.
            </p>
          ) : (
            <div className={styles.taskList}>
              {filteredTasks.map((task: Task) => (
                <div key={task.id}>
                  <div className={styles.taskItem}>
                    <div className={styles.taskItemInfo}>
                      <span className={styles.taskItemTitle}>{task.title}</span>
                      <TypeBadge type={task.type} size="small" />
                    </div>
                    <div className={styles.taskItemActions}>
                      {canDerive(task.type) && (
                        <button
                          type="button"
                          className={`${styles.deriveButton} ${expandedTaskId === task.id ? styles.deriveButtonActive : ''}`}
                          onClick={() => toggleExpand(task.id)}
                          aria-label={expandedTaskId === task.id ? `Collapse ${task.title} derivation` : `Derive subtasks from ${task.title}`}
                          aria-expanded={expandedTaskId === task.id}
                        >
                          {expandedTaskId === task.id ? '\u25BC' : '\u25B6'}
                        </button>
                      )}
                      {isInPool(task.id) ? (
                        <span className={styles.inPoolBadge}>In Pool</span>
                      ) : (
                        <button
                          type="button"
                          className={styles.addButton}
                          onClick={() => {
                            addToPool({ taskId: task.id, title: task.title, type: task.type });
                            showSuccess(`Added to board pool: "${task.title}"`);
                          }}
                        >
                          Add
                        </button>
                      )}
                    </div>
                  </div>
                  {expandedTaskId === task.id && renderInlineTaskPanel(task)}
                </div>
              ))}

              {filteredCompositeTasks.map((ct: CompositeTask) => (
                <div key={ct.id}>
                  <div className={styles.taskItem}>
                    <div className={styles.taskItemInfo}>
                      <span className={styles.taskItemTitle}>{ct.title}</span>
                      <TypeBadge type="composite" size="small" />
                    </div>
                    <div className={styles.taskItemActions}>
                      <button
                        type="button"
                        className={`${styles.deriveButton} ${expandedTaskId === ct.id ? styles.deriveButtonActive : ''}`}
                        onClick={() => toggleExpand(ct.id)}
                        aria-label={expandedTaskId === ct.id ? `Collapse ${ct.title} subtasks` : `Show subtasks of ${ct.title}`}
                        aria-expanded={expandedTaskId === ct.id}
                      >
                        {expandedTaskId === ct.id ? '\u25BC' : '\u25B6'}
                      </button>
                    </div>
                  </div>
                  {expandedTaskId === ct.id && renderInlineCompositePanel(ct)}
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {/* ── Board Task Pool — always visible ── */}
      <div id="create-board-task-pool" className={styles.poolSection}>
        <h4 className={styles.poolTitle}>
          Board Task Pool
          {boardPool.length > 0 && (
            <span className={styles.poolCount}>{boardPool.length}</span>
          )}
        </h4>
        {boardPool.length === 0 ? (
          <p className={styles.emptyState}>
            No tasks in the pool yet. Use the tabs above to add tasks.
          </p>
        ) : (
          <div className={styles.poolList}>
            {boardPool.map((entry) => (
              <PoolItem
                key={entry.taskId}
                title={entry.title}
                type={entry.type}
                onRemove={() => removeFromPool(entry.taskId)}
              />
            ))}
            <button
              type="button"
              className={styles.poolClearButton}
              onClick={() => setBoardPool([])}
            >
              Clear Pool
            </button>
          </div>
        )}
      </div>

      {/* ── Board Creator — shown when pool has tasks ── */}
      {boardPool.length > 0 && userId && (
        <BoardCreatorPanel
          pool={boardPool}
          taskMap={taskMap}
          allTaskSteps={allTaskSteps}
          userId={userId}
          onBoardCreated={(boardId: string) => {
            navigate(`/boards/${boardId}`);
          }}
        />
      )}
    </div>
  );
}
