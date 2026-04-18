import { useMemo, useRef, useState } from 'react';
import {
  CenterSquareType,
  Timeframe,
  fisherYatesShuffle,
  formatTimeframeLabel,
  getTimeframeBoundaries,
  toLocalISO,
  type Task,
} from '@oybc/shared';
import type { BoardWizardController } from '../../pages/createHub/useBoardWizard';
import type { TaskLibrary } from '../../pages/createPage/useTaskLibrary';
import { createBoard } from '../../db/operations/boards';
import { createBoardTask } from '../../db/operations/boardTasks';
import { activateBoard } from '../../db/operations/boards';
import { BingoBoard } from '../BingoBoard';
import styles from './BoardWizardPreviewStep.module.css';

export type CompletionStatus = 'active' | 'draft';

export interface BoardWizardPreviewStepProps {
  controller: BoardWizardController;
  library: TaskLibrary;
  /** Authenticated user id used as the new board's owner. */
  userId: string;
  /** Step navigation back to Tasks. */
  onBack: () => void;
  /** Called after the board record + all `BoardTask` rows have been
   *  written. `status` reflects whether `activateBoard` was also called. */
  onComplete: (boardId: string, status: CompletionStatus) => void;
}

/**
 * Per-cell placement of a task on the preview/activated grid. Index
 * corresponds to the flattened row-major position (`row * size + col`).
 * `null` slots only appear at the reserved center cell for FREE /
 * CUSTOM_FREE center types; every other slot must be a real task.
 */
type Placement = (Task | null)[];

/**
 * Builds the full placement array for the wizard's current selection +
 * geometry. Used as the single source of truth for both the preview
 * grid and the `createBoardTask` calls so what the user sees and what
 * gets persisted are identical.
 *
 * - NONE / even boards: every cell is a task; shuffle if randomized.
 * - FREE / CUSTOM_FREE on odd boards: center cell is `null` (auto-
 *   filled by `BingoBoard`); other cells are tasks.
 * - CHOSEN on odd boards: center cell is the chosen task; other
 *   cells are the remaining selected tasks.
 */
function buildPlacement(
  controller: BoardWizardController,
  library: TaskLibrary,
): Placement {
  const { size, centerType, centerTaskId, isRandomized, selectedTaskIds } = controller;
  const totalCells = size * size;
  const isOdd = size % 2 !== 0;
  const centerIdx = Math.floor(size / 2) * size + Math.floor(size / 2);

  const selected: Task[] = library.allTasks.filter((t) => selectedTaskIds.has(t.id));

  // Separate the chosen center task (if any) from the rest.
  const chosenCenter: Task | null =
    isOdd && centerType === CenterSquareType.CHOSEN && centerTaskId !== null
      ? selected.find((t) => t.id === centerTaskId) ?? null
      : null;
  const others = chosenCenter !== null
    ? selected.filter((t) => t.id !== chosenCenter.id)
    : selected;

  const ordered = isRandomized ? fisherYatesShuffle([...others]) : [...others];

  const grid: Placement = new Array(totalCells).fill(null);
  let oi = 0;
  for (let i = 0; i < totalCells; i++) {
    if (i === centerIdx && isOdd) {
      if (chosenCenter !== null) {
        grid[i] = chosenCenter;
        continue;
      }
      if (centerType === CenterSquareType.FREE || centerType === CenterSquareType.CUSTOM_FREE) {
        // Reserved cell — leave null, BingoBoard will render the FREE label.
        continue;
      }
      // NONE on odd: fall through and place a regular task here.
    }
    if (oi < ordered.length) {
      grid[i] = ordered[oi++];
    }
  }
  return grid;
}

/**
 * BoardWizardPreviewStep — Step 3 of the wizard. Renders a read-only
 * `BingoBoard` preview of the chosen geometry + selection, a summary
 * card with edit-jumps, and the Activate / Save Draft callbacks that
 * write the new board to the local DB (and queue the sync).
 *
 * The placement (which task goes where) is computed once via
 * `useMemo` and cached against a stable selection signature. The
 * activation handler reuses the same array so what the user previews
 * is exactly what gets persisted.
 */
