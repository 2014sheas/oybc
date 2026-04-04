import { useState } from 'react';
import {
  CenterSquareType,
  Timeframe,
  fisherYatesShuffle,
  getTimeframeBoundaries,
  formatTimeframeLabel,
  toLocalISO,
  type Task,
  type TaskStep,
  type BoardTask,
  type WeekStartDay,
} from '@oybc/shared';
import { useBoardTasks } from '../hooks';
import { taskToSquareData, boardTaskToSquareState } from '../db/adapters';
import { createBoard } from '../db/operations/boards';
import { createBoardTask } from '../db/operations/boardTasks';
import { InteractiveTaskSquare } from './InteractiveTaskSquare';
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
  const [timeframe, setTimeframe] = useState<Timeframe>(Timeframe.CUSTOM);
  const [weekStartDay, setWeekStartDay] = useState<WeekStartDay>('monday');
  const [customStartDate, setCustomStartDate] = useState('');
  const [customEndDate, setCustomEndDate] = useState('');

  // ── Async / result state ───────────────────────────────────────────────────
  const [isCreating, setIsCreating] = useState(false);
  const [createdBoardId, setCreatedBoardId] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  // ── Reactive preview data ──────────────────────────────────────────────────

  /** Board tasks for the newly created board, used to render the preview grid */
  const previewBoardTasks = useBoardTasks(createdBoardId ?? '') ?? [];

  // ── Derived values ─────────────────────────────────────────────────────────

  // ── Computed timeframe boundaries ──────────────────────────────────────────
  const computedBoundaries = timeframe !== Timeframe.CUSTOM
    ? getTimeframeBoundaries(timeframe, new Date(), weekStartDay)
    : null;

  const timeframeLabel = timeframe !== Timeframe.CUSTOM && computedBoundaries
    ? formatTimeframeLabel(timeframe, computedBoundaries.startDate)
    : null;

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
    setTimeframe(Timeframe.CUSTOM);
    setWeekStartDay('monday');
    setCustomStartDate('');
    setCustomEndDate('');
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
      // Resolve dates — computed boundaries for non-Custom, user inputs for Custom
      let startDate: string;
      let endDate: string;
      if (computedBoundaries) {
        startDate = computedBoundaries.startDate;
        endDate = computedBoundaries.endDate;
      } else if (customStartDate && customEndDate) {
        // Use toLocalISO to match the format used by getTimeframeBoundaries
        const s = new Date(customStartDate);
        const e = new Date(customEndDate);
        startDate = toLocalISO(new Date(s.getFullYear(), s.getMonth(), s.getDate(), 0, 0, 0, 0));
        endDate = toLocalISO(new Date(e.getFullYear(), e.getMonth(), e.getDate(), 23, 59, 59, 999));
      } else {
        const now = new Date();
        startDate = toLocalISO(now);
        const future = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 30, 23, 59, 59, 999);
        endDate = toLocalISO(future);
      }

      // For CHOSEN center, separate the center task from the rest
      const poolForGrid = centerType === CenterSquareType.CHOSEN && centerTaskId
        ? pool.filter((e) => e.taskId !== centerTaskId)
        : [...pool];

      // For CHOSEN, center task is separate — only slice grid tasks
      const gridTasksNeeded = centerType === CenterSquareType.CHOSEN && isOddBoard
        ? boardSize * boardSize - 1
        : tasksNeeded;

      const selectedTasks = isRandomized
        ? fisherYatesShuffle([...poolForGrid]).slice(0, gridTasksNeeded)
        : [...poolForGrid].slice(0, gridTasksNeeded);

      const board = await createBoard(userId, {
        name: trimmedName,
        boardSize,
        timeframe,
        startDate,
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
            isCenter: isCenter && centerType === CenterSquareType.NONE,
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

          {/* Timeframe selector */}
          <div className={styles.fieldGroup}>
            <span className={styles.label}>Timeframe</span>
            <div className={styles.sizeSelector}>
              {([
                { value: Timeframe.DAILY, label: 'Daily' },
                { value: Timeframe.WEEKLY, label: 'Weekly' },
                { value: Timeframe.MONTHLY, label: 'Monthly' },
                { value: Timeframe.YEARLY, label: 'Yearly' },
                { value: Timeframe.CUSTOM, label: 'Custom' },
              ] as const).map((opt) => (
                <button
                  key={opt.value}
                  type="button"
                  className={`${styles.sizeButton} ${timeframe === opt.value ? styles.sizeButtonActive : ''}`}
                  onClick={() => setTimeframe(opt.value)}
                >
                  {opt.label}
                </button>
              ))}
            </div>
          </div>

          {/* Week start — only when Weekly is selected */}
          {timeframe === Timeframe.WEEKLY && (
            <div className={styles.fieldGroup}>
              <span className={styles.label}>Week Starts On</span>
              <div className={styles.sizeSelector}>
                {([
                  { value: 'monday' as WeekStartDay, label: 'Monday' },
                  { value: 'sunday' as WeekStartDay, label: 'Sunday' },
                ]).map((opt) => (
                  <button
                    key={opt.value}
                    type="button"
                    className={`${styles.sizeButton} ${weekStartDay === opt.value ? styles.sizeButtonActive : ''}`}
                    onClick={() => setWeekStartDay(opt.value)}
                  >
                    {opt.label}
                  </button>
                ))}
              </div>
            </div>
          )}

          {/* Date display — auto-calculated or editable for Custom */}
          {timeframe !== Timeframe.CUSTOM && computedBoundaries && (
            <div className={styles.dateDisplay}>
              <span className={styles.dateLabel}>{timeframeLabel}</span>
              <span className={styles.dateRange}>
                {computedBoundaries.startDate.split('T')[0]} to{' '}
                {computedBoundaries.endDate.split('T')[0]}
              </span>
            </div>
          )}

          {timeframe === Timeframe.CUSTOM && (
            <div className={styles.dateInputRow}>
              <div className={styles.fieldGroup}>
                <label className={styles.label} htmlFor="bcp-start-date">
                  Start Date
                </label>
                <input
                  id="bcp-start-date"
                  type="date"
                  className={styles.input}
                  value={customStartDate}
                  onChange={(e) => setCustomStartDate(e.target.value)}
                />
              </div>
              <div className={styles.fieldGroup}>
                <label className={styles.label} htmlFor="bcp-end-date">
                  End Date
                </label>
                <input
                  id="bcp-end-date"
                  type="date"
                  className={styles.input}
                  value={customEndDate}
                  onChange={(e) => setCustomEndDate(e.target.value)}
                />
              </div>
            </div>
          )}

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
