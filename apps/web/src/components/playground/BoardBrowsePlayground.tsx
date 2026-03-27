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
import { PoolItem } from '../PoolItem';
import { CountingDerivationPanel } from '../CountingDerivationPanel';
import { ProgressDerivationPanel } from '../ProgressDerivationPanel';
import { CompositeDerivationPanel } from '../CompositeDerivationPanel';
import {
  InteractiveTaskSquare,
  type TaskSquareData,
  type SquareState,
} from '../InteractiveTaskSquare';
import { PLAYGROUND_USER_ID, SUCCESS_DISMISS_MS } from './playgroundUtils';
import styles from './BoardBrowsePlayground.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

/**
 * Entry in the Board Task Pool staging area.
 * Tracks the task ID, display title, and type for rendering.
 */
interface PoolEntry {
  taskId: string;
  title: string;
  type: string;
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
 * @param taskSteps - All task steps; filtered internally by task ID
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
 * BoardBrowsePlayground — SF4 playground for browsing boards to find parent tasks
 * for subtask derivation.
 *
 * UI Flow: Board List → Select Board → Board's Tasks (grid squares) → Select Task →
 *          Derivation Panel (below grid) → Board Pool
 *
 * Users can browse all boards created for the playground user, select a board to
 * see its tasks rendered as InteractiveTaskSquare tiles, and then select a tile to
 * open the appropriate derivation panel below the grid. Derived subtasks are staged
 * in the Board Task Pool at the bottom.
 *
 * All reads are reactive via Dexie live queries. Writes use createTask() and
 * direct Dexie updates. Success messages auto-dismiss after SUCCESS_DISMISS_MS.
 */
export function BoardBrowsePlayground(): React.ReactElement {
  const [selectedBoardId, setSelectedBoardId] = useState<string | null>(null);
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null);
  const [partialCount, setPartialCount] = useState<string>('');
  const [isCreating, setIsCreating] = useState(false);
  const [isSettingUp, setIsSettingUp] = useState(false);
  const [creationSuccess, setCreationSuccess] = useState<string | null>(null);
  const [boardPool, setBoardPool] = useState<PoolEntry[]>([]);