export function BoardWizardPreviewStep({
  controller,
  library,
  userId,
  onBack,
  onComplete,
}: BoardWizardPreviewStepProps): React.ReactElement {
  const [isCreating, setIsCreating] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  // Stable signature so the placement only re-shuffles when the user
  // changes something that affects the layout, not on every render.
  const selectionKey = useMemo(
    () => Array.from(controller.selectedTaskIds).sort().join('|'),
    [controller.selectedTaskIds],
  );

  const placement: Placement = useMemo(
    () => buildPlacement(controller, library),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [
      controller.size,
      controller.centerType,
      controller.centerTaskId,
      controller.isRandomized,
      selectionKey,
      library.allTasks,
    ],
  );

  // Track the placement in a ref so the async create handler reads the
  // exact array used to render the preview, even if a re-render happens
  // mid-create.
  const placementRef = useRef<Placement>(placement);
  placementRef.current = placement;

  const taskNames = useMemo<string[]>(
    () => placement.map((t) => (t === null ? '' : t.title)),
    [placement],
  );

  // ── Summary helpers ──
  const timeframeSummary = useMemo<string>(() => {
    if (controller.timeframe === Timeframe.CUSTOM) {
      if (controller.customStartDate && controller.customEndDate) {
        return `Custom · ${controller.customStartDate} → ${controller.customEndDate}`;
      }
      return 'Custom (no dates set)';
    }
    const b = getTimeframeBoundaries(
      controller.timeframe,
      new Date(),
      controller.weekStartDay,
    );
    return formatTimeframeLabel(controller.timeframe, b.startDate);
  }, [
    controller.timeframe,
    controller.customStartDate,
    controller.customEndDate,
    controller.weekStartDay,
  ]);

  const isOddBoard = controller.size % 2 !== 0;
  const centerSummary: string = (() => {
    if (!isOddBoard) return 'n/a (even board)';
    switch (controller.centerType) {
      case CenterSquareType.FREE:
        return 'Free space';
      case CenterSquareType.CUSTOM_FREE:
        return controller.centerCustomName.trim().length > 0
          ? `Custom · "${controller.centerCustomName.trim()}"`
          : 'Custom (unnamed)';
      case CenterSquareType.CHOSEN:
        if (controller.centerTaskId !== null) {
          const t = library.taskMap[controller.centerTaskId];
          return t ? `Chosen · "${t.title}"` : 'Chosen';
        }
        return 'Chosen (none picked)';
      case CenterSquareType.NONE:
        return 'None';
    }
  })();

  /**
   * Resolves start/end ISO timestamps for the new board record. Mirrors
   * the existing `BoardCreatorPanel` logic so the wizard produces dates
   * indistinguishable from the legacy panel's output.
   */
  function resolveDates(): { startDate: string; endDate: string } | { error: string } {
    if (controller.timeframe !== Timeframe.CUSTOM) {
      const b = getTimeframeBoundaries(
        controller.timeframe,
        new Date(),
        controller.weekStartDay,
      );
      return { startDate: b.startDate, endDate: b.endDate };
    }
    if (!controller.customStartDate || !controller.customEndDate) {
      return { error: 'Pick a start and end date.' };
    }
    // Parse YYYY-MM-DD manually to avoid UTC shift from `new Date('YYYY-MM-DD')`.
    const [sy, sm, sd] = controller.customStartDate.split('-').map(Number);
    const [ey, em, ed] = controller.customEndDate.split('-').map(Number);
    const start = new Date(sy, sm - 1, sd, 0, 0, 0, 0);
    const end = new Date(ey, em - 1, ed, 23, 59, 59, 999);
    if (end.getTime() < start.getTime()) {
      return { error: 'End date must be on or after the start date.' };
    }
    return { startDate: toLocalISO(start), endDate: toLocalISO(end) };
  }

  async function performCreation(status: CompletionStatus): Promise<void> {
    setErrorMessage(null);
    const dates = resolveDates();
    if ('error' in dates) {
      setErrorMessage(dates.error);
      return;
    }

    setIsCreating(true);
    try {
      const trimmedName = controller.name.trim();
      const { startDate, endDate } = dates;
      const customName =
        controller.centerType === CenterSquareType.CUSTOM_FREE
          ? controller.centerCustomName.trim() || undefined
          : undefined;
      const centerTaskId =
        controller.centerType === CenterSquareType.CHOSEN
          ? controller.centerTaskId ?? undefined
          : undefined;

      const board = await createBoard(userId, {
        name: trimmedName,
        boardSize: controller.size,
        timeframe: controller.timeframe,
        startDate,
        endDate,
        centerSquareType: controller.centerType,
        centerSquareCustomName: customName,
        centerTaskId,
        isRandomized: controller.isRandomized,
      });

      const size = controller.size;
      const centerRow = Math.floor(size / 2);
      const centerCol = Math.floor(size / 2);
      const grid = placementRef.current;

      for (let i = 0; i < grid.length; i++) {
        const task = grid[i];
        if (task === null) continue;
        const row = Math.floor(i / size);
        const col = i % size;
        const isCenterPos = isOddBoard && row === centerRow && col === centerCol;
        await createBoardTask({
          boardId: board.id,
          taskId: task.id,
          row,
          col,
          // Mark center for CHOSEN (real task at center) and NONE (any task can be center).
          isCenter:
            isCenterPos &&
            (controller.centerType === CenterSquareType.CHOSEN ||
              controller.centerType === CenterSquareType.NONE),
        });
      }

      if (status === 'active') {
        await activateBoard(board.id);
      }

      onComplete(board.id, status);
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Unknown error.';
      setErrorMessage(`Failed to create board: ${msg}`);
    } finally {
      setIsCreating(false);
    }
  }

  return (
    <div className={styles.container}>
      {/* Live preview using the existing BingoBoard in readOnly mode */}
      <div className={styles.previewWrapper}>
        <BingoBoard
          key={`${controller.size}-${controller.centerType}-${selectionKey}`}
          taskNames={taskNames}
          gridSize={controller.size}
          squareSize={84}
          centerSquareType={controller.centerType}
          centerSquareCustomName={controller.centerCustomName || undefined}
          readOnly
        />
      </div>

      {/* Summary card with edit jumps */}
      <div className={styles.summary}>
        <div className={styles.summaryRow}>
          <span className={styles.summaryLabel}>Name</span>
          <span className={styles.summaryValue}>
            {controller.name || '(unset)'}
          </span>
          <button
            type="button"
            className={styles.editLink}
            onClick={() => controller.goToStep(1)}
          >
            Edit
          </button>
        </div>
        <div className={styles.summaryRow}>
          <span className={styles.summaryLabel}>Size</span>
          <span className={styles.summaryValue}>
            {controller.size}×{controller.size}
          </span>
          <button
            type="button"
            className={styles.editLink}
            onClick={() => controller.goToStep(1)}
          >
            Edit
          </button>
        </div>
        <div className={styles.summaryRow}>
          <span className={styles.summaryLabel}>Timeframe</span>
          <span className={styles.summaryValue}>{timeframeSummary}</span>
          <button
            type="button"
            className={styles.editLink}
            onClick={() => controller.goToStep(1)}
          >
            Edit
          </button>
        </div>
        <div className={styles.summaryRow}>
          <span className={styles.summaryLabel}>Center</span>
          <span className={styles.summaryValue}>{centerSummary}</span>
          <button
            type="button"
            className={styles.editLink}
            onClick={() => controller.goToStep(1)}
          >
            Edit
          </button>
        </div>
        <div className={styles.summaryRow}>
          <span className={styles.summaryLabel}>Tasks</span>
          <span className={styles.summaryValue}>
            {controller.selectedTaskIds.size} selected ·{' '}
            {controller.tasksRequired} required
          </span>
          <button
            type="button"
            className={styles.editLink}
            onClick={() => controller.goToStep(2)}
          >
            Edit
          </button>
        </div>
        <div className={styles.summaryRow}>
          <span className={styles.summaryLabel}>Randomize</span>
          <span className={styles.summaryValue}>
            {controller.isRandomized ? 'Yes' : 'No'}
          </span>
          <button
            type="button"
            className={styles.editLink}
            onClick={() => controller.goToStep(1)}
          >
            Edit
          </button>
        </div>
      </div>

      {errorMessage && <div className={styles.errorMessage}>{errorMessage}</div>}

      {/* Footer */}
      <div className={styles.footer}>
        <button
          type="button"
          className={styles.backButton}
          onClick={onBack}
          disabled={isCreating}
        >
          ‹ Back
        </button>
        <div className={styles.footerActions}>
          <button
            type="button"
            className={styles.draftButton}
            onClick={() => void performCreation('draft')}
            disabled={isCreating}
          >
            {isCreating ? 'Saving…' : 'Save as Draft'}
          </button>
          <button
            type="button"
            className={styles.activateButton}
            onClick={() => void performCreation('active')}
            disabled={isCreating}
          >
            {isCreating ? 'Activating…' : 'Activate Board'}
          </button>
        </div>
      </div>
    </div>
  );
}
