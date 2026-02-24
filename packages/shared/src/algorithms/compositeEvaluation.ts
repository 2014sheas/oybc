import { OperatorType } from '../constants/enums';
import { CompositeNode } from '../types/compositeTask';

/**
 * Evaluate a composite task tree given flat nodes and task completion states.
 *
 * This is a pure function — no database access. Pass in all nodes for
 * the composite task and a map of taskId → isCompleted.
 *
 * @param nodes - All CompositeNode rows for this composite task (any order)
 * @param rootNodeId - The id of the root node
 * @param taskCompletions - Map of taskId → whether that task is complete
 * @param compositeCompletions - Map of compositeTaskId → whether that composite task is complete
 * @returns true if the composite task is complete, false otherwise
 * @throws Error if rootNodeId is not found in nodes
 */
export function evaluateCompositeTree(
  nodes: CompositeNode[],
  rootNodeId: string,
  taskCompletions: Record<string, boolean>,
  compositeCompletions: Record<string, boolean> = {}
): boolean {
  // Build a map for O(1) lookups
  const nodeMap = new Map<string, CompositeNode>();
  for (const node of nodes) {
    if (!node.isDeleted) {
      nodeMap.set(node.id, node);
    }
  }

  const rootNode = nodeMap.get(rootNodeId);
  if (!rootNode) {
    throw new Error(`Root node "${rootNodeId}" not found in nodes`);
  }

  return evaluateNode(rootNode, nodeMap, taskCompletions, compositeCompletions);
}

/**
 * Recursively evaluate a single node.
 *
 * @param node - The node to evaluate
 * @param nodeMap - Map of all non-deleted nodes by id
 * @param taskCompletions - Map of taskId → completion state
 * @param compositeCompletions - Map of compositeTaskId → completion state
 * @returns true if this node evaluates as complete
 */
function evaluateNode(
  node: CompositeNode,
  nodeMap: Map<string, CompositeNode>,
  taskCompletions: Record<string, boolean>,
  compositeCompletions: Record<string, boolean>
): boolean {
  if (node.nodeType === 'leaf') {
    if (node.taskId) return taskCompletions[node.taskId] ?? false;
    if (node.childCompositeTaskId) return compositeCompletions[node.childCompositeTaskId] ?? false;
    return false;
  }

  // Operator node: find children sorted by nodeIndex
  const children = Array.from(nodeMap.values())
    .filter((n) => n.parentNodeId === node.id)
    .sort((a, b) => a.nodeIndex - b.nodeIndex);

  if (children.length === 0) {
    // Empty AND is vacuously true; empty OR / M_OF_N is false
    return node.operatorType === OperatorType.AND;
  }

  const childResults = children.map((child) =>
    evaluateNode(child, nodeMap, taskCompletions, compositeCompletions)
  );

  switch (node.operatorType) {
    case OperatorType.AND:
      return childResults.every((r) => r === true);

    case OperatorType.OR:
      return childResults.some((r) => r === true);

    case OperatorType.M_OF_N: {
      const completedCount = childResults.filter((r) => r === true).length;
      return completedCount >= (node.threshold ?? 0);
    }

    default:
      throw new Error(`Unknown operator type: "${node.operatorType}"`);
  }
}

