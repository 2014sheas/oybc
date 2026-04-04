import { db } from '../database';
import { currentTimestamp } from '../utils';
import type {
  CompositeTask,
  CompositeNode,
  CreateCompositeTaskInput,
  CreateCompositeNodeInput,
} from '@oybc/shared';

// ─── Read Operations ──────────────────────────────────────────────────────────

/**
 * Fetch all non-deleted composite tasks for a user.
 *
 * @param userId - The user ID to filter by
 * @returns Array of composite tasks, sorted by updatedAt descending
 */
export async function fetchCompositeTasks(userId: string): Promise<CompositeTask[]> {
  const tasks = await db.compositeTasks
    .where('[userId+isDeleted]')
    .equals([userId, 0])
    .sortBy('updatedAt');
  return tasks.reverse();
}

/**
 * Fetch a single composite task by ID.
 *
 * @param id - The composite task ID
 * @returns The composite task, or undefined if not found
 */
export async function fetchCompositeTask(id: string): Promise<CompositeTask | undefined> {
  return db.compositeTasks.get(id);
}

/**
 * Fetch all non-deleted nodes for a composite task.
 *
 * @param compositeTaskId - The composite task ID
 * @returns Array of composite nodes, sorted by nodeIndex
 */
export async function fetchCompositeNodes(compositeTaskId: string): Promise<CompositeNode[]> {
  return db.compositeNodes
    .where('[compositeTaskId+isDeleted]')
    .equals([compositeTaskId, 0])
    .sortBy('nodeIndex');
}

// ─── Write Operations ─────────────────────────────────────────────────────────

/**
 * Create a composite task with its node tree in a single atomic transaction.
 *
 * Accepts the shared `CreateCompositeTaskInput` which uses a recursive tree
 * structure for nodes. The tree is flattened to rows during persistence.
 *
 * @param userId - The user ID to associate with the composite task
 * @param input - Title, description, and root node tree definition
 * @returns The created composite task record
 */
export async function createCompositeTask(
  userId: string,
  input: CreateCompositeTaskInput,
): Promise<CompositeTask> {
  const now = currentTimestamp();
  const compositeTaskId = crypto.randomUUID();
  const rootNodeId = crypto.randomUUID();

  const compositeTask: CompositeTask = {
    id: compositeTaskId,
    userId,
    title: input.title.trim(),
    description: input.description?.trim(),
    rootNodeId,
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
  };

  // Flatten the recursive tree into a flat array of nodes
  const flatNodes: CompositeNode[] = [];

  function flattenNode(
    nodeInput: CreateCompositeNodeInput,
    parentNodeId: string | undefined,
    nodeIndex: number,
    nodeId: string,
  ): void {
    flatNodes.push({
      id: nodeId,
      compositeTaskId,
      parentNodeId,
      nodeIndex,
      nodeType: nodeInput.nodeType,
      operatorType: nodeInput.operatorType,
      threshold: nodeInput.threshold,
      taskId: nodeInput.taskId,
      childCompositeTaskId: nodeInput.childCompositeTaskId,
      createdAt: now,
      updatedAt: now,
      version: 1,
      isDeleted: false,
    });

    // Recurse into children for operator nodes
    if (nodeInput.children) {
      for (let i = 0; i < nodeInput.children.length; i++) {
        flattenNode(nodeInput.children[i], nodeId, i, crypto.randomUUID());
      }
    }
  }

  flattenNode(input.rootNode, undefined, 0, rootNodeId);

  await db.transaction('rw', [db.compositeTasks, db.compositeNodes], async () => {
    await db.compositeTasks.add(compositeTask);
    for (const node of flatNodes) {
      await db.compositeNodes.add(node);
    }
  });

  return compositeTask;
}

/**
 * Soft-delete a composite task and all its nodes.
 *
 * @param id - The composite task ID to delete
 */
export async function deleteCompositeTask(id: string): Promise<void> {
  const now = currentTimestamp();

  await db.transaction('rw', [db.compositeTasks, db.compositeNodes], async () => {
    const task = await db.compositeTasks.get(id);
    if (!task) return;

    await db.compositeTasks.update(id, {
      isDeleted: true,
      deletedAt: now,
      updatedAt: now,
      version: (task.version ?? 1) + 1,
    });

    // Soft-delete all nodes belonging to this composite task
    const nodes = await db.compositeNodes
      .where('compositeTaskId')
      .equals(id)
      .toArray();

    for (const node of nodes) {
      await db.compositeNodes.update(node.id, {
        isDeleted: true,
        deletedAt: now,
        updatedAt: now,
        version: (node.version ?? 1) + 1,
      });
    }
  });
}
