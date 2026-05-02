# OYBC Task System

> **Canonical reference for the unified 3-type model** shipped by the Compound Tasks Unification (PR #43, PR #42, and the Phase 8 cleanup). The implementations in `apps/web` and `apps/ios` match this shape today. Cross-board square mechanisms (achievement squares + the planned specific-board extension for Phase 6.3) live on `BoardTask`, not on `Task` — see [`docs/ARCHITECTURE.md` §Phase 6](./ARCHITECTURE.md#phase-6-recurring-boards-in-design) for the cross-board design.

## Overview

OYBC supports **three** task types:

1. **Normal** — binary completion. *"Call Mom"*, *"Meditate"*.
2. **Counting** — quantifiable progress toward a target. *"Run 5 miles"*, *"Read 100 pages"*.
3. **Compound** — composed of other tasks evaluated by an operator. *"Morning routine"* (all of: shower, brush teeth, journal). *"Cardio choice"* (any of: run, bike, swim).

Compound subsumes what used to be modeled as two separate concepts (`Progress` and `Composite`). Conceptually they're the same parent-children-with-completion-rule pattern; the unified `Compound` carries an operator (`AND`/`OR`/`M_OF_N`) and an `isOrdered` display hint that distinguishes the "step list" UX (former Progress) from the "subtask group" UX (former Composite).

**Completion is global per Task.** A Task on three boards has one shared completion state — completing it on one board reflects everywhere.

---

## Table of contents

1. [Task type taxonomy](#task-type-taxonomy)
2. [Compounds in depth](#compounds-in-depth)
3. [Global completion semantics](#global-completion-semantics)
4. [Data model](#data-model)
5. [Validation rules](#validation-rules)
6. [UI interaction patterns](#ui-interaction-patterns)
7. [Code examples](#code-examples)
8. [Sync](#sync)
9. [Common pitfalls](#common-pitfalls)
10. [Appendix — Task square interaction patterns (UX exploration)](#appendix--task-square-interaction-patterns-ux-exploration)

---

## Task type taxonomy

### 1. Normal tasks

**Definition**: binary completion — done or not done.

**Use cases**: one-time actions (*"Call Mom"*, *"File taxes"*), simple habits (*"Meditate"*, *"Walk the dog"*).

**Shape**:
```ts
{
  id, userId,
  type: 'normal',
  title,
  description?,
  isCompleted, completedAt?,           // global state
  totalCompletions, totalInstances,    // denormalised stats
  createdAt, updatedAt, version, isDeleted, deletedAt?
}
```

### 2. Counting tasks

**Definition**: numerical progress toward a target. Auto-completes when `currentCount >= maxCount`.

**Use cases**: *"Read 100 pages"*, *"Walk 10,000 steps"*, *"Drink 8 glasses of water"*.

**Shape**:
```ts
{
  id, userId,
  type: 'counting',
  title,
  action,    unit,    maxCount,        // counting fields
  currentCount,                        // global progress
  description?,
  isCompleted, completedAt?,           // auto-derived from count vs max
  totalCompletions, totalInstances,
  createdAt, updatedAt, version, isDeleted, deletedAt?
}
```

The optional title auto-fills from `action + maxCount + unit` via `generateCounterTaskTitle()` in `@oybc/shared` if blank — don't duplicate that logic.

### 3. Compound tasks

**Definition**: composed of other tasks (its *children*) and evaluated by a logical operator. Completion is **derived** from children's global states; never stored on the compound itself.

**Use cases**:
- *"Morning routine"* — `AND` of [shower, brush teeth, journal] with `isOrdered=true` (renders as ordered "step list").
- *"Cardio choice"* — `OR` of [run 5 miles, bike 10 miles, swim 1 mile].
- *"At least 2 of 3 hobbies today"* — `M_OF_N` (`threshold=2`) of [paint, play guitar, write].

**Shape**:
```ts
{
  id, userId,
  type: 'compound',
  title,
  description?,
  operator: 'AND' | 'OR' | 'M_OF_N',
  threshold?,                          // only for M_OF_N
  isOrdered,                           // display hint: true → progress-style step UX
  isCompleted: bool,                   // present for column uniformity but NEVER WRITTEN/READ — see "Compound completion is always derived"
  completedAt?,                        // same — never used on compound rows
  totalCompletions, totalInstances,
  createdAt, updatedAt, version, isDeleted, deletedAt?
}
```

> **`isCompleted` on compound rows is structurally present but never written or read.** Code that reads `Task.isCompleted` for a `type='compound'` Task is a bug. Always go through the derivation helper (which evaluates `compound_children` recursively).

Children live in `compound_children`:
```ts
{
  id,
  compoundTaskId,    // FK tasks (the parent compound)
  childTaskId,       // FK tasks (any task type, including another compound)
  childIndex,        // ordering — honored when parent.isOrdered
  createdAt, updatedAt, version, isDeleted, deletedAt?
}
```

A child can be **any Task** — Normal, Counting, or another Compound. Nesting is natural; depth is bounded by user behavior (typically ≤ 2 in practice).

> **Cross-board square mechanisms are not task types.** Achievement squares (today: aggregate-counter form via `isAchievementSquare + achievementType + achievementCount + achievementTimeframe + achievementProgress` on `BoardTask`; Phase 6.3 will add a specific-board reference mode via `referencedBoardId`) live on the placement record, not on `Task`. They can co-exist with any task type at any cell. See [`docs/ARCHITECTURE.md` §Phase 6](./ARCHITECTURE.md#phase-6-recurring-boards-in-design) for the planned extension.

---

## Compounds in depth

### Operators

| Operator | Semantics | UI label |
|---|---|---|
| `AND` | Every non-deleted child is complete | "All of" |
| `OR` | At least one non-deleted child is complete | "Any of" |
| `M_OF_N` | At least `threshold` of the non-deleted children complete | "At least N of" |

Edge cases:
- `AND` with **0 non-deleted children** evaluates to `true` (vacuous truth).
- `OR` / `M_OF_N` with 0 non-deleted children evaluates to `false`.
- `M_OF_N`'s `threshold` is clamped to `[1, childCount]` when children are added/removed.

### Ordered vs unordered

`isOrdered: true` is a **display hint only** — evaluation semantics don't change. The UI uses it to:
- Render children as numbered steps (1, 2, 3, …) like the legacy Progress UX.
- Sort children by `childIndex` rather than alphabetically.
- Filter into the "Progress" library tab (vs. `isOrdered: false` which appears under "Composite").

`operator='AND' + isOrdered=true` is the migration shape for former Progress tasks. Any operator can be `isOrdered` if the user wants — there's no enforced coupling.

### Children + nesting

Each `compound_children` row points one Task at one Task. Nesting works because `childTaskId` may itself be a compound:

```
"Wellness routine" (AND)
├─ "Morning meditation" (Normal)
├─ "Active recovery" (OR)
│   ├─ "Run 5 miles" (Counting)
│   └─ "Yoga" (Normal)
└─ "Journal" (Normal)
```

The evaluator recurses naturally: evaluating "Wellness routine" requires evaluating "Active recovery" first, which requires reading "Run 5 miles" and "Yoga" completion states.

### Constraints

- Minimum 2 children to save a compound.
- No duplicate children (same `childTaskId` cannot appear twice).
- No circular references (a compound cannot transitively reference itself). Validated at creation.
- Soft-deleting a child Task cascades a soft-delete to its `compound_children` rows.

---

## Global completion semantics

### Why global

Tasks are **library entities** — definitions a user reuses. Completing "Read book" on Monday's board and seeing it still incomplete on Tuesday's board (which has the same task) is confusing. The unified model treats Task completion as a property of the Task itself, mirrored across every board it appears on.

### Storage

- **Primitives** (`Normal`, `Counting`): `Task.isCompleted` and `Task.currentCount` are the source of truth, written directly on the Task row.
- **Compounds**: completion is **never stored**. Always computed from children's states at evaluation time.

`BoardTask` rows carry no completion state — they are pure placement records mapping a board to a task at a row/col/center position.

### The derivation pass

When a primitive Task's completion changes, a transaction-scoped derivation pass:

1. Updates the primitive Task row.
2. Walks up `compound_children` to find every compound that contains this Task transitively.
3. Resolves the set of affected boards: every board placing the changed task or any transitive parent compound.
4. For each affected board, rebuilds the completion grid (reading Task states + recursively evaluating compounds), runs `detectBingos`, diffs against `boards.completedLineIds` for new/lost-bingo signals, writes board stats, and enqueues a Board sync entry.

The full algorithm is documented in §5 of the [unification spec](./superpowers/specs/2026-04-23-compound-tasks-unification-design.md).

### Cross-board behavior — examples

**Example 1**: Same Counting task on three boards.
- "Run 5 miles" placed on a weekly board, a monthly board, and a Q2-themed board.
- User logs 1 mile → `Task.currentCount` becomes 1 → all three boards' renders show "1/5 miles".
- User logs 4 more miles → `Task.currentCount` becomes 5 → `isCompleted=true` → all three boards' bingo grids re-evaluate.

**Example 2**: Compound parent + leaf both on the same board.
- "Wellness routine" compound has children including "Run 5 miles".
- Both placed as separate squares on Board A.
- Logging miles on the "Run 5 miles" square completes that primitive globally → Board A's "Wellness routine" square recomputes (one fewer pending child) → if all children now complete, the compound square fills → bingo detection runs once on the rebuilt grid.

**Example 3**: Counting race across devices.
- Device 1 increments count to 6. Device 2 (offline) increments count to 7.
- Both sync. LWW picks one. The "lost" increment is lost. Acceptable cost; CRDT counters are a future option.

---

## Data model

### tasks (unified, source of truth)

```sql
CREATE TABLE tasks (
    id TEXT PRIMARY KEY NOT NULL,
    userId TEXT NOT NULL,
    type TEXT NOT NULL,                        -- 'normal' | 'counting' | 'compound'
    title TEXT NOT NULL,
    description TEXT,

    -- counting-specific (NULL for other types)
    action TEXT,
    unit TEXT,
    maxCount INTEGER,
    currentCount INTEGER,

    -- compound-specific (NULL for other types)
    operator TEXT,                             -- 'AND' | 'OR' | 'M_OF_N'
    threshold INTEGER,                         -- only when operator='M_OF_N'
    isOrdered INTEGER,                         -- 0/1 boolean

    -- global completion state
    --   stored for primitives; structurally present but never written/read on compound rows
    isCompleted INTEGER NOT NULL DEFAULT 0,
    completedAt TEXT,

    totalCompletions INTEGER NOT NULL DEFAULT 0,
    totalInstances INTEGER NOT NULL DEFAULT 0,

    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    isDeleted INTEGER NOT NULL DEFAULT 0,
    deletedAt TEXT,

    FOREIGN KEY (userId) REFERENCES users(id)
);
```

### compound_children (replaces task_steps + composite_nodes)

```sql
CREATE TABLE compound_children (
    id TEXT PRIMARY KEY NOT NULL,
    compoundTaskId TEXT NOT NULL,              -- parent compound
    childTaskId TEXT NOT NULL,                 -- child task (any type, incl. nested compound)
    childIndex INTEGER NOT NULL,               -- order; honored when parent.isOrdered

    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,
    isDeleted INTEGER NOT NULL DEFAULT 0,
    deletedAt TEXT,

    FOREIGN KEY (compoundTaskId) REFERENCES tasks(id) ON DELETE CASCADE,
    FOREIGN KEY (childTaskId) REFERENCES tasks(id)
);

CREATE INDEX idx_compound_children_parent_index ON compound_children(compoundTaskId, childIndex);
CREATE INDEX idx_compound_children_child ON compound_children(childTaskId);
```

### board_tasks (pure placement)

```sql
CREATE TABLE board_tasks (
    id TEXT PRIMARY KEY NOT NULL,
    boardId TEXT NOT NULL,
    taskId TEXT NOT NULL,
    row INTEGER NOT NULL,
    col INTEGER NOT NULL,
    isCenter INTEGER NOT NULL DEFAULT 0,

    -- achievement-square fields (per-board cross-board-rollup goals)
    isAchievementSquare INTEGER NOT NULL DEFAULT 0,
    achievementType TEXT,
    achievementCount INTEGER,
    achievementTimeframe TEXT,
    achievementProgress INTEGER,

    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL,
    lastSyncedAt TEXT,
    version INTEGER NOT NULL DEFAULT 1,

    FOREIGN KEY (boardId) REFERENCES boards(id),
    FOREIGN KEY (taskId) REFERENCES tasks(id)
);
```

> Notably absent from `board_tasks`: `isCompleted`, `completedAt`, `currentCount`, `completedStepIds`. Completion lives globally on `tasks`. BoardTask is just placement.

### Tables removed by the migration

- `task_steps` — children move to `compound_children` (with `linkedTaskId` becoming `childTaskId`).
- `composite_tasks` — merged into `tasks` (with `type='compound'`).
- `composite_nodes` — leaf nodes move to `compound_children`; root operator nodes are discarded (operator now lives on the parent Task).

---

## Validation rules

### Normal

- `title` required, 1–200 characters.
- `description` optional, max 1000 characters.
- `action`, `unit`, `maxCount`, `currentCount`, `operator`, `threshold`, `isOrdered` all forbidden.

### Counting

- `title` optional (auto-generated from action/max/unit if blank — `generateCounterTaskTitle()`).
- `action` required, 1–50 characters.
- `unit` required, 1–50 characters.
- `maxCount` required, positive integer.
- `currentCount` defaults to 0; integer in `[0, ∞)`. Auto-derives `isCompleted` when `currentCount >= maxCount`.

### Compound

- `title` required.
- `operator` required.
- `threshold` required iff `operator='M_OF_N'`; integer in `[1, childCount]` (clamped on child changes).
- `isOrdered` required (boolean).
- Minimum 2 children at save time.
- No duplicate `childTaskId` across `compound_children` rows for the same `compoundTaskId`.
- No circular references — adding a child must not produce a cycle. Validated at creation by walking the descendant tree.

### compound_children

- `childIndex` is unique per `compoundTaskId` (enforced via app code, not a unique index, so reordering can be a swap).
- A `childTaskId` cannot point to its own `compoundTaskId` (self-reference) or any ancestor.

---

## UI interaction patterns

### Library / wizard tabs

Five user-facing filter tabs on the wizard's Tasks step: **All / Normal / Counting / Progress / Composite**.

The internal mapping:
- **Progress** = `type='compound' && isOrdered=true`
- **Composite** = `type='compound' && !isOrdered`

`TypeBadge` shows "P" for Progress, "C" for Composite — selected on the same `isOrdered` lookup.

### Creating a task

Two entry points, both writing through the same compound-create transaction:

- **+ New Progress task** → creates `Task(type='compound', operator='AND', isOrdered=true)` + step children. The step editor UI looks identical to today's progress step editor.
- **+ New Composite task** → opens the existing composite wizard. Creates `Task(type='compound', operator=<chosen>, isOrdered=false, threshold)` + subtask children.

Inline-created children (a child whose definition is authored alongside the parent) become their own primitive Task rows in the same transaction — preserves today's step-with-`linkedTaskId` pattern.

### Editing a task

- **Progress editor** (isOrdered=true): step list view with add / remove / reorder.
- **Composite wizard** (isOrdered=false): operator picker + subtask list.
- Both run the same compound-structure-edit transaction (mutate `compound_children`, then run derivation pass for affected boards).

### Board grid

- **Primitives**: render as today, but read `Task.isCompleted` / `Task.currentCount` from the resolved Task (one JOIN per square, cached per render).
- **Compounds**: render **read-only** with an operator-appropriate fill bar:
  - `AND` / `AND_ORDERED`: `done / total children`.
  - `OR`: full bar if any child complete, else empty.
  - `M_OF_N`: `done / threshold`.
- Tap on a compound square opens the detail sheet.

### Compound detail sheet (interactive)

- Lists the compound's children with current global completion state.
- Each child has a toggle that writes through the standard primitive-completion path (which fires the derivation pass for every affected board).
- Each child row also shows an **"appears on: Board A, Board B"** link list — taps navigate to that board.
- Footer: *"Completion applies to all boards where this task appears."*

### Counting square modal

Tap a counting square → detail modal:
- Display: `currentCount / maxCount unit` (e.g., "45 / 100 pages")
- Increment / decrement buttons (write through to `Task.currentCount` directly).
- Quick-action buttons (+1, +5, +10) when relevant.
- Auto-completes globally when `currentCount >= maxCount`.

---

## Code examples

The examples below are illustrative — the canonical implementations live in `apps/web/src/db/operations/` and `apps/ios/OYBC/Database/`.

### TypeScript (Web — Dexie)

#### Create a Compound

```ts
async function createCompound(input: CreateCompoundInput): Promise<Task> {
  const validated = CreateCompoundSchema.parse(input);

  return await db.transaction('rw', [db.tasks, db.compoundChildren, db.syncQueue], async () => {
    const compound: Task = {
      id: generateUUID(),
      userId: getCurrentUserId(),
      type: 'compound',
      title: validated.title,
      description: validated.description,
      operator: validated.operator,
      threshold: validated.operator === 'M_OF_N' ? validated.threshold : undefined,
      isOrdered: validated.isOrdered,
      isCompleted: false,         // structurally required; never read on compound rows
      totalCompletions: 0,
      totalInstances: 0,
      createdAt: now(),
      updatedAt: now(),
      version: 1,
      isDeleted: false,
    };
    await db.tasks.add(compound);
    await addToSyncQueue('tasks', compound.id, 'CREATE', compound);

    for (let i = 0; i < validated.children.length; i++) {
      const child = validated.children[i];
      let childTaskId = child.taskId;

      if (!childTaskId && child.autoCreate) {
        // Inline-create a primitive child Task in the same transaction.
        const childTask = await createPrimitiveTask(child.autoCreate);
        childTaskId = childTask.id;
      }

      const link: CompoundChild = {
        id: generateUUID(),
        compoundTaskId: compound.id,
        childTaskId: childTaskId!,
        childIndex: i,
        createdAt: now(),
        updatedAt: now(),
        version: 1,
        isDeleted: false,
      };
      await db.compoundChildren.add(link);
      await addToSyncQueue('compoundChildren', link.id, 'CREATE', link);
    }

    return compound;
  });
}
```

#### Complete a primitive Task → fires derivation pass

```ts
async function completeTask(taskId: string, isCompleted: boolean): Promise<void> {
  await db.transaction(
    'rw',
    [db.tasks, db.compoundChildren, db.boardTasks, db.boards, db.syncQueue],
    async () => {
      const task = await db.tasks.get(taskId);
      if (!task || task.type === 'compound') return; // compounds derive their state

      await db.tasks.update(taskId, {
        isCompleted,
        completedAt: isCompleted ? now() : undefined,
        version: task.version + 1,
        updatedAt: now(),
      });
      await addToSyncQueue('tasks', taskId, 'UPDATE');

      await runDerivationPass(taskId);
    },
  );
}
```

The `runDerivationPass(taskId)` helper:
1. Walks `compound_children` to find transitive parent compounds of `taskId`.
2. Resolves the set of affected boardIds.
3. For each board, rebuilds the completion grid (Task lookups + recursive compound evaluation), runs `detectBingos`, diffs against the previous `completedLineIds`, writes board stats + sync queue entry.

### Swift (iOS — GRDB)

```swift
func completeTask(taskId: String, isCompleted: Bool) async throws {
    try await AppDatabase.shared.write { db in
        guard let task = try Task.fetchOne(db, key: taskId), task.type != .compound else {
            return  // compounds derive their state
        }

        var updated = task
        updated.isCompleted = isCompleted
        updated.completedAt = isCompleted ? currentTimestamp() : nil
        updated.version += 1
        updated.updatedAt = currentTimestamp()
        try updated.update(db)

        try SyncQueueBuilder.makeItem(db: db, entityType: "tasks", entityId: taskId, op: .update, payload: updated)

        try CompoundCascade.runDerivationPass(db: db, changedTaskId: taskId)
    }
}
```

`CompoundCascade.runDerivationPass(db:changedTaskId:)` mirrors the web algorithm — same shape, GRDB read calls instead of Dexie.

### Compound evaluation (shared package)

```ts
// packages/shared/src/algorithms/compoundEvaluation.ts

export function evaluateCompound(
  compound: Task,                       // type='compound'
  childrenByCompound: Record<string, CompoundChild[]>,
  taskById: Record<string, Task>,
): boolean {
  const links = (childrenByCompound[compound.id] ?? []).filter(c => !c.isDeleted);
  const childStates = links.map(link => {
    const child = taskById[link.childTaskId];
    if (!child) return false;
    if (child.type === 'compound') {
      return evaluateCompound(child, childrenByCompound, taskById);  // recurse
    }
    return child.isCompleted;
  });

  switch (compound.operator) {
    case 'AND':
      return childStates.length === 0 || childStates.every(Boolean);
    case 'OR':
      return childStates.some(Boolean);
    case 'M_OF_N':
      return childStates.filter(Boolean).length >= (compound.threshold ?? 0);
  }
}
```

The Swift twin lives at `apps/ios/OYBC/Services/CompoundEvaluation.swift` and mirrors the algorithm exactly.

---

## Sync

### Collections

- `tasks` — all task types, including compounds.
- `compoundChildren` — new collection.
- `boardTasks` — placement only (no completion state).
- Legacy `taskSteps`, `compositeTasks`, `compositeNodes` are deleted by the migration; not written or pulled.

### Versioning

- `Task.version` bumps on every Task write (completion, count, title, structure).
- `CompoundChild.version` bumps per child row on add / remove / reorder.
- Derived state (compound completion) is never stored → never synced → never bumped.

### Pull handlers

- Pulled `Task` row: apply LWW. If `isCompleted` or `currentCount` differ from local, trigger the derivation pass for affected boards (do NOT bump `version` — pulled value is authoritative).
- Pulled `CompoundChild` row: apply LWW. Trigger derivation pass for the parent compound's boards.
- Pulled `BoardTask` row: apply LWW. No completion fields to reconcile.
- Pulls from legacy collections (`taskSteps`, etc.): ignored.

### Conflict resolution (LWW)

- Two devices completing the same task → both arrive at `isCompleted=true`; no real conflict.
- Two devices incrementing `Task.currentCount` → LWW picks one; the lost increment is lost. Known tradeoff; CRDT counters are a future option.
- Soft-delete vs add-child race → LWW resolves; whichever record has the higher `version` (or later timestamp on tie) wins.

See [SYNC_STRATEGY.md](./SYNC_STRATEGY.md) for the broader sync architecture.

---

## Common pitfalls

### ❌ DON'T

1. **Read `Task.isCompleted` for a compound Task.**
   ```ts
   // WRONG — compound completion is derived, not stored
   const compound = await db.tasks.get(compoundId);
   if (compound.isCompleted) { … }   // ❌ value is meaningless for compounds
   ```
   Use the derivation helper instead.

2. **Write `Task.isCompleted` to a compound row.**
   ```ts
   // WRONG — compound state is computed, never written
   await db.tasks.update(compoundId, { isCompleted: true });   // ❌
   ```

3. **Track per-board completion state for primitives.**
   ```ts
   // WRONG — completion is global, not per-BoardTask
   await db.boardTasks.update(boardTaskId, { isCompleted: true });   // ❌
   ```
   Update the underlying Task instead.

4. **Bump `version` on a pulled record.**
   ```ts
   // WRONG — pull paths apply remote state, they don't author writes
   await db.tasks.update(taskId, { ...remote, version: remote.version + 1 });   // ❌
   ```

5. **Forget to fire the derivation pass after a primitive write.**
   ```ts
   // WRONG — bingos and parent compounds won't update
   await db.tasks.update(taskId, { isCompleted: true });   // ❌ missing derivation
   ```

6. **Hard-delete tasks.**
   ```ts
   await db.tasks.delete(taskId);   // ❌ breaks sync
   // Use isDeleted=true + deletedAt instead.
   ```

7. **Add a child to a compound that creates a cycle.**
   ```ts
   // WRONG — A → B → C → A
   addChild(compoundA, childCompoundC);   // C transitively references A → reject
   ```

### ✅ DO

1. **Always go through the completion helper.**
   ```ts
   await completeTask(taskId, true);  // fires derivation pass internally
   ```

2. **Resolve compound state via the evaluator.**
   ```ts
   const isDone = evaluateCompound(compound, childrenByCompound, taskById);
   ```

3. **Validate input via Zod / Swift schemas before writing.**
   ```ts
   const validated = CreateCompoundSchema.parse(input);
   ```

4. **Use soft delete for sync compatibility.**
   ```ts
   await db.tasks.update(taskId, {
     isDeleted: true,
     deletedAt: currentTimestamp(),
     version: task.version + 1,
   });
   ```

5. **Cache the per-board completion map per render.**
   Build once on entry, reuse across squares.

---

## Appendix — Task square interaction patterns (UX exploration)

The following five approaches are implemented in the Playground to compare interaction models. Each maps to a distinct gesture model with platform-appropriate equivalents on iOS and web.

### Gesture mapping table

| # | Name | iOS Primary | iOS Secondary | Web Primary | Web Secondary |
|---|------|-------------|---------------|-------------|---------------|
| 1 | Tap-to-Act | Tap body → type action | ⓘ button → detail sheet | Click → type action | ⓘ button → modal |
| 2 | Tap-to-Info | Tap → detail sheet | — | Click → modal | — |
| 3 | Act + Inspect | Tap → type action | Long press → detail sheet | Click → type action | Right-click → modal |
| 4 | Act + Context Menu | Tap → type action | Long press → action menu | Click → type action | Right-click → action menu |
| 5 | Double-tap to Act | Double-tap → type action | Single tap → detail sheet | Double-click → type action | Single click → modal |

### Type-action summary

When any approach triggers a "type action" on a square:

| Type | Action triggered |
|------|------------------|
| Normal | Toggle global `Task.isCompleted` |
| Counting | Increment global `Task.currentCount` by 1 (no-op if already at max) |
| Compound | Open detail sheet (compound squares are read-only on the grid) |

### Implementation notes

- Sub-components receive data + callbacks only; they hold no state of their own.
- All interaction state in the Playground is local component state (no DB writes).
- Reset restores all states to initial and closes any open UI, but preserves the current approach selection.

---

## See also

- [`superpowers/specs/2026-04-23-compound-tasks-unification-design.md`](./superpowers/specs/2026-04-23-compound-tasks-unification-design.md) — full design spec for the unification + global-completion shift.
- [`SYNC_STRATEGY.md`](./SYNC_STRATEGY.md) — push/pull/LWW reconciliation.
- [`OFFLINE_FIRST.md`](./OFFLINE_FIRST.md) — local-first architecture.
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — overall system design.
