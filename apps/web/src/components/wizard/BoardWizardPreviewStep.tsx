import { useMemo, useRef, useState } from 'react';
import {
  CenterSquareType,
  Timeframe,
  formatTimeframeLabel,
  getTimeframeBoundaries,
} from '@oybc/shared';
import type { BoardWizardController } from '../../pages/createHub/useBoardWizard';
import type { TaskLibrary } from '../../pages/createPage/useTaskLibrary';
import { BingoBoard } from '../BingoBoard';
import {
  buildWizardPlacement,
  persistRecurringTemplate,
  persistWizardBoard,
  resolveWizardDates,
  type WizardPlacement,
  type WizardStatus,
} from './wizardPersist';
import styles from './BoardWizardPreviewStep.module.css';

export type CompletionStatus = WizardStatus;

export interface BoardWizardPreviewStepProps {
  controller: BoardWizardController;
  library: TaskLibrary;
  /** Authenticated user id used as the new board's owner. */
  userId: string;
  /** Step navigation back to Tasks. */
  onBack: () => void;
  /** Called after the board record + all `BoardTask` rows have been
   *  written. `status` reflects whether the record is ACTIVE or DRAFT. */
  onComplete: (boardId: string, status: CompletionStatus) => void;
}

/**
 * BoardWizardPreviewStep — Step 3 of the wizard. Renders a read-only
 * `BingoBoard` preview, a summary card with edit-jumps, and Activate
 * / Save Draft buttons. The actual DB writes delegate to
 * `persistWizardBoard` in `wizardPersist.ts` so the same logic can
 * be reused by the cancel dialog's Save-Draft path.
 *
 * The placement (which task goes where) is computed once via
 * `useMemo` keyed on a stable selection signature so the visual
 * preview and the persisted records stay in sync and re-shuffles
 * only happen on layout-affecting changes.
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

  const selectionKey = useMemo(
    () => Array.from(controller.selectedTaskIds).sort().join('|'),
    [controller.selectedTaskIds],
  );

  const placement: WizardPlacement = useMemo(
    () => buildWizardPlacement(controller, library),
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

  const placementRef = useRef<WizardPlacement>(placement);
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

  async function performCreation(status: CompletionStatus): Promise<void> {
    setErrorMessage(null);

    // Recurring branch — persist the template and (for fresh creates)
    // immediately spawn the current window's board. The status arg is
    // ignored: recurring templates don't have a draft concept.
    if (controller.isRecurring) {
      setIsCreating(true);
      try {
        const result = await persistRecurringTemplate({ controller, userId });
        // Treat both spawn-success and spawn-skip as completion: the
        // template is saved either way, and the user can fix a skip
        // via the Profile templates list. Pass the spawned board's id
        // when one exists (so cross-tab nav can land on the board);
        // otherwise pass the template id so the parent can decide
        // where to navigate.
        onComplete(result.spawnedBoardId ?? result.templateId, status);
      } catch (err) {
        const msg = err instanceof Error ? err.message : 'Unknown error.';
        setErrorMessage(
          controller.editingTemplateId === null
            ? `Failed to create recurring template: ${msg}`
            : `Failed to update recurring template: ${msg}`,
        );
      } finally {
        setIsCreating(false);
      }
      return;
    }

    // One-off branch — existing behavior unchanged.
    const dates = resolveWizardDates(controller);
    if ('error' in dates) {
      setErrorMessage(dates.error);
      return;
    }
    setIsCreating(true);
    try {
      const boardId = await persistWizardBoard({
        controller,
        library,
        userId,
        placement: placementRef.current,
        dates,
        status,
      });
      onComplete(boardId, status);
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Unknown error.';
      setErrorMessage(
        controller.draftBoardId === null
          ? `Failed to create board: ${msg}`
          : `Failed to update draft: ${msg}`,
      );
    } finally {
      setIsCreating(false);
    }
  }

  return (
    <div className={styles.container}>
      {/* Live preview using the existing BingoBoard in readOnly mode */}
      <div className={styles.previewWrapper}>
        <BingoBoard
          // BingoBoard snapshots taskNames into internal state on mount,
          // so any field that affects placement must remount it via key.
          // centerTaskId swaps which selection sits at the centre under
          // CHOSEN; isRandomized re-shuffles the grid; centerCustomName
          // is the displayed label for CUSTOM_FREE.
          key={[
            controller.size,
            controller.centerType,
            controller.centerTaskId ?? '',
            controller.centerCustomName,
            controller.isRandomized ? '1' : '0',
            selectionKey,
          ].join('|')}
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
        {controller.isRecurring && (
          <div className={styles.summaryRow}>
            <span className={styles.summaryLabel}>Recurring</span>
            <span className={styles.summaryValue}>
              Spawns a new {controller.timeframe} board from a{' '}
              {controller.selectedTaskIds.size}-task pool (random subset
              each window).
            </span>
            <button
              type="button"
              className={styles.editLink}
              onClick={() => controller.goToStep(1)}
            >
              Edit
            </button>
          </div>
        )}
      </div>

      {errorMessage && <div className={styles.errorMessage}>{errorMessage}</div>}

      {/* Footer — three button-set variants:
          - one-off: Save as Draft + Activate Board (existing)
          - recurring create: single primary "Create template & spawn first board"
          - recurring edit: single primary "Save changes" (no spawn)
          The actual write branching lives in `wizardPersist` (see
          Commit B); this component only chooses the label. */}
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
          {!controller.isRecurring && (
            <>
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
            </>
          )}
          {controller.isRecurring && (
            <button
              type="button"
              className={styles.activateButton}
              onClick={() => void performCreation('active')}
              disabled={isCreating}
            >
              {isCreating
                ? 'Saving…'
                : controller.editingTemplateId !== null
                  ? 'Save changes'
                  : 'Create template & spawn first board'}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
