import { useEffect, useMemo, useRef, useState } from 'react';
import {
  CenterSquareType,
  TaskType,
  Timeframe,
  fillableCellCount,
  formatRecurringCadence,
  formatTimeframeLabel,
  getTimeframeBoundaries,
} from '@oybc/shared';
import type { CompoundChild, Task } from '@oybc/shared';
import type { BoardWizardController } from '../../pages/createHub/useBoardWizard';
import { computeCoreFloorGate } from '../../pages/createHub/poolPullLogic';
import type { TaskLibrary } from '../../pages/createPage/useTaskLibrary';
import { taskToSquareState, type SquareWindowContext } from '../../db/adapters';
import { useSquareWindowContext } from '../../hooks/useSquareWindowContext';
import { ArrangeGrid } from '../boardEdit/ArrangeGrid';
import type { ArrangeSlot } from '../boardEdit/ArrangeGrid';
import type { BoardCellModel } from '../board/RisoBoardCell';
import { formatDeckPreview, type DeckFloor } from '../pools/poolDeckPreview';
import { RisoSegmented } from '../riso';
import type { RisoSegmentedOption } from '../riso';
import { renderTaskRow } from './TaskRow';
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
   *  written. `status` reflects whether the record is ACTIVE or DRAFT.
   *  In recurring mode this fires only when the spawn succeeded — the
   *  parent navigates to `/boards/${boardId}` (web) / `boardsPath.append(boardId)`
   *  (iOS), so passing a templateId here would land on a non-existent
   *  board. Use `onTemplateComplete` for template-only outcomes. */
  onComplete: (boardId: string, status: CompletionStatus) => void;
  /** Phase 6.2: called when a recurring template was saved without a
   *  spawned board to show — either the spawn was skipped (e.g. a seed
   *  task got soft-deleted) or this was a template edit (no spawn). The
   *  parent should navigate somewhere template-relevant (the Profile
   *  templates list) rather than `/boards/${id}`. Without this callback
   *  the wizard would have to overload `onComplete` with a templateId,
   *  which the parent would mistakenly route to a non-existent board. */
  onTemplateComplete?: (templateId: string) => void;
}

// ─── Arrange mode ─────────────────────────────────────────────────────────────

type ArrangeMode = 'preview' | 'rearrange';

const ARRANGE_MODE_OPTIONS: ReadonlyArray<RisoSegmentedOption<ArrangeMode>> = [
  { value: 'preview', label: 'Preview' },
  { value: 'rearrange', label: 'Rearrange' },
];

// ─── Cell model helpers ───────────────────────────────────────────────────────

/**
 * Map a Task to a BoardCellModel for ArrangeGrid rendering.
 *
 * Progress (done) and count values are informational only (the wizard doesn't
 * write them) — but they must be WINDOWED against the prospective board's
 * window (`[resolveWizardDates(...).startDate, ∞)`), not the task's lifetime
 * cache: a shared library task completed in a PREVIOUS window must preview
 * grey on the new board, exactly as it will render after Save. Resolution
 * goes through `taskToSquareState` — the same branch order the play surfaces
 * use (derived-counter lifetime carve-out, windowed compound evaluation,
 * windowed events for event-owning tasks). Achievements aren't placeable via
 * the wizard, so the adapter's kernel-cellState branch is never needed here.
 *
 * Exported for unit tests (`__tests__/wizardPreviewWindowed.test.ts`).
 */
export function taskToModel(
  task: Task,
  taskMap: Record<string, Task>,
  childrenByCompound: Record<string, CompoundChild[]>,
  windowContext: SquareWindowContext,
): BoardCellModel {
  const state = taskToSquareState(task, undefined, taskMap, childrenByCompound, windowContext);
  return {
    key: task.id,
    label: task.title,
    type:
      task.type === TaskType.COUNTING
        ? 'counting'
        : task.type === TaskType.COMPOUND
          ? 'compound'
          : 'normal',
    done: state.isCompleted,
    count:
      task.type === TaskType.COUNTING && task.maxCount != null
        ? { cur: state.currentCount, max: task.maxCount }
        : undefined,
    isFree: false,
    isLine: false,
  };
}

