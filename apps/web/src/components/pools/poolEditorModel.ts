import { TaskType, type CompoundChild, type Task } from '@oybc/shared';
import {
  childPatchFromTask,
  overlayCompoundChildrenWithStagedEdits,
  overlayTaskMapWithStagedEdits,
  seedPatchForEditor,
  stagedNewChildPlaceholders,
  type TaskEditPatch,
} from '../../db/taskEditPatch';

/**
 * poolEditorModel.ts — pure derivations the pool editor body renders from
 * its raw state (`taskIds`, the staged inline edits, the live task/link
 * reads). Extracted so the overlay / order / seed logic has a direct test
 * seam (this repo has no component-render harness). Mirrors the board
 * wizard's Tasks-step wiring (`BoardWizardTasksStep` `effectiveTaskMap`,
 * `effectiveChildrenByCompound`, `openEditor`).
 */

/** What the editor's `PoolList` renders. */
export interface PoolEditorView {
  /** Resolvable ids in `taskIds` order (unresolvable ids are skipped). */
  poolOrder: string[];
  /** The resolvable tasks in `poolOrder`, staged edits overlaid. */
  poolTasks: Task[];
  /** id → Task over the library + session cache, staged edits overlaid. */
  effectiveTaskMap: Record<string, Task>;
  /** compound id → ordered links, staged compound edits overlaid. */
  effectiveChildrenByCompound: Record<string, CompoundChild[]>;
}

/**
 * Builds the editor's view model.
 *
 * @param userId - Owner (stamps staged new-sub-task placeholders).
 * @param taskIds - The pool's raw ordered id list.
 * @param allTasks - The user's full non-deleted library.
 * @param sessionCache - Tasks added this session that the live query may not have delivered yet.
 * @param linksByCompound - Live compound links grouped by parent, sorted by `childIndex`.
 * @param stagedEdits - Inline row edits staged so far.
 * @returns The overlaid maps and the resolvable pool order.
 */
export function buildPoolEditorView(
  userId: string,
  taskIds: readonly string[],
  allTasks: readonly Task[],
  sessionCache: ReadonlyMap<string, Task>,
  linksByCompound: Record<string, CompoundChild[]>,
  stagedEdits: Map<string, TaskEditPatch>,
): PoolEditorView {
  const base: Record<string, Task> = {};
  for (const [id, t] of sessionCache) base[id] = t;
  for (const t of allTasks) base[t.id] = t;
  let effectiveTaskMap = overlayTaskMapWithStagedEdits(base, stagedEdits);
  if (stagedEdits.size > 0) {
    const placeholders = stagedNewChildPlaceholders(userId, stagedEdits);
    if (Object.keys(placeholders).length > 0) {
      effectiveTaskMap = { ...effectiveTaskMap, ...placeholders };
    }
  }
  const effectiveChildrenByCompound = overlayCompoundChildrenWithStagedEdits(
    linksByCompound,
    stagedEdits,
  );
  const poolOrder = taskIds.filter((id) => effectiveTaskMap[id] !== undefined);
  return {
    poolOrder,
    poolTasks: poolOrder.map((id) => effectiveTaskMap[id]),
    effectiveTaskMap,
    effectiveChildrenByCompound,
  };
}

/**
 * Seeds the inline editor's draft for a row — exactly the wizard's
 * `openEditor`: a reopen reuses the staged patch verbatim (scalar overlay
 * carries no compound child edits); a first open seeds
 * `seedPatchForEditor`, plus the sorted children for a compound.
 */
export function seedEditorDraft(
  task: Task,
  stagedEdits: Map<string, TaskEditPatch>,
  effectiveTaskMap: Record<string, Task>,
  effectiveChildrenByCompound: Record<string, CompoundChild[]>,
): TaskEditPatch {
  const staged = stagedEdits.get(task.id);
  if (staged) return staged;
  const draft = seedPatchForEditor(task);
  if (task.type !== TaskType.COMPOUND) return draft;
  const links = [...(effectiveChildrenByCompound[task.id] ?? [])].sort(
    (a, b) => a.childIndex - b.childIndex,
  );
  return {
    ...draft,
    children: links
      .map((link) => effectiveTaskMap[link.childTaskId])
      .filter((t): t is Task => t !== undefined)
      .map((t) => childPatchFromTask(t)),
  };
}

/** Returns a copy of `stagedEdits` with `patch` set for `taskId` (a re-stage replaces). */
export function stageEditInto(
  stagedEdits: Map<string, TaskEditPatch>,
  taskId: string,
  patch: TaskEditPatch,
): Map<string, TaskEditPatch> {
  const next = new Map(stagedEdits);
  next.set(taskId, patch);
  return next;
}

/** Returns a copy of `stagedEdits` without `taskId` (a removed row's edit is dropped). */
export function dropStagedEdit(
  stagedEdits: Map<string, TaskEditPatch>,
  taskId: string,
): Map<string, TaskEditPatch> {
  if (!stagedEdits.has(taskId)) return stagedEdits;
  const next = new Map(stagedEdits);
  next.delete(taskId);
  return next;
}

/**
 * Prunes staged edits to the rows the save will actually keep: ids still in
 * `taskIds` AND still resolvable in the editor model (a task deleted by sync
 * after staging has vanished — its edit is dropped, mirroring iOS's prune).
 */
export function pruneStagedEdits(
  stagedEdits: Map<string, TaskEditPatch>,
  taskIds: readonly string[],
  resolvableIds: ReadonlySet<string>,
): Map<string, TaskEditPatch> {
  const kept = new Set(taskIds);
  const next = new Map<string, TaskEditPatch>();
  for (const [id, patch] of stagedEdits) {
    if (kept.has(id) && resolvableIds.has(id)) next.set(id, patch);
  }
  return next;
}

/** Save gate: a trimmed name, at least one resolvable task, not mid-write. */
export function canSavePool(name: string, resolvableCount: number, busy: boolean): boolean {
  return name.trim() !== '' && resolvableCount > 0 && !busy;
}

/** Groups links by parent compound, each sorted by `childIndex`. */
export function groupLinksByCompound(links: readonly CompoundChild[]): Record<string, CompoundChild[]> {
  const m: Record<string, CompoundChild[]> = {};
  for (const l of links) (m[l.compoundTaskId] ??= []).push(l);
  for (const id of Object.keys(m)) m[id].sort((a, b) => a.childIndex - b.childIndex);
  return m;
}
