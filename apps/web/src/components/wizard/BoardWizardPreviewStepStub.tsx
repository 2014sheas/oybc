import { useMemo } from 'react';
import {
  CenterSquareType,
  Timeframe,
  fisherYatesShuffle,
  formatTimeframeLabel,
  getTimeframeBoundaries,
} from '@oybc/shared';
import type { BoardWizardController } from '../../pages/createHub/useBoardWizard';
import type { TaskLibrary } from '../../pages/createPage/useTaskLibrary';
import { BingoBoard } from '../BingoBoard';
import styles from './BoardWizardPreviewStepStub.module.css';

export interface BoardWizardPreviewStepStubProps {
  controller: BoardWizardController;
  library: TaskLibrary;
  onBack: () => void;
  /** Stub callback — real DB write lands in build sequence step 3. */
  onActivate: () => void;
  /** Stub callback — real DB write lands in build sequence step 3. */
  onSaveDraft: () => void;
}

/**
 * BoardWizardPreviewStepStub — Step 3 placeholder used only to verify
 * end-to-end wizard navigation in the playground. Renders a real
 * `BingoBoard` preview from the wizard's selected task ids plus a
 * summary card and stub Activate / Save Draft buttons.
 *
 * The full implementation (seeded shuffle, edit-jumps, real DB writes,
 * navigation to the created board) lands in build sequence step 3.
 */
export function BoardWizardPreviewStepStub({
  controller,
  library,
  onBack,
  onActivate,
  onSaveDraft,
}: BoardWizardPreviewStepStubProps): React.ReactElement {
  const {
    name,
    size,
    timeframe,
    customStartDate,
    customEndDate,
    centerType,
    centerCustomName,
    centerTaskId,
    isRandomized,
    weekStartDay,
    selectedTaskIds,
    tasksRequired,
    centerMode,
    goToStep,
  } = controller;

  const isOddBoard = size % 2 !== 0;

  // Resolve selected ids to actual task records for the preview render.
  const selectedTasks = useMemo(
    () => library.allTasks.filter((t) => selectedTaskIds.has(t.id)),
    [library.allTasks, selectedTaskIds],
  );

  // Build the task-name array for the BingoBoard preview component.
  // For CHOSEN center, place the chosen task at the center position;
  // remaining tasks fill the other cells in order (shuffled or not).
  const taskNames: string[] = useMemo(() => {
    const base = selectedTasks.map((t) => t.title);
    if (centerMode && centerTaskId !== null) {
      const centerTask = selectedTasks.find((t) => t.id === centerTaskId);
      const rest = base.filter((_, i) => selectedTasks[i].id !== centerTaskId);
      const shuffled = isRandomized ? fisherYatesShuffle([...rest]) : rest;
      const cells: string[] = shuffled.slice(0, size * size);
      // Place the center task at index = centerRow * size + centerCol
      const centerIdx = Math.floor(size / 2) * size + Math.floor(size / 2);
      if (centerTask) {
        cells.splice(centerIdx, 0, centerTask.title);
        cells.length = size * size;
      }
      return cells;
    }
    const ordered = isRandomized ? fisherYatesShuffle([...base]) : base;
    return ordered.slice(0, tasksRequired);
  }, [selectedTasks, centerMode, centerTaskId, isRandomized, size, tasksRequired]);

  const timeframeSummary = useMemo<string>(() => {
    if (timeframe === Timeframe.CUSTOM) {
      if (customStartDate && customEndDate) {
        return `Custom · ${customStartDate} → ${customEndDate}`;
      }
      return 'Custom (no dates set)';
    }
    const b = getTimeframeBoundaries(timeframe, new Date(), weekStartDay);
    return formatTimeframeLabel(timeframe, b.startDate);
  }, [timeframe, customStartDate, customEndDate, weekStartDay]);

  const centerSummary: string = (() => {
    if (!isOddBoard) return 'n/a (even board)';
    switch (centerType) {
      case CenterSquareType.FREE:
        return 'Free space';
      case CenterSquareType.CUSTOM_FREE:
        return centerCustomName.trim().length > 0
          ? `Custom · "${centerCustomName.trim()}"`
          : 'Custom (unnamed)';
      case CenterSquareType.CHOSEN:
        if (centerTaskId !== null) {
          const t = library.taskMap[centerTaskId];
          return t ? `Chosen · "${t.title}"` : 'Chosen';
        }
        return 'Chosen (none picked)';
      case CenterSquareType.NONE:
        return 'None';
    }
  })();

  return (
    <div className={styles.container}>
      <div className={styles.stubBanner}>
        <strong>Preview stub</strong> — full preview, edit-jumps, and real DB writes
        ship in build-sequence step 3.
      </div>

      {/* Live preview using existing BingoBoard component.
          The `key` forces a re-mount when the task list or geometry
          changes, since BingoBoard snapshots `taskNames` on mount. */}
      <div className={styles.previewWrapper}>
        <BingoBoard
          key={`${size}-${centerType}-${taskNames.join('|')}`}
          taskNames={taskNames}
          gridSize={size}
          squareSize={84}
          centerSquareType={centerType}
          centerSquareCustomName={centerCustomName}
        />
      </div>

      {/* Summary card with edit jumps */}
      <div className={styles.summary}>
        <div className={styles.summaryRow}>
          <span className={styles.summaryLabel}>Name</span>
          <span className={styles.summaryValue}>{name || '(unset)'}</span>
          <button
            type="button"
            className={styles.editLink}
            onClick={() => goToStep(1)}
          >
            Edit
          </button>
        </div>
        <div className={styles.summaryRow}>
          <span className={styles.summaryLabel}>Size</span>
          <span className={styles.summaryValue}>
            {size}×{size}
          </span>
          <button
            type="button"
            className={styles.editLink}
            onClick={() => goToStep(1)}
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
            onClick={() => goToStep(1)}
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
            onClick={() => goToStep(1)}
          >
            Edit
          </button>
        </div>
        <div className={styles.summaryRow}>
          <span className={styles.summaryLabel}>Tasks</span>
          <span className={styles.summaryValue}>
            {selectedTasks.length} selected · {tasksRequired} required
          </span>
          <button
            type="button"
            className={styles.editLink}
            onClick={() => goToStep(2)}
          >
            Edit
          </button>
        </div>
        <div className={styles.summaryRow}>
          <span className={styles.summaryLabel}>Randomize</span>
          <span className={styles.summaryValue}>{isRandomized ? 'Yes' : 'No'}</span>
          <button
            type="button"
            className={styles.editLink}
            onClick={() => goToStep(1)}
          >
            Edit
          </button>
        </div>
      </div>

      {/* Footer */}
      <div className={styles.footer}>
        <button type="button" className={styles.backButton} onClick={onBack}>
          ‹ Back
        </button>
        <div className={styles.footerActions}>
          <button
            type="button"
            className={styles.draftButton}
            onClick={onSaveDraft}
            title="Stub — not wired to DB writes yet"
          >
            Save as Draft
          </button>
          <button
            type="button"
            className={styles.activateButton}
            onClick={onActivate}
            title="Stub — not wired to DB writes yet"
          >
            Activate Board
          </button>
        </div>
      </div>
    </div>
  );
}