/**
 * Build a flat ArrangeSlot[] from a WizardPlacement.
 *
 * Center pinning:
 *   - FREE (null at centerIdx) → isCenter=true, isFree=true.
 *   - CHOSEN (Task at centerIdx) → isCenter=true, real task model.
 *   - NONE on odd board → no pinning (regular moveable task at centerIdx).
 *   - Even boards → centerIdx=-1, no center slot.
 *
 * Empty non-center slots (null) become droppable empty slots in the grid.
 */
function buildArrangeSlots(
  placement: WizardPlacement,
  gridSize: number,
  centerType: CenterSquareType,
  toModel: (task: Task) => BoardCellModel,
): ArrangeSlot[] {
  const isOdd = gridSize % 2 !== 0;
  const centerIdx = isOdd
    ? Math.floor(gridSize / 2) * gridSize + Math.floor(gridSize / 2)
    : -1;

  return placement.map((task, i) => {
    // Center is pinned for FREE / CHOSEN — not for NONE.
    const isPinnedCenter =
      isOdd && i === centerIdx && centerType !== CenterSquareType.NONE;

    if (isPinnedCenter) {
      if (task === null) {
        // FREE center: star cell, pinned, not a real task.
        const label = 'FREE';
        return {
          cid: 'center',
          isCenter: true,
          isEmpty: false,
          model: {
            key: 'center',
            label,
            type: 'normal',
            done: false,
            isFree: true,
            isLine: false,
          } as BoardCellModel,
        };
      }
      // CHOSEN center: real task pinned at the center.
      return {
        cid: task.id,
        isCenter: true,
        isEmpty: false,
        model: toModel(task),
      };
    }

    if (task === null) {
      // Empty slot: fewer tasks than grid squares.
      return { cid: `empty-${i}`, isCenter: false, isEmpty: true, model: null };
    }

    return {
      cid: task.id,
      isCenter: false,
      isEmpty: false,
      model: toModel(task),
    };
  });
}

// ─── Component ────────────────────────────────────────────────────────────────

/**
 * BoardWizardPreviewStep — Step 3 of the wizard. Renders an arrangeable
 * board preview (Preview ⇄ Rearrange toggle + Shuffle), a compact summary
 * chip row, a full summary card with edit-jumps, and Activate / Save Draft
 * buttons.
 *
 * Placement is lifted into state so user reorders mutate it in place.
 * `buildWizardPlacement` re-seeds the state whenever selection / size /
 * center / shuffle changes. The async save handler reads `placementRef.current`
 * (synced after every placement state update) so the user's arranged order is
 * exactly what gets written to the DB — no re-computation at save time.
 */
