import { useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  TaskType,
  Timeframe,
  CenterSquareType,
  fisherYatesShuffle,
  generateCounterTaskTitle,
  type Task,
  type TaskStep,
  type CompositeTask,
  type CompositeNode,
  type Board,
  type BoardTask,
} from '@oybc/shared';
import { db } from '../../db/database';
import { createTask } from '../../db/operations/tasks';
import { createBoard } from '../../db/operations/boards';
import { createBoardTask } from '../../db/operations/boardTasks';
import { useBoards, useBoardTasks, useTasks } from '../../hooks';
import { taskToSquareData, boardTaskToSquareState } from '../../db/adapters';
import {
  InteractiveTaskSquare,
  FloatingContextMenu,
  type TaskSquareData,
  type SquareState,
  type ContextMenuState,
  interactiveTaskSquareStyles as sqStyles,
} from '../InteractiveTaskSquare';
import { FilterTabs } from '../FilterTabs';
import { TaskTypeSelector } from '../TaskTypeSelector';
import { TypeBadge } from '../TypeBadge';
import { PoolItem } from '../PoolItem';
import { ProgressStepRow, type StepFormState, createEmptyStep } from '../ProgressStepRow';
import { CountingDerivationPanel } from '../CountingDerivationPanel';
import { ProgressDerivationPanel } from '../ProgressDerivationPanel';
import { CompositeDerivationPanel } from '../CompositeDerivationPanel';
import { CompositeTaskForm } from './CompositeTaskForm';
import { BoardCreatorPanel } from '../BoardCreatorPanel';
import {
  PLAYGROUND_USER_ID,
  SUCCESS_DISMISS_MS,
  getCharCountClass,
} from './playgroundUtils';
import styles from './BoardTaskSelectionPlayground.module.css';

// ─── Constants ────────────────────────────────────────────────────────────────

/** Maximum character lengths matching shared validation schemas */
const TITLE_MAX_LENGTH = 200;
const DESCRIPTION_MAX_LENGTH = 1000;
const ACTION_MAX_LENGTH = 50;
const UNIT_MAX_LENGTH = 50;
const STEP_TITLE_MAX_LENGTH = 200;

/** Sentinel value used for the composite type selector (not a TaskType enum value) */
const COMPOSITE_TYPE = 'composite' as const;
type TaskTypeOrComposite = TaskType | typeof COMPOSITE_TYPE;

/** Modes for the two top-level tabs */
type Mode = 'create' | 'existing';

/** Sub-toggle within the Existing Tasks tab */
type ExistingBrowseMode = 'library' | 'board';

/** Entry in the Board Task Pool staging area */
interface PoolEntry {
  taskId: string;
  title: string;
  type: string;
}

/** Validation error state for the create form */
interface FormErrors {
  title?: string;
  description?: string;
  action?: string;
  unit?: string;
  maxCount?: string;
  steps?: Record<
    string,
    {
      title?: string;
      action?: string;
      unit?: string;
      maxCount?: string;
    }
  >;
  general?: string;
}

// ─── Tab configurations ───────────────────────────────────────────────────────

const MODE_TABS: { value: Mode; label: string }[] = [
  { value: 'create', label: 'Create New' },
  { value: 'existing', label: 'Existing Tasks' },
];

