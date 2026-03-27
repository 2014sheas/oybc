import { OperatorType } from '@oybc/shared';
import type { Task, CompositeTask, CompositeNode } from '@oybc/shared';
import { TypeBadge } from './TypeBadge';
import styles from './CompositeDerivationPanel.module.css';

/**
 * Returns the human-readable operator description for a composite's root operator.
 * Uses a more detailed format than the shared utility for the derivation context.
 *
 * @param operatorType - The OperatorType enum value
 * @param threshold - Required for M_OF_N; the minimum count
 * @param leafCount - Total number of leaf nodes
 * @returns Display string such as "AND (all required)"
 */
function formatOperatorLabelDetailed(
  operatorType: OperatorType,
  threshold: number | undefined,
  leafCount: number
): string {
  if (operatorType === OperatorType.AND) return 'AND (all required)';
  if (operatorType === OperatorType.OR) return 'OR (any one)';
  return `M_OF_N (at least ${threshold ?? '?'} of ${leafCount})`;
}

/**
 * Props for CompositeDerivationPanel.
 */
export interface CompositeDerivationPanelProps {
  compositeTask: CompositeTask;
  allNodes: CompositeNode[];
  taskMap: Record<string, Task>;
  compositeTaskMap: Record<string, CompositeTask>;
  onAddLeafToPool: (taskId: string, title: string, type: string) => void;
  isInPool: (taskId: string) => boolean;
}

/**
 * CompositeDerivationPanel — shown when the selected parent is a composite task.
 *
 * Resolves the root operator node and leaf nodes, displaying operator type and
 * each leaf with its referenced task or nested composite name.
 *
 * @param compositeTask - The selected composite task record
 * @param allNodes - All composite nodes (filtering to this composite's ID is done internally)
 * @param taskMap - Map of task ID → Task for name resolution
 * @param compositeTaskMap - Map of composite task ID → CompositeTask for name resolution
 * @param onAddLeafToPool - Callback invoked to add a leaf's referenced task to the pool
 * @param isInPool - Function to check whether a task ID is already in the pool
 */
export function CompositeDerivationPanel({
  compositeTask,
  allNodes,
  taskMap,
  compositeTaskMap,
  onAddLeafToPool,
  isInPool,
}: CompositeDerivationPanelProps): React.ReactElement {
  const nodes = allNodes.filter((n) => n.compositeTaskId === compositeTask.id && !n.isDeleted);
  const rootNode = nodes.find((n) => n.id === compositeTask.rootNodeId);
  const leafNodes = nodes.filter((n) => n.nodeType === 'leaf');

  if (!rootNode || rootNode.nodeType !== 'operator' || !rootNode.operatorType) {
    return (
      <p className={styles.emptyState}>This composite task has no operator structure yet.</p>
    );
  }

  const operatorType = rootNode.operatorType as OperatorType;
  const operatorDisplay = formatOperatorLabelDetailed(
    operatorType,
    rootNode.threshold,
    leafNodes.length
  );

  return (
    <>
      {/* Operator row */}
      <div className={styles.operatorRow}>
        <span className={styles.operatorLabel}>Operator:</span>
        <span className={styles.operatorValue}>{operatorDisplay}</span>
      </div>

      {/* Leaf nodes */}
      {leafNodes.length === 0 ? (
        <p className={styles.emptyState}>No leaf nodes defined.</p>
      ) : (
        <ul className={styles.leafList} style={{ listStyle: 'none', padding: 0, margin: 0 }}>
          {leafNodes.map((leaf: CompositeNode) => {
            let leafTitle = '(unknown)';
            let badgeType = 'normal';
            let inLibrary = false;

            if (leaf.taskId && taskMap[leaf.taskId]) {
              const referencedTask = taskMap[leaf.taskId];
              leafTitle = referencedTask.title;
              badgeType = referencedTask.type;
              inLibrary = true;
            } else if (
              leaf.childCompositeTaskId &&
              compositeTaskMap[leaf.childCompositeTaskId]
            ) {
              leafTitle = compositeTaskMap[leaf.childCompositeTaskId].title;
              badgeType = 'composite';
              inLibrary = true;
            }

            return (
              <li key={leaf.id} className={styles.leafItem}>
                <span className={styles.leafBullet}>·</span>
                <span className={styles.leafTitle}>{leafTitle}</span>
                <TypeBadge type={badgeType} size="small" />
                {inLibrary && leaf.taskId &&
                  (isInPool(leaf.taskId) ? (
                    <span className={styles.linkedBadge}>In Pool ✓</span>
                  ) : (
                    <button
                      type="button"
                      className={styles.actionButton}
                      onClick={() => onAddLeafToPool(leaf.taskId!, leafTitle, badgeType)}
                    >
                      Add to Pool
                    </button>
                  ))}
              </li>
            );
          })}
        </ul>
      )}
    </>
  );
}
