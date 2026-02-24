# Composite Tasks

## Overview

Composite tasks compose other tasks using one of three logical operators, evaluated over a **flat list of subtasks** (depth 1). Unlike the task types in the `tasks` table (Normal, Counting, Progress), composite tasks live in a separate `composite_tasks` / `composite_nodes` table hierarchy and are not a `TaskType` enum value.

**Core design principle**: Keep composition simple and approachable. A composite task has one operator and a flat list of subtasks — no nested tree building. If a user needs deeper nesting, they create an inner composite first (as a standalone task), then add it as an existing subtask when building the outer composite.

---

## Operators

Composite tasks support three operators, presented with friendly user-facing names:

| Internal value | User-facing label | Description |
|---|---|---|
| `AND` | **All of** | Every subtask must be complete |
| `OR` | **Any of** | At least one subtask must be complete |
| `M_OF_N` | **At least N of** | At least N subtasks must be complete |

For **At least N of**, a stepper control appears below the operator picker. N is clamped to `[1, subtaskCount]` — if subtasks are removed and N would exceed the new count, it is automatically clamped down.

---

## Structure

### One level deep

```
CompositeTask
  └─ root (operator node: All of / Any of / At least N of)
       ├─ leaf 0 (taskId or childCompositeTaskId)
       ├─ leaf 1 (taskId or childCompositeTaskId)
       └─ leaf N (taskId or childCompositeTaskId)
```

There are exactly **two node levels** in the database:

1. **Root node** — always an operator node (`nodeType = 'operator'`)
2. **Leaf nodes** — each references either a regular task (`taskId`) or an existing composite task (`childCompositeTaskId`)

The depth constraint is enforced by the UI. The data model (two-level flat tree) is always the result.

### Constraints

- **Minimum 2 subtasks** required to save a composite task
- **No duplicate subtasks** — the same `taskId` or `childCompositeTaskId` cannot appear twice in one composite task
- **No circular references** — a composite task cannot directly or transitively reference itself (validated at creation time)

---

## Subtasks

### Adding existing tasks

