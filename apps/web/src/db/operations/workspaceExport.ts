import { db } from '../internal';
import { anonymiseWorkspace, type AnonymisedWorkspace } from '@oybc/shared';

/**
 * workspaceExport.ts — the dev-only "Export anonymised workspace" data
 * assembly (TASK_WINDOW_REWORK slice 4, Gate 1 ruling b). Loads the user's
 * rows and runs the shared pure anonymiser (ids, numbers, dates and relations
 * kept; every piece of user text replaced). The result is committed under
 * `packages/shared/tests/fixtures/` as the sweep's acceptance fixture.
 *
 * @param userId - The signed-in user's uid.
 * @returns The anonymised workspace, ready to serialise.
 */
export async function exportAnonymisedWorkspace(userId: string): Promise<AnonymisedWorkspace> {
  const tasks = (await db.tasks.toArray()).filter((t) => t.userId === userId);
  const boards = (await db.boards.toArray()).filter((b) => b.userId === userId);
  const boardIds = new Set(boards.map((b) => b.id));
  const taskIds = new Set(tasks.map((t) => t.id));
  const boardTasks = (await db.boardTasks.toArray()).filter((bt) => boardIds.has(bt.boardId));
  const compoundChildren = (await db.compoundChildren.toArray()).filter((c) => taskIds.has(c.compoundTaskId));
  const events = (await db.taskEvents.toArray()).filter((e) => taskIds.has(e.taskId));
  const templates = (await db.recurringBoardTemplates.toArray()).filter((t) => t.userId === userId);
  const pools = (await db.pools.toArray()).filter((p) => p.userId === userId);
  return anonymiseWorkspace({ tasks, boards, boardTasks, compoundChildren, events, templates, pools });
}
