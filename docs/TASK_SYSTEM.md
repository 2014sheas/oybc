# OYBC Task System Documentation

## Overview

The OYBC task system supports four task types designed for different use cases: Normal (simple completion), Counting (quantifiable goals), Progress (multi-step workflows), and Composite (logical combinations). All task types work offline-first with instant UX.

---

## Table of Contents

1. [Task Type Taxonomy](#task-type-taxonomy)
2. [Task Type Comparison](#task-type-comparison)
3. [Data Model Overview](#data-model-overview)
4. [Validation Rules](#validation-rules)
5. [UI Interaction Patterns](#ui-interaction-patterns)
6. [Code Examples](#code-examples)
7. [Testing Strategies](#testing-strategies)
8. [Common Pitfalls](#common-pitfalls)

---

## Task Type Taxonomy

### 1. Normal Tasks (Simple Completion)

**Definition**: Binary completion tasks - either done or not done.

**Use Cases**:
- One-time actions: "Call Mom", "File taxes", "Buy groceries"
- Habits without tracking: "Meditate", "Journal", "Walk the dog"
- Binary goals: "Clean garage", "Submit report", "Book vacation"

**Data Structure**:
```typescript
{
  id: string;
  userId: string;
  type: TaskType.NORMAL;
  title: string;             // Required: "Call Mom"
  description?: string;      // Optional: Additional context
  createdAt: string;
  updatedAt: string;
  version: number;
  isDeleted: boolean;
}
```

**Completion Tracking** (in `board_tasks` table):
```typescript
{
  boardId: string;
  taskId: string;
  isCompleted: boolean;      // True or false only
  completedAt?: string;      // ISO8601 timestamp when completed
}
```

**Behavior**:
- Single tap/click to mark complete
- No intermediate state (can't be "partially" complete)
- Completion is per-board (same task can be on multiple boards with independent completion state)

---

### 2. Counting Tasks (Quantifiable Goals)

**Definition**: Tasks with numerical targets that can be partially completed.

**Use Cases**:
- Reading: "Read 100 pages", "Read 5 chapters"
- Fitness: "Run 5 miles", "Do 50 pushups", "Walk 10,000 steps"
- Hydration: "Drink 8 glasses of water"
- Productivity: "Write 500 words", "Code for 2 hours"

**Data Structure**:
```typescript
{
  id: string;
  userId: string;
  type: TaskType.COUNTING;
  title: string;             // Required: "Read book"
  action: string;            // Required: Verb ("Read", "Run", "Drink")
  unit: string;              // Required: Unit ("pages", "miles", "glasses")
  maxCount: number;          // Required: Target (100, 5, 8)
  description?: string;
  createdAt: string;
  updatedAt: string;
  version: number;
  isDeleted: boolean;
}
```

**Completion Tracking** (in `board_tasks` table):
```typescript
{
  boardId: string;
  taskId: string;
  currentCount: number;      // Progress (0 to maxCount)
  isCompleted: boolean;      // Auto-completes when currentCount >= maxCount
  completedAt?: string;
}
```

**Behavior**:
- Displays progress: "45/100 pages"
- User increments/decrements count
- Auto-completes when target reached: `currentCount >= maxCount`
- Completion is per-board (different boards can have different progress)

**UI Interaction**:
```
User taps task → Modal opens
  ┌─────────────────────────┐
  │  Read book              │
  │                         │
  │  [  -  ] 45 [  +  ]     │
  │  ───────────────────    │
  │  45 / 100 pages         │
  │                         │
  │  Progress: 45%          │
  └─────────────────────────┘
```

---

### 3. Progress Tasks (Multi-Step Workflows)

**Definition**: Tasks composed of multiple steps, where **each step IS a task** that can appear on other boards.

**Use Cases**:
- Chores: "Clean House" (vacuum, dust, mop, etc.)
- Projects: "Plan Vacation" (book flight, reserve hotel, plan itinerary)
- Workflows: "File Taxes" (gather documents, fill forms, submit, pay)
- Routines: "Morning Routine" (shower, brush teeth, make bed)

**Data Structure**:

Parent Task:
```typescript
{
  id: string;
  userId: string;
  type: TaskType.PROGRESS;
  title: string;             // Required: "Clean House"
  description?: string;
  createdAt: string;
  updatedAt: string;
  version: number;
  isDeleted: boolean;
}
```

Steps (in `task_steps` table):
```typescript
{
  id: string;
  progressTaskId: string;    // FK to parent progress task
  stepIndex: number;         // Order (0-based)
  stepTaskId: string;        // FK to tasks table (ALWAYS set)

  // NO title, type, action, unit, maxCount here
  // All task data comes from the referenced task

  createdAt: string;
  updatedAt: string;
  version: number;
  isDeleted: boolean;
}
```

**Completion Tracking** (in `board_tasks` table):
```typescript
{
  boardId: string;
  taskId: string;            // Can be progress task OR step task
  isCompleted: boolean;
  completedAt?: string;
  currentCount?: number;     // For counting task steps
}
```

**Behavior**:
- Displays progress: "2/5 steps complete"
- **Every step references a task** (either existing or auto-created)
- **Step tasks can appear on other boards** independently
- Completing a step task on ANY board completes that step in the progress task
- Auto-completes when all step tasks are completed
- Steps can be normal or counting tasks (NOT progress - no nested progress tasks)

**Key Design**: Progress steps ARE tasks, not embedded data. This enables:
- ✅ Automatic cross-board reusability
- ✅ Single source of truth for completion (`board_tasks` only)
- ✅ Simpler sync strategy
- ✅ Consistent with composite task pattern

**Validation Rule**: Step tasks cannot be progress type (no recursion).

**UI Interaction**:
```
User taps task → Modal opens
  ┌─────────────────────────┐
  │  Clean House            │
  │                         │
  │  [✓] Vacuum (Step 1)    │  ← Task (can be on other boards)
  │  [✓] Dust (Step 2)      │  ← Task (can be on other boards)
  │  [ ] Mop (Step 3)       │  ← Task (can be on other boards)
  │  [ ] Windows (Step 4)   │  ← Task (can be on other boards)
  │  [ ] Organize (Step 5)  │  ← Task (can be on other boards)
  │                         │
  │  Progress: 2/5 (40%)    │
  └─────────────────────────┘

  Tap step → Navigate to step task detail
  Complete step task → Progress task updates automatically
```

---

### 4. Composite Tasks (Logical Combinations)

**Definition**: Tasks composed using logical operators (AND, OR, M-of-N) over other tasks.

**Use Cases**:
- Flexible goals: "Exercise OR Yoga" (either satisfies the requirement)
- Combined requirements: "Run 3 miles AND Stretch"
- Threshold-based: "2 of [Meditate, Journal, Read]" (pick any 2 of 3)
- Complex workflows: "(Exercise OR Yoga) AND (2 of [Meditate, Journal, Read])"

**Data Structure**:

Root Composite Task:
```typescript
{
  id: string;
  userId: string;
  title: string;             // "Weekly Wellness"
  description?: string;
  rootNodeId: string;        // FK to composite_nodes (root of tree)
  createdAt: string;
  updatedAt: string;
  version: number;
  isDeleted: boolean;
}
```

Tree Nodes (in `composite_nodes` table):
```typescript
{
  id: string;
  compositeTaskId: string;
  parentNodeId?: string;     // NULL for root
  nodeIndex: number;         // Order among siblings

  // Node type discriminator
  nodeType: 'operator' | 'leaf';

  // Operator node fields
  operatorType?: 'AND' | 'OR' | 'M_OF_N';
  threshold?: number;        // For M_OF_N (e.g., 2 in "2 of 3")

  // Leaf node field (always task reference)
  taskId?: string;           // FK to tasks table

  createdAt: string;
  updatedAt: string;
  version: number;
  isDeleted: boolean;
}
```

**Completion Tracking** (in `board_composite_tasks` table):
```typescript
{
  boardId: string;
  compositeTaskId: string;
  isCompleted: boolean;      // Evaluated from tree
  completedAt?: string;
}
```

**Operators**:
- **AND**: All children must be complete
  - Example: "Exercise AND Meditate" (both required)
  - Evaluation: `childResults.every(r => r === true)`

- **OR**: Any child can be complete
  - Example: "Run 3 miles OR Bike 10 miles" (either satisfies)
  - Evaluation: `childResults.some(r => r === true)`

- **M_OF_N**: M out of N children must be complete
  - Example: "2 of [Meditate, Journal, Read]" (choose any 2)
  - Evaluation: `completedCount >= threshold`

**Tree Evaluation**: Recursive traversal from leaves to root.

**See [COMPOSITE_TASKS.md](./COMPOSITE_TASKS.md) for detailed documentation.**

---

## Task Linking and Cross-Board Reusability

### Overview

**Task Linking** in OYBC means that progress task steps are NOT embedded data - they are **references to real tasks** in the `tasks` table. This design enables:

1. **Automatic Cross-Board Reusability**: Any step task can appear independently on other boards
2. **Single Source of Truth**: Completion state tracked in `board_tasks` only (not duplicated)
3. **Simpler Data Model**: Task steps are just structure (order), not data
4. **Consistent Pattern**: Same design as composite task leaf nodes

### How It Works

#### Creating Progress Tasks

When users create a progress task, each step can:
- **Reference an existing task** (user selects from task library)
- **Auto-create a new task** (user types title inline, task created automatically)

```typescript
// Example: Creating "Clean House" progress task
await createProgressTask({
  title: "Clean House",
  steps: [
    { taskId: 'task-123' },                // Reference existing "Vacuum" task
    { autoCreateTask: { type: 'normal', title: 'Dust' } },      // Auto-create
    { autoCreateTask: { type: 'normal', title: 'Mop' } },       // Auto-create
    { autoCreateTask: { type: 'counting', title: 'Do Dishes', action: 'Wash', unit: 'dishes', maxCount: 10 } }
  ]
});

// Result: 4 task_steps entries, each referencing a task in tasks table
// task-123 was existing, 3 new tasks auto-created
```

#### Completion Behavior

**Key Rule**: Completing a step task on ANY board completes that step in the progress task (on that board).

**Example Scenario**:
- **Board A (Weekly Chores)**: Progress task "Clean House" with step "Do Dishes"
- **Board B (Daily Tasks)**: Standalone task "Do Dishes"
- Both reference the same task (task-456)

**What happens when you complete "Do Dishes" on Board B:**
1. `board_tasks` entry for Board B + task-456 marked complete
2. Progress task "Clean House" on Board B checks step completion
3. Step "Do Dishes" shows as complete in "Clean House"
4. If all steps complete, "Clean House" auto-completes

**What DOESN'T happen:**
- Board A is NOT affected (board isolation)
- Completion on Board B doesn't complete on Board A
- Each board has independent completion state

### Cross-Board Behavior

#### Same Task on Multiple Boards

A task can appear on multiple boards in different contexts:
- As a standalone task on Board 1
- As a progress step on Board 2
- As another progress step on Board 3

**Completion is per-board** (tracked in `board_tasks`):

```typescript
// Same task (task-789 "Exercise") on three boards
board_tasks:
  { boardId: 'board-1', taskId: 'task-789', isCompleted: true }   // Complete on B1
  { boardId: 'board-2', taskId: 'task-789', isCompleted: false }  // Incomplete on B2
  { boardId: 'board-3', taskId: 'task-789', isCompleted: false }  // Incomplete on B3
```

#### Same Task in Multiple Progress Tasks (Same Board)

A task can be a step in multiple progress tasks on the same board:

**Example**:
- Progress Task A "Clean House": includes step "Do Dishes"
- Progress Task B "Kitchen Chores": includes step "Do Dishes"
- Progress Task C "Daily Routine": includes step "Do Dishes"
- All three reference the same task (task-456)

**When you complete "Do Dishes" on that board:**
- All three progress tasks show that step as complete
- Each progress task checks if ALL its steps are complete
- Progress tasks auto-complete independently based on their step completion

### Data Flow Example

**Creating and completing a linked step:**

```
1. User creates progress task "Clean House"
   ↓
   tasks table:
     { id: 'prog-1', type: 'progress', title: 'Clean House' }

2. User adds step "Vacuum" (auto-create)
   ↓
   tasks table:
     { id: 'task-vac', type: 'normal', title: 'Vacuum' }
   task_steps table:
     { id: 'step-1', progressTaskId: 'prog-1', stepTaskId: 'task-vac', stepIndex: 0 }

3. Board A includes progress task "Clean House"
   ↓
   board_tasks table:
     { boardId: 'board-a', taskId: 'prog-1', isCompleted: false }
     { boardId: 'board-a', taskId: 'task-vac', isCompleted: false }

4. Board B includes standalone task "Vacuum"
   ↓
   board_tasks table:
     { boardId: 'board-b', taskId: 'task-vac', isCompleted: false }

5. User completes "Vacuum" on Board B
   ↓
   board_tasks:
     { boardId: 'board-b', taskId: 'task-vac', isCompleted: true }  ✅

   Board A NOT affected:
     { boardId: 'board-a', taskId: 'task-vac', isCompleted: false }

6. User completes "Vacuum" on Board A
   ↓
   board_tasks:
     { boardId: 'board-a', taskId: 'task-vac', isCompleted: true }  ✅

   Progress task checks: Is "Vacuum" complete on Board A? → YES
   Progress task "Clean House" updates its progress: 1/5 steps complete
```

### Checking Progress Task Completion

**Algorithm** (runs when any step task completes):

```typescript
async function checkProgressTaskCompletion(boardId: string, progressTaskId: string) {
  // 1. Get all steps for this progress task
  const steps = await db.taskSteps
    .where('progressTaskId')
    .equals(progressTaskId)
    .toArray();

  // 2. Check if each step's task is complete on this board
  let allComplete = true;
  for (const step of steps) {
    const stepTask = await db.boardTasks
      .where(['boardId', 'taskId'])
      .equals([boardId, step.stepTaskId])
      .first();

    if (!stepTask?.isCompleted) {
      allComplete = false;
      break;
    }
  }

  // 3. If all steps complete, mark progress task complete
  if (allComplete) {
    await db.boardTasks
      .where(['boardId', 'taskId'])
      .equals([boardId, progressTaskId])
      .update({ isCompleted: true, completedAt: currentTimestamp() });
  }
}
```

### Sync Strategy for Linked Tasks

**Key Principle**: Sync tasks and board_tasks independently, task_steps just syncs structure.

**Sync Order**:
1. **tasks table** syncs first (task definitions)
2. **task_steps table** syncs next (structure: which tasks are steps of which progress tasks)
3. **board_tasks table** syncs last (completion state per board)

**Example Sync Flow**:

```typescript
// Device A creates progress task offline
Device A:
  tasks: { id: 'prog-1', type: 'progress', title: 'Clean House' }
  tasks: { id: 'task-1', type: 'normal', title: 'Vacuum' }
  task_steps: { progressTaskId: 'prog-1', stepTaskId: 'task-1' }
  board_tasks: { boardId: 'board-a', taskId: 'prog-1', isCompleted: false }
  board_tasks: { boardId: 'board-a', taskId: 'task-1', isCompleted: false }

// Syncs to Firestore when online
Firestore: (same data)

// Device B pulls updates
Device B:
  1. Pull tasks → gets 'prog-1' and 'task-1'
  2. Pull task_steps → gets step structure
  3. Pull board_tasks → gets completion state for board-a

// Now Device B can display the progress task correctly
```

### UI Patterns

#### Creating Progress Tasks with Steps

**Option 1: Select Existing Tasks**
```
┌─────────────────────────────────┐
│ Create Progress Task            │
│                                 │
│ Title: Clean House              │
│                                 │
│ Steps:                          │
│  1. [Select Task ▼] → Vacuum   │
│  2. [Select Task ▼] → Dust     │
│  3. [Select Task ▼] → Mop      │
│                                 │
│ [+ Add Step] [Create]           │
└─────────────────────────────────┘
```

**Option 2: Create New Tasks Inline**
```
┌─────────────────────────────────┐
│ Create Progress Task            │
│                                 │
│ Title: Clean House              │
│                                 │
│ Steps:                          │
│  1. [Create New] Vacuum         │  ← Auto-creates task
│  2. [Create New] Dust           │  ← Auto-creates task
│  3. [Select Existing] Mop ▼     │
│                                 │
│ [+ Add Step] [Create]           │
└─────────────────────────────────┘
```

#### Displaying Progress with Links

```
┌─────────────────────────────────┐
│ Clean House (Progress)          │
│                                 │
│ [✓] Vacuum                      │ → Tap to view task detail
│ [✓] Dust                        │ → Tap to view task detail
│ [ ] Mop                         │ → Tap to view task detail
│ [ ] Windows                     │
│ [ ] Organize                    │
│                                 │
│ Progress: 2/5 (40%)             │
│                                 │
│ These tasks can appear on       │
│ other boards independently.     │
└─────────────────────────────────┘
```

### Edge Cases

#### 1. Deleting a Step Task

**Question**: What happens if a task that's used as a step gets deleted?

**Answer**: Soft delete (set `isDeleted = true`). The task still exists in the database, but:
- Removed from task library (user can't add to new boards)
- Still appears in existing progress tasks (historical data)
- Can still be completed on existing boards

```typescript
// Soft delete task-789
await db.tasks.update('task-789', { isDeleted: true, deletedAt: currentTimestamp() });

// Progress tasks still reference it
task_steps: { progressTaskId: 'prog-1', stepTaskId: 'task-789' }  // Still valid

// But new boards can't add it
const activeTasks = await db.tasks.where('isDeleted').equals(false).toArray();
// task-789 not in results
```

#### 2. Circular References

**Question**: Can progress task A have step B, where B is also a progress task with step A?

**Answer**: NO. Validation prevents this:
- Progress task steps can ONLY be normal or counting tasks
- Step tasks CANNOT be progress type (enforced at creation)

```typescript
// PREVENTED:
Progress Task A "Clean House"
  → Step: Task B "Kitchen Chores" (progress type)  ❌ INVALID
    → Step: Task A "Clean House"
```

#### 3. Same Step Task Appearing Multiple Times in One Progress Task

**Question**: Can "Do Dishes" appear as step 1 AND step 3 in "Clean House"?

**Answer**: YES (technically), but validation should warn user (unusual pattern).

```typescript
// Allowed but unusual:
task_steps:
  { progressTaskId: 'prog-1', stepTaskId: 'task-456', stepIndex: 0 }
  { progressTaskId: 'prog-1', stepTaskId: 'task-456', stepIndex: 2 }

// When task-456 completes, BOTH steps marked complete simultaneously
```

### Benefits of Task Linking Design

1. **Automatic Reusability**: Every step is automatically reusable across boards
2. **Single Source of Truth**: Completion in `board_tasks` only (not duplicated in `completedStepIds`)
3. **Simpler Sync**: Just sync tasks, task_steps, and board_tasks independently
4. **Consistent Pattern**: Same design as composite task leaf nodes (always reference tasks)
5. **Flexible Task Library**: Users naturally build a library of reusable tasks
6. **Clear Ownership**: Tasks exist independently, progress tasks just organize them

### Comparison to Alternative Design

**Alternative (Embedded Steps)**:
- Steps have their own title, type, action, unit, maxCount
- Optional `linkedTaskId` for sharing
- Completion tracked in `completedStepIds` array

**Current Design (All Steps Are Tasks)**:
- Steps ONLY reference tasks (structure, not data)
- ALL steps are tasks (automatic sharing)
- Completion tracked in `board_tasks` table

**Why Current Design is Better**:
- ✅ Simpler data model (task_steps is just structure)
- ✅ Single completion tracking system
- ✅ Automatic reusability without user action
- ✅ Consistent with composite task pattern
- ❌ More entries in tasks table (acceptable tradeoff)

---

## Task Type Comparison

| Feature | Normal | Counting | Progress | Composite |
|---------|--------|----------|----------|-----------|
| **Complexity** | Simple | Medium | High | Very High |
| **Completion** | Binary | Partial (0-100%) | Multi-step | Tree evaluation |
| **UI Interaction** | Single tap | Counter modal | Step checklist | Tree display |
| **Use Case** | One-time actions | Quantifiable goals | Multi-step workflows | Logical combinations |
| **Nested Support** | No | No | Steps (1 level) | Unlimited (tree) |
| **Example** | "Call Mom" | "Read 100 pages" | "Clean House" | "(Exercise OR Yoga) AND ..." |
| **Storage** | `tasks` | `tasks` | `tasks` + `task_steps` | `composite_tasks` + `composite_nodes` |
| **Completion Tracking** | `board_tasks.isCompleted` | `board_tasks.currentCount` | `board_tasks.completedStepIds` | Tree evaluation |
| **Auto-Completion** | Manual only | When count >= maxCount | When all steps done | When conditions met |

---

## Data Model Overview

### Core Tables

```sql
-- Reusable task definitions
CREATE TABLE tasks (
    id TEXT PRIMARY KEY,
    userId TEXT NOT NULL,
    type TEXT NOT NULL,                    -- 'normal', 'counting', 'progress'
    title TEXT NOT NULL,
    description TEXT,

    -- Counting task fields
    action TEXT,                           -- For counting: "Read", "Run"
    unit TEXT,                             -- For counting: "pages", "miles"
    maxCount INTEGER,                      -- For counting: 100, 5

    -- Metadata
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    isDeleted INTEGER NOT NULL DEFAULT 0,
    deletedAt TEXT,

    FOREIGN KEY (userId) REFERENCES users(id)
);

-- Progress task steps (structure only, data comes from tasks)
CREATE TABLE task_steps (
    id TEXT PRIMARY KEY,
    progressTaskId TEXT NOT NULL,          -- FK to parent progress task
    stepIndex INTEGER NOT NULL,            -- Order (0-based)
    stepTaskId TEXT NOT NULL,              -- FK to the step's task (ALWAYS set)

    -- NO title, type, action, unit, maxCount fields
    -- All task data comes from the referenced task in tasks table

    -- Metadata
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    isDeleted INTEGER NOT NULL DEFAULT 0,
    deletedAt TEXT,

    FOREIGN KEY (progressTaskId) REFERENCES tasks(id),
    FOREIGN KEY (stepTaskId) REFERENCES tasks(id)
);

-- Per-board task completion state
CREATE TABLE board_tasks (
    id TEXT PRIMARY KEY,
    boardId TEXT NOT NULL,
    taskId TEXT NOT NULL,
    row INTEGER NOT NULL,
    col INTEGER NOT NULL,
    isCenter INTEGER NOT NULL DEFAULT 0,

    -- Completion tracking
    isCompleted INTEGER NOT NULL DEFAULT 0,
    completedAt TEXT,

    -- Counting task progress
    currentCount INTEGER,                  -- For counting tasks only

    -- NO completedStepIds field - progress completion tracked via step tasks

    -- Metadata
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,

    FOREIGN KEY (boardId) REFERENCES boards(id),
    FOREIGN KEY (taskId) REFERENCES tasks(id)
);

-- Composite tasks (separate table hierarchy)
CREATE TABLE composite_tasks (
    id TEXT PRIMARY KEY,
    userId TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT,
    rootNodeId TEXT NOT NULL,              -- FK to composite_nodes

    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    isDeleted INTEGER NOT NULL DEFAULT 0,
    deletedAt TEXT,

    FOREIGN KEY (userId) REFERENCES users(id),
    FOREIGN KEY (rootNodeId) REFERENCES composite_nodes(id)
);

-- Composite task tree structure
CREATE TABLE composite_nodes (
    id TEXT PRIMARY KEY,
    compositeTaskId TEXT NOT NULL,
    parentNodeId TEXT,                     -- NULL for root
    nodeIndex INTEGER NOT NULL,

    nodeType TEXT NOT NULL,                -- 'operator' or 'leaf'
    operatorType TEXT,                     -- 'AND', 'OR', 'M_OF_N'
    threshold INTEGER,                     -- For M_OF_N

    taskId TEXT,                           -- FK to tasks (for leaf nodes)

    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    isDeleted INTEGER NOT NULL DEFAULT 0,
    deletedAt TEXT,

    FOREIGN KEY (compositeTaskId) REFERENCES composite_tasks(id),
    FOREIGN KEY (parentNodeId) REFERENCES composite_nodes(id),
    FOREIGN KEY (taskId) REFERENCES tasks(id)
);

-- Per-board composite task completion state
CREATE TABLE board_composite_tasks (
    id TEXT PRIMARY KEY,
    boardId TEXT NOT NULL,
    compositeTaskId TEXT NOT NULL,
    row INTEGER NOT NULL,
    col INTEGER NOT NULL,
    isCenter INTEGER NOT NULL DEFAULT 0,

    isCompleted INTEGER NOT NULL DEFAULT 0,
    completedAt TEXT,

    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,

    FOREIGN KEY (boardId) REFERENCES boards(id),
    FOREIGN KEY (compositeTaskId) REFERENCES composite_tasks(id)
);
```

---

## Validation Rules

### Normal Task Validation

```typescript
const CreateNormalTaskSchema = z.object({
  type: z.literal(TaskType.NORMAL),
  title: z.string().min(1).max(200),
  description: z.string().max(1000).optional(),
})
.refine(
  (data) => !data.action && !data.unit && !data.maxCount,
  { message: 'Normal tasks cannot have action, unit, or maxCount' }
);
```

**Validation Rules**:
- ✅ `title` required (1-200 chars)
- ✅ `description` optional (max 1000 chars)
- ❌ Cannot have `action`, `unit`, or `maxCount` fields

---

### Counting Task Validation

```typescript
const CreateCountingTaskSchema = z.object({
  type: z.literal(TaskType.COUNTING),
  title: z.string().min(1).max(200),
  action: z.string().min(1).max(50),        // Required
  unit: z.string().min(1).max(50),          // Required
  maxCount: z.number().int().positive(),    // Required
  description: z.string().max(1000).optional(),
});
```

**Validation Rules**:
- ✅ `title` required
- ✅ `action` required (max 50 chars) - e.g., "Read", "Run", "Drink"
- ✅ `unit` required (max 50 chars) - e.g., "pages", "miles", "glasses"
- ✅ `maxCount` required (positive integer)
- ❌ Cannot have `steps`

---

### Progress Task Validation

```typescript
const CreateProgressTaskStepSchema = z.object({
  // EITHER reference existing task OR auto-create (not both)
  taskId: z.string().uuid().optional(),
  autoCreateTask: z.object({
    type: z.enum([TaskType.NORMAL, TaskType.COUNTING]),  // NOT progress
    title: z.string().min(1).max(200),
    action: z.string().min(1).max(50).optional(),
    unit: z.string().min(1).max(50).optional(),
    maxCount: z.number().int().positive().optional(),
    description: z.string().max(1000).optional(),
  }).optional(),
})
.refine(
  (data) => (data.taskId !== undefined) !== (data.autoCreateTask !== undefined),
  { message: 'Must provide either taskId or autoCreateTask (not both)' }
)
.refine(
  async (data) => {
    // If referencing existing task, ensure it's not progress type
    if (data.taskId) {
      const task = await db.tasks.get(data.taskId);
      return task?.type !== TaskType.PROGRESS;
    }
    return true;
  },
  { message: 'Step tasks cannot be progress type (no recursion)' }
);

const CreateProgressTaskSchema = z.object({
  type: z.literal(TaskType.PROGRESS),
  title: z.string().min(1).max(200),
  description: z.string().max(1000).optional(),
  steps: z.array(CreateProgressTaskStepSchema).min(1),  // At least 1 step
})
.refine(
  (data) => !data.action && !data.unit && !data.maxCount,
  { message: 'Progress tasks cannot have action, unit, or maxCount on parent' }
);
```

**Validation Rules**:
- ✅ `title` required
- ✅ `steps` required (minimum 1 step)
- ✅ Each step must EITHER reference existing task OR auto-create new task (not both)
- ✅ Referenced tasks must NOT be progress type (no recursion)
- ✅ Auto-created tasks can be normal or counting (NOT progress)
- ❌ Parent task cannot have `action`, `unit`, or `maxCount` (only step tasks can)

---

### Composite Task Validation

**See [COMPOSITE_TASKS.md](./COMPOSITE_TASKS.md) for comprehensive validation rules.**

Summary:
- ✅ Operator nodes must have `operatorType` and children
- ✅ M_OF_N must have valid threshold (1 <= M <= N)
- ✅ Leaf nodes must reference a task (via `taskId` or auto-create)
- ❌ No circular references allowed
- ❌ Tree depth limit: 5 levels (soft limit)
- ❌ Node count limit: 20 nodes (soft limit)

---

## UI Interaction Patterns

### Normal Task

**Board Grid**:
- Display: Task title
- Visual: Checkmark when complete
- Interaction: Single tap/click to toggle completion

**Detail Modal** (optional):
```
┌─────────────────────────┐
│  Call Mom               │
│                         │
│  One-time action        │
│                         │
│  [Mark Complete]        │
└─────────────────────────┘
```

---

### Counting Task

**Board Grid**:
- Display: Task title + progress
  - "Read book (45/100)"
  - Progress bar below title

**Detail Modal**:
```
┌─────────────────────────┐
│  Read book              │
│                         │
│  [  -  ] 45 [  +  ]     │
│  ═══════════════════    │
│  45 / 100 pages         │
│                         │
│  Progress: 45%          │
│                         │
│  Quick Actions:         │
│  [+1] [+5] [+10]        │
└─────────────────────────┘
```

**Interactions**:
- Tap +/- buttons to increment/decrement
- Tap quick action buttons for common values
- Direct number entry (optional)
- Auto-completes when `currentCount >= maxCount`

---

### Progress Task

**Board Grid**:
- Display: Task title + progress
  - "Clean House (2/5 steps)"
  - Progress bar

**Detail Modal**:
```
┌─────────────────────────┐
│  Clean House            │
│                         │
│  [✓] Vacuum (Step 1)    │
│  [✓] Dust (Step 2)      │
│  [ ] Mop (Step 3)       │
│  [ ] Windows (Step 4)   │
│  [ ] Organize (Step 5)  │
│                         │
│  Progress: 2/5 (40%)    │
└─────────────────────────┘
```

**Interactions**:
- Tap step checkbox to toggle completion
- Counting steps show counter (+/- buttons)
- Auto-completes when all steps checked

---

### Composite Task

**Board Grid**:
- Display: Task title + evaluation result
  - "Weekly Wellness ✅"
  - "Fitness Combo (1/2 conditions met)"

**Detail Modal**:
```
┌─────────────────────────┐
│  Weekly Wellness        │
│                         │
│  ✅ AND (both required) │
│    ├─ ✅ OR (any of)    │
│    │  ├─ ✅ Exercise    │
│    │  └─ ❌ Yoga        │
│    └─ ✅ 2 of 3         │
│       ├─ ✅ Meditate    │
│       ├─ ✅ Journal     │
│       └─ ❌ Read        │
│                         │
│  Status: Complete ✅    │
└─────────────────────────┘
```

**Interactions**:
- View tree structure with completion state
- Tap leaf task to navigate to task detail
- Real-time evaluation updates when sub-tasks complete

---

## Code Examples

### TypeScript (Web - Dexie)

#### Creating Tasks

```typescript
// Normal task
async function createNormalTask(title: string): Promise<Task> {
  const task: Task = {
    id: generateUUID(),
    userId: getCurrentUserId(),
    type: TaskType.NORMAL,
    title,
    createdAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: 1,
    isDeleted: false,
  };

  await db.tasks.add(task);
  await syncQueue.enqueue({ entityType: 'task', entityId: task.id, operationType: 'CREATE' });

  return task;
}

// Counting task
async function createCountingTask(input: CreateCountingTaskInput): Promise<Task> {
  const validated = CreateCountingTaskSchema.parse(input);

  const task: Task = {
    id: generateUUID(),
    userId: getCurrentUserId(),
    type: TaskType.COUNTING,
    title: validated.title,
    action: validated.action,
    unit: validated.unit,
    maxCount: validated.maxCount,
    description: validated.description,
    createdAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: 1,
    isDeleted: false,
  };

  await db.tasks.add(task);
  await syncQueue.enqueue({ entityType: 'task', entityId: task.id, operationType: 'CREATE' });

  return task;
}

// Progress task (all steps are tasks)
async function createProgressTask(input: CreateProgressTaskInput): Promise<Task> {
  const validated = CreateProgressTaskSchema.parse(input);

  return await db.transaction('rw', [db.tasks, db.taskSteps], async () => {
    // 1. Create progress task
    const progressTask: Task = {
      id: generateUUID(),
      userId: getCurrentUserId(),
      type: TaskType.PROGRESS,
      title: validated.title,
      description: validated.description,
      createdAt: currentTimestamp(),
      updatedAt: currentTimestamp(),
      version: 1,
      isDeleted: false,
    };

    await db.tasks.add(progressTask);

    // 2. Process steps (create tasks if needed, create step references)
    for (let index = 0; index < validated.steps.length; index++) {
      const stepInput = validated.steps[index];
      let stepTaskId = stepInput.taskId;

      // Auto-create task if user provided inline task data
      if (!stepTaskId && stepInput.autoCreateTask) {
        const stepTask: Task = {
          id: generateUUID(),
          userId: getCurrentUserId(),
          type: stepInput.autoCreateTask.type,
          title: stepInput.autoCreateTask.title,
          action: stepInput.autoCreateTask.action,
          unit: stepInput.autoCreateTask.unit,
          maxCount: stepInput.autoCreateTask.maxCount,
          description: stepInput.autoCreateTask.description,
          createdAt: currentTimestamp(),
          updatedAt: currentTimestamp(),
          version: 1,
          isDeleted: false,
        };

        await db.tasks.add(stepTask);
        stepTaskId = stepTask.id;

        // Queue step task for sync
        await syncQueue.enqueue({ entityType: 'task', entityId: stepTask.id, operationType: 'CREATE' });
      }

      // Create step reference
      const step: TaskStep = {
        id: generateUUID(),
        progressTaskId: progressTask.id,
        stepIndex: index,
        stepTaskId: stepTaskId!,
        createdAt: currentTimestamp(),
        updatedAt: currentTimestamp(),
        version: 1,
        isDeleted: false,
      };

      await db.taskSteps.add(step);
    }

    // Queue progress task for sync
    await syncQueue.enqueue({ entityType: 'task', entityId: progressTask.id, operationType: 'CREATE' });

    return progressTask;
  });
}
```

#### Completing Tasks

```typescript
// Complete normal task
async function completeNormalTask(boardTaskId: string): Promise<void> {
  const boardTask = await db.boardTasks.get(boardTaskId);

  await db.boardTasks.update(boardTaskId, {
    isCompleted: true,
    completedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: boardTask.version + 1,
  });

  // Update board stats
  await updateBoardStats(boardTask.boardId);

  // Queue for sync
  await syncQueue.enqueue({ entityType: 'board_task', entityId: boardTaskId, operationType: 'UPDATE' });
}

// Increment counting task
async function incrementCountingTask(boardTaskId: string, increment: number): Promise<void> {
  const boardTask = await db.boardTasks.get(boardTaskId);
  const task = await db.tasks.get(boardTask.taskId);

  const newCount = (boardTask.currentCount || 0) + increment;
  const isComplete = newCount >= task.maxCount;

  await db.boardTasks.update(boardTaskId, {
    currentCount: newCount,
    isCompleted: isComplete,
    completedAt: isComplete ? currentTimestamp() : boardTask.completedAt,
    updatedAt: currentTimestamp(),
    version: boardTask.version + 1,
  });

  // Update board stats if newly completed
  if (isComplete && !boardTask.isCompleted) {
    await updateBoardStats(boardTask.boardId);
  }

  await syncQueue.enqueue({ entityType: 'board_task', entityId: boardTaskId, operationType: 'UPDATE' });
}

// Complete step task (triggers progress task check)
async function completeStepTask(boardId: string, stepTaskId: string): Promise<void> {
  // 1. Complete the step task itself
  const boardTask = await db.boardTasks
    .where(['boardId', 'taskId'])
    .equals([boardId, stepTaskId])
    .first();

  if (!boardTask) return;

  await db.boardTasks.update(boardTask.id, {
    isCompleted: true,
    completedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: boardTask.version + 1,
  });

  // 2. Find progress tasks that include this step task
  const progressSteps = await db.taskSteps
    .where('stepTaskId')
    .equals(stepTaskId)
    .toArray();

  // 3. Check completion for each progress task
  for (const step of progressSteps) {
    await checkProgressTaskCompletion(boardId, step.progressTaskId);
  }

  await syncQueue.enqueue({ entityType: 'board_task', entityId: boardTask.id, operationType: 'UPDATE' });
}

// Check if progress task is complete (all steps done)
async function checkProgressTaskCompletion(boardId: string, progressTaskId: string): Promise<void> {
  // Get all steps for this progress task
  const steps = await db.taskSteps
    .where('progressTaskId')
    .equals(progressTaskId)
    .and(s => !s.isDeleted)
    .toArray();

  // Check if each step task is complete on this board
  let allComplete = true;
  for (const step of steps) {
    const stepBoardTask = await db.boardTasks
      .where(['boardId', 'taskId'])
      .equals([boardId, step.stepTaskId])
      .first();

    if (!stepBoardTask?.isCompleted) {
      allComplete = false;
      break;
    }
  }

  // If all steps complete, mark progress task complete
  if (allComplete) {
    const progressBoardTask = await db.boardTasks
      .where(['boardId', 'taskId'])
      .equals([boardId, progressTaskId])
      .first();

    if (progressBoardTask && !progressBoardTask.isCompleted) {
      await db.boardTasks.update(progressBoardTask.id, {
        isCompleted: true,
        completedAt: currentTimestamp(),
        updatedAt: currentTimestamp(),
        version: progressBoardTask.version + 1,
      });

      await updateBoardStats(boardId);
    }
  }
}
```

---

### Swift (iOS - GRDB)

#### Creating Tasks

```swift
// Normal task
func createNormalTask(title: String) async throws -> Task {
    let task = Task(
        id: UUID().uuidString,
        userId: getCurrentUserId(),
        type: .normal,
        title: title,
        createdAt: currentTimestamp(),
        updatedAt: currentTimestamp(),
        version: 1,
        isDeleted: false
    )

    try await db.write { db in
        try task.insert(db)
    }

    try await syncQueue.enqueue(.create, entity: task)

    return task
}

// Counting task
func createCountingTask(input: CreateCountingTaskInput) async throws -> Task {
    let validated = try CreateCountingTaskSchema.validate(input)

    let task = Task(
        id: UUID().uuidString,
        userId: getCurrentUserId(),
        type: .counting,
        title: validated.title,
        action: validated.action,
        unit: validated.unit,
        maxCount: validated.maxCount,
        description: validated.description,
        createdAt: currentTimestamp(),
        updatedAt: currentTimestamp(),
        version: 1,
        isDeleted: false
    )

    try await db.write { db in
        try task.insert(db)
    }

    try await syncQueue.enqueue(.create, entity: task)

    return task
}

// Progress task (all steps are tasks)
func createProgressTask(input: CreateProgressTaskInput) async throws -> Task {
    let validated = try CreateProgressTaskSchema.validate(input)

    return try await db.write { db in
        // 1. Create progress task
        let progressTask = Task(
            id: UUID().uuidString,
            userId: getCurrentUserId(),
            type: .progress,
            title: validated.title,
            description: validated.description,
            createdAt: currentTimestamp(),
            updatedAt: currentTimestamp(),
            version: 1,
            isDeleted: false
        )

        try progressTask.insert(db)

        // 2. Process steps (create tasks if needed, create step references)
        for (index, stepInput) in validated.steps.enumerated() {
            var stepTaskId = stepInput.taskId

            // Auto-create task if user provided inline task data
            if stepTaskId == nil, let autoCreate = stepInput.autoCreateTask {
                let stepTask = Task(
                    id: UUID().uuidString,
                    userId: getCurrentUserId(),
                    type: autoCreate.type,
                    title: autoCreate.title,
                    action: autoCreate.action,
                    unit: autoCreate.unit,
                    maxCount: autoCreate.maxCount,
                    description: autoCreate.description,
                    createdAt: currentTimestamp(),
                    updatedAt: currentTimestamp(),
                    version: 1,
                    isDeleted: false
                )

                try stepTask.insert(db)
                stepTaskId = stepTask.id

                // Queue step task for sync
                try await syncQueue.enqueue(.create, entity: stepTask)
            }

            // Create step reference
            let step = TaskStep(
                id: UUID().uuidString,
                progressTaskId: progressTask.id,
                stepIndex: index,
                stepTaskId: stepTaskId!,
                createdAt: currentTimestamp(),
                updatedAt: currentTimestamp(),
                version: 1,
                isDeleted: false
            )

            try step.insert(db)
        }

        // Queue progress task for sync
        try await syncQueue.enqueue(.create, entity: progressTask)

        return progressTask
    }
}
```

#### Completing Tasks

```swift
// Complete normal task
func completeNormalTask(boardTaskId: String) async throws {
    let boardTask = try await db.read { db in
        try BoardTask.fetchOne(db, key: boardTaskId)
    }

    guard let boardTask = boardTask else { return }

    try await db.write { db in
        var updatedBoardTask = boardTask
        updatedBoardTask.isCompleted = true
        updatedBoardTask.completedAt = currentTimestamp()
        updatedBoardTask.updatedAt = currentTimestamp()
        updatedBoardTask.version += 1

        try updatedBoardTask.update(db)
    }

    try await updateBoardStats(boardTask.boardId)
    try await syncQueue.enqueue(.update, entity: boardTask)
}

// Increment counting task
func incrementCountingTask(boardTaskId: String, increment: Int) async throws {
    let boardTask = try await db.read { db in
        try BoardTask.fetchOne(db, key: boardTaskId)
    }

    guard let boardTask = boardTask else { return }

    let task = try await db.read { db in
        try Task.fetchOne(db, key: boardTask.taskId)
    }

    guard let task = task else { return }

    let newCount = (boardTask.currentCount ?? 0) + increment
    let isComplete = newCount >= task.maxCount

    try await db.write { db in
        var updatedBoardTask = boardTask
        updatedBoardTask.currentCount = newCount
        updatedBoardTask.isCompleted = isComplete
        updatedBoardTask.completedAt = isComplete ? currentTimestamp() : boardTask.completedAt
        updatedBoardTask.updatedAt = currentTimestamp()
        updatedBoardTask.version += 1

        try updatedBoardTask.update(db)
    }

    if isComplete && !boardTask.isCompleted {
        try await updateBoardStats(boardTask.boardId)
    }

    try await syncQueue.enqueue(.update, entity: boardTask)
}

// Complete step task (triggers progress task check)
func completeStepTask(boardId: String, stepTaskId: String) async throws {
    // 1. Complete the step task itself
    guard let boardTask = try await db.read { db in
        try BoardTask
            .filter(Column("boardId") == boardId && Column("taskId") == stepTaskId)
            .fetchOne(db)
    } else { return }

    try await db.write { db in
        var updated = boardTask
        updated.isCompleted = true
        updated.completedAt = currentTimestamp()
        updated.updatedAt = currentTimestamp()
        updated.version += 1

        try updated.update(db)
    }

    // 2. Find progress tasks that include this step task
    let progressSteps = try await db.read { db in
        try TaskStep
            .filter(Column("stepTaskId") == stepTaskId)
            .fetchAll(db)
    }

    // 3. Check completion for each progress task
    for step in progressSteps {
        try await checkProgressTaskCompletion(boardId: boardId, progressTaskId: step.progressTaskId)
    }

    try await syncQueue.enqueue(.update, entity: boardTask)
}

// Check if progress task is complete (all steps done)
func checkProgressTaskCompletion(boardId: String, progressTaskId: String) async throws {
    // Get all steps for this progress task
    let steps = try await db.read { db in
        try TaskStep
            .filter(Column("progressTaskId") == progressTaskId && Column("isDeleted") == false)
            .fetchAll(db)
    }

    // Check if each step task is complete on this board
    var allComplete = true
    for step in steps {
        let stepBoardTask = try await db.read { db in
            try BoardTask
                .filter(Column("boardId") == boardId && Column("taskId") == step.stepTaskId)
                .fetchOne(db)
        }

        if stepBoardTask?.isCompleted != true {
            allComplete = false
            break
        }
    }

    // If all steps complete, mark progress task complete
    if allComplete {
        guard let progressBoardTask = try await db.read { db in
            try BoardTask
                .filter(Column("boardId") == boardId && Column("taskId") == progressTaskId)
                .fetchOne(db)
        } else { return }

        if !progressBoardTask.isCompleted {
            try await db.write { db in
                var updated = progressBoardTask
                updated.isCompleted = true
                updated.completedAt = currentTimestamp()
                updated.updatedAt = currentTimestamp()
                updated.version += 1

                try updated.update(db)
            }

            try await updateBoardStats(boardId)
        }
    }
}
```

---

## Testing Strategies

### Unit Tests (Shared Package)

Test pure algorithms and validation:

```typescript
describe('Task validation', () => {
  it('validates normal task schema', () => {
    const valid = { type: TaskType.NORMAL, title: 'Call Mom' };
    expect(() => CreateNormalTaskSchema.parse(valid)).not.toThrow();

    const invalid = { type: TaskType.NORMAL, title: 'Test', action: 'Read' };
    expect(() => CreateNormalTaskSchema.parse(invalid)).toThrow();
  });

  it('validates counting task schema', () => {
    const valid = {
      type: TaskType.COUNTING,
      title: 'Read book',
      action: 'Read',
      unit: 'pages',
      maxCount: 100
    };
    expect(() => CreateCountingTaskSchema.parse(valid)).not.toThrow();

    const invalid = { type: TaskType.COUNTING, title: 'Test' };
    expect(() => CreateCountingTaskSchema.parse(invalid)).toThrow('action is required');
  });

  it('prevents progress steps from being progress type', () => {
    const invalid = {
      type: TaskType.PROGRESS,
      title: 'Test',
      steps: [
        { type: TaskType.PROGRESS, title: 'Nested progress' }
      ]
    };
    expect(() => CreateProgressTaskSchema.parse(invalid)).toThrow('no recursion');
  });
});
```

### Integration Tests (Database Operations)

```typescript
describe('Task CRUD operations', () => {
  beforeEach(async () => {
    await db.tasks.clear();
    await db.boardTasks.clear();
  });

  it('creates and completes normal task', async () => {
    const task = await createNormalTask('Call Mom');
    const boardTask = await addTaskToBoard(boardId, task.id, 0, 0);

    await completeNormalTask(boardTask.id);

    const completed = await db.boardTasks.get(boardTask.id);
    expect(completed.isCompleted).toBe(true);
    expect(completed.completedAt).toBeDefined();
  });

  it('increments counting task and auto-completes', async () => {
    const task = await createCountingTask({
      title: 'Read book',
      action: 'Read',
      unit: 'pages',
      maxCount: 100
    });

    const boardTask = await addTaskToBoard(boardId, task.id, 0, 0);

    await incrementCountingTask(boardTask.id, 50);
    let updated = await db.boardTasks.get(boardTask.id);
    expect(updated.currentCount).toBe(50);
    expect(updated.isCompleted).toBe(false);

    await incrementCountingTask(boardTask.id, 50);
    updated = await db.boardTasks.get(boardTask.id);
    expect(updated.currentCount).toBe(100);
    expect(updated.isCompleted).toBe(true);
  });

  it('completes progress task when all step tasks done', async () => {
    const progressTask = await createProgressTask({
      title: 'Clean House',
      steps: [
        { autoCreateTask: { type: TaskType.NORMAL, title: 'Vacuum' } },
        { autoCreateTask: { type: TaskType.NORMAL, title: 'Dust' } },
        { autoCreateTask: { type: TaskType.NORMAL, title: 'Mop' } }
      ]
    });

    // Get the step tasks
    const steps = await db.taskSteps.where('progressTaskId').equals(progressTask.id).toArray();
    const stepTaskIds = steps.map(s => s.stepTaskId);

    // Add progress task and step tasks to board
    await addTaskToBoard(boardId, progressTask.id, 0, 0);
    for (let i = 0; i < stepTaskIds.length; i++) {
      await addTaskToBoard(boardId, stepTaskIds[i], i + 1, 0);
    }

    // Complete 2 step tasks - progress task still incomplete
    await completeStepTask(boardId, stepTaskIds[0]);
    await completeStepTask(boardId, stepTaskIds[1]);

    let progressBoardTask = await db.boardTasks
      .where(['boardId', 'taskId'])
      .equals([boardId, progressTask.id])
      .first();
    expect(progressBoardTask.isCompleted).toBe(false);

    // Complete final step task - progress task auto-completes
    await completeStepTask(boardId, stepTaskIds[2]);

    progressBoardTask = await db.boardTasks
      .where(['boardId', 'taskId'])
      .equals([boardId, progressTask.id])
      .first();
    expect(progressBoardTask.isCompleted).toBe(true);
  });
});
```

---

## Common Pitfalls

### ❌ DON'T

1. **Add invalid fields to task types**
   ```typescript
   // WRONG: Normal task with counting fields
   const task = {
     type: TaskType.NORMAL,
     title: 'Call Mom',
     action: 'Call',  // ❌ Not allowed on normal tasks
     maxCount: 1      // ❌ Not allowed on normal tasks
   };
   ```

2. **Create progress steps with progress type tasks**
   ```typescript
   // WRONG: Step task is progress type
   const progressTaskId = 'task-123'; // This is a progress task
   const task = {
     type: TaskType.PROGRESS,
     title: 'Parent',
     steps: [
       { taskId: progressTaskId }  // ❌ No recursion - step cannot be progress
     ]
   };
   ```

3. **Forget that steps are tasks (not embedded data)**
   ```typescript
   // WRONG: Trying to access step title from task_steps
   const step = await db.taskSteps.get(stepId);
   console.log(step.title);  // ❌ No title field! Data comes from task

   // CORRECT: Get step's task
   const step = await db.taskSteps.get(stepId);
   const stepTask = await db.tasks.get(step.stepTaskId);
   console.log(stepTask.title);  // ✅ Correct
   ```

4. **Forget to update board stats after completion**
   ```typescript
   // WRONG: Missing board stats update
   await db.boardTasks.update(boardTaskId, { isCompleted: true });
   // Missing: await updateBoardStats(boardId);
   ```

5. **Hard delete tasks instead of soft delete**
   ```typescript
   // WRONG: Hard delete breaks sync
   await db.tasks.delete(taskId);

   // CORRECT: Soft delete
   await db.tasks.update(taskId, {
     isDeleted: true,
     deletedAt: currentTimestamp(),
     version: task.version + 1
   });
   ```

### ✅ DO

1. **Validate task input before creating**
   ```typescript
   // CORRECT: Validate first
   const validated = CreateCountingTaskSchema.parse(input);
   const task = await createCountingTask(validated);
   ```

2. **Use appropriate task type for use case**
   ```typescript
   // CORRECT: Choose right type
   const oneTime = await createNormalTask('Call Mom');
   const quantifiable = await createCountingTask({ title: 'Read 100 pages', ... });
   const multiStep = await createProgressTask({
     title: 'Clean House',
     steps: [
       { autoCreateTask: { type: 'normal', title: 'Vacuum' } },
       { taskId: 'existing-task-123' }  // Reference existing
     ]
   });
   ```

6. **Remember steps are tasks (get data from tasks table)**
   ```typescript
   // CORRECT: Fetch step task to get data
   const step = await db.taskSteps.get(stepId);
   const stepTask = await db.tasks.get(step.stepTaskId);
   console.log(stepTask.title, stepTask.type);  // ✅ Data from task
   ```

3. **Always update denormalized stats**
   ```typescript
   // CORRECT: Update board stats after task completion
   await completeTask(boardTaskId);
   await updateBoardStats(boardId);
   await detectBingoLines(boardId);
   ```

4. **Use soft deletes for sync compatibility**
   ```typescript
   // CORRECT: Soft delete
   await softDeleteTask(taskId);
   ```

---

## Next Steps

- **For composite task details**: See [COMPOSITE_TASKS.md](./COMPOSITE_TASKS.md)
- **For sync strategies**: See [SYNC_STRATEGY.md](./SYNC_STRATEGY.md)
- **For offline-first patterns**: See [OFFLINE_FIRST.md](./OFFLINE_FIRST.md)
- **For implementation guidelines**: See [CLAUDE_GUIDE.md](./CLAUDE_GUIDE.md)

---

## Summary

The OYBC task system supports four task types:

1. **Normal**: Simple binary completion ("Call Mom")
2. **Counting**: Quantifiable goals with progress ("Read 100 pages")
3. **Progress**: Multi-step workflows ("Clean House" with steps)
4. **Composite**: Logical combinations with operators ("(Exercise OR Yoga) AND ...")

All task types:
- ✅ Work offline-first (local DB is source of truth)
- ✅ Have instant UX (< 10ms operations)
- ✅ Support multi-board reuse with independent completion state
- ✅ Use soft deletes for sync compatibility
- ✅ Follow same validation and testing patterns

Choose the appropriate task type based on your use case, validate inputs, and follow offline-first patterns for optimal UX.
