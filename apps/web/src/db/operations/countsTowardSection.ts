/**
 * countsTowardSection.ts — the read model behind Counter Detail's "Counts
 * toward" section (docs/SHARED_COUNTER_SETTINGS.md §3d, PR 4). Loads what
 * the shared `countsTowardRows` needs for one counter root and returns the
 * rows plus the tasks / boards they reference for rendering. Read-only.
 *
 * iOS twin: `AppDatabase+CountsTowardSection.swift`.
 */

import {
  buildForkChildrenIndex,
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
 * Loads the "Counts toward" rows for counter root `counterId`.
 *
 * Reads every task + compound link (the lineage / subtree walks need them),
 * then only the events and placements of the contributors, their fork
 * lineages, their compound subtrees and the root itself.
 *
 * @param counterId - The counter root.
 * @returns Rows (empty when nothing counts toward it) + the referenced tasks / boards.
 */
export async function loadCountsTowardSection(counterId: string): Promise<CountsTowardSectionData> {
  const contributors = await countContributorsOf(counterId);
  if (contributors.length === 0) return EMPTY;
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
  const memberIds = new Set<string>();
  for (const c of contributors) {
    memberIds.add(c.id);
    for (const id of forkLineageIds(c.id, taskById, forkChildren)) memberIds.add(id);
  }
  const eventTaskIds = new Set<string>([counterId, ...memberIds]);
  for (const id of memberIds) for (const sub of subtreeIds(id, allChildrenByCompound, taskById)) eventTaskIds.add(sub);

  const events = await db.taskEvents.where('taskId').anyOf([...eventTaskIds]).toArray();
  const eventsByTaskId: Record<string, TaskEvent[]> = {};
  const allEventsByTaskId: Record<string, TaskEvent[]> = {};
  for (const e of events) {
    (allEventsByTaskId[e.taskId] ??= []).push(e);
    if (!e.isDeleted) (eventsByTaskId[e.taskId] ??= []).push(e);
  }
  const placements = await db.boardTasks.where('taskId').anyOf([...memberIds]).toArray();
  const boardIds = [...new Set(placements.map((p) => p.boardId))];
  const boards = boardIds.length > 0 ? healBoardNames(await db.boards.where('id').anyOf(boardIds).toArray()) : [];
  const boardById: Record<string, Board> = Object.fromEntries(boards.map((b) => [b.id, b]));

  const inputs: ContributionInputs = { taskById, childrenByCompound, allChildrenByCompound, eventsByTaskId, allEventsByTaskId, placements, boardById };
  return { rows: countsTowardRows(counterId, tasks, inputs), taskById, boardById };
}
