import { OperatorType, TaskType } from '../constants/enums';

/**
 * CompositeTask - Root composite task definition
 *
 * A composite task composes existing tasks using logical operators (AND, OR, M_OF_N).
 * It is NOT a TaskType — it lives in its own composite_tasks table.
 *
 * Tree structure: composite_task → root_node → children... → leaf nodes (task references)
 */
export interface CompositeTask {
  // Identity
  id: string;                   // UUID (client-generated)
  userId: string;               // Foreign key to users table

  // Core fields
  title: string;                // e.g., "Weekly Wellness"
  description?: string;

  // Tree structure
  rootNodeId: string;           // FK to composite_nodes (root of tree)

  // Timestamps
  createdAt: string;            // ISO8601
  updatedAt: string;            // ISO8601

  // Sync metadata
  lastSyncedAt?: string;        // ISO8601
  version: number;              // Optimistic locking
  isDeleted: boolean;           // Soft delete
  deletedAt?: string;           // ISO8601
}

/**
 * CompositeNode - A node in the composite task tree
 *
 * Nodes are either operator nodes (AND, OR, M_OF_N) with children,
 * or leaf nodes that reference a task in the tasks table.
 */
export interface CompositeNode {
  // Identity
  id: string;                        // UUID (client-generated)
  compositeTaskId: string;           // FK to composite_tasks

  // Tree position
  parentNodeId?: string;             // FK to composite_nodes (null for root)
  nodeIndex: number;                 // Order among siblings (0-based)

  // Node type
  nodeType: 'operator' | 'leaf';

  // Operator node fields (only when nodeType='operator')
  operatorType?: OperatorType;
  threshold?: number;                // Required for M_OF_N (e.g., 2 in "2 of 3")

  // Leaf node fields (only when nodeType='leaf')
  taskId?: string;                   // FK to tasks table
  childCompositeTaskId?: string;     // FK to composite_tasks (leaf → nested composite)

  // Timestamps
  createdAt: string;                 // ISO8601
  updatedAt: string;                 // ISO8601

  // Sync metadata
  lastSyncedAt?: string;             // ISO8601
  version: number;                   // Optimistic locking
  isDeleted: boolean;                // Soft delete
  deletedAt?: string;                // ISO8601
}

/**
 * Inline task definition for leaf nodes
 *
 * When a leaf node is created inline (no existing task selected),
 * this data is used to auto-create a real task in the tasks table.
 */
export interface AutoCreateTaskInput {
  type: TaskType;
  title: string;
  action?: string;
  unit?: string;
  maxCount?: number;
}

/**
 * Input for creating a composite node (nested tree structure)
 *
 * The tree is specified as nested input — operator nodes contain
 * their children inline. This is flattened to rows when persisted.
 */
export interface CreateCompositeNodeInput {
  nodeType: 'operator' | 'leaf';

  // Operator node fields
  operatorType?: OperatorType;
  threshold?: number;                // Required for M_OF_N
  children?: CreateCompositeNodeInput[]; // Operator children (recursive)

  // Leaf node fields (exactly one of taskId, childCompositeTaskId, or autoCreateTask must be set)
  taskId?: string;                   // Reference existing task
  childCompositeTaskId?: string;     // Reference nested composite task
  autoCreateTask?: AutoCreateTaskInput; // Create new task inline
}

/**
 * Input for creating a composite task
 */
export interface CreateCompositeTaskInput {
  title: string;
  description?: string;
  rootNode: CreateCompositeNodeInput;
}
