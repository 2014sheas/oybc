import { useState, useCallback } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  TaskType,
  Timeframe,
  CenterSquareType,
  calculateProgressRollup,
  type BoardTask,
  type Task,
  type TaskStep,
} from '@oybc/shared';
import { db } from '../../db/database';
import { createTask } from '../../db/operations/tasks';
import { createBoard } from '../../db/operations/boards';
import { createBoardTask } from '../../db/operations/boardTasks';
import { PLAYGROUND_USER_ID, SUCCESS_DISMISS_MS } from './playgroundUtils';
import {
  InteractiveTaskSquare,
  DetailModal,
  FloatingContextMenu,
  type TaskSquareData,
  type SquareState,
  type ContextMenuState,
} from '../InteractiveTaskSquare';
import styles from './CrossBoardRollupPlayground.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

/**
 * Maps a parent task ID to the subtask task ID whose completion triggers
 * a counting rollup onto the parent.
 *
 * @property subtaskTaskId - The counting subtask's task ID
 */
interface CountingRelationship {
  subtaskTaskId: string;
}

/**
 * Associates a step-task (standalone task on Board B) with the step ID it
 * represents in the parent progress task, and the total step count for the
 * parent so rollup can determine completion.
 *
 * @property parentTaskId - Task ID of the progress parent on Board A
 * @property stepId - The TaskStep.id this standalone task represents
 * @property totalSteps - Total number of steps in the parent progress task
 */
interface StepRelationship {
  parentTaskId: string;
  stepId: string;
  totalSteps: number;
}

/**
 * All IDs and relationship maps produced after demo setup.
 */
interface DemoState {
  boardAId: string;
  boardBId: string;
  /** parent task ID → CountingRelationship */
  countingRelationships: Record<string, CountingRelationship>;
  /** step-task task ID → StepRelationship */
  stepRelationships: Record<string, StepRelationship>;
}

// ─── Adapters ─────────────────────────────────────────────────────────────────

/**
 * Converts a Task record (and its associated TaskStep records) to the
 * TaskSquareData shape expected by InteractiveTaskSquare.
 *
 * Steps are included for progress tasks so that `progressFraction` inside
 * InteractiveTaskSquare can compute the correct completion fraction using the
 * `completedStepIds` set derived from the BoardTask record.
 *
 * @param task - The Task record to adapt
 * @param taskSteps - All task steps for the user; filtered internally by task ID
 * @returns TaskSquareData suitable for InteractiveTaskSquare
 */
function taskToSquareData(task: Task, taskSteps: TaskStep[]): TaskSquareData {
  const type =
    task.type === TaskType.COUNTING
      ? 'counting'
      : task.type === TaskType.PROGRESS
        ? 'progress'
        : 'normal';

  const steps =
    task.type === TaskType.PROGRESS
      ? taskSteps
          .filter((s) => s.taskId === task.id)
          .sort((a, b) => a.stepIndex - b.stepIndex)
          .map((s) => ({ id: s.id, label: s.title }))
      : undefined;

  return {
    id: task.id,
    title: task.title,
    type,
    action: task.action ?? undefined,
    maxCount: task.maxCount ?? undefined,
    unit: task.unit ?? undefined,
    steps,
  };
}

/**
 * Converts a BoardTask record to the SquareState shape expected by
 * InteractiveTaskSquare.
 *
 * @param bt - The BoardTask record to adapt
 * @returns SquareState with completedStepIds as a Set
 */
function boardTaskToSquareState(bt: BoardTask): SquareState {
  return {
    isCompleted: bt.isCompleted,
    currentCount: bt.currentCount ?? 0,
    completedStepIds: new Set(bt.completedStepIds ?? []),
  };
}

// ─── Main component ───────────────────────────────────────────────────────────

