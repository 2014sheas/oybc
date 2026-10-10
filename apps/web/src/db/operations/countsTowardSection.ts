/**
 * countsTowardSection.ts — the read model behind Counter Detail's "Counts
 * toward" section (docs/SHARED_COUNTER_SETTINGS.md §3d, PR 4). Loads what
 * the shared `countsTowardRows` needs for one counter root and returns the
 * rows plus the tasks / boards they reference for rendering. Read-only.
 *
 * iOS twin: `AppDatabase+CountsTowardSection.swift`.
 */

import {
  BoardStatus,
  buildForkChildrenIndex,
  buildSealImmuneWindows,
  candidateContributionIds,
  countsTowardRows,
  forkLineageIds,
  type Board,
  type CompoundChild,
  type ContributionInputs,
  type ContributorRow,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../internal';
import { healBoardNames } from './boardNames';
import { countContributorsOf } from './countsToward';
import type { AffectedBoard } from './tasks.sharedCounter';

/** The section's rows plus the rows' display data. */
export interface CountsTowardSectionData {
  rows: ContributorRow[];
  taskById: Record<string, Task>;
  boardById: Record<string, Board>;
}

const EMPTY: CountsTowardSectionData = { rows: [], taskById: {}, boardById: {} };

/** A compound's subtree ids (links in any state) plus the roots its linked children read. */
function subtreeIds(taskId: string, linksByCompound: Record<string, CompoundChild[]>, taskById: Record<string, Task>): string[] {
  const seen = new Set<string>([taskId]);
  const out: string[] = [];
  const stack = [taskId];
  while (stack.length > 0) {
    const parent = stack.pop() as string;
    for (const l of linksByCompound[parent] ?? []) {
      if (seen.has(l.childTaskId)) continue;
      seen.add(l.childTaskId);
      out.push(l.childTaskId);
      const child = taskById[l.childTaskId];
      if (child?.sharedCounterId) out.push(child.sharedCounterId);
      if (child?.type === 'compound') stack.push(l.childTaskId);
    }
  }
  return out;
}

/**
 * The {@link ContributionInputs} for `memberIds` (contributors, any state):
 * every task + compound link (the lineage / subtree walks need them), the
 * events (any state) of the members, their fork lineages, their compound
 * subtrees and `extraEventTaskIds` (the roots), the members' placements and
 * the boards they reference.
 *
 * @param memberIds - The contributors to load for.
 * @param extraEventTaskIds - Further tasks whose events are needed (the counter roots).
 */
export async function loadContributionInputs(
  memberIds: ReadonlyArray<string>,
  extraEventTaskIds: ReadonlyArray<string> = [],
): Promise<{ tasks: Task[]; inputs: ContributionInputs & { boardById: Record<string, Board> } }> {
  const tasks = await db.tasks.toArray();
  const taskById: Record<string, Task> = Object.fromEntries(tasks.map((t) => [t.id, t]));
  const links = await db.compoundChildren.toArray();
  const childrenByCompound: Record<string, CompoundChild[]> = {};
  const allChildrenByCompound: Record<string, CompoundChild[]> = {};
  for (const l of links) {
    (allChildrenByCompound[l.compoundTaskId] ??= []).push(l);
    if (!l.isDeleted) (childrenByCompound[l.compoundTaskId] ??= []).push(l);
  }

  const forkChildren = buildForkChildrenIndex(tasks);
  const members = new Set<string>();
  for (const id of memberIds) {
    members.add(id);
    for (const other of forkLineageIds(id, taskById, forkChildren)) members.add(other);
  }
  const eventTaskIds = new Set<string>([...extraEventTaskIds, ...members]);
  for (const id of members) for (const sub of subtreeIds(id, allChildrenByCompound, taskById)) eventTaskIds.add(sub);

  const events = await db.taskEvents.where('taskId').anyOf([...eventTaskIds]).toArray();
  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  const allEventsByTaskId: Record<string, TaskEvent[]> = {};
  for (const e of events) {
    (allEventsByTaskId[e.taskId] ??= []).push(e);
    if (!e.isDeleted) (eventsByTaskId[e.taskId] ??= []).push(e);
  }
  const placements = await db.boardTasks.where('taskId').anyOf([...members]).toArray();
  const boardIds = [...new Set(placements.map((p) => p.boardId))];
  const boards = boardIds.length > 0 ? healBoardNames(await db.boards.where('id').anyOf(boardIds).toArray()) : [];
  const boardById: Record<string, Board> = Object.fromEntries(boards.map((b) => [b.id, b]));
  return { tasks, inputs: { taskById, childrenByCompound, allChildrenByCompound, eventsByTaskId, allEventsByTaskId, placements, boardById } };
}

/**
 * Loads the "Counts toward" rows for counter root `counterId`.
 *
 * @param counterId - The counter root.
 * @returns Rows (empty when nothing counts toward it) + the referenced tasks / boards.
 */
export async function loadCountsTowardSection(counterId: string): Promise<CountsTowardSectionData> {
  const contributors = await countContributorsOf(counterId);
  if (contributors.length === 0) return EMPTY;
  const { tasks, inputs } = await loadContributionInputs(contributors.map((c) => c.id), [counterId]);
  return { rows: countsTowardRows(counterId, tasks, inputs), taskById: inputs.taskById, boardById: inputs.boardById };
}

// ---------------------------------------------------------------------------
// Completion moment — did this write credit a contributor on this board?
// ---------------------------------------------------------------------------

/** The ids of the live credit increments on `rootIds` (a hand log is one too — the DIFF is what matters). */
export async function snapshotLiveCreditIds(rootIds: ReadonlyArray<string>): Promise<Set<string>> {
  if (rootIds.length === 0) return new Set();
  const rows = await db.taskEvents.where('taskId').anyOf([...rootIds]).filter((e) => !e.isDeleted && e.kind === 'increment').toArray();
  return new Set(rows.map((e) => e.id));
}

/** What the credited toast shows for the counts-toward credits this write produced. */
export interface NewBoardCredit {
  /** The on-board contributor the credits belong to. */
  contributor: Task;
  /** The counter root they were written on. */
  root: Task;
  /** The new credit events on that root (their `delta`s sum to `amount`; their instants pick the boards). */
  credits: TaskEvent[];
  /** The amount the toast shows — the sum of the new credits' deltas. */
  amount: number;
  /** OTHER boards placing the root or a live copy whose window contains a credit — the toast's trigger. */
  otherBoards: AffectedBoard[];
}

/**
 * Whether the board's COUNTED window contains `iso`: `[startDate, endDate]`
 * (inclusive; open-ended without an end), bounded at `sealedAt` on a sealed
 * board (`buildSealImmuneWindows` — `[startDate, min(endDate, sealedAt)]`,
 * the set of instants a closed board counted).
 */
function countedWindowContains(board: Pick<Board, 'startDate' | 'endDate' | 'sealedAt'>, iso: string): boolean {
  const t = new Date(iso).getTime();
  if (board.sealedAt != null) {
    const [w] = buildSealImmuneWindows([{ startDate: board.startDate, endDate: board.endDate, sealedAt: board.sealedAt }]);
    return t >= w.startMs && t <= w.endMs;
  }
  if (!(t >= new Date(board.startDate).getTime())) return false;
  return board.endDate == null || t <= new Date(board.endDate).getTime();
}

/**
 * After a write on `boardId` (+ its cascade): the NEW live credit — one of
 * the on-board contributors' candidate ids — that was not in `before`, with
 * the OTHER boards it landed on (design handoff §C4, ruled 2026-10-10: the
 * toast fires only when a credit was actually written for a contributor
 * placed on THIS board, and only when the counter has squares on other
 * boards whose window contains the credit's instant). `null` otherwise — a
 * late log before `since`, a seal-suppressed write, a lineage already
 * credited, an unflagged task, a sub-task of an unplaced compound.
 *
 * @param boardId - The board the write was made on.
 * @param contributors - The flagged tasks placed on it (board order).
 * @param before - {@link snapshotLiveCreditIds} taken before the write.
 */
export async function findNewBoardCredit(boardId: string, contributors: ReadonlyArray<Task>, before: ReadonlySet<string>): Promise<NewBoardCredit | null> {
  const rootIds = [...new Set(contributors.map((c) => c.countsTowardCounterId).filter((id): id is string => id != null))];
  if (rootIds.length === 0) return null;
  const after = await db.taskEvents.where('taskId').anyOf(rootIds).filter((e) => !e.isDeleted && e.kind === 'increment' && !before.has(e.id)).toArray();
  if (after.length === 0) return null;
  const newById = new Map(after.map((e) => [e.id, e]));
  const { inputs } = await loadContributionInputs(contributors.map((c) => c.id), rootIds);
  for (const contributor of contributors) {
    const rootId = contributor.countsTowardCounterId as string;
    const root = inputs.taskById[rootId];
    if (!root || root.isDeleted) continue;
    // Every new credit on this root that belongs to the contributor — summed (iOS parity).
    const credits = candidateContributionIds(contributor, inputs, [rootId]).map((id) => newById.get(id)).filter((e): e is TaskEvent => e != null);
    if (credits.length === 0) continue;
    const copies = (await db.tasks.filter((t) => !t.isDeleted && t.sharedCounterId === rootId).toArray()).map((t) => t.id);
    const placements = await db.boardTasks.where('taskId').anyOf([rootId, ...copies]).filter((bt) => !bt.isDeleted).toArray();
    const boardIds = [...new Set(placements.map((p) => p.boardId))].filter((id) => id !== boardId);
    const boards = boardIds.length > 0 ? healBoardNames(await db.boards.where('id').anyOf(boardIds).toArray()) : [];
    const otherBoards = boards
      .filter((b) => !b.isDeleted && b.status !== BoardStatus.DRAFT && credits.some((c) => countedWindowContains(b, c.occurredAt)))
      .map((b) => ({ boardId: b.id, boardName: b.name }));
    // No other board counts it → keep looking (another contributor's credit may have one).
    if (otherBoards.length === 0) continue;
    const amount = credits.reduce((sum, c) => sum + (c.delta ?? 1), 0);
    return { contributor, root, credits, amount, otherBoards };
  }
  return null;
}