  // ── Success message helper ─────────────────────────────────────────────────

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
   * Creates a fully populated 3×3 demo board with a mix of task types.
   * Includes counting, progress, and normal tasks so derivation panels
   * can be tested for all types.
   */
  async function handleCreateDemoBoard(): Promise<void> {
    setIsSettingUp(true);
    try {
      const demoStart = new Date().toISOString();
      const demoEnd = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();

      // Create a mix of task types
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

      // Create tasks
      const createdTasks: Task[] = [];
      for (const def of taskDefs) {
        const task = await createTask(PLAYGROUND_USER_ID, def);
        createdTasks.push(task);
      }

      // Shuffle and pick 8 for a 3×3 board (center = free space)
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

      // Place 8 tasks on non-center positions
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

  // ── Reactive data sources ──────────────────────────────────────────────────

  /** All non-deleted boards for the playground user */
  const allBoards = useBoards(PLAYGROUND_USER_ID) ?? [];

  /** Board tasks for the currently selected board */
  const boardTasks = useBoardTasks(selectedBoardId ?? '') ?? [];

  /** All non-deleted tasks for the playground user (for task lookup) */
  const allTasks = useTasks(PLAYGROUND_USER_ID) ?? [];

  /** All non-deleted task steps (for feeding step data into taskToSquareData) */
  const allTaskSteps: TaskStep[] =
    useLiveQuery(
      () => db.taskSteps.filter((s: TaskStep) => !s.isDeleted).toArray(),
      []
    ) ?? [];

  /** All non-deleted composite tasks for the playground user */
  const allCompositeTasks =
    useLiveQuery(
      () =>
        db.compositeTasks
          .filter((ct: CompositeTask) => ct.userId === PLAYGROUND_USER_ID && !ct.isDeleted)
          .toArray(),
      []
    ) ?? [];

  /** All composite nodes (filtering per-composite happens in the panel) */
  const allCompositeNodes =
    useLiveQuery(
      () => db.compositeNodes.filter((n: CompositeNode) => !n.isDeleted).toArray(),
      []
    ) ?? [];

  // ── Derived values ─────────────────────────────────────────────────────────

  /** The currently selected board (for reading boardSize) */
  const selectedBoard = selectedBoardId
    ? allBoards.find((b: Board) => b.id === selectedBoardId) ?? null
    : null;

  const taskMap: Record<string, Task> = {};
  for (const t of allTasks) taskMap[t.id] = t;

  const compositeTaskMap: Record<string, CompositeTask> = {};
  for (const ct of allCompositeTasks) compositeTaskMap[ct.id] = ct;

  // ── Handlers ──────────────────────────────────────────────────────────────

  /**
   * Selects a board by ID. Clears task selection and counting input.
   *
   * @param boardId - The board ID to select, or null to deselect
   */
  function handleSelectBoard(boardId: string): void {
    setSelectedBoardId((prev) => (prev === boardId ? null : boardId));
    setSelectedTaskId(null);
    setPartialCount('');
  }

  /**
   * Selects a task by ID, resetting the counting input.
   * Toggling the same task deselects it.
   *
   * @param taskId - The task or composite task ID to select
   */
  function handleSelectTask(taskId: string): void {
    setSelectedTaskId((prev) => (prev === taskId ? null : taskId));
    setPartialCount('');
  }

  /**
   * Adds a task to the board pool staging area. Skips duplicates.
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
   * Creates a counting subtask from a parent counting task and a partial count.
   * Persists the new task to the task library and adds it to the board pool.
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
   * Extracts a progress task step as a standalone task, then links the step back
   * to the newly created task via its linkedTaskId field.
   *
   * @param step - The TaskStep to extract
   */
  async function handleExtractStep(step: TaskStep): Promise<void> {
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

  // ── Render helpers ─────────────────────────────────────────────────────────

  /**
   * Formats a board's size for display (e.g. "3×3").
   *
   * @param board - The Board record
   * @returns Size string such as "3×3"
   */
  function formatBoardSize(board: Board): string {
    return `${board.boardSize}×${board.boardSize}`;
  }

  /**
   * Renders the derivation panel for a regular task, shown below the square grid.
   *
   * @param task - The selected task
   */
  function renderInlineTaskPanel(task: Task): React.ReactElement {
    return (
      <div className={styles.inlinePanel}>
        {task.type === TaskType.NORMAL && (
          <p className={styles.normalMessage}>
            Normal tasks cannot be subdivided. Select a Counting, Progress, or Composite task to
            see derivation options.
          </p>
        )}
        {task.type === TaskType.COUNTING && (
          <CountingDerivationPanel
            task={task}
            partialCount={partialCount}
            onPartialCountChange={setPartialCount}
            onCreateSubtask={handleCreateCountingSubtask}
            isCreating={isCreating}
          />
        )}
        {task.type === TaskType.PROGRESS && (
          <ProgressDerivationPanel
            taskId={task.id}
            onExtractStep={handleExtractStep}
            onAddStepToPool={(step: TaskStep) => {
              if (step.linkedTaskId) {
                const linkedTask = taskMap[step.linkedTaskId];
                if (linkedTask) {
                  addToPool({
                    taskId: linkedTask.id,
                    title: linkedTask.title,
                    type: linkedTask.type,
                  });
                  showSuccess(`Added to board pool: "${linkedTask.title}"`);
                }
              }
            }}
            isCreating={isCreating}
            isInPool={(taskId: string) => boardPool.some((e) => e.taskId === taskId)}
          />
        )}
      </div>
    );
  }

  /**
   * Renders the derivation panel for a composite task, shown below the square grid.
   *
   * @param ct - The selected composite task
   */
  function renderInlineCompositePanel(ct: CompositeTask): React.ReactElement {
    return (
      <div className={styles.inlinePanel}>
        <CompositeDerivationPanel
          compositeTask={ct}
          allNodes={allCompositeNodes}
          taskMap={taskMap}
          compositeTaskMap={compositeTaskMap}
          onAddLeafToPool={(taskId: string, title: string, type: string) => {
            addToPool({ taskId, title, type });
            showSuccess(`Added to board pool: "${title}"`);
          }}
          isInPool={(taskId: string) => boardPool.some((e) => e.taskId === taskId)}
        />
      </div>
    );
  }

  // Sorted board tasks by row then col for consistent grid ordering
  const sortedBoardTasks = [...boardTasks].sort((a, b) =>
    a.row !== b.row ? a.row - b.row : a.col - b.col
  );

  // Resolve selected task or composite for the derivation panel
  const selectedTask = selectedTaskId ? taskMap[selectedTaskId] : null;
  const selectedComposite = selectedTaskId ? compositeTaskMap[selectedTaskId] : null;

  // ── Render ─────────────────────────────────────────────────────────────────

  return (
    <div className={styles.container}>
      {/* Success message */}
      {creationSuccess && <div className={styles.successMessage}>{creationSuccess}</div>}

      {/* Board list section */}
      <section className={styles.section}>
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

      {/* Board tasks section — only shown when a board is selected */}
      {selectedBoardId !== null && (
        <section className={styles.section}>
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
                // Build a grid with all cells, including empty ones
                const btMap: Record<string, BoardTask> = {};
                for (const bt of sortedBoardTasks) {
                  btMap[`${bt.row}-${bt.col}`] = bt;
                }

                const cells: React.ReactElement[] = [];
                for (let row = 0; row < size; row++) {
                  for (let col = 0; col < size; col++) {
                    const bt = btMap[`${row}-${col}`];
                    if (!bt) {
                      // Empty cell — show "FREE" only at the center when board uses a free center type
                      const isCenter = row === Math.floor(size / 2) && col === Math.floor(size / 2) && size % 2 === 1;
                      const showFree = isCenter && selectedBoard?.centerSquareType === CenterSquareType.FREE;
                      cells.push(
                        <div key={`empty-${row}-${col}`} className={styles.emptySquare}>
                          <span className={styles.emptySquareLabel}>{showFree ? 'FREE' : '—'}</span>
                        </div>
                      );
                      continue;
                    }

                    const task = taskMap[bt.taskId];
                    const composite = compositeTaskMap[bt.taskId];

                    if (task) {
                      const squareData = taskToSquareData(task, allTaskSteps);
                      const squareState = boardTaskToSquareState(bt);
                      const isSelected = selectedTaskId === task.id;
                      cells.push(
                        <div
                          key={bt.id}
                          className={isSelected ? styles.squareSelected : undefined}
                        >
                          <InteractiveTaskSquare
                            sq={squareData}
                            state={squareState}
                            onAct={() => handleSelectTask(task.id)}
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
                      const isSelected = selectedTaskId === composite.id;
                      cells.push(
                        <div
                          key={bt.id}
                          className={isSelected ? styles.squareSelected : undefined}
                        >
                          <InteractiveTaskSquare
                            sq={squareData}
                            state={squareState}
                            onAct={() => handleSelectTask(composite.id)}
                          />
                        </div>
                      );
                    } else {
                      // Task not yet loaded — empty placeholder
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
          {selectedTaskId !== null && (selectedTask || selectedComposite) && (
            <div className={styles.derivationSection}>
              {selectedTask && renderInlineTaskPanel(selectedTask)}
              {selectedComposite && renderInlineCompositePanel(selectedComposite)}
            </div>
          )}
        </section>
      )}

      {/* Board Task Pool */}
      <div className={styles.poolSection}>
        <h4 className={styles.poolTitle}>
          Board Task Pool
          {boardPool.length > 0 && <span className={styles.poolCount}>{boardPool.length}</span>}
        </h4>
        {boardPool.length === 0 ? (
          <p className={styles.emptyState}>
            No tasks in the pool yet. Browse a board and use the buttons above to add subtasks.
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
    </div>
  );
}
