# Composite Tasks - Deep Dive

## Overview

Composite tasks enable users to create complex workflows using logical operators (AND, OR, M-of-N) over existing tasks. They're represented as tree structures and evaluated recursively to determine completion state.

**Key Design Principle**: Composite tasks are a **composition layer**, not a fourth task type. Any task (Normal, Counting, Progress) can be composed using logical operators.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Tree-Based Data Model](#tree-based-data-model)
3. [Operators](#operators)
4. [Evaluation Algorithm](#evaluation-algorithm)
5. [Auto-Task-Conversion](#auto-task-conversion)
6. [Validation](#validation)
7. [Tree Builder UI](#tree-builder-ui)
8. [Performance Optimization](#performance-optimization)
9. [Edge Cases](#edge-cases)
10. [Sync Strategy](#sync-strategy)
11. [Testing](#testing)

---

## Architecture Overview

### Design Goals

1. **Flexible Composition**: Support arbitrary nesting of operators
2. **Type Safety**: Prevent invalid trees (circular references, invalid thresholds)
3. **Performance**: Evaluate complex trees < 50ms
4. **Offline-First**: All operations work offline, sync in background
5. **Simple UX**: Tree builder UI that's intuitive for users

### Three-Table Architecture

```
composite_tasks          Root composite task definitions
  ↓
composite_nodes          Tree structure (operators + leaf task references)
  ↓
board_composite_tasks    Per-board completion state
```

**Why Three Tables?**

- `composite_tasks`: Metadata (title, description, user ownership)
- `composite_nodes`: Tree structure (parent-child relationships, operators)
- `board_composite_tasks`: Completion tracking (same pattern as `board_tasks`)

**Alternative Considered**: Single table with JSON column for tree structure.

**Rejected**: Poor query performance, can't use foreign keys for task references, harder to debug.

---

## Tree-Based Data Model

### Composite Task (Root)

```typescript
interface CompositeTask {
  id: string;
  userId: string;
  title: string;                 // "Weekly Wellness"
  description?: string;
  rootNodeId: string;            // FK to composite_nodes (root of tree)

  // Metadata
  createdAt: string;
  updatedAt: string;
  lastSyncedAt?: string;
  version: number;
  isDeleted: boolean;
  deletedAt?: string;
}
```

**SQLite Schema**:
```sql
CREATE TABLE composite_tasks (
    id TEXT PRIMARY KEY,
    userId TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT,
    rootNodeId TEXT NOT NULL,

    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    isDeleted INTEGER NOT NULL DEFAULT 0,
    deletedAt TEXT,

    FOREIGN KEY (userId) REFERENCES users(id),
    FOREIGN KEY (rootNodeId) REFERENCES composite_nodes(id)
);

CREATE INDEX idx_composite_tasks_user_deleted ON composite_tasks(userId, isDeleted);
CREATE INDEX idx_composite_tasks_root ON composite_tasks(rootNodeId);
```

---

### Composite Node (Tree Structure)

```typescript
interface CompositeNode {
  id: string;
  compositeTaskId: string;       // FK to composite_tasks
  parentNodeId?: string;         // FK to composite_nodes (NULL for root)
  nodeIndex: number;             // Order among siblings (0-based)

  // Node type discriminator
  nodeType: 'operator' | 'leaf';

  // Operator node fields (only for nodeType='operator')
  operatorType?: 'AND' | 'OR' | 'M_OF_N';
  threshold?: number;            // Only for M_OF_N (e.g., 2 in "2 of 3")

  // Leaf node field (only for nodeType='leaf')
  taskId?: string;               // FK to tasks table

  // Metadata
  createdAt: string;
  updatedAt: string;
  version: number;
  isDeleted: boolean;
}
```

**SQLite Schema**:
```sql
CREATE TABLE composite_nodes (
    id TEXT PRIMARY KEY,
    compositeTaskId TEXT NOT NULL,
    parentNodeId TEXT,
    nodeIndex INTEGER NOT NULL,

    nodeType TEXT NOT NULL,       -- 'operator' or 'leaf'
    operatorType TEXT,            -- 'AND', 'OR', 'M_OF_N'
    threshold INTEGER,

    taskId TEXT,                  -- FK to tasks (for leaf nodes)

    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    isDeleted INTEGER NOT NULL DEFAULT 0,
    deletedAt TEXT,

    FOREIGN KEY (compositeTaskId) REFERENCES composite_tasks(id) ON DELETE CASCADE,
    FOREIGN KEY (parentNodeId) REFERENCES composite_nodes(id),
    FOREIGN KEY (taskId) REFERENCES tasks(id)
);

CREATE INDEX idx_composite_nodes_composite ON composite_nodes(compositeTaskId);
CREATE INDEX idx_composite_nodes_parent_index ON composite_nodes(parentNodeId, nodeIndex);
CREATE INDEX idx_composite_nodes_task ON composite_nodes(taskId);
```

---

### Board Composite Task (Completion State)

```typescript
interface BoardCompositeTask {
  id: string;
  boardId: string;
  compositeTaskId: string;
  row: number;
  col: number;
  isCenter: boolean;

  // Completion state (derived from evaluation)
  isCompleted: boolean;
  completedAt?: string;

  // Achievement square fields (optional, same as BoardTask)
  isAchievementSquare?: boolean;
  achievementType?: 'bingo' | 'full_completion';
  achievementCount?: number;
  achievementTimeframe?: Timeframe;
  achievementProgress?: number;

  // Metadata
  createdAt: string;
  updatedAt: string;
  version: number;
}
```

**SQLite Schema**:
```sql
CREATE TABLE board_composite_tasks (
    id TEXT PRIMARY KEY,
    boardId TEXT NOT NULL,
    compositeTaskId TEXT NOT NULL,
    row INTEGER NOT NULL,
    col INTEGER NOT NULL,
    isCenter INTEGER NOT NULL DEFAULT 0,

    isCompleted INTEGER NOT NULL DEFAULT 0,
    completedAt TEXT,

    -- Achievement square fields
    isAchievementSquare INTEGER DEFAULT 0,
    achievementType TEXT,
    achievementCount INTEGER,
    achievementTimeframe TEXT,
    achievementProgress INTEGER,

    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,

    FOREIGN KEY (boardId) REFERENCES boards(id) ON DELETE CASCADE,
    FOREIGN KEY (compositeTaskId) REFERENCES composite_tasks(id)
);

CREATE INDEX idx_board_composite_tasks_board_completed ON board_composite_tasks(boardId, isCompleted);
CREATE INDEX idx_board_composite_tasks_composite ON board_composite_tasks(compositeTaskId);
```

---

### Tree Example

**User creates**: "(Exercise OR Yoga) AND (2 of [Meditate, Journal, Read])"

```
CompositeTask {
  id: "comp-1"
  title: "Weekly Wellness"
  rootNodeId: "node-and-root"
}

Node Tree:
  node-and-root (AND operator)
  ├─ node-or-1 (OR operator)
  │  ├─ node-exercise (leaf → taskId: "task-exercise")
  │  └─ node-yoga (leaf → taskId: "task-yoga")
  └─ node-m-of-n-2 (M_OF_N operator, threshold: 2)
     ├─ node-meditate (leaf → taskId: "task-meditate")
     ├─ node-journal (leaf → taskId: "task-journal")
     └─ node-read (leaf → taskId: "task-read")
```

**Database Representation**:
```typescript
// Nodes table
[
  { id: "node-and-root", compositeTaskId: "comp-1", parentNodeId: null, nodeType: "operator", operatorType: "AND", nodeIndex: 0 },

  { id: "node-or-1", compositeTaskId: "comp-1", parentNodeId: "node-and-root", nodeType: "operator", operatorType: "OR", nodeIndex: 0 },
  { id: "node-exercise", compositeTaskId: "comp-1", parentNodeId: "node-or-1", nodeType: "leaf", taskId: "task-exercise", nodeIndex: 0 },
  { id: "node-yoga", compositeTaskId: "comp-1", parentNodeId: "node-or-1", nodeType: "leaf", taskId: "task-yoga", nodeIndex: 1 },

  { id: "node-m-of-n-2", compositeTaskId: "comp-1", parentNodeId: "node-and-root", nodeType: "operator", operatorType: "M_OF_N", threshold: 2, nodeIndex: 1 },
  { id: "node-meditate", compositeTaskId: "comp-1", parentNodeId: "node-m-of-n-2", nodeType: "leaf", taskId: "task-meditate", nodeIndex: 0 },
  { id: "node-journal", compositeTaskId: "comp-1", parentNodeId: "node-m-of-n-2", nodeType: "leaf", taskId: "task-journal", nodeIndex: 1 },
  { id: "node-read", compositeTaskId: "comp-1", parentNodeId: "node-m-of-n-2", nodeType: "leaf", taskId: "task-read", nodeIndex: 2 }
]
```

---

## Operators

### AND Operator

**Definition**: All children must be complete.

**Use Cases**:
- "Exercise AND Meditate" (must do both)
- "Run 3 miles AND Stretch" (both required)
- "Read chapter AND Take notes"

**Evaluation**:
```typescript
function evaluateAND(childResults: boolean[]): boolean {
  return childResults.every(result => result === true);
}
```

**Truth Table** (2 children):
| Child A | Child B | Result |
|---------|---------|--------|
| ✅      | ✅      | ✅     |
| ✅      | ❌      | ❌     |
| ❌      | ✅      | ❌     |
| ❌      | ❌      | ❌     |

---

### OR Operator

**Definition**: Any child can be complete (at least one).

**Use Cases**:
- "Run 3 miles OR Bike 10 miles" (either satisfies)
- "Exercise OR Yoga" (flexible goal)
- "Call OR Email Mom"

**Evaluation**:
```typescript
function evaluateOR(childResults: boolean[]): boolean {
  return childResults.some(result => result === true);
}
```

**Truth Table** (2 children):
| Child A | Child B | Result |
|---------|---------|--------|
| ✅      | ✅      | ✅     |
| ✅      | ❌      | ✅     |
| ❌      | ✅      | ✅     |
| ❌      | ❌      | ❌     |

---

### M_OF_N Operator (Threshold)

**Definition**: M out of N children must be complete.

**Use Cases**:
- "2 of [Meditate, Journal, Read]" (choose any 2)
- "3 of 5 chores" (do at least 3)
- "1 of [Call, Email, Text]" (at least one contact method)

**Parameters**:
- `threshold`: M (number required)
- `children`: N (total children)
- **Constraint**: 1 <= M <= N

**Evaluation**:
```typescript
function evaluateMOfN(childResults: boolean[], threshold: number): boolean {
  const completedCount = childResults.filter(r => r === true).length;
  return completedCount >= threshold;
}
```

**Truth Table** (3 children, threshold=2):
| Child A | Child B | Child C | Completed | Result |
|---------|---------|---------|-----------|--------|
| ✅      | ✅      | ✅      | 3/3       | ✅     |
| ✅      | ✅      | ❌      | 2/3       | ✅     |
| ✅      | ❌      | ✅      | 2/3       | ✅     |
| ❌      | ✅      | ✅      | 2/3       | ✅     |
| ✅      | ❌      | ❌      | 1/3       | ❌     |
| ❌      | ✅      | ❌      | 1/3       | ❌     |
| ❌      | ❌      | ✅      | 1/3       | ❌     |
| ❌      | ❌      | ❌      | 0/3       | ❌     |

---

## Evaluation Algorithm

### Recursive Tree Traversal

**Algorithm**: Depth-first post-order traversal (leaves → root)

1. Start at root node
2. Recursively evaluate all children
3. Apply operator logic to child results
4. Return result up the tree

**TypeScript Implementation**:

```typescript
/**
 * Evaluate composite task completion state.
 *
 * @param compositeTaskId - Composite task ID
 * @param boardId - Board ID (for task completion state)
 * @returns Evaluation result (isComplete + details)
 */
async function evaluateCompositeTask(
  compositeTaskId: string,
  boardId: string,
  db: DatabaseInstance
): Promise<CompositeEvaluationResult> {
  // 1. Fetch composite task
  const compositeTask = await db.compositeTasks.get(compositeTaskId);
  if (!compositeTask) {
    throw new Error(`CompositeTask ${compositeTaskId} not found`);
  }

  // 2. Fetch all nodes for this composite task
  const nodes = await db.compositeNodes
    .where('compositeTaskId')
    .equals(compositeTaskId)
    .and(node => !node.isDeleted)
    .toArray();

  // 3. Build node map for O(1) lookups
  const nodeMap = new Map<string, CompositeNode>();
  nodes.forEach(node => nodeMap.set(node.id, node));

  // 4. Get root node
  const rootNode = nodeMap.get(compositeTask.rootNodeId);
  if (!rootNode) {
    throw new Error(`Root node ${compositeTask.rootNodeId} not found`);
  }

  // 5. Recursively evaluate from root
  const result = await evaluateNode(rootNode, nodeMap, boardId, db);

  return {
    isComplete: result.isComplete,
    evaluationDetails: result
  };
}

/**
 * Recursively evaluate a single node.
 */
async function evaluateNode(
  node: CompositeNode,
  nodeMap: Map<string, CompositeNode>,
  boardId: string,
  db: DatabaseInstance
): Promise<EvaluationNode> {
  // BASE CASE: Leaf node
  if (node.nodeType === 'leaf') {
    const isComplete = await evaluateLeafNode(node, boardId, db);

    return {
      nodeId: node.id,
      nodeType: 'leaf',
      isComplete,
      taskId: node.taskId,
      taskTitle: await getTaskTitle(node.taskId, db)
    };
  }

  // RECURSIVE CASE: Operator node
  // Find children
  const children = Array.from(nodeMap.values())
    .filter(n => n.parentNodeId === node.id)
    .sort((a, b) => a.nodeIndex - b.nodeIndex);

  // Evaluate all children recursively
  const childEvaluations = await Promise.all(
    children.map(child => evaluateNode(child, nodeMap, boardId, db))
  );

  // Extract boolean results
  const childResults = childEvaluations.map(e => e.isComplete);

  // Apply operator logic
  let isComplete = false;
  const completedCount = childResults.filter(r => r).length;

  switch (node.operatorType) {
    case 'AND':
      isComplete = childResults.every(r => r === true);
      break;

    case 'OR':
      isComplete = childResults.some(r => r === true);
      break;

    case 'M_OF_N':
      isComplete = completedCount >= (node.threshold || 0);
      break;

    default:
      throw new Error(`Unknown operator: ${node.operatorType}`);
  }

  return {
    nodeId: node.id,
    nodeType: 'operator',
    isComplete,
    operatorType: node.operatorType,
    threshold: node.threshold,
    completedChildren: completedCount,
    totalChildren: children.length,
    children: childEvaluations
  };
}

/**
 * Evaluate leaf node completion.
 */
async function evaluateLeafNode(
  node: CompositeNode,
  boardId: string,
  db: DatabaseInstance
): Promise<boolean> {
  if (!node.taskId) {
    return false;  // Invalid leaf node
  }

  // Check if task is deleted
  const task = await db.tasks.get(node.taskId);
  if (task?.isDeleted) {
    return false;  // Deleted task is always incomplete
  }

  // Check task completion on this board
  const boardTask = await db.boardTasks
    .where(['boardId', 'taskId'])
    .equals([boardId, node.taskId])
    .first();

  return boardTask?.isCompleted ?? false;
}

/**
 * Get task title for display.
 */
async function getTaskTitle(
  taskId: string,
  db: DatabaseInstance
): Promise<string> {
  const task = await db.tasks.get(taskId);
  return task?.title ?? 'Unknown Task';
}
```

**Swift Implementation** (mirrors TypeScript):

```swift
func evaluateCompositeTask(
    compositeTaskId: String,
    boardId: String
) async throws -> CompositeEvaluationResult {
    // 1. Fetch composite task
    let compositeTask = try await db.compositeTasks.get(compositeTaskId)
    guard let compositeTask = compositeTask else {
        throw CompositeTaskError.notFound(compositeTaskId)
    }

    // 2. Fetch all nodes
    let nodes = try await db.compositeNodes
        .filter(Column("compositeTaskId") == compositeTaskId && Column("isDeleted") == false)
        .fetchAll()

    // 3. Build node map
    var nodeMap: [String: CompositeNode] = [:]
    for node in nodes {
        nodeMap[node.id] = node
    }

    // 4. Get root node
    guard let rootNode = nodeMap[compositeTask.rootNodeId] else {
        throw CompositeTaskError.rootNodeNotFound(compositeTask.rootNodeId)
    }

    // 5. Recursively evaluate
    let result = try await evaluateNode(rootNode, nodeMap: nodeMap, boardId: boardId)

    return CompositeEvaluationResult(
        isComplete: result.isComplete,
        evaluationDetails: result
    )
}

func evaluateNode(
    _ node: CompositeNode,
    nodeMap: [String: CompositeNode],
    boardId: String
) async throws -> EvaluationNode {
    // Base case: Leaf node
    if node.nodeType == .leaf {
        let isComplete = try await evaluateLeafNode(node, boardId: boardId)
        let taskTitle = try await getTaskTitle(node.taskId)

        return EvaluationNode(
            nodeId: node.id,
            nodeType: .leaf,
            isComplete: isComplete,
            taskId: node.taskId,
            taskTitle: taskTitle
        )
    }

    // Recursive case: Operator node
    let children = nodeMap.values
        .filter { $0.parentNodeId == node.id }
        .sorted { $0.nodeIndex < $1.nodeIndex }

    let childEvaluations = try await withThrowingTaskGroup(of: EvaluationNode.self) { group in
        for child in children {
            group.addTask {
                try await evaluateNode(child, nodeMap: nodeMap, boardId: boardId)
            }
        }

        var results: [EvaluationNode] = []
        for try await result in group {
            results.append(result)
        }
        return results
    }

    let childResults = childEvaluations.map { $0.isComplete }
    let completedCount = childResults.filter { $0 }.count

    var isComplete = false

    switch node.operatorType {
    case .and:
        isComplete = childResults.allSatisfy { $0 }
    case .or:
        isComplete = childResults.contains(true)
    case .mOfN:
        isComplete = completedCount >= (node.threshold ?? 0)
    default:
        throw CompositeTaskError.unknownOperator(node.operatorType)
    }

    return EvaluationNode(
        nodeId: node.id,
        nodeType: .operator,
        isComplete: isComplete,
        operatorType: node.operatorType,
        threshold: node.threshold,
        completedChildren: completedCount,
        totalChildren: children.count,
        children: childEvaluations
    )
}
```

---

### Performance Characteristics

| Tree Size | Nodes | Depth | Evaluation Time |
|-----------|-------|-------|-----------------|
| Small     | 5     | 2     | < 10ms          |
| Medium    | 10    | 3     | < 25ms          |
| Large     | 20    | 5     | < 50ms          |

**Complexity**:
- **Time**: O(N) where N = number of nodes (each node evaluated once)
- **Space**: O(D) where D = depth (recursion stack)

---

## Auto-Task-Conversion

### Problem

Users should be able to create "inline" tasks when building composite trees without manually creating tasks first.

**Example**: User wants composite task "(Exercise OR Yoga)". They don't want to:
1. Navigate to task creation
2. Create "Exercise" task
3. Navigate to task creation
4. Create "Yoga" task
5. Navigate back to composite builder
6. Reference the two tasks

Instead, they should create both tasks inline in the tree builder.

### Solution: Auto-Convert Inline to Real Tasks

When user provides inline task data, automatically create a real task in the `tasks` table and reference it.

**Benefits**:
- ✅ Simpler data model (no separate `composite_node_completion` table)
- ✅ "Inline" tasks become automatically reusable
- ✅ All completion state in `board_tasks` (single source of truth)
- ✅ Inline tasks sync like any other task

### Implementation

```typescript
async function createCompositeNode(
  input: CreateCompositeNodeInput,
  userId: string,
  db: DatabaseInstance
): Promise<CompositeNode> {
  if (input.nodeType === 'leaf') {
    let taskId = input.taskId;

    // Auto-create task if user provided inline task data
    if (!taskId && input.autoCreateTask) {
      const newTask = await db.tasks.add({
        id: generateUUID(),
        userId,
        type: input.autoCreateTask.type,
        title: input.autoCreateTask.title,
        action: input.autoCreateTask.action,
        unit: input.autoCreateTask.unit,
        maxCount: input.autoCreateTask.maxCount,
        createdAt: currentTimestamp(),
        updatedAt: currentTimestamp(),
        version: 1,
        isDeleted: false
      });

      // Queue task for sync
      await syncQueue.enqueue({
        entityType: 'task',
        entityId: newTask.id,
        operationType: 'CREATE',
        payload: newTask
      });

      taskId = newTask.id;
    }

    // Create leaf node (always with taskId)
    return {
      id: generateUUID(),
      compositeTaskId: input.compositeTaskId,
      parentNodeId: input.parentNodeId,
      nodeIndex: input.nodeIndex,
      nodeType: 'leaf',
      taskId,  // Always set (either referenced or auto-created)
      createdAt: currentTimestamp(),
      updatedAt: currentTimestamp(),
      version: 1,
      isDeleted: false
    };
  }

  // Operator node logic...
}
```

**User Flow**:
```
User opens tree builder
  ↓
Adds OR operator as root
  ↓
Adds child: "Exercise" (inline)
  → Auto-creates Task { title: "Exercise", type: NORMAL }
  → Creates leaf node { taskId: <auto-created-task-id> }
  ↓
Adds child: "Yoga" (inline)
  → Auto-creates Task { title: "Yoga", type: NORMAL }
  → Creates leaf node { taskId: <auto-created-task-id> }
  ↓
Saves composite task
```

---

## Validation

### Schema Validation (Zod)

```typescript
export const CreateCompositeNodeInputSchema: z.ZodSchema = z.lazy(() =>
  z.object({
    nodeType: z.enum(['operator', 'leaf']),

    // Operator node fields
    operatorType: z.enum(['AND', 'OR', 'M_OF_N']).optional(),
    threshold: z.number().int().positive().optional(),
    children: z.array(CreateCompositeNodeInputSchema).optional(),

    // Leaf node fields
    taskId: z.string().uuid().optional(),
    autoCreateTask: z.object({
      type: z.nativeEnum(TaskType),
      title: z.string().min(1).max(200),
      action: z.string().max(50).optional(),
      unit: z.string().max(50).optional(),
      maxCount: z.number().int().positive().optional()
    }).optional(),
  })
  .refine(
    (data) => {
      // Operator node must have operatorType and children
      if (data.nodeType === 'operator') {
        return data.operatorType && data.children && data.children.length > 0;
      }
      return true;
    },
    { message: 'Operator nodes must have operatorType and children' }
  )
  .refine(
    (data) => {
      // M_OF_N must have threshold
      if (data.operatorType === 'M_OF_N') {
        return data.threshold !== undefined && data.threshold > 0;
      }
      return true;
    },
    { message: 'M_OF_N operator must have threshold > 0' }
  )
  .refine(
    (data) => {
      // Threshold must be <= children count
      if (data.operatorType === 'M_OF_N' && data.threshold && data.children) {
        return data.threshold <= data.children.length;
      }
      return true;
    },
    { message: 'Threshold must be <= number of children' }
  )
  .refine(
    (data) => {
      // Leaf node must have EITHER taskId OR autoCreateTask (not both)
      if (data.nodeType === 'leaf') {
        return (data.taskId !== undefined) !== (data.autoCreateTask !== undefined);
      }
      return true;
    },
    { message: 'Leaf nodes must have either taskId or autoCreateTask (not both)' }
  )
  .refine(
    (data) => {
      // Leaf node cannot have children
      if (data.nodeType === 'leaf') {
        return !data.children || data.children.length === 0;
      }
      return true;
    },
    { message: 'Leaf nodes cannot have children' }
  )
);
```

### Circular Reference Prevention

```typescript
/**
 * Validate composite task input for circular references.
 *
 * Circular references occur when:
 * - A composite task references itself
 * - Composite A → Task B → Composite C → Task A (cycle)
 */
export async function validateNoCircularReferences(
  input: CreateCompositeTaskInput,
  userId: string,
  db: DatabaseInstance
): Promise<void> {
  const visited = new Set<string>();
  await checkNodeForCircularReferences(input.rootNode, visited, db);
}

async function checkNodeForCircularReferences(
  nodeInput: CreateCompositeNodeInput,
  visited: Set<string>,
  db: DatabaseInstance
): Promise<void> {
  if (nodeInput.nodeType === 'leaf' && nodeInput.taskId) {
    const taskId = nodeInput.taskId;

    // Check if already visited (circular reference)
    if (visited.has(taskId)) {
      throw new Error(
        `Circular reference detected: task ${taskId} is already in the tree`
      );
    }

    visited.add(taskId);

    // Check if this task is itself a composite task
    // (composite tasks currently stored in separate table, so this won't happen)
    // But if we later allow composite tasks to reference other composites, we'd check here

    // For now, only regular tasks can be referenced, so no further checking needed
  }

  // Recursively check children
  if (nodeInput.children) {
    for (const child of nodeInput.children) {
      // Create new Set for each branch to allow same task in different branches
      await checkNodeForCircularReferences(child, new Set(visited), db);
    }
  }
}
```

### Tree Size Limits

```typescript
const MAX_TREE_DEPTH = 5;       // Max nesting levels
const MAX_NODES_PER_TREE = 20;  // Max total nodes

function validateTreeSize(rootNode: CreateCompositeNodeInput): void {
  const depth = calculateDepth(rootNode);
  const nodeCount = countNodes(rootNode);

  if (depth > MAX_TREE_DEPTH) {
    throw new Error(
      `Tree depth ${depth} exceeds limit ${MAX_TREE_DEPTH}`
    );
  }

  if (nodeCount > MAX_NODES_PER_TREE) {
    throw new Error(
      `Tree has ${nodeCount} nodes, limit is ${MAX_NODES_PER_TREE}`
    );
  }
}

function calculateDepth(node: CreateCompositeNodeInput, currentDepth = 1): number {
  if (!node.children || node.children.length === 0) {
    return currentDepth;
  }

  const childDepths = node.children.map(child =>
    calculateDepth(child, currentDepth + 1)
  );

  return Math.max(...childDepths);
}

function countNodes(node: CreateCompositeNodeInput): number {
  if (!node.children || node.children.length === 0) {
    return 1;
  }

  const childCounts = node.children.map(child => countNodes(child));
  return 1 + childCounts.reduce((sum, count) => sum + count, 0);
}
```

---

## Tree Builder UI

### Recommended Approach

**Form-Based Nested Builder** (simpler than drag-and-drop for MVP)

### Component Structure

```typescript
interface TreeNodeBuilderProps {
  node: CompositeNodeInput;
  onChange: (node: CompositeNodeInput) => void;
  onRemove: () => void;
  existingTasks: Task[];
  depth: number;
}

function TreeNodeBuilder({
  node,
  onChange,
  onRemove,
  existingTasks,
  depth
}: TreeNodeBuilderProps) {
  if (node.nodeType === 'operator') {
    return (
      <div className="operator-node" style={{ marginLeft: `${depth * 20}px` }}>
        {/* Operator type selector */}
        <select
          value={node.operatorType}
          onChange={(e) => onChange({ ...node, operatorType: e.target.value })}
        >
          <option value="AND">All of (AND)</option>
          <option value="OR">Any of (OR)</option>
          <option value="M_OF_N">M of N</option>
        </select>

        {/* Threshold input for M_OF_N */}
        {node.operatorType === 'M_OF_N' && (
          <input
            type="number"
            min="1"
            max={node.children?.length || 1}
            value={node.threshold}
            onChange={(e) => onChange({ ...node, threshold: parseInt(e.target.value) })}
          />
        )}

        {/* Children */}
        <div className="children">
          {node.children?.map((child, index) => (
            <TreeNodeBuilder
              key={index}
              node={child}
              onChange={(updatedChild) => {
                const updatedChildren = [...(node.children || [])];
                updatedChildren[index] = updatedChild;
                onChange({ ...node, children: updatedChildren });
              }}
              onRemove={() => {
                const updatedChildren = (node.children || []).filter((_, i) => i !== index);
                onChange({ ...node, children: updatedChildren });
              }}
              existingTasks={existingTasks}
              depth={depth + 1}
            />
          ))}
        </div>

        {/* Add child button */}
        <button onClick={() => {
          const newChild: CompositeNodeInput = {
            nodeType: 'leaf',
            autoCreateTask: { type: TaskType.NORMAL, title: '' }
          };
          onChange({
            ...node,
            children: [...(node.children || []), newChild]
          });
        }}>
          Add Child
        </button>

        {/* Remove this operator */}
        <button onClick={onRemove}>Remove</button>
      </div>
    );
  }

  // Leaf node
  return (
    <div className="leaf-node" style={{ marginLeft: `${depth * 20}px` }}>
      <select
        value={node.taskId || 'create-new'}
        onChange={(e) => {
          if (e.target.value === 'create-new') {
            onChange({
              ...node,
              taskId: undefined,
              autoCreateTask: { type: TaskType.NORMAL, title: '' }
            });
          } else {
            onChange({
              ...node,
              taskId: e.target.value,
              autoCreateTask: undefined
            });
          }
        }}
      >
        <option value="create-new">Create New Task...</option>
        {existingTasks.map(task => (
          <option key={task.id} value={task.id}>
            {task.title}
          </option>
        ))}
      </select>

      {/* Inline task creation */}
      {node.autoCreateTask && (
        <input
          type="text"
          placeholder="Task title"
          value={node.autoCreateTask.title}
          onChange={(e) => onChange({
            ...node,
            autoCreateTask: { ...node.autoCreateTask!, title: e.target.value }
          })}
        />
      )}

      <button onClick={onRemove}>Remove</button>
    </div>
  );
}
```

### Usage

```typescript
function CompositeTaskBuilder() {
  const [rootNode, setRootNode] = useState<CompositeNodeInput>({
    nodeType: 'operator',
    operatorType: 'AND',
    children: []
  });

  const [title, setTitle] = useState('');
  const existingTasks = useExistingTasks();

  const handleSave = async () => {
    // Validate
    validateTreeSize(rootNode);
    await validateNoCircularReferences({ title, rootNode }, userId, db);

    // Create composite task
    await createCompositeTask({ title, rootNode });
  };

  return (
    <div>
      <input
        type="text"
        placeholder="Composite task title"
        value={title}
        onChange={(e) => setTitle(e.target.value)}
      />

      <TreeNodeBuilder
        node={rootNode}
        onChange={setRootNode}
        onRemove={() => {}}
        existingTasks={existingTasks}
        depth={0}
      />

      <button onClick={handleSave}>Save Composite Task</button>
    </div>
  );
}
```

---

## Performance Optimization

### 1. Evaluation Caching

```typescript
class CompositeEvaluationCache {
  private cache = new Map<string, boolean>();

  getCacheKey(compositeTaskId: string, boardId: string): string {
    return `${compositeTaskId}:${boardId}`;
  }

  get(compositeTaskId: string, boardId: string): boolean | undefined {
    return this.cache.get(this.getCacheKey(compositeTaskId, boardId));
  }

  set(compositeTaskId: string, boardId: string, result: boolean): void {
    this.cache.set(this.getCacheKey(compositeTaskId, boardId), result);
  }

  invalidate(compositeTaskId: string, boardId: string): void {
    this.cache.delete(this.getCacheKey(compositeTaskId, boardId));
  }

  invalidateAll(): void {
    this.cache.clear();
  }
}

// Usage
const evaluationCache = new CompositeEvaluationCache();

async function evaluateCompositeTaskCached(
  compositeTaskId: string,
  boardId: string
): Promise<boolean> {
  // Check cache
  const cached = evaluationCache.get(compositeTaskId, boardId);
  if (cached !== undefined) {
    return cached;
  }

  // Evaluate
  const result = await evaluateCompositeTask(compositeTaskId, boardId);

  // Cache result
  evaluationCache.set(compositeTaskId, boardId, result.isComplete);

  return result.isComplete;
}

// Invalidate cache when sub-tasks complete
async function completeTask(boardId: string, taskId: string) {
  // ... update board_tasks ...

  // Find composite tasks referencing this task
  const compositeNodes = await db.compositeNodes
    .where('taskId')
    .equals(taskId)
    .toArray();

  // Invalidate cache for all affected composite tasks
  for (const node of compositeNodes) {
    evaluationCache.invalidate(node.compositeTaskId, boardId);
  }
}
```

### 2. Batch Node Queries

```typescript
// ✅ GOOD: Fetch all nodes in one query
const nodes = await db.compositeNodes
  .where('compositeTaskId')
  .equals(compositeTaskId)
  .toArray();

const nodeMap = new Map(nodes.map(n => [n.id, n]));

// ❌ BAD: Individual queries per node
for (const nodeId of childNodeIds) {
  const node = await db.compositeNodes.get(nodeId);  // Slow!
}
```

### 3. Parallel Child Evaluation

```typescript
// ✅ GOOD: Evaluate children in parallel
const childEvaluations = await Promise.all(
  children.map(child => evaluateNode(child, nodeMap, boardId, db))
);

// ❌ BAD: Sequential evaluation
const childEvaluations = [];
for (const child of children) {
  const result = await evaluateNode(child, nodeMap, boardId, db);
  childEvaluations.push(result);
}
```

---

## Edge Cases

### 1. Deleted Task Reference

**Problem**: Referenced task is soft-deleted.

**Solution**: Treat as incomplete, show warning in UI.

```typescript
async function evaluateLeafNode(
  node: CompositeNode,
  boardId: string,
  db: DatabaseInstance
): Promise<boolean> {
  if (!node.taskId) return false;

  const task = await db.tasks.get(node.taskId);

  // Deleted task → always incomplete
  if (task?.isDeleted) {
    return false;
  }

  const boardTask = await db.boardTasks
    .where(['boardId', 'taskId'])
    .equals([boardId, node.taskId])
    .first();

  return boardTask?.isCompleted ?? false;
}
```

**UI Handling**:
```typescript
function LeafNodeDisplay({ node, taskTitle }: Props) {
  const task = useTask(node.taskId);

  if (task?.isDeleted) {
    return (
      <div className="deleted-task-warning">
        ⚠️ Referenced task deleted: "{taskTitle}"
        <button onClick={() => replaceTask(node.id)}>Replace Task</button>
      </div>
    );
  }

  return <div>{taskTitle}</div>;
}
```

---

### 2. Empty Operator (No Children)

**Problem**: Operator node has no children (e.g., AND with 0 children).

**Solution**: Prevent at validation, handle gracefully in evaluation.

```typescript
// Validation prevents creation
CreateCompositeNodeInputSchema.refine(
  (data) => {
    if (data.nodeType === 'operator') {
      return data.children && data.children.length > 0;
    }
    return true;
  },
  { message: 'Operator nodes must have at least 1 child' }
);

// Evaluation handles edge case
function evaluateOperator(operatorType: string, childResults: boolean[]): boolean {
  if (childResults.length === 0) {
    // Edge case: No children
    // AND(∅) = true (vacuous truth)
    // OR(∅) = false
    // M_OF_N(∅) = false
    return operatorType === 'AND';
  }

  // Normal logic...
}
```

---

### 3. Counting Task as Leaf

**Problem**: Composite leaf references a counting task. When is it "complete"?

**Solution**: Complete when `currentCount >= maxCount`.

```typescript
async function evaluateLeafNode(
  node: CompositeNode,
  boardId: string,
  db: DatabaseInstance
): Promise<boolean> {
  if (!node.taskId) return false;

  const task = await db.tasks.get(node.taskId);
  if (task?.isDeleted) return false;

  const boardTask = await db.boardTasks
    .where(['boardId', 'taskId'])
    .equals([boardId, node.taskId])
    .first();

  if (!boardTask) return false;

  // Counting task: Check if count >= maxCount
  if (task.type === TaskType.COUNTING) {
    return (boardTask.currentCount || 0) >= task.maxCount;
  }

  // Normal/Progress task: Check isCompleted
  return boardTask.isCompleted;
}
```

---

## Sync Strategy

**See [SYNC_STRATEGY.md#composite-task-sync](./SYNC_STRATEGY.md#composite-task-sync) for comprehensive sync documentation.**

### Key Principles

1. **Atomic Tree Sync**: Sync entire trees (all nodes or none)
2. **Last-Write-Wins**: Use version field at composite task level
3. **No Node-Level Merging**: Too complex for MVP

### Pull Sync

```typescript
async function pullCompositeTaskTree(compositeTaskId: string) {
  // 1. Fetch remote tree
  const remoteTask = await firestoreGet(`compositeTasks/${compositeTaskId}`);
  const remoteNodes = await firestoreQuery(
    'compositeNodes',
    where('compositeTaskId', '==', compositeTaskId)
  );

  // 2. Replace local tree atomically
  await db.transaction('rw', [db.compositeTasks, db.compositeNodes], async () => {
    // Delete old nodes
    await db.compositeNodes
      .where('compositeTaskId')
      .equals(compositeTaskId)
      .delete();

    // Insert remote task and nodes
    await db.compositeTasks.put(remoteTask);
    await db.compositeNodes.bulkPut(remoteNodes);
  });
}
```

---

## Testing

### Unit Tests (Evaluation Algorithm)

```typescript
describe('Composite task evaluation', () => {
  it('evaluates AND operator correctly', async () => {
    const result = await evaluateNode(andNode, nodeMap, boardId, db);

    expect(result.isComplete).toBe(true);  // All children complete
    expect(result.completedChildren).toBe(2);
    expect(result.totalChildren).toBe(2);
  });

  it('evaluates OR operator correctly', async () => {
    const result = await evaluateNode(orNode, nodeMap, boardId, db);

    expect(result.isComplete).toBe(true);  // At least one complete
    expect(result.completedChildren).toBe(1);
  });

  it('evaluates M_OF_N operator correctly', async () => {
    const mOfNNode = {
      operatorType: 'M_OF_N',
      threshold: 2
    };

    const result = await evaluateNode(mOfNNode, nodeMap, boardId, db);

    expect(result.isComplete).toBe(true);  // 2 of 3 complete
    expect(result.completedChildren).toBe(2);
    expect(result.totalChildren).toBe(3);
  });

  it('handles nested operators correctly', async () => {
    // (Exercise OR Yoga) AND (2 of [Meditate, Journal, Read])
    const result = await evaluateCompositeTask(compositeTaskId, boardId, db);

    expect(result.isComplete).toBe(true);
    expect(result.evaluationDetails.children).toHaveLength(2);
  });

  it('handles deleted task references', async () => {
    const deletedTaskNode = {
      nodeType: 'leaf',
      taskId: deletedTaskId
    };

    const result = await evaluateLeafNode(deletedTaskNode, boardId, db);

    expect(result).toBe(false);  // Deleted task is incomplete
  });
});
```

### Integration Tests

```typescript
describe('Composite task integration', () => {
  it('auto-creates tasks from inline definitions', async () => {
    const compositeTask = await createCompositeTask({
      title: 'Wellness',
      rootNode: {
        nodeType: 'operator',
        operatorType: 'OR',
        children: [
          {
            nodeType: 'leaf',
            autoCreateTask: { type: TaskType.NORMAL, title: 'Exercise' }
          },
          {
            nodeType: 'leaf',
            autoCreateTask: { type: TaskType.NORMAL, title: 'Yoga' }
          }
        ]
      }
    });

    // Verify tasks were auto-created
    const tasks = await db.tasks
      .where('title')
      .anyOf(['Exercise', 'Yoga'])
      .toArray();

    expect(tasks).toHaveLength(2);

    // Verify nodes reference the tasks
    const nodes = await db.compositeNodes
      .where('compositeTaskId')
      .equals(compositeTask.id)
      .toArray();

    const leafNodes = nodes.filter(n => n.nodeType === 'leaf');
    expect(leafNodes.every(n => n.taskId !== undefined)).toBe(true);
  });

  it('completes composite when all conditions met', async () => {
    // Create composite: "Exercise AND Meditate"
    const compositeTask = await createCompositeTask({
      title: 'Daily Routine',
      rootNode: {
        nodeType: 'operator',
        operatorType: 'AND',
        children: [
          { nodeType: 'leaf', taskId: exerciseTaskId },
          { nodeType: 'leaf', taskId: meditateTaskId }
        ]
      }
    });

    // Add to board
    await addCompositeTaskToBoard(boardId, compositeTask.id, 0, 0);

    // Complete first task - composite still incomplete
    await completeTask(boardId, exerciseTaskId);

    let evaluation = await evaluateCompositeTask(compositeTask.id, boardId, db);
    expect(evaluation.isComplete).toBe(false);

    // Complete second task - composite completes
    await completeTask(boardId, meditateTaskId);

    evaluation = await evaluateCompositeTask(compositeTask.id, boardId, db);
    expect(evaluation.isComplete).toBe(true);
  });

  it('syncs composite task tree correctly', async () => {
    // Create on device A
    const compositeTask = await createCompositeTask({ ... });

    // Sync to Firestore
    await pushCompositeTaskTree(compositeTask.id);

    // Pull on device B
    await pullCompositeTaskTree(compositeTask.id);

    // Verify tree structure
    const localTask = await db.compositeTasks.get(compositeTask.id);
    const localNodes = await db.compositeNodes
      .where('compositeTaskId')
      .equals(compositeTask.id)
      .toArray();

    expect(localTask).toBeDefined();
    expect(localNodes.length).toBeGreaterThan(0);
  });
});
```

---

## Summary

Composite tasks provide powerful task composition using logical operators:

**Key Features**:
- ✅ Three operators: AND, OR, M_OF_N
- ✅ Unlimited nesting depth (soft limit: 5 levels)
- ✅ Recursive evaluation algorithm (< 50ms for 20-node trees)
- ✅ Auto-task-conversion (inline → real tasks)
- ✅ Circular reference prevention
- ✅ Atomic tree sync (all nodes or none)
- ✅ Evaluation caching for performance

**Best Practices**:
- Validate tree size (depth <= 5, nodes <= 20)
- Prevent circular references at creation
- Sync entire trees atomically
- Cache evaluation results
- Handle deleted task references gracefully
- Use form-based tree builder (simpler than drag-and-drop)

**See Also**:
- [TASK_SYSTEM.md](./TASK_SYSTEM.md) - Overview of all task types
- [SYNC_STRATEGY.md](./SYNC_STRATEGY.md) - Composite task sync strategies
- [OFFLINE_FIRST.md](./OFFLINE_FIRST.md) - Offline-first architecture
- [CLAUDE_GUIDE.md](./CLAUDE_GUIDE.md) - Implementation guidelines
