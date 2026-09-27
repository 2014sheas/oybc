import type { PendingTaskPayload } from '../pages/createPage/useCreateFormState';
import type { UpdateTaskPatch } from '../db/operations/tasks';

/**
 * Board Edit redesign slice 3 (D11/D12) — the squares editor's staged draft
 * cell, position-keyed. Replaces the slice-1/2 shape (`boardTaskId` always a
 * live id) with one that also represents a staged ADD: `originalTaskId` is
 * `null` when the cell held no live placement at seed time — either a
 * genuinely empty square, or the (legacy-CHOSEN) positional center once its
 * placement has been staged for removal.
 *
 * `cellId` is a stable per-cell key: the live `BoardTask.id` for an existing
 * placement, or a client-generated id for a staged add (never sent to the
 * DB — `addBoardTaskToBoard` mints its own placement id at commit time).
 */
export interface SquareDraftCell {
  cellId: string;
  row: number;
  col: number;
  taskId: string;
  /** Set only for a staged NEW (not-yet-persisted) task — D14. */
  pending?: PendingTaskPayload;
  isLocked: boolean;
  /** `null` ⇒ this cell held no live placement when the draft was seeded (a staged ADD). */
  originalTaskId: string | null;
  originalRow: number;
  originalCol: number;
  originalLocked: boolean;
}

export interface SquareEditCountInput {
  cells: SquareDraftCell[];
  /** Staged global task-field overrides, keyed by taskId. */
  taskOverrides: ReadonlyMap<string, UpdateTaskPatch>;
  /** Count of live placements (present at seed time) staged for removal. */
  removedCount: number;
  /** Whether the center Free⇄Task type differs from baseline (`effectiveCenter` compare, D1). */
  centerChanged: boolean;
  /** Set once `shuffle()` has run and at least one cell is still off its baseline position (D11). */
  shuffled: boolean;
}

/**
 * Whether a staged cell differs from what was seeded on edit-mode entry —
 * the gold "dirty" chip on the square (D12). A cell with no baseline
 * placement (`originalTaskId === null`, a staged ADD) is always dirty: it
 * holds a placement that does not exist in the saved state. A replace, a
 * task-field override, a position change, or a lock toggle each make an
 * existing cell dirty; reverting it clears the chip (the count is derived,
 * never accumulated).
 */
export function isSquareDirty(
  cell: SquareDraftCell,
  taskOverrides: ReadonlyMap<string, UpdateTaskPatch>,
): boolean {
  return (
    cell.originalTaskId === null ||
    cell.taskId !== cell.originalTaskId ||
    taskOverrides.has(cell.taskId) ||
    cell.row !== cell.originalRow ||
    cell.col !== cell.originalCol ||
    cell.isLocked !== cell.originalLocked
  );
}

/**
 * Count of staged square edits — DERIVED from draft state (not an action
 * counter) so reverting a cell to its original state un-counts it (no
 * phantom edits / no "Board saved" for a net-zero session). Mirrors iOS
 * `SquaresEditCount`. Terms (D11): replacements + adds + removals +
 * task-field overrides + lock toggles + a center Free⇄Task change +
 * position edits (a Shuffle collapses however many cells moved into ONE
 * edit; a plain hold-move counts each moved cell).
 */
export function deriveSquareEditCount(input: SquareEditCountInput): number {
  const { cells, taskOverrides, removedCount, centerChanged, shuffled } = input;

  const replacements = cells.filter(
    (c) => c.originalTaskId !== null && c.taskId !== c.originalTaskId,
  ).length;
  const adds = cells.filter((c) => c.originalTaskId === null).length;
  const lockChanges = cells.filter((c) => c.isLocked !== c.originalLocked).length;
  const movedCount = cells.filter(
    (c) => c.originalTaskId !== null && (c.row !== c.originalRow || c.col !== c.originalCol),
  ).length;
  const positionEdits = movedCount === 0 ? 0 : shuffled ? 1 : movedCount;

  return (
    replacements +
    adds +
    removedCount +
    taskOverrides.size +
    lockChanges +
    (centerChanged ? 1 : 0) +
    positionEdits
  );
}
