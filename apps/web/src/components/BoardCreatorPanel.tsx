import { useState } from 'react';
import {
  CenterSquareType,
  Timeframe,
  fisherYatesShuffle,
  TaskType,
  type Task,
  type TaskStep,
  type BoardTask,
} from '@oybc/shared';
import { useBoardTasks } from '../hooks';
import { createBoard } from '../db/operations/boards';
import { createBoardTask } from '../db/operations/boardTasks';
import {
  InteractiveTaskSquare,
  type TaskSquareData,
  type SquareState,
} from './InteractiveTaskSquare';
import styles from './BoardCreatorPanel.module.css';

// ─── Types ────────────────────────────────────────────────────────────────────

/** Entry in the board task pool passed from the parent playground */
export interface PoolEntry {
  taskId: string;
  title: string;
  type: string;
}

export interface BoardCreatorPanelProps {
  /** Pool of tasks staged for board creation */
  pool: PoolEntry[];
  /** Record mapping task IDs to Task objects for resolving square data */
  taskMap: Record<string, Task>;
  /** All non-deleted task steps, used to resolve progress step fractions */
  allTaskSteps: TaskStep[];
  /** User ID to associate with the created board */
  userId: string;
  /** Called with the new board's ID after successful creation */
  onBoardCreated?: (boardId: string) => void;
}

// ─── Adapters ─────────────────────────────────────────────────────────────────

/**
 * Converts a Task record (and its associated TaskStep records) to the
 * TaskSquareData shape expected by InteractiveTaskSquare.
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

// ─── Center type options (odd-board only) ─────────────────────────────────────

const CENTER_TYPE_OPTIONS: { value: CenterSquareType; label: string }[] = [
  { value: CenterSquareType.FREE, label: 'Free Space' },
  { value: CenterSquareType.CUSTOM_FREE, label: 'Custom Name' },
  { value: CenterSquareType.CHOSEN, label: 'Chosen Task' },
  { value: CenterSquareType.NONE, label: 'None' },
];

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * BoardCreatorPanel — Form to create a real board from a staged task pool.
 *
 * Lets the user configure a board name, size, center square type, and
 * randomization, then places pool tasks onto the board. After creation,
 * shows a read-only preview grid of the placed tasks.
 *
 * @param props.pool - Pool entries from the parent playground
 * @param props.taskMap - Record mapping task IDs to Task objects
 * @param props.allTaskSteps - All task steps for step-fraction rendering
 * @param props.userId - User ID for the created board
 * @param props.onBoardCreated - Optional callback after successful creation
 */