export function BoardWizardPreviewStep({
  controller,
  library,
  userId,
  onBack,
  onComplete,
  onTemplateComplete,
}: BoardWizardPreviewStepProps): React.ReactElement {
  const [isCreating, setIsCreating] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  // Bumped by the Shuffle button to re-roll the placement on demand.
  const [shuffleNonce, setShuffleNonce] = useState(0);
  // Arrange sub-mode: default is Preview (display-only), Rearrange enables drag+swap.
  const [subMode, setSubMode] = useState<ArrangeMode>('preview');

  // Stable key derived from the current task selection.
  const selectionKey = useMemo(
    () => Array.from(controller.selectedTaskIds).sort().join('|'),
    [controller.selectedTaskIds],
  );

  // Placement as state so user reorders are preserved between renders.
  // The lazy initializer seeds it once at mount; the effect below re-seeds on
  // layout-affecting dep changes.
  const [placement, setPlacement] = useState<WizardPlacement>(() =>
    buildWizardPlacement(controller, library, controller.pendingTasks),
  );

  // Re-seed placement when any layout-affecting input changes (same dep set as
  // the old useMemo). User reorders are discarded on dep changes — this is correct:
  // a task-selection change or size change invalidates the prior arrangement.
  useEffect(() => {
    setPlacement(buildWizardPlacement(controller, library, controller.pendingTasks));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [
    controller.size,
    controller.centerType,
    controller.centerTaskId,
    selectionKey,
    library.allTasks,
    controller.pendingTasks,
    shuffleNonce,
  ]);

  // Keep a ref synchronized with the latest placement so the async save handler
  // reads the current arranged order rather than a stale closure capture.
  const placementRef = useRef<WizardPlacement>(placement);
  useEffect(() => {
    placementRef.current = placement;
  }, [placement]);

  // ── Arrange slot derivation ──────────────────────────────────────────────

  // The prospective board's window lower bound — the SAME resolution the Save
  // handler persists (incl. plan-ahead `targetWindowDate`), so the preview's
  // windowed completion matches the board the user actually gets. On a date
  // validation error the Save button surfaces it; previewing lifetime-ish
  // "today" state until then is harmless.
  const resolvedDates = useMemo(
    () => resolveWizardDates(controller, controller.targetWindowDate ?? undefined),
    // Re-resolve on the fields resolveWizardDates actually reads (controller
    // itself is a fresh object every render — depending on it would defeat the
    // memo).
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [controller.timeframe, controller.customStartDate, controller.customEndDate, controller.targetWindowDate],
  );
  const windowStart = 'startDate' in resolvedDates ? resolvedDates.startDate : new Date().toISOString();
  const windowContext = useSquareWindowContext({ startDate: windowStart });

  // Build the ArrangeSlot[] from the current (possibly user-reordered) placement.
  const arrangeSlots = useMemo(
    () =>
      buildArrangeSlots(
        placement,
        controller.size,
        controller.centerType,
        (task) => taskToModel(task, library.taskMap, library.compoundChildrenByCompound, windowContext),
      ),
    [
      placement,
      controller.size,
      controller.centerType,
      library.taskMap,
      library.compoundChildrenByCompound,
      windowContext,
    ],
  );

  // cid → Task look-up used inside handleReorder.
  const taskByCid = useMemo<Map<string, Task>>(() => {
    const map = new Map<string, Task>();
    for (const task of placement) {
      if (task !== null) map.set(task.id, task);
    }
    return map;
  }, [placement]);

  // ── Repeating-board deck view (P4) ────────────────────────────────────────
  // A repeating board re-randomizes its cell layout every window, so a
  // specific arrangement is meaningless — the Preview step shows the POOL
  // (the deck) instead of `ArrangeGrid`. Health uses the same
  // `fillableCellCount` floor as everywhere else in the app (never a
  // hardcoded 8/Daily).
  const deckFloor: DeckFloor = useMemo(
    () => ({
      boardSize: controller.size,
      floor: fillableCellCount(controller.size, controller.centerType),
    }),
    [controller.size, controller.centerType],
  );
  const deckHeaderText = useMemo(
    () => formatDeckPreview(controller.selectedTaskIds.size, deckFloor),
    [controller.selectedTaskIds, deckFloor],
  );
  // P5 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
  // §Surfaces item 6 "Core-board setup") — Activate-button floor gate for
  // core-board setup. `deckFloor.floor` is already `fillableCellCount`
  // (never a hardcoded constant, see above); this is a real gap-closer —
  // today's Activate button isn't gated by the floor at all. isCore-only;
  // never affects a non-core one-off board's Activate button.
  const coreFloorGate = useMemo(
    () => computeCoreFloorGate(controller.selectedTaskIds.size, deckFloor.floor),
    [controller.selectedTaskIds, deckFloor],
  );
  const isCoreFloorBlocked =
    controller.isCore && !controller.isRecurring && !coreFloorGate.isSatisfied;
  // Resolved Task objects for every selected id, including this-session
  // pending (not-yet-persisted) tasks — mirrors the Tasks step's
  // `effectiveTaskMap` merge so a just-created task still shows up here.
  // Sorted by title for a stable, predictable list.
  const deckTasks = useMemo<Task[]>(() => {
    const merged: Record<string, Task> = { ...library.taskMap };
    for (const payload of controller.pendingTasks.values()) {
      merged[payload.task.id] = payload.task;
    }
    return Array.from(controller.selectedTaskIds)
      .map((id) => merged[id])
      .filter((t): t is Task => t !== undefined)
      .sort((a, b) => a.title.localeCompare(b.title));
  }, [controller.selectedTaskIds, controller.pendingTasks, library.taskMap]);

  /**
   * Handle a committed reorder from ArrangeGrid (drag drop or tap-swap).
   * Maps the new ArrangeSlot[] back to WizardPlacement: center slots are
   * preserved verbatim (ArrangeGrid never moves them), and each non-center
   * cid is resolved to its Task via taskByCid.
   */
  function handleReorder(newSlots: ArrangeSlot[]): void {
    const newPlacement: WizardPlacement = newSlots.map((slot, i) => {
      // Center never moves; preserve original value (null for FREE, Task for CHOSEN).
      if (slot.isCenter) return placement[i];
      if (slot.isEmpty) return null;
      return taskByCid.get(slot.cid) ?? null;
    });
    setPlacement(newPlacement);
  }

  // ── Shuffle + canShuffle ─────────────────────────────────────────────────

  // Tasks actually shuffled in the grid (CHOSEN center is pinned, so -1).
  const shuffleableCount =
    controller.size % 2 !== 0 &&
    controller.centerType === CenterSquareType.CHOSEN
      ? Math.max(0, controller.selectedTaskIds.size - 1)
      : controller.selectedTaskIds.size;
  const canShuffle = controller.isRandomized && shuffleableCount >= 2;

  // ── Summary helpers ──────────────────────────────────────────────────────

  const timeframeSummary = useMemo<string>(() => {
    if (controller.timeframe === Timeframe.CUSTOM) {
      if (controller.customStartDate && controller.customEndDate) {
        return `Custom · ${controller.customStartDate} → ${controller.customEndDate}`;
      }
      return 'Custom (no dates set)';
    }
    // Ongoing boards have no computed window either — getTimeframeBoundaries
    // throws for INDEFINITE just like it does for CUSTOM, so this must be
    // special-cased before the boundaries call below (sibling of the
    // recurring-seed INDEFINITE guard elsewhere in the wizard).
    if (controller.timeframe === Timeframe.INDEFINITE) {
      return controller.customStartDate
        ? `Ongoing · starting ${controller.customStartDate}`
        : 'Ongoing (no start date set)';
    }
    const b = getTimeframeBoundaries(
      controller.timeframe,
      controller.targetWindowDate ?? new Date(),
      controller.weekStartDay,
    );
    const windowLabel = formatTimeframeLabel(controller.timeframe, b.startDate);
    if (controller.isRecurring) {
      return `${formatRecurringCadence(controller.timeframe)} · starting ${windowLabel}`;
    }
    return windowLabel;
  }, [
    controller.timeframe,
    controller.customStartDate,
    controller.customEndDate,
    controller.weekStartDay,
    controller.isRecurring,
    controller.targetWindowDate,
  ]);

  const isOddBoard = controller.size % 2 !== 0;
  const centerSummary: string = (() => {
    if (!isOddBoard) return 'n/a (even board)';
    switch (controller.centerType) {
      case CenterSquareType.FREE:
        return 'Free space';
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

  // Short labels for the compact chip row above the board.
  const centerChip: string = (() => {
    if (!isOddBoard) return 'None';
    switch (controller.centerType) {
      case CenterSquareType.FREE:
        return 'Free';
      case CenterSquareType.CHOSEN:
        return 'Chosen';
      case CenterSquareType.NONE:
        return 'None';
    }
  })();

  const timeframeChip =
    controller.timeframe.charAt(0).toUpperCase() + controller.timeframe.slice(1);

  // ── Async creation ────────────────────────────────────────────────────────

  async function performCreation(status: CompletionStatus): Promise<void> {
    setErrorMessage(null);

    // Recurring branch — persist the template and (for fresh creates)
    // immediately spawn the current window's board. The status arg is
    // ignored: recurring templates don't have a draft concept.
    if (controller.isRecurring) {
      setIsCreating(true);
      try {
        const result = await persistRecurringTemplate({ controller, userId });
        if (result.spawnedBoardId !== null) {
          onComplete(result.spawnedBoardId, status);
        } else {
          onTemplateComplete?.(result.templateId);
        }
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

    // One-off branch — use placementRef.current so the user's arranged
    // order is persisted (not a freshly shuffled placement).
    const dates = resolveWizardDates(controller, controller.targetWindowDate ?? undefined);
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
        pendingTasks: controller.pendingTasks,
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
      {/* Compact summary chips — quick-glance overview above the board */}
      <div className={styles.chipRow}>
        <span className={styles.chip}>
          <span className={styles.chipKey}>Name</span>
          <b>{controller.name || '(unset)'}</b>
        </span>
        <span className={styles.chip}>
          <span className={styles.chipKey}>When</span>
          <b>{timeframeChip}</b>
        </span>
        <span className={styles.chip}>
          <span className={styles.chipKey}>Size</span>
          <b>{controller.size}×{controller.size}</b>
        </span>
        <span className={styles.chip}>
          <span className={styles.chipKey}>Center</span>
          <b>{centerChip}</b>
        </span>
        <span className={styles.chip}>
          <span className={styles.chipKey}>Tasks</span>
          <b>{controller.selectedTaskIds.size}</b>
        </span>
      </div>

      {controller.isRecurring ? (
        /* P4 — a repeating board re-randomizes its layout every window, so
           a specific arrangement is meaningless: show the deck (the pool
           of resolved tasks) instead of an arrangeable grid. No Preview ⇄
           Rearrange toggle, no Shuffle — nothing here is a fixed layout. */
        <div className={styles.deckSection}>
          <p className={styles.deckHeader}>{deckHeaderText}</p>
          <ul className={styles.deckList}>
            {deckTasks.map((task) => (
              <li key={task.id}>
                {renderTaskRow({
                  task,
                  isSelected: true,
                  provenance: controller.taskProvenance.get(task.id),
                  readOnly: true,
                })}
              </li>
            ))}
          </ul>
        </div>
      ) : (
        <>
          {/* Toggle bar: Preview ⇄ Rearrange + Shuffle */}
          <div className={styles.arrangeBar}>
            <RisoSegmented
              options={ARRANGE_MODE_OPTIONS}
              value={subMode}
              onChange={setSubMode}
              variant="pill"
              aria-label="Board arrangement mode"
            />
            {canShuffle && (
              <button
                type="button"
                className={styles.shuffleButton}
                onClick={() => setShuffleNonce((n) => n + 1)}
                disabled={isCreating}
                aria-label="Shuffle board layout"
              >
                ⤮ Shuffle
              </button>
            )}
          </div>

          {/* Static rearrange-mode hint. ArrangeGrid supplies its own
              in-progress tap-swap hint (hintBar) when a tile is picked. */}
          {subMode === 'rearrange' && (
            <p className={styles.rearrangeHint}>
              <b>Drag a square</b> to drop it in — the rest shift to make room.
              Or <b>tap two squares</b> to swap them.
            </p>
          )}

          {/* ArrangeGrid — display-only in Preview, interactive in Rearrange */}
          <div className={styles.previewWrapper}>
            <ArrangeGrid
              slots={arrangeSlots}
              gridSize={controller.size}
              rearrange={subMode === 'rearrange'}
              onReorder={handleReorder}
            />
          </div>
        </>
      )}

      {/* Full summary card with edit-jump links */}
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

      {/* P5 — core-board-setup floor gate. Only ever shown for a one-off
          core board short of `fillableCellCount` — a recurring board's
          Activate button has no such gate (loose-fit spawn). */}
      {isCoreFloorBlocked && (
        <div className={styles.coreFloorWarning}>{coreFloorGate.message}</div>
      )}

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
                disabled={isCreating || isCoreFloorBlocked}
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