Any task type can be added as an existing subtask:
- Normal tasks
- Counting tasks
- Progress tasks
- **Existing composite tasks** (treated as a single black-box unit — its internal structure is not displayed or editable from the parent composite's form)

### Adding new inline tasks

Users can also create tasks inline during composite task creation. Only the three core task types are available for inline creation:
- Normal
- Counting
- Progress

Composite tasks **cannot** be created inline — they must be created as standalone composites first, then added as an existing subtask.

Inline-created tasks are auto-saved to the `tasks` table as real tasks within the same write transaction as the composite task. They become fully reusable and appear in the regular task library.

---

## Data Model

### composite_tasks table

```typescript
interface CompositeTask {
  id: string;
  userId: string;
  title: string;
  description?: string;
  rootNodeId: string;   // FK to composite_nodes (always the operator node)

  createdAt: string;    // ISO8601
  updatedAt: string;    // ISO8601
  lastSyncedAt?: string;
  version: number;
  isDeleted: boolean;
  deletedAt?: string;
}
```

```sql
CREATE TABLE composite_tasks (
    id TEXT PRIMARY KEY NOT NULL,
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

    FOREIGN KEY (userId) REFERENCES users(id)
);

CREATE INDEX idx_composite_tasks_user_deleted ON composite_tasks(userId, isDeleted);
```

### composite_nodes table

```typescript
interface CompositeNode {
  id: string;
  compositeTaskId: string;   // FK to composite_tasks
  parentNodeId?: string;     // FK to composite_nodes (null for root)
  nodeIndex: number;         // Order among siblings (0-based)

  nodeType: 'operator' | 'leaf';

  // Operator node fields (only when nodeType === 'operator')
  operatorType?: 'AND' | 'OR' | 'M_OF_N';
  threshold?: number;        // Only for M_OF_N

  // Leaf node fields — exactly one of these is set
  taskId?: string;                  // FK to tasks (normal/counting/progress)
  childCompositeTaskId?: string;    // FK to composite_tasks (nested composite)

  createdAt: string;
  updatedAt: string;
  lastSyncedAt?: string;
  version: number;
  isDeleted: boolean;
  deletedAt?: string;
}
```

```sql
CREATE TABLE composite_nodes (
    id TEXT PRIMARY KEY NOT NULL,
    compositeTaskId TEXT NOT NULL,
    parentNodeId TEXT,
    nodeIndex INTEGER NOT NULL,

    nodeType TEXT NOT NULL,        -- 'operator' or 'leaf'
    operatorType TEXT,             -- 'AND', 'OR', 'M_OF_N'
    threshold INTEGER,             -- For M_OF_N only

    taskId TEXT,                   -- FK to tasks (leaf → regular task)
    childCompositeTaskId TEXT,     -- FK to composite_tasks (leaf → nested composite)

    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    isDeleted INTEGER NOT NULL DEFAULT 0,
    deletedAt TEXT,

    FOREIGN KEY (compositeTaskId) REFERENCES composite_tasks(id) ON DELETE CASCADE,
    FOREIGN KEY (parentNodeId) REFERENCES composite_nodes(id),
    FOREIGN KEY (taskId) REFERENCES tasks(id),
    FOREIGN KEY (childCompositeTaskId) REFERENCES composite_tasks(id)
);

CREATE INDEX idx_composite_nodes_composite ON composite_nodes(compositeTaskId);
CREATE INDEX idx_composite_nodes_parent_index ON composite_nodes(parentNodeId, nodeIndex);
CREATE INDEX idx_composite_nodes_task ON composite_nodes(taskId);
CREATE INDEX idx_composite_nodes_child_composite ON composite_nodes(childCompositeTaskId);
```

> **DB migration**: `childCompositeTaskId` and its index are added in migration v3 via `ALTER TABLE composite_nodes ADD COLUMN childCompositeTaskId TEXT REFERENCES composite_tasks(id)` + `CREATE INDEX`.

### Leaf node invariants

A leaf node has **exactly one** of `taskId` or `childCompositeTaskId` set — never both, never neither (validated at creation).

---

## Evaluation Algorithm

### Pure function signature

```typescript
/**
 * Evaluate whether a flat composite task tree is complete.
 *
 * @param nodes           All CompositeNode records for one composite task (non-deleted)
 * @param rootNodeId      ID of the root (operator) node
 * @param taskCompletions Map of taskId → isCompleted for regular tasks
 * @param compositeCompletions Map of compositeTaskId → isCompleted for child composites
 * @returns true if the composite task is complete
 */
function evaluateCompositeTree(
  nodes: CompositeNode[],
  rootNodeId: string,
  taskCompletions: Record<string, boolean>,
  compositeCompletions: Record<string, boolean>
): boolean
```

The function is pure — it takes pre-fetched completion maps and performs no I/O.

### Operator logic

```
AND:     all children complete
OR:      at least one child complete
M_OF_N:  completedCount >= threshold
```

### Leaf evaluation

```
leaf.taskId              → taskCompletions[taskId] ?? false
leaf.childCompositeTaskId → compositeCompletions[childCompositeTaskId] ?? false
```

When a child composite is used as a leaf, its completion is evaluated independently (its own `evaluateCompositeTree` call) and passed in via `compositeCompletions`. This keeps the algorithm pure and avoids circular evaluation.

### Edge cases

| Situation | Result |
|---|---|
| Unknown `taskId` (not in completions map) | `false` |
| Unknown `childCompositeTaskId` | `false` |
| Deleted leaf nodes | Filtered out before evaluation |
| AND operator with 0 non-deleted children | `true` (vacuous truth) |
| OR / M_OF_N with 0 non-deleted children | `false` |

---

## Validation

### UI constraints (enforced before saving)

- Title: required, 1–200 characters
- Operator: required
- Subtasks: minimum 2 (cannot save with 0 or 1 subtasks)
- No duplicate subtasks: same `taskId` or `childCompositeTaskId` cannot appear twice
- Threshold (M_OF_N): integer in `[1, subtaskCount]`

### Circular reference prevention

When an existing composite task is added as a subtask, validate that adding it would not create a cycle:

```
A → B → C → A  (circular — reject)
A → B, A → C   (DAG — allowed)
```

Check at creation time: for each `childCompositeTaskId` leaf, fetch that composite's nodes and confirm none of them (directly or transitively) reference the composite task being created.

---

## UI Design

### Creation form layout

```
┌──────────────────────────────────────┐
│ Title                                │
│ [____________________________________]│
│                                      │
│ Operator                             │
│ [All of] [Any of] [At least N of]   │
│                                      │
│ (only shown for "At least N of"):    │
│ Required: [−] 2 [+] of 3 subtasks   │
│                                      │
│ Subtasks                             │
│ ┌────────────────────────────────┐   │
│ │ [Select existing ▼ ] [× Remove]│   │
│ │  Run 5 miles (Counting)        │   │
│ ├────────────────────────────────┤   │
│ │ [Create new] [× Remove]        │   │
│ │  Normal ▼  Title: [__________] │   │
│ └────────────────────────────────┘   │
│                                      │
│ [+ Add existing task]                │
│ [+ Create new task]                  │
│                                      │
│ [Create Composite Task]              │
└──────────────────────────────────────┘
```

### Key UX rules

- "Add existing task" shows ALL task types including composites; already-selected tasks are excluded
- "Create new task" shows only Normal / Counting / Progress type options (not Composite)
- The threshold stepper is only visible when "At least N of" is selected
- If a subtask is removed and the threshold exceeds the new count, threshold auto-clamps
- Submit is disabled until title is set and at least 2 subtasks are present

---

## Example

**User creates**: "Wellness routine — Exercise OR Yoga, AND journal"

With the new flat design, this would be two separate composites:

**Composite 1** — "Active Recovery" (Any of)
- Leaf: Run 5 miles (existing Counting task)
- Leaf: Yoga (existing Normal task)

**Composite 2** — "Wellness Routine" (All of)
- Leaf: Active Recovery (existing Composite task — Composite 1 above)
- Leaf: Journal (existing Normal task)

---

## Sync Strategy

**See [SYNC_STRATEGY.md](./SYNC_STRATEGY.md) for comprehensive sync documentation.**

Key principle: sync the entire composite task tree atomically (all nodes or none). Last-write-wins using the `version` field on the `composite_tasks` record.

---

## See Also

- [TASK_SYSTEM.md](./TASK_SYSTEM.md) — Overview of all task types
- [SYNC_STRATEGY.md](./SYNC_STRATEGY.md) — Sync strategies
- [OFFLINE_FIRST.md](./OFFLINE_FIRST.md) — Offline-first architecture