export function BoardCreatorPanel({
  pool,
  taskMap,
  allTaskSteps,
  userId,
  onBoardCreated,
}: BoardCreatorPanelProps): React.ReactElement {
  // ── Form state ─────────────────────────────────────────────────────────────
  const [boardName, setBoardName] = useState('');
  const [boardSize, setBoardSize] = useState<3 | 4 | 5>(3);
  const [centerType, setCenterType] = useState<CenterSquareType>(CenterSquareType.FREE);
  const [centerCustomName, setCenterCustomName] = useState('');
  const [centerTaskId, setCenterTaskId] = useState<string | null>(null);
  const [isRandomized, setIsRandomized] = useState(true);

  // ── Async / result state ───────────────────────────────────────────────────
  const [isCreating, setIsCreating] = useState(false);
  const [createdBoardId, setCreatedBoardId] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  // ── Reactive preview data ──────────────────────────────────────────────────

  /** Board tasks for the newly created board, used to render the preview grid */
  const previewBoardTasks = useBoardTasks(createdBoardId ?? '') ?? [];

  // ── Derived values ─────────────────────────────────────────────────────────

  const isOddBoard = boardSize % 2 !== 0;
  const hasCenterSquare = isOddBoard && centerType !== CenterSquareType.NONE;
  // FREE/CUSTOM_FREE: center is auto-filled, need boardSize²-1 pool tasks
  // CHOSEN: center comes from pool, need boardSize²-1 non-center tasks + 1 center = boardSize² total
  // NONE: all positions filled, need boardSize² pool tasks
  const tasksNeeded = centerType === CenterSquareType.CHOSEN
    ? boardSize * boardSize
    : boardSize * boardSize - (hasCenterSquare ? 1 : 0);
  const hasEnoughTasks = pool.length >= tasksNeeded;

  // ── Handlers ───────────────────────────────────────────────────────────────

  /**
   * Changes board size and resets center type to FREE for odd boards or NONE
   * for even boards.
   *
   * @param size - The new board size (3, 4, or 5)
   */
  function handleSizeChange(size: 3 | 4 | 5): void {
    setBoardSize(size);
    const newIsOdd = size % 2 !== 0;
    if (!newIsOdd) {
      setCenterType(CenterSquareType.NONE);
    } else if (centerType === CenterSquareType.NONE) {
      setCenterType(CenterSquareType.FREE);
    }
  }

  /**
   * Resets the form to its initial state, clearing the created board preview.
   */
  function handleCreateAnother(): void {
    setCreatedBoardId(null);
    setSuccessMessage(null);
    setErrorMessage(null);
    setBoardName('');
    setBoardSize(3);
    setCenterType(CenterSquareType.FREE);
    setCenterCustomName('');
    setCenterTaskId(null);
    setIsRandomized(true);
  }

  /**
   * Creates a new board from the current pool and form configuration.
   * Selects tasks from the pool (shuffled if randomized), creates the board,
   * then places each task at its grid position.
   */
  async function handleCreateBoard(): Promise<void> {
    setErrorMessage(null);

    const trimmedName = boardName.trim();
    if (!trimmedName) {
      setErrorMessage('Board name is required.');
      return;
    }
    if (!hasEnoughTasks) {
      setErrorMessage(
        `Not enough tasks in the pool. Need ${tasksNeeded}, have ${pool.length}.`
      );
      return;
    }
    if (centerType === CenterSquareType.CHOSEN && !centerTaskId) {
      setErrorMessage('Please select a task for the center square.');
      return;
    }

    setIsCreating(true);
    try {
      const now = new Date().toISOString();
      const endDate = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();

      // For CHOSEN center, separate the center task from the rest
      const poolForGrid = centerType === CenterSquareType.CHOSEN && centerTaskId
        ? pool.filter((e) => e.taskId !== centerTaskId)
        : [...pool];

      const selectedTasks = isRandomized
        ? fisherYatesShuffle([...poolForGrid]).slice(0, tasksNeeded)
        : [...poolForGrid].slice(0, tasksNeeded);

      const board = await createBoard(userId, {
        name: trimmedName,
        boardSize,
        timeframe: Timeframe.CUSTOM,
        startDate: now,
        endDate,
        centerSquareType: centerType,
        centerSquareCustomName:
          centerType === CenterSquareType.CUSTOM_FREE
            ? centerCustomName.trim() || undefined
            : undefined,
        centerTaskId: centerType === CenterSquareType.CHOSEN ? centerTaskId ?? undefined : undefined,
        isRandomized,
      });

      const centerRow = Math.floor(boardSize / 2);
      const centerCol = Math.floor(boardSize / 2);
      let taskIndex = 0;

      // Place the chosen center task first
      if (centerType === CenterSquareType.CHOSEN && centerTaskId && isOddBoard) {
        await createBoardTask({
          boardId: board.id,
          taskId: centerTaskId,
          row: centerRow,
          col: centerCol,
          isCenter: true,
        });
      }

      for (let row = 0; row < boardSize; row++) {
        for (let col = 0; col < boardSize; col++) {
          const isCenter = isOddBoard && row === centerRow && col === centerCol;
          if (isCenter && hasCenterSquare) continue;
          if (taskIndex >= selectedTasks.length) break;

          await createBoardTask({
            boardId: board.id,
            taskId: selectedTasks[taskIndex].taskId,
            row,
            col,
            isCenter: false,
          });
          taskIndex++;
        }
      }

      setCreatedBoardId(board.id);
      setSuccessMessage(
        `Created "${board.name}" — ${taskIndex} task${taskIndex !== 1 ? 's' : ''} placed.`
      );
      onBoardCreated?.(board.id);
    } catch (err) {
      console.error('Failed to create board:', err);
      setErrorMessage(
        err instanceof Error ? err.message : 'An unexpected error occurred.'
      );
    } finally {
      setIsCreating(false);
    }
  }

  // ── Render: board preview grid ─────────────────────────────────────────────

  /**
   * Renders the read-only CSS grid of InteractiveTaskSquare tiles for the
   * newly created board.
   */
  function renderPreviewGrid(): React.ReactElement {
    const btMap: Record<string, BoardTask> = {};
    for (const bt of previewBoardTasks) {
      btMap[`${bt.row}-${bt.col}`] = bt;
    }

    const centerRow = Math.floor(boardSize / 2);
    const centerCol = Math.floor(boardSize / 2);
    const cells: React.ReactElement[] = [];

    for (let row = 0; row < boardSize; row++) {
      for (let col = 0; col < boardSize; col++) {
        const bt = btMap[`${row}-${col}`];

        if (!bt) {
          const isCenterPos = isOddBoard && row === centerRow && col === centerCol;
          const label =
            isCenterPos && centerType !== CenterSquareType.NONE
              ? centerType === CenterSquareType.CUSTOM_FREE && centerCustomName.trim()
                ? centerCustomName.trim().toUpperCase()
                : 'FREE'
              : '—';
          cells.push(
            <div key={`empty-${row}-${col}`} className={styles.emptySquare}>
              <span className={styles.emptySquareLabel}>{label}</span>
            </div>
          );
          continue;
        }

        const task = taskMap[bt.taskId];
        if (task) {
          const squareData = taskToSquareData(task, allTaskSteps);
          const squareState = boardTaskToSquareState(bt);
          cells.push(
            <div key={bt.id}>
              <InteractiveTaskSquare
                sq={squareData}
                state={squareState}
                onAct={() => {}}
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

    return (
      <div
        className={styles.squareGrid}
        style={{ gridTemplateColumns: `repeat(${boardSize}, 90px)` }}
      >
        {cells}
      </div>
    );
  }

  // ── Render ─────────────────────────────────────────────────────────────────

  return (
    <div className={styles.container}>
      <h4 className={styles.panelTitle}>Create Board from Pool</h4>

      {/* ── Config form — hidden when preview is showing ── */}
      {!createdBoardId && (
        <>
          {/* Board name */}
          <div className={styles.fieldGroup}>
            <label className={styles.label} htmlFor="bcp-board-name">
              Board Name<span className={styles.required}>*</span>
            </label>
            <input
              id="bcp-board-name"
              type="text"
              className={styles.input}
              value={boardName}
              onChange={(e) => {
                setBoardName(e.target.value);
                if (errorMessage) setErrorMessage(null);
              }}
              placeholder='e.g., "Weekly Goals"'
              maxLength={200}
            />
          </div>

          {/* Board size selector */}
          <div className={styles.fieldGroup}>
            <span className={styles.label}>Board Size</span>
            <div className={styles.sizeSelector}>
              {([3, 4, 5] as const).map((size) => (
                <button
                  key={size}
                  type="button"
                  className={`${styles.sizeButton} ${boardSize === size ? styles.sizeButtonActive : ''}`}
                  onClick={() => handleSizeChange(size)}
                >
                  {size}×{size}
                </button>
              ))}
            </div>
          </div>

          {/* Center type — only for odd-sized boards */}
          {isOddBoard && (
            <div className={styles.fieldGroup}>
              <label className={styles.label} htmlFor="bcp-center-type">
                Center Square
              </label>
              <select
                id="bcp-center-type"
                className={styles.input}
                value={centerType}
                onChange={(e) => setCenterType(e.target.value as CenterSquareType)}
              >
                {CENTER_TYPE_OPTIONS.map((opt) => (
                  <option key={opt.value} value={opt.value}>
                    {opt.label}
                  </option>
                ))}
              </select>
            </div>
          )}

          {/* Custom name input — only when CUSTOM_FREE is selected */}
          {isOddBoard && centerType === CenterSquareType.CUSTOM_FREE && (
            <div className={styles.fieldGroup}>
              <label className={styles.label} htmlFor="bcp-center-custom-name">
                Custom Center Name
              </label>
              <input
                id="bcp-center-custom-name"
                type="text"
                className={styles.input}
                value={centerCustomName}
                onChange={(e) => setCenterCustomName(e.target.value)}
                placeholder='e.g., "Wild Card"'
                maxLength={100}
              />
            </div>
          )}

          {/* Chosen center task selector — only when CHOSEN is selected */}
          {isOddBoard && centerType === CenterSquareType.CHOSEN && (
            <div className={styles.fieldGroup}>
              <label className={styles.label} htmlFor="bcp-center-task">
                Center Task<span className={styles.required}>*</span>
              </label>
              <select
                id="bcp-center-task"
                className={styles.input}
                value={centerTaskId ?? ''}
                onChange={(e) => setCenterTaskId(e.target.value || null)}
              >
                <option value="">— Select a pool task —</option>
                {pool.map((entry) => (
                  <option key={entry.taskId} value={entry.taskId}>
                    {entry.title} ({entry.type})
                  </option>
                ))}
              </select>
            </div>
          )}

          {/* Randomize toggle */}
          <div className={styles.checkboxGroup}>
            <input
              id="bcp-randomize"
              type="checkbox"
              className={styles.checkbox}
              checked={isRandomized}
              onChange={(e) => setIsRandomized(e.target.checked)}
            />
            <label className={styles.checkboxLabel} htmlFor="bcp-randomize">
              Randomize task positions
            </label>
          </div>

          {/* Task count indicator */}
          <p
            className={`${styles.taskCountIndicator} ${hasEnoughTasks ? styles.taskCountSufficient : styles.taskCountInsufficient}`}
          >
            {pool.length} of {tasksNeeded} tasks needed
            {!hasEnoughTasks && ` — add ${tasksNeeded - pool.length} more to the pool`}
          </p>

          {/* Error message */}
          {errorMessage && (
            <div className={styles.errorMessage}>{errorMessage}</div>
          )}

          {/* Create button */}
          <button
            type="button"
            className={styles.createButton}
            onClick={() => void handleCreateBoard()}
            disabled={isCreating || !hasEnoughTasks}
          >
            {isCreating ? 'Creating...' : 'Create Board'}
          </button>
        </>
      )}

      {/* ── Board preview — shown after creation ── */}
      {createdBoardId && (
        <div className={styles.previewSection}>
          <div className={styles.createdBanner}>
            <span className={styles.createdBannerIcon}>✓</span>
            <div className={styles.createdBannerText}>
              <strong>Board Created!</strong>
              {successMessage && <span>{successMessage}</span>}
            </div>
          </div>

          {renderPreviewGrid()}

          <button
            type="button"
            className={styles.createAnotherButton}
            onClick={handleCreateAnother}
          >
            Create Another Board
          </button>
        </div>
      )}
    </div>
  );
}