const BROWSE_MODE_TABS: { value: ExistingBrowseMode; label: string }[] = [
  { value: 'library', label: 'Task Library' },
  { value: 'board', label: 'From Board' },
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

// ─── Adapters (imported from shared module) ──────────────────────────────────
// taskToSquareData and boardTaskToSquareState imported via db/adapters.ts

// ─── Validation ───────────────────────────────────────────────────────────────

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
      const errs: {
        title?: string;
        action?: string;
        unit?: string;
        maxCount?: string;
      } = {};

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

// ─── Main Component ───────────────────────────────────────────────────────────

/**
 * BoardTaskSelectionPlayground — Two-tab task pool builder.
 *
 * Provides two workflows for populating a board task pool:
 * - Create New: unified form (Normal, Counting, Progress, Composite) with auto-add to pool
 * - Existing Tasks: filterable list with "Add" to pool directly, plus expandable derivation
 *   panels for counting/progress/composite tasks (partial count, step extraction, leaf inspection)
 *
 * The pool is always visible at the bottom regardless of active tab.
 */
export function BoardTaskSelectionPlayground(): React.ReactElement {
  // ── Top-level tab mode ─────────────────────────────────────────────────────
  const [mode, setMode] = useState<Mode>('create');

  // ── Create tab state ───────────────────────────────────────────────────────
  const [taskType, setTaskType] = useState<TaskTypeOrComposite>(TaskType.NORMAL);
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [action, setAction] = useState('');
  const [unit, setUnit] = useState('');
  const [maxCountStr, setMaxCountStr] = useState('');
  const [steps, setSteps] = useState<StepFormState[]>([createEmptyStep()]);
  const [errors, setErrors] = useState<FormErrors>({});
  const [isSubmitting, setIsSubmitting] = useState(false);

  // ── Existing Tasks tab state ────────────────────────────────────────────────
  const [existingBrowseMode, setExistingBrowseMode] = useState<ExistingBrowseMode>('library');
  const [existingFilter, setExistingFilter] = useState<'all' | TaskTypeOrComposite>('all');
  const [expandedTaskId, setExpandedTaskId] = useState<string | null>(null);
  const [partialCount, setPartialCount] = useState('');
  const [isCreating, setIsCreating] = useState(false);

  // ── From Board tab state ───────────────────────────────────────────────────
  const [selectedBoardId, setSelectedBoardId] = useState<string | null>(null);
  const [boardSelectedTaskId, setBoardSelectedTaskId] = useState<string | null>(null);
  const [isSettingUp, setIsSettingUp] = useState(false);
  const [boardContextMenu, setBoardContextMenu] = useState<ContextMenuState | null>(null);

  // ── Shared state ───────────────────────────────────────────────────────────
  const [boardPool, setBoardPool] = useState<PoolEntry[]>([]);
  const [creationSuccess, setCreationSuccess] = useState<string | null>(null);

  // ── Reactive data sources ──────────────────────────────────────────────────

  const allTasks = useTasks(PLAYGROUND_USER_ID) ?? [];

  /** All non-deleted boards for the playground user (From Board tab) */
  const allBoards = useBoards(PLAYGROUND_USER_ID) ?? [];

  /** Board tasks for the currently selected board (From Board tab) */
  const boardTasks = useBoardTasks(selectedBoardId ?? '') ?? [];

  const allCompositeTasks =
    useLiveQuery(
      () =>
        db.compositeTasks
          .filter((ct: CompositeTask) => ct.userId === PLAYGROUND_USER_ID && !ct.isDeleted)
          .toArray(),
      []
    ) ?? [];

  const allCompositeNodes =
    useLiveQuery(
      () => db.compositeNodes.filter((n: CompositeNode) => !n.isDeleted).toArray(),
      []
    ) ?? [];

  /** All non-deleted task steps (for From Board tab InteractiveTaskSquare progress data) */
  const allTaskSteps: TaskStep[] =
    useLiveQuery(
      () => db.taskSteps.filter((s: TaskStep) => !s.isDeleted).toArray(),
      []
    ) ?? [];

  // ── Derived lookup maps ────────────────────────────────────────────────────

  const taskMap: Record<string, Task> = {};
  for (const t of allTasks) taskMap[t.id] = t;

  const compositeTaskMap: Record<string, CompositeTask> = {};
  for (const ct of allCompositeTasks) compositeTaskMap[ct.id] = ct;

  // ── From Board tab derived values ──────────────────────────────────────────

  /** The currently selected board object */
  const selectedBoard: Board | null = selectedBoardId
    ? (allBoards.find((b: Board) => b.id === selectedBoardId) ?? null)
    : null;

  /** Board tasks sorted by row then col for consistent grid ordering */
  const sortedBoardTasks = [...boardTasks].sort((a: BoardTask, b: BoardTask) =>
    a.row !== b.row ? a.row - b.row : a.col - b.col
  );

  // ── Pool helpers ───────────────────────────────────────────────────────────

  /**
   * Shows a success message that auto-dismisses after SUCCESS_DISMISS_MS.
   *
   * @param message - The message string to display
   */
  function showSuccess(message: string): void {
    setCreationSuccess(message);
    setTimeout(() => setCreationSuccess(null), SUCCESS_DISMISS_MS);
  }

  /**
   * Adds a task to the board pool. Skips duplicates.
   *
   * @param entry - The pool entry to add
   */
  function addToPool(entry: PoolEntry): void {
    setBoardPool((prev) => {
      if (prev.some((e) => e.taskId === entry.taskId)) return prev;
      return [...prev, entry];
    });
  }

  /**
   * Removes a task from the board pool by task ID.
   *
   * @param taskId - The task ID to remove
   */
  function removeFromPool(taskId: string): void {
    setBoardPool((prev) => prev.filter((e) => e.taskId !== taskId));
  }

  /**
   * Returns whether a task ID is already in the pool.
   *
   * @param taskId - The task ID to check
   */
  function isInPool(taskId: string): boolean {
    return boardPool.some((e) => e.taskId === taskId);
  }

  // ── Create tab helpers ─────────────────────────────────────────────────────

  /**
   * Resets the create form to its default state.
   */
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

  /**
   * Handles task type change, clearing type-specific field errors.
   *
   * @param newType - The newly selected task type or composite sentinel
   */
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

  /**
   * Updates a specific step's field value and clears associated errors.
   *
   * @param stepId - The step form ID to update
   * @param field - The field name to update
   * @param value - The new value
   */
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
        return {
          ...prev,
          steps: hasStepErrors ? newStepErrors : undefined,
        };
      });
    }
  }

  /**
   * Adds a new empty step to the create form.
   */
  function addStep(): void {
    setSteps((prev) => [...prev, createEmptyStep()]);
  }

  /**
   * Removes a step from the create form by ID. Won't remove the last step.
   *
   * @param stepId - The step form ID to remove
   */
  function removeStep(stepId: string): void {
    if (steps.length <= 1) return;
    setSteps((prev) => prev.filter((s) => s.id !== stepId));
    if (errors.steps?.[stepId]) {
      setErrors((prev) => {
        const newStepErrors = { ...prev.steps };
        delete newStepErrors[stepId];
        const hasStepErrors = Object.keys(newStepErrors).length > 0;
        return {
          ...prev,
          steps: hasStepErrors ? newStepErrors : undefined,
        };
      });
    }
  }

  /**
   * Handles form submission to create a new task and add it to the pool.
   * Composite type is handled by CompositeTaskForm and should not reach here.
   *
   * @param e - The form submit event
   */
  async function handleSubmit(e: React.FormEvent): Promise<void> {
    e.preventDefault();

    if (taskType === COMPOSITE_TYPE) return;

    const validationErrors = validateForm(
      taskType,
      title,
      description,
      action,
      unit,
      maxCountStr,
      steps
    );
    setErrors(validationErrors);

    if (Object.keys(validationErrors).length > 0) {
      return;
    }

    setIsSubmitting(true);

    try {
      let newTask: Task;

      if (taskType === TaskType.NORMAL) {
        newTask = await createTask(PLAYGROUND_USER_ID, {
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
        newTask = await createTask(PLAYGROUND_USER_ID, {
          title: resolvedTitle,
          description: description.trim() || undefined,
          type: TaskType.COUNTING,
          action: action.trim(),
          unit: unit.trim(),
          maxCount: parsedMaxCount,
        });
      } else {
        // TaskType.PROGRESS
        newTask = await createTask(PLAYGROUND_USER_ID, {
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
                ? {
                    action: trimmedAction,
                    unit: trimmedUnit,
                    maxCount,
                  }
                : {}),
            };
          }),
        });
      }

      addToPool({ taskId: newTask.id, title: newTask.title, type: newTask.type });
      resetCreateForm();
      showSuccess(`Created & added to pool: "${newTask.title}"`);
    } catch (error) {
      const errorMessage =
        error instanceof Error ? error.message : 'Unknown error occurred';
      setErrors((prev) => ({ ...prev, general: errorMessage }));
    } finally {
      setIsSubmitting(false);
    }
  }

  // ── From Board tab helpers ─────────────────────────────────────────────────

  /**
   * Creates a fully populated 3×3 demo board with a mix of task types.
   * Includes counting, progress, and normal tasks so all derivation panels
   * can be tested. Auto-selects the new board on completion.
   */
  async function handleCreateDemoBoard(): Promise<void> {
    setIsSettingUp(true);
    try {
      const demoStart = new Date().toISOString();
      const demoEnd = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();

      const taskDefs = [
        { type: TaskType.COUNTING, title: 'Read 50 pages', action: 'Read', unit: 'pages', maxCount: 50 },
        { type: TaskType.COUNTING, title: 'Walk 10 km', action: 'Walk', unit: 'km', maxCount: 10 },
        { type: TaskType.PROGRESS, title: 'Weekly Workout', steps: [
          { title: 'Monday run', type: TaskType.NORMAL },
          { title: 'Wednesday weights', type: TaskType.NORMAL },
          { title: 'Friday yoga', type: TaskType.NORMAL },
        ]},
        { type: TaskType.PROGRESS, title: 'Clean House', steps: [
          { title: 'Vacuum', type: TaskType.NORMAL },
          { title: 'Dust', type: TaskType.NORMAL },
          { title: 'Mop', type: TaskType.NORMAL },
        ]},
        { type: TaskType.NORMAL, title: 'Meditate' },
        { type: TaskType.NORMAL, title: 'Call a friend' },
        { type: TaskType.NORMAL, title: 'Cook dinner' },
        { type: TaskType.NORMAL, title: 'Write in journal' },
        { type: TaskType.NORMAL, title: 'Read a chapter' },
      ];

      const createdTasks: Task[] = [];
      for (const def of taskDefs) {
        const task = await createTask(PLAYGROUND_USER_ID, def);
        createdTasks.push(task);
      }

      const shuffled = fisherYatesShuffle([...createdTasks]);
      const boardSize = 3;

      const board = await createBoard(PLAYGROUND_USER_ID, {
        name: `Demo Board ${allBoards.length + 1}`,
        boardSize,
        timeframe: Timeframe.CUSTOM,
        startDate: demoStart,
        endDate: demoEnd,
        centerSquareType: CenterSquareType.FREE,
        isRandomized: true,
      });

      let taskIndex = 0;
      for (let row = 0; row < boardSize; row++) {
        for (let col = 0; col < boardSize; col++) {
          const isCenter = row === 1 && col === 1;
          if (isCenter) continue;
          if (taskIndex >= shuffled.length) break;
          await createBoardTask({
            boardId: board.id,
            taskId: shuffled[taskIndex].id,
            row,
            col,
            isCenter: false,
          });
          taskIndex++;
        }
      }

      showSuccess(`Created "${board.name}" with ${taskIndex} tasks`);
      setSelectedBoardId(board.id);
    } catch (err) {
      console.error('Failed to create demo board:', err);
    } finally {
      setIsSettingUp(false);
    }
  }

  /**
   * Selects a board by ID. Toggling the same board deselects it.
   * Clears any selected task when switching boards.
   *
   * @param boardId - The board ID to select
   */
  function handleSelectBoard(boardId: string): void {
    setSelectedBoardId((prev) => (prev === boardId ? null : boardId));
    setBoardSelectedTaskId(null);
  }

  /**
   * Formats a board's size for display (e.g. "3×3").
   *
   * @param board - The Board record
   * @returns Size string such as "3×3"
   */
  function formatBoardSize(board: Board): string {
    return `${board.boardSize}×${board.boardSize}`;
  }

  // ── Existing Tasks tab helpers ──────────────────────────────────────────────

  /**
   * Toggles the derivation panel for a task by ID. Collapses if already expanded.
   *
   * @param id - The task or composite task ID to toggle
   */
  function toggleExpand(id: string): void {
    setExpandedTaskId((prev) => (prev === id ? null : id));
    setPartialCount('');
  }

  /**
   * Returns whether a task supports derivation (counting/progress/composite).
   *
   * @param taskType - The task type string
   */
  function canDerive(taskType: string): boolean {
    return taskType === TaskType.COUNTING || taskType === TaskType.PROGRESS || taskType === 'composite';
  }

  /**
   * Changes the existing tasks filter tab and collapses any expanded task hidden by the new filter.
   *
   * @param newFilter - The filter type to apply
   */
  function handleExistingFilterChange(newFilter: 'all' | TaskTypeOrComposite): void {
    setExistingFilter(newFilter);
    setPartialCount('');

    if (expandedTaskId) {
      const task = taskMap[expandedTaskId];
      const composite = compositeTaskMap[expandedTaskId];

      if (task) {
        const nowVisible =
          newFilter === 'all' || task.type === newFilter;
        if (!nowVisible) setExpandedTaskId(null);
      } else if (composite) {
        const nowVisible = newFilter === 'all' || newFilter === COMPOSITE_TYPE;
        if (!nowVisible) setExpandedTaskId(null);
      }
    }
  }

  /**
   * Creates a counting subtask from a parent counting task and partial count.
   * Adds the new task to the pool.
   *
   * @param task - The parent counting task
   * @param count - The partial count to allocate to the subtask
   */
  async function handleCreateCountingSubtask(task: Task, count: number): Promise<void> {
    setIsCreating(true);
    try {
      const newTask = await createTask(PLAYGROUND_USER_ID, {
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

  /**
   * Extracts a progress task step as a standalone task, then links the step back.
   *
   * @param step - The TaskStep to extract
   */
  async function handleExtractStep(step: TaskStep): Promise<void> {
    // If step already has a linked task, just add it to pool — don't create a duplicate
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

      const newTask = await createTask(PLAYGROUND_USER_ID, {
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

      // Link the step to the newly created task
      await db.taskSteps.update(step.id, {
        linkedTaskId: newTask.id,
        updatedAt: new Date().toISOString(),
      });

      addToPool({ taskId: newTask.id, title: newTask.title, type: newTask.type });
      showSuccess(`Added to board pool: "${newTask.title}"`);
    } catch (err) {
      console.error('Failed to extract step as task:', err);
    } finally {
      setIsCreating(false);
    }
  }

  // ── Existing Tasks tab filter logic ─────────────────────────────────────────

  const filteredTasks: Task[] =
    existingFilter === 'all'
      ? allTasks
      : existingFilter === COMPOSITE_TYPE
        ? []
        : allTasks.filter((t: Task) => t.type === existingFilter);

  const filteredCompositeTasks: CompositeTask[] =
    existingFilter === 'all' || existingFilter === COMPOSITE_TYPE ? allCompositeTasks : [];

  // ── Render: inline derivation panel for regular tasks ─────────────────────

  /**
   * Renders the inline derivation panel for a regular task in the Derive tab.
   *
   * @param task - The selected parent task
   */
  function renderInlineTaskPanel(task: Task): React.ReactElement {
    return (
      <div className={styles.inlinePanel}>
        {/* Add this task directly to pool */}
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

        {/* Derivation options (non-normal tasks only) */}
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

  /**
   * Renders the inline panel for a composite task — add directly + derivation.
   *
   * @param ct - The selected composite task
   */
  function renderInlineCompositePanel(ct: CompositeTask): React.ReactElement {
    return (
      <div className={styles.inlinePanel}>
        {/* Add this composite directly to pool */}
        <div className={styles.panelAddRow}>
          <span className={styles.panelAddLabel}>{ct.title}</span>
          {isInPool(ct.id) ? (
            <span className={styles.inPoolBadge}>In Pool</span>
          ) : (
            <button
              type="button"
              className={styles.addButton}
              onClick={() => {
                addToPool({ taskId: ct.id, title: ct.title, type: 'composite' });
                showSuccess(`Added to board pool: "${ct.title}"`);
              }}
            >
              Add to Pool
            </button>
          )}
        </div>

        {/* Derivation: inspect and add leaf nodes */}
        <div className={styles.panelDivider} />
        <span className={styles.panelSectionLabel}>Or add individual subtasks:</span>
        <CompositeDerivationPanel
          compositeTask={ct}
          allNodes={allCompositeNodes}
          taskMap={taskMap}
          compositeTaskMap={compositeTaskMap}
          onAddLeafToPool={(taskId: string, leafTitle: string, type: string) => {
            addToPool({ taskId, title: leafTitle, type });
            showSuccess(`Added to board pool: "${leafTitle}"`);
          }}
          isInPool={isInPool}
        />
      </div>
    );
  }

  // ── Render ─────────────────────────────────────────────────────────────────

  return (
    <div className={styles.container}>
      {/* Success message — shared across all tabs */}
      {creationSuccess && <div className={styles.successMessage}>{creationSuccess}</div>}

      {/* Top-level mode tabs — pool count shown on each tab when pool is non-empty */}
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
              document.getElementById('board-task-pool')?.scrollIntoView({ behavior: 'smooth' });
            }}
          >
            Pool: {boardPool.length}
          </button>
        )}
      </div>

      {/* ── Create New tab ── */}
      {mode === 'create' && (
        <div className={styles.modeSection}>
          {/* Type selector */}
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

          {/* Composite form */}
          {taskType === COMPOSITE_TYPE ? (
            <CompositeTaskForm
              onCreated={(ct: CompositeTask) =>
                addToPool({ taskId: ct.id, title: ct.title, type: 'composite' })
              }
            />
          ) : (
            <form className={styles.form} onSubmit={handleSubmit}>
              {/* Title */}
              <div className={styles.fieldGroup}>
                <label className={styles.label} htmlFor="bts-task-title">
                  Title
                  {taskType !== TaskType.COUNTING && <span className={styles.required}>*</span>}
                </label>
                <input
                  id="bts-task-title"
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
                {errors.title && (
                  <span className={styles.fieldError}>{errors.title}</span>
                )}
              </div>

              {/* Description */}
              <div className={styles.fieldGroup}>
                <label className={styles.label} htmlFor="bts-task-description">
                  Description
                </label>
                <textarea
                  id="bts-task-description"
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
                {errors.description && (
                  <span className={styles.fieldError}>{errors.description}</span>
                )}
              </div>

              {/* Counting fields */}
              {taskType === TaskType.COUNTING && (
                <div className={styles.countingFields}>
                  {/* Action */}
                  <div className={styles.fieldGroup}>
                    <label className={styles.label} htmlFor="bts-task-action">
                      Action<span className={styles.required}>*</span>
                    </label>
                    <input
                      id="bts-task-action"
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
                    {errors.action && (
                      <span className={styles.fieldError}>{errors.action}</span>
                    )}
                  </div>

                  {/* Max Count */}
                  <div className={styles.fieldGroup}>
                    <label className={styles.label} htmlFor="bts-task-maxcount">
                      Max Count<span className={styles.required}>*</span>
                    </label>
                    <input
                      id="bts-task-maxcount"
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
                    {errors.maxCount && (
                      <span className={styles.fieldError}>{errors.maxCount}</span>
                    )}
                  </div>

                  {/* Unit */}
                  <div className={styles.fieldGroup}>
                    <label className={styles.label} htmlFor="bts-task-unit">
                      Unit<span className={styles.required}>*</span>
                    </label>
                    <input
                      id="bts-task-unit"
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
                    {errors.unit && (
                      <span className={styles.fieldError}>{errors.unit}</span>
                    )}
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
                        idPrefix={`bts-step-${step.id}`}
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

              {/* General error */}
              {errors.general && (
                <div className={styles.errorMessage}>{errors.general}</div>
              )}

              {/* Submit */}
              <button
                type="submit"
                className={styles.submitButton}
                disabled={isSubmitting}
              >
                {isSubmitting ? 'Creating...' : 'Create & Add to Pool'}
              </button>
            </form>
          )}
        </div>
      )}

      {/* ── Existing Tasks tab ── */}
      {mode === 'existing' && (
        <div className={styles.modeSection}>
          {/* Browse mode sub-toggle — Task Library vs From Board */}
          <div className={styles.browseToggle}>
            <FilterTabs
              tabs={BROWSE_MODE_TABS}
              activeTab={existingBrowseMode}
              onTabChange={(value) => setExistingBrowseMode(value as ExistingBrowseMode)}
            />
          </div>

          {/* Task Library sub-view */}
          {existingBrowseMode === 'library' && (
            <>
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
                  {/* Regular tasks */}
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
                              title="Derive subtasks"
                            >
                              {expandedTaskId === task.id ? '▼' : '▶'}
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

                  {/* Composite tasks */}
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
                            title="Derive subtasks"
                          >
                            {expandedTaskId === ct.id ? '▼' : '▶'}
                          </button>
                          {isInPool(ct.id) ? (
                            <span className={styles.inPoolBadge}>In Pool</span>
                          ) : (
                            <button
                              type="button"
                              className={styles.addButton}
                              onClick={() => {
                                addToPool({ taskId: ct.id, title: ct.title, type: 'composite' });
                                showSuccess(`Added to board pool: "${ct.title}"`);
                              }}
                            >
                              Add
                            </button>
                          )}
                        </div>
                      </div>
                      {expandedTaskId === ct.id && renderInlineCompositePanel(ct)}
                    </div>
                  ))}
                </div>
              )}
            </>
          )}

          {/* From Board sub-view */}
          {existingBrowseMode === 'board' && (
            <>
              {/* Board list */}
              <section className={styles.boardSection}>
                <div className={styles.sectionHeader}>
                  <h4 className={styles.sectionTitle}>Boards</h4>
                  <button
                    type="button"
                    className={styles.demoBoardButton}
                    onClick={() => void handleCreateDemoBoard()}
                    disabled={isSettingUp}
                  >
                    {isSettingUp ? 'Creating...' : '+ Create Demo Board'}
                  </button>
                </div>

                {allBoards.length === 0 ? (
                  <p className={styles.emptyState}>
                    No boards yet. Click "Create Demo Board" above to get started.
                  </p>
                ) : (
                  <div className={styles.boardList}>
                    {allBoards.map((board: Board) => (
                      <button
                        key={board.id}
                        type="button"
                        className={`${styles.boardRow} ${selectedBoardId === board.id ? styles.boardRowActive : ''}`}
                        onClick={() => handleSelectBoard(board.id)}
                        aria-pressed={selectedBoardId === board.id}
                      >
                        <span className={styles.boardName}>{board.name}</span>
                        <span className={styles.boardSize}>{formatBoardSize(board)}</span>
                      </button>
                    ))}
                  </div>
                )}
              </section>

              {/* Board tasks grid — only shown when a board is selected */}
              {selectedBoardId !== null && (
                <section className={styles.boardSection}>
                  <h4 className={styles.sectionTitle}>
                    Tasks on Board
                    {boardTasks.length > 0 && (
                      <span className={styles.taskCount}>{boardTasks.length}</span>
                    )}
                  </h4>

                  {boardTasks.length === 0 ? (
                    <p className={styles.emptyState}>This board has no tasks assigned to it.</p>
                  ) : (
                    <div
                      className={styles.squareGrid}
                      style={{
                        gridTemplateColumns: `repeat(${selectedBoard?.boardSize ?? 3}, 90px)`,
                      }}
                    >
                      {(() => {
                        const size = selectedBoard?.boardSize ?? 3;
                        const btMap: Record<string, BoardTask> = {};
                        for (const bt of sortedBoardTasks) {
                          btMap[`${bt.row}-${bt.col}`] = bt;
                        }

                        const cells: React.ReactElement[] = [];
                        for (let row = 0; row < size; row++) {
                          for (let col = 0; col < size; col++) {
                            const bt = btMap[`${row}-${col}`];
                            if (!bt) {
                              const isCenter =
                                row === Math.floor(size / 2) &&
                                col === Math.floor(size / 2) &&
                                size % 2 === 1;
                              const showFree =
                                isCenter && selectedBoard?.centerSquareType === CenterSquareType.FREE;
                              cells.push(
                                <div key={`empty-${row}-${col}`} className={styles.emptySquare}>
                                  <span className={styles.emptySquareLabel}>
                                    {showFree ? 'FREE' : '—'}
                                  </span>
                                </div>
                              );
                              continue;
                            }

                            const task = taskMap[bt.taskId];
                            const composite = compositeTaskMap[bt.taskId];

                            if (task) {
                              const squareData = taskToSquareData(task, allTaskSteps);
                              const squareState = boardTaskToSquareState(bt);
                              const isSelected = boardSelectedTaskId === task.id;
                              cells.push(
                                <div
                                  key={bt.id}
                                  className={isSelected ? styles.squareSelected : undefined}
                                >
                                  <InteractiveTaskSquare
                                    sq={squareData}
                                    state={squareState}
                                    onAct={() =>
                                      setBoardSelectedTaskId((prev) =>
                                        prev === task.id ? null : task.id
                                      )
                                    }
                                    onContextMenu={(e) => {
                                      setBoardContextMenu({ squareId: task.id, x: e.clientX, y: e.clientY });
                                    }}
                                  />
                                </div>
                              );
                            } else if (composite) {
                              const squareData: TaskSquareData = {
                                id: composite.id,
                                title: composite.title,
                                type: 'normal',
                              };
                              const squareState = boardTaskToSquareState(bt);
                              const isSelected = boardSelectedTaskId === composite.id;
                              cells.push(
                                <div
                                  key={bt.id}
                                  className={isSelected ? styles.squareSelected : undefined}
                                >
                                  <InteractiveTaskSquare
                                    sq={squareData}
                                    state={squareState}
                                    onAct={() =>
                                      setBoardSelectedTaskId((prev) =>
                                        prev === composite.id ? null : composite.id
                                      )
                                    }
                                    onContextMenu={(e) => {
                                      setBoardContextMenu({ squareId: composite.id, x: e.clientX, y: e.clientY });
                                    }}
                                  />
                                </div>
                              );
                            } else {
                              cells.push(
                                <div key={bt.id} className={styles.emptySquare}>
                                  <span className={styles.emptySquareLabel}>?</span>
                                </div>
                              );
                            }
                          }
                        }
                        return cells;
                      })()}
                    </div>
                  )}

                  {/* Derivation panel — shown below the grid when a task is selected */}
                  {boardSelectedTaskId !== null && (() => {
                    const selectedTask = taskMap[boardSelectedTaskId] ?? null;
                    const selectedComposite = compositeTaskMap[boardSelectedTaskId] ?? null;
                    if (!selectedTask && !selectedComposite) return null;
                    return (
                      <div className={styles.derivationSection}>
                        {selectedTask && renderInlineTaskPanel(selectedTask)}
                        {selectedComposite && renderInlineCompositePanel(selectedComposite)}
                      </div>
                    );
                  })()}
                </section>
              )}
            </>
          )}
        </div>
      )}

      {/* ── Board grid context menu — pool-specific actions ── */}
      {boardContextMenu && (() => {
        const task = taskMap[boardContextMenu.squareId];
        const composite = compositeTaskMap[boardContextMenu.squareId];
        if (!task && !composite) return null;

        const id = task?.id ?? composite!.id;
        const title = task?.title ?? composite!.title;
        const type = task?.type ?? 'composite';
        const sqData: TaskSquareData = task
          ? taskToSquareData(task, allTaskSteps)
          : { id, title, type: 'normal' };
        const sqState: SquareState = { isCompleted: false, currentCount: 0, completedStepIds: new Set() };

        return (
          <FloatingContextMenu
            sq={sqData}
            state={sqState}
            position={{ x: boardContextMenu.x, y: boardContextMenu.y }}
            onClose={() => setBoardContextMenu(null)}
          >
            {/* Add to Pool */}
            {isInPool(id) ? (
              <div className={sqStyles.contextMenuItem} style={{ opacity: 0.5 }}>
                ✓ Already in Pool
              </div>
            ) : (
              <button
                className={sqStyles.contextMenuItem}
                onClick={() => {
                  addToPool({ taskId: id, title, type: String(type) });
                  showSuccess(`Added to pool: "${title}"`);
                  setBoardContextMenu(null);
                }}
              >
                + Add to Pool
              </button>
            )}

            {/* Progress tasks: individual step quick-adds */}
            {task?.type === TaskType.PROGRESS && (() => {
              const steps = allTaskSteps
                .filter((s) => s.taskId === task.id)
                .sort((a, b) => a.stepIndex - b.stepIndex);
              if (steps.length === 0) return null;
              return (
                <>
                  <div className={sqStyles.contextMenuDivider} />
                  {steps.map((step) => {
                    const linkedTask = step.linkedTaskId ? taskMap[step.linkedTaskId] : null;
                    const stepInPool = linkedTask ? isInPool(linkedTask.id) : false;
                    return (
                      <button
                        key={step.id}
                        className={sqStyles.contextMenuItem}
                        disabled={stepInPool || !linkedTask}
                        onClick={() => {
                          if (linkedTask && !stepInPool) {
                            addToPool({ taskId: linkedTask.id, title: linkedTask.title, type: linkedTask.type });
                            showSuccess(`Added step: "${linkedTask.title}"`);
                            setBoardContextMenu(null);
                          }
                        }}
                      >
                        {stepInPool ? `✓ ${step.title}` :
                         linkedTask ? `+ ${step.title}` :
                         `${step.title} (extract first)`}
                      </button>
                    );
                  })}
                </>
              );
            })()}

            {/* Derive option — only for non-normal tasks */}
            {(task ? canDerive(task.type) : !!composite) && (
              <>
                <div className={sqStyles.contextMenuDivider} />
                <button
                  className={sqStyles.contextMenuItem}
                  onClick={() => {
                    setBoardSelectedTaskId(id);
                    setBoardContextMenu(null);
                  }}
                >
                  {task?.type === TaskType.COUNTING ? '↓ Derive Subtask...' :
                   task?.type === TaskType.PROGRESS ? '↓ View All Steps...' :
                   '↓ Inspect Subtasks...'}
                </button>
              </>
            )}
          </FloatingContextMenu>
        );
      })()}

      {/* ── Board Task Pool — always visible ── */}
      <div id="board-task-pool" className={styles.poolSection}>
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
      {boardPool.length > 0 && (
        <BoardCreatorPanel
          pool={boardPool}
          taskMap={taskMap}
          allTaskSteps={allTaskSteps}
          userId={PLAYGROUND_USER_ID}
        />
      )}

      {/* Sticky floating pool indicator — visible when scrolled past the mode tabs */}
      {boardPool.length > 0 && (
        <button
          type="button"
          className={styles.stickyPoolChip}
          onClick={() => {
            document.getElementById('board-task-pool')?.scrollIntoView({ behavior: 'smooth' });
          }}
        >
          Board Task Pool: {boardPool.length}
        </button>
      )}
    </div>
  );
}