/**
 * CrossBoardRollupPlayground demonstrates the SF3 cross-board progress rollup
 * feature: completing a subtask on Board B automatically propagates progress to
 * the parent task on Board A using `calculateCountingRollup` and
 * `calculateProgressRollup` from `@oybc/shared`.
 *
 * The demo creates:
 * - Board A ("Parent Board") with a counting parent "Read 100 pages" and a
 *   progress parent "Clean House" (3 steps: Vacuum, Dust, Mop).
 * - Board B ("Subtask Board") with an interactive counting subtask "Read 25 pages"
 *   and three step-task squares (Vacuum, Dust, Mop) that each map to a step on
 *   the progress parent.
 *
 * All DB writes follow the project convention: increment `version`, set
 * `updatedAt`. Reads are reactive via `useLiveQuery`.
 */
export function CrossBoardRollupPlayground(): React.ReactElement {
  // ── Setup / demo state ─────────────────────────────────────────────────────

  const [demoState, setDemoState] = useState<DemoState | null>(null);
  const [isSettingUp, setIsSettingUp] = useState(false);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  /** Board task IDs briefly highlighted after a rollup */
  const [highlightedBoardTaskIds, setHighlightedBoardTaskIds] = useState<Set<string>>(new Set());
  /** Board task ID currently open in the detail modal (Board B only) */
  const [selectedSquareId, setSelectedSquareId] = useState<string | null>(null);
  /** Active floating context menu state */
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null);

  // ── Success message helper ─────────────────────────────────────────────────

  /**
   * Displays a success/rollup message that auto-dismisses after SUCCESS_DISMISS_MS.
   *
   * @param message - The message to display
   */
  function showSuccess(message: string): void {
    setSuccessMessage(message);
    setTimeout(() => setSuccessMessage(null), SUCCESS_DISMISS_MS);
  }

  /**
   * Briefly highlights one or more board task squares to signal a rollup event.
   *
   * @param ids - Board task IDs to highlight
   */
  function highlightBoardTasks(ids: string[]): void {
    setHighlightedBoardTaskIds(new Set(ids));
    setTimeout(() => setHighlightedBoardTaskIds(new Set()), SUCCESS_DISMISS_MS);
  }

  // ── Reactive data ──────────────────────────────────────────────────────────

  /** All BoardTasks for Board A, reactively updated */
  const boardABoardTasks: BoardTask[] =
    useLiveQuery<BoardTask[]>(
      () =>
        demoState
          ? db.boardTasks.where('boardId').equals(demoState.boardAId).toArray()
          : Promise.resolve([] as BoardTask[]),
      [demoState?.boardAId]
    ) ?? [];

  /** All BoardTasks for Board B, reactively updated */
  const boardBBoardTasks: BoardTask[] =
    useLiveQuery<BoardTask[]>(
      () =>
        demoState
          ? db.boardTasks.where('boardId').equals(demoState.boardBId).toArray()
          : Promise.resolve([] as BoardTask[]),
      [demoState?.boardBId]
    ) ?? [];

  /** All tasks for the playground user, for resolving task metadata */
  const allTasks: Task[] =
    useLiveQuery(
      () =>
        db.tasks
          .filter((t: Task) => t.userId === PLAYGROUND_USER_ID && !t.isDeleted)
          .toArray(),
      []
    ) ?? [];

  /** All task steps for the playground user (to resolve step IDs) */
  const allTaskSteps: TaskStep[] =
    useLiveQuery(
      () =>
        db.taskSteps.filter((s: TaskStep) => !s.isDeleted).toArray(),
      []
    ) ?? [];

  // Build task lookup map
  const taskMap: Record<string, Task> = {};
  for (const t of allTasks) taskMap[t.id] = t;

  // ── Demo setup ─────────────────────────────────────────────────────────────

  /**
   * Creates all demo boards, tasks, and board tasks for the rollup demonstration.
   * Stores relationship maps in component state so handlers can look up parents
   * without additional DB reads.
   */
  const handleSetUp = useCallback(async () => {
    setIsSettingUp(true);
    try {
      // Shared date range for demo boards (no real timeframe enforced)
      const demoStart = new Date().toISOString();
      const demoEnd = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();

      // ── Create Board A ("Parent Board") ──────────────────────────────────
      const boardA = await createBoard(PLAYGROUND_USER_ID, {
        name: 'Parent Board',
        boardSize: 3,
        timeframe: Timeframe.CUSTOM,
        startDate: demoStart,
        endDate: demoEnd,
        centerSquareType: CenterSquareType.NONE,
        isRandomized: false,
      });

      // ── Create Board B ("Subtask Board") ─────────────────────────────────
      const boardB = await createBoard(PLAYGROUND_USER_ID, {
        name: 'Subtask Board',
        boardSize: 3,
        timeframe: Timeframe.CUSTOM,
        startDate: demoStart,
        endDate: demoEnd,
        centerSquareType: CenterSquareType.NONE,
        isRandomized: false,
      });

      // ── Create tasks ──────────────────────────────────────────────────────

      // Counting parent: "Read 100 pages" (Board A, row 0, col 0)
      const countingParent = await createTask(PLAYGROUND_USER_ID, {
        type: TaskType.COUNTING,
        title: 'Read 100 pages',
        action: 'Read',
        unit: 'pages',
        maxCount: 100,
      });

      // Progress parent: "Clean House" with 3 steps (Board A, row 0, col 1)
      const progressParent = await createTask(PLAYGROUND_USER_ID, {
        type: TaskType.PROGRESS,
        title: 'Clean House',
        steps: [
          { title: 'Vacuum', type: TaskType.NORMAL },
          { title: 'Dust', type: TaskType.NORMAL },
          { title: 'Mop', type: TaskType.NORMAL },
        ],
      });

      // Fetch steps for progressParent so we have their IDs
      const progressSteps = await db.taskSteps
        .filter((s: TaskStep) => s.taskId === progressParent.id && !s.isDeleted)
        .sortBy('stepIndex');

      // Counting subtask: "Read 25 pages" (Board B, row 0, col 0)
      const countingSubtask = await createTask(PLAYGROUND_USER_ID, {
        type: TaskType.COUNTING,
        title: 'Read 25 pages',
        action: 'Read',
        unit: 'pages',
        maxCount: 25,
      });

      // Step tasks on Board B — one for each progress step
      // progressSteps are in order: [Vacuum, Dust, Mop]
      const stepTask0 = await createTask(PLAYGROUND_USER_ID, {
        type: TaskType.NORMAL,
        title: 'Vacuum',
      });
      const stepTask1 = await createTask(PLAYGROUND_USER_ID, {
        type: TaskType.NORMAL,
        title: 'Dust',
      });
      const stepTask2 = await createTask(PLAYGROUND_USER_ID, {
        type: TaskType.NORMAL,
        title: 'Mop',
      });

      // ── Create BoardTasks ─────────────────────────────────────────────────

      // Board A
      await createBoardTask({
        boardId: boardA.id,
        taskId: countingParent.id,
        row: 0,
        col: 0,
        isCenter: false,
      });
      await createBoardTask({
        boardId: boardA.id,
        taskId: progressParent.id,
        row: 0,
        col: 1,
        isCenter: false,
      });

      // Board B
      await createBoardTask({
        boardId: boardB.id,
        taskId: countingSubtask.id,
        row: 0,
        col: 0,
        isCenter: false,
      });
      // Step tasks at fixed positions
      await createBoardTask({
        boardId: boardB.id,
        taskId: stepTask0.id,
        row: 0,
        col: 1,
        isCenter: false,
      });
      await createBoardTask({
        boardId: boardB.id,
        taskId: stepTask1.id,
        row: 0,
        col: 2,
        isCenter: false,
      });
      await createBoardTask({
        boardId: boardB.id,
        taskId: stepTask2.id,
        row: 1,
        col: 0,
        isCenter: false,
      });

      // ── Build relationship maps ────────────────────────────────────────────

      const countingRelationships: Record<string, CountingRelationship> = {
        [countingParent.id]: { subtaskTaskId: countingSubtask.id },
      };

      const stepRelationships: Record<string, StepRelationship> = {};
      // Map each step-task's task ID to its parent step ID and total step count
      const totalSteps = progressSteps.length;
      if (progressSteps[0]) {
        stepRelationships[stepTask0.id] = {
          parentTaskId: progressParent.id,
          stepId: progressSteps[0].id,
          totalSteps,
        };
      }
      if (progressSteps[1]) {
        stepRelationships[stepTask1.id] = {
          parentTaskId: progressParent.id,
          stepId: progressSteps[1].id,
          totalSteps,
        };
      }
      if (progressSteps[2]) {
        stepRelationships[stepTask2.id] = {
          parentTaskId: progressParent.id,
          stepId: progressSteps[2].id,
          totalSteps,
        };
      }

      setDemoState({
        boardAId: boardA.id,
        boardBId: boardB.id,
        countingRelationships,
        stepRelationships,
      });
    } catch (err) {
      console.error('CrossBoardRollupPlayground: setup failed', err);
    } finally {
      setIsSettingUp(false);
    }
  }, []);

  /**
   * Soft-deletes all demo boards (and their board tasks via absence of hard
   * delete) and clears component state to allow a fresh setup.
   */
  const handleReset = useCallback(async () => {
    if (!demoState) return;
    try {
      const now = new Date().toISOString();
      // Soft-delete boards
      await db.boards.update(demoState.boardAId, { isDeleted: true, updatedAt: now });
      await db.boards.update(demoState.boardBId, { isDeleted: true, updatedAt: now });
      // Remove all board tasks for these boards
      const allBoardTaskIds = [
        ...boardABoardTasks.map((bt) => bt.id),
        ...boardBBoardTasks.map((bt) => bt.id),
      ];
      await Promise.all(allBoardTaskIds.map((id) => db.boardTasks.delete(id)));
    } catch (err) {
      console.error('CrossBoardRollupPlayground: reset failed', err);
    }
    setDemoState(null);
    setSuccessMessage(null);
    setHighlightedBoardTaskIds(new Set());
    setSelectedSquareId(null);
    setContextMenu(null);
  }, [demoState, boardABoardTasks, boardBBoardTasks]);

  // ── Interaction handlers ───────────────────────────────────────────────────

  /**
   * Handles tapping a counting subtask square on Board B.
   *
   * Increments the subtask's currentCount by 1. If the subtask is now
   * complete (currentCount >= maxCount), calls `calculateCountingRollup`
   * to update all parent board tasks on Board A that use the counting parent task.
   *
   * @param subtaskBoardTask - The BoardTask record for the tapped subtask square
   */
  const handleCountingSubtaskTap = useCallback(
    async (subtaskBoardTask: BoardTask) => {
      if (!demoState) return;
      const subtaskTask = taskMap[subtaskBoardTask.taskId];
      if (!subtaskTask) return;

      const newCount = (subtaskBoardTask.currentCount ?? 0) + 1;
      const maxCount = subtaskTask.maxCount ?? 0;
      const isNowCompleted = newCount >= maxCount;
      const now = new Date().toISOString();

      // Update subtask boardTask
      await db.boardTasks.update(subtaskBoardTask.id, {
        currentCount: newCount,
        isCompleted: isNowCompleted,
        ...(isNowCompleted ? { completedAt: now } : {}),
        updatedAt: now,
        version: (subtaskBoardTask.version ?? 1) + 1,
      });

      // Roll up every increment to the parent on Board A
      const parentTaskId = Object.keys(demoState.countingRelationships).find(
        (pId) => demoState.countingRelationships[pId].subtaskTaskId === subtaskTask.id
      );
      if (parentTaskId) {
        const parentTask = taskMap[parentTaskId];
        if (parentTask) {
          const parentBoardTasks = boardABoardTasks.filter(
            (bt) => bt.taskId === parentTaskId
          );

          const rollupHighlightIds: string[] = [];

          for (const parentBT of parentBoardTasks) {
            const parentNewCount = Math.min(
              (parentBT.currentCount ?? 0) + 1,
              parentTask.maxCount!
            );
            const parentCompleted = parentNewCount >= parentTask.maxCount!;
            await db.boardTasks.update(parentBT.id, {
              currentCount: parentNewCount,
              isCompleted: parentCompleted,
              ...(parentCompleted ? { completedAt: now } : {}),
              updatedAt: now,
              version: (parentBT.version ?? 1) + 1,
            });
            rollupHighlightIds.push(parentBT.id);
          }

          if (rollupHighlightIds.length > 0) {
            highlightBoardTasks(rollupHighlightIds);
            showSuccess(
              `Rollup: +1 → "${parentTask.title}" now ${Math.min((boardABoardTasks.find(bt => bt.taskId === parentTaskId)?.currentCount ?? 0) + 1, parentTask.maxCount!)}/${parentTask.maxCount} pages`
            );
          }
        }
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [demoState, taskMap, boardABoardTasks]
  );

  /**
   * Handles decrementing a counting subtask square on Board B.
   *
   * Decrements the subtask's currentCount by 1 (minimum 0) and unmarks
   * completion if it was previously complete. Also decrements the parent
   * task's count on Board A by 1 (minimum 0) and unmarks parent completion
   * if needed.
   *
   * @param subtaskBoardTask - The BoardTask record for the counting subtask square
   */
  const handleCountingSubtaskDecrement = useCallback(
    async (subtaskBoardTask: BoardTask) => {
      if (!demoState) return;
      const subtaskTask = taskMap[subtaskBoardTask.taskId];
      if (!subtaskTask) return;

      const prevCount = subtaskBoardTask.currentCount ?? 0;
      if (prevCount <= 0) return;

      const newCount = prevCount - 1;
      const wasCompleted = subtaskBoardTask.isCompleted;
      const now = new Date().toISOString();

      // Update subtask boardTask
      await db.boardTasks.update(subtaskBoardTask.id, {
        currentCount: newCount,
        isCompleted: false,
        ...(wasCompleted ? { completedAt: undefined } : {}),
        updatedAt: now,
        version: (subtaskBoardTask.version ?? 1) + 1,
      });

      // Reverse rollup: decrement parent count on Board A
      const parentTaskId = Object.keys(demoState.countingRelationships).find(
        (pId) => demoState.countingRelationships[pId].subtaskTaskId === subtaskTask.id
      );
      if (parentTaskId) {
        const parentTask = taskMap[parentTaskId];
        if (parentTask) {
          const parentBoardTasks = boardABoardTasks.filter(
            (bt) => bt.taskId === parentTaskId
          );

          const rollupHighlightIds: string[] = [];

          for (const parentBT of parentBoardTasks) {
            const parentPrevCount = parentBT.currentCount ?? 0;
            const parentNewCount = Math.max(parentPrevCount - 1, 0);
            const parentWasCompleted = parentBT.isCompleted;
            await db.boardTasks.update(parentBT.id, {
              currentCount: parentNewCount,
              isCompleted: false,
              ...(parentWasCompleted ? { completedAt: undefined } : {}),
              updatedAt: now,
              version: (parentBT.version ?? 1) + 1,
            });
            rollupHighlightIds.push(parentBT.id);
          }

          if (rollupHighlightIds.length > 0) {
            highlightBoardTasks(rollupHighlightIds);
            showSuccess(
              `Rollup: −1 → "${parentTask.title}" count decreased`
            );
          }
        }
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [demoState, taskMap, boardABoardTasks]
  );

  /**
   * Handles tapping a step-task square on Board B.
   *
   * Toggles the step-task's completion state. If the step was just completed,
   * calls `calculateProgressRollup` to update the parent progress board task
   * on Board A with the new completedStepIds.
   *
   * @param stepBoardTask - The BoardTask record for the tapped step-task square
   */
  const handleStepTaskTap = useCallback(
    async (stepBoardTask: BoardTask) => {
      if (!demoState) return;
      const stepTask = taskMap[stepBoardTask.taskId];
      if (!stepTask) return;

      const nowCompleted = !stepBoardTask.isCompleted;
      const now = new Date().toISOString();

      // Update step boardTask
      await db.boardTasks.update(stepBoardTask.id, {
        isCompleted: nowCompleted,
        ...(nowCompleted ? { completedAt: now } : { completedAt: undefined }),
        updatedAt: now,
        version: (stepBoardTask.version ?? 1) + 1,
      });

      // If just completed, roll up to parent progress task on Board A
      if (nowCompleted) {
        const rel = demoState.stepRelationships[stepTask.id];
        if (!rel) return;

        const parentTask = taskMap[rel.parentTaskId];
        if (!parentTask) return;

        // Find all BoardTasks on Board A that use the parent progress task
        const parentBoardTasks = boardABoardTasks.filter(
          (bt) => bt.taskId === rel.parentTaskId
        );

        const rollupHighlightIds: string[] = [];

        for (const parentBT of parentBoardTasks) {
          const result = calculateProgressRollup(
            parentBT.completedStepIds ?? [],
            rel.stepId,
            rel.totalSteps
          );
          await db.boardTasks.update(parentBT.id, {
            completedStepIds: result.newCompletedStepIds,
            isCompleted: result.isCompleted,
            ...(result.isCompleted ? { completedAt: now } : {}),
            updatedAt: now,
            version: (parentBT.version ?? 1) + 1,
          });
          rollupHighlightIds.push(parentBT.id);
          showSuccess(
            `Rollup: "${stepTask.title}" completed → "${parentTask.title}" now ${result.newCompletedStepIds.length}/${rel.totalSteps} steps`
          );
        }

        if (rollupHighlightIds.length > 0) {
          highlightBoardTasks(rollupHighlightIds);
        }
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [demoState, taskMap, boardABoardTasks]
  );

  // ── Render ─────────────────────────────────────────────────────────────────

  // Pre-setup screen
  if (!demoState) {
    return (
      <div className={styles.container}>
        <div className={styles.setupSection}>
          <p className={styles.setupDescription}>
            This demo shows SF3: completing a subtask on Board B automatically updates
            the parent task's progress on Board A. Click "Set Up Demo Boards" to create
            two boards with pre-linked parent and subtask relationships.
          </p>
          <button
            type="button"
            className={styles.setupButton}
            onClick={() => void handleSetUp()}
            disabled={isSettingUp}
          >
            {isSettingUp ? 'Setting up...' : 'Set Up Demo Boards'}
          </button>
        </div>
      </div>
    );
  }

  // Sort board tasks by row then col for consistent ordering
  const sortedBoardA = [...boardABoardTasks].sort((a, b) =>
    a.row !== b.row ? a.row - b.row : a.col - b.col
  );
  const sortedBoardB = [...boardBBoardTasks].sort((a, b) =>
    a.row !== b.row ? a.row - b.row : a.col - b.col
  );

  return (
    <div className={styles.container}>
      {/* Success / rollup message */}
      {successMessage && (
        <div className={styles.successMessage} role="status" aria-live="polite">
          {successMessage}
        </div>
      )}

      {/* Controls */}
      <div className={styles.controls}>
        <button
          type="button"
          className={styles.resetButton}
          onClick={() => void handleReset()}
        >
          Reset Demo
        </button>
      </div>

      {/* Legend */}
      <div className={styles.legend}>
        <span className={styles.legendItem}>
          Board A — parent tasks (read-only, updated via rollup)
        </span>
        <span>·</span>
        <span className={styles.legendItem}>
          Board B — subtasks (click to act, right-click for details)
        </span>
        <span>·</span>
        <span className={styles.legendItem}>
          Blue ring = rollup just fired
        </span>
      </div>

      {/* Side-by-side board cards */}
      <div className={styles.boardsLayout}>
        {/* Board A — Parent Board */}
        <div className={styles.boardCard}>
          <div className={styles.boardHeader}>
            <p className={styles.boardTitle}>Board A — Parent Board</p>
            <p className={styles.boardSubtitle}>Updates automatically when subtasks complete</p>
          </div>
          <div className={styles.boardBody}>
            {sortedBoardA.length === 0 ? (
              <p className={styles.loadingState}>Loading…</p>
            ) : (
              <div className={styles.squareGrid}>
                {sortedBoardA.map((bt) => {
                  const task = taskMap[bt.taskId];
                  if (!task) return null;
                  const squareData = taskToSquareData(task, allTaskSteps);
                  const squareState = boardTaskToSquareState(bt);
                  const isHighlighted = highlightedBoardTaskIds.has(bt.id);
                  return (
                    <div
                      key={bt.id}
                      className={isHighlighted ? styles.squareRollupHighlight : undefined}
                    >
                      <InteractiveTaskSquare
                        sq={squareData}
                        state={squareState}
                        onAct={() => {}}
                      />
                    </div>
                  );
                })}
              </div>
            )}
          </div>
        </div>

        {/* Board B — Subtask Board */}
        <div className={styles.boardCard}>
          <div className={styles.boardHeader}>
            <p className={styles.boardTitle}>Board B — Subtask Board</p>
            <p className={styles.boardSubtitle}>Click to act · Right-click for details</p>
          </div>
          <div className={styles.boardBody}>
            {sortedBoardB.length === 0 ? (
              <p className={styles.loadingState}>Loading…</p>
            ) : (
              <div className={styles.squareGrid}>
                {sortedBoardB.map((bt) => {
                  const task = taskMap[bt.taskId];
                  if (!task) return null;
                  const squareData = taskToSquareData(task, allTaskSteps);
                  const squareState = boardTaskToSquareState(bt);
                  return (
                    <InteractiveTaskSquare
                      key={bt.id}
                      sq={squareData}
                      state={squareState}
                      onAct={() => {
                        // Match established interaction pattern from TaskSquareActionsPlayground:
                        // Normal: click toggles directly (+ rollup)
                        // Counting: click increments +1 directly (+ rollup)
                        // Progress: click opens detail modal
                        if (squareData.type === 'progress') {
                          setSelectedSquareId(bt.id);
                        } else if (squareData.type === 'normal') {
                          void handleStepTaskTap(bt);
                        } else if (squareData.type === 'counting') {
                          void handleCountingSubtaskTap(bt);
                        }
                      }}
                      onContextMenu={(e) => {
                        setContextMenu({ squareId: bt.id, x: e.clientX, y: e.clientY });
                      }}
                    />
                  );
                })}
              </div>
            )}
          </div>
        </div>
      </div>

      {/* Detail modal — Board B squares only (Board A is read-only via rollup) */}
      {selectedSquareId && (() => {
        const bt = boardBBoardTasks.find((b) => b.id === selectedSquareId);
        if (!bt) return null;
        const task = taskMap[bt.taskId];
        if (!task) return null;
        const squareData = taskToSquareData(task, allTaskSteps);
        const squareState = boardTaskToSquareState(bt);

        return (
          <DetailModal
            sq={squareData}
            state={squareState}
            onClose={() => setSelectedSquareId(null)}
            onToggleComplete={() => {
              void handleStepTaskTap(bt);
            }}
            onIncrementCount={() => {
              void handleCountingSubtaskTap(bt);
            }}
            onDecrementCount={() => {
              void handleCountingSubtaskDecrement(bt);
            }}
            onToggleStep={() => {}}
          />
        );
      })()}

      {/* Floating context menu — Board B squares only */}
      {contextMenu && (() => {
        const bt = boardBBoardTasks.find((b) => b.id === contextMenu.squareId);
        if (!bt) return null;
        const task = taskMap[bt.taskId];
        if (!task) return null;
        const squareData = taskToSquareData(task, allTaskSteps);
        const squareState = boardTaskToSquareState(bt);

        return (
          <FloatingContextMenu
            sq={squareData}
            state={squareState}
            position={{ x: contextMenu.x, y: contextMenu.y }}
            onClose={() => setContextMenu(null)}
            onToggleComplete={() => { void handleStepTaskTap(bt); setContextMenu(null); }}
            onIncrementCount={() => { void handleCountingSubtaskTap(bt); setContextMenu(null); }}
            onDecrementCount={() => { void handleCountingSubtaskDecrement(bt); setContextMenu(null); }}
            onResetCount={() => { setContextMenu(null); }}
            onMarkAllStepsComplete={() => { setContextMenu(null); }}
            onMarkAllStepsIncomplete={() => { setContextMenu(null); }}
            onViewDetails={() => { setSelectedSquareId(bt.id); setContextMenu(null); }}
          />
        );
      })()}
    </div>
  );
}
