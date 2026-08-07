# OYBC Task System

> **Canonical reference for the unified task model.** The Compound Tasks Unification (PR #43, PR #42, Phase 8 cleanup) collapsed Progress + Composite into **Compound**; Phase 6.3 (PR #54) then added **Achievement** as a fourth first-class type. The implementations in `apps/web` and `apps/ios` match this shape today. Achievement is a cross-board watcher that lives on `Task` (via `referencedBoardId` XOR `referencedTemplateId`); `BoardTask` is a pure placement record. See [`docs/ARCHITECTURE.md` §Phase 6](./ARCHITECTURE.md#phase-6-recurring-boards--shipped) for the cross-board design. Shared Counters (Issue #84, shipped both platforms) added `sharedCounterId`/`baseline` fields to `COUNTING` tasks — no new task type — see [§Shared counters](#shared-counters-linked-counting-tasks) below. (`lastSyncedCount` also shipped with Shared Counters but is now **retired inert residue** — see the Windowed Completion callout below.)

> **Amended by Windowed Completion (SHIPPED, PRs #316/#318/#326/D — canonical doc [`docs/WINDOWED_COMPLETION.md`](./WINDOWED_COMPLETION.md)).** Completion is now **event-sourced**: normal + plain-counting tasks own a `task_events` log (`kind: completion | increment`, `occurredAt`), and a task's state on a given board is evaluated **against that board's window** `[startDate, ∞)`, not a single global bit. `Task.isCompleted` / `currentCount` / `completedAt` are demoted to **lifetime caches** (latest lifetime state; read by library/global surfaces, recomputed from events on pull, never trusted for windowed board grids). Past windows **seal** into a permanent record. Derived (shared-counter-linked) counters, compounds, and achievements are **carved out** — they don't own events and read their lifetime caches / derive as before. The old additive-merge shared-counter sync (`sharedCounterMerge` + `lastSyncedCount` stamping) is **retired** — counting conflicts now resolve by union-of-events. The "Completion is global per Task" framing below is the *library/lifetime* view; the *per-board* view is windowed.

## Overview

OYBC supports **four** task types:

1. **Normal** — binary completion. *"Call Mom"*, *"Meditate"*.
2. **Counting** — quantifiable progress toward a target. *"Run 5 miles"*, *"Read 100 pages"*.
3. **Compound** — composed of other tasks evaluated by an operator. *"Morning routine"* (all of: shower, brush teeth, journal). *"Cardio choice"* (any of: run, bike, swim).
4. **Achievement** (Phase 6.3) — a cross-board watcher that completes when a referenced board (`referencedBoardId`) **or** every in-window spawn of a recurring template (`referencedTemplateId`, with `requiredCount`) hits its `achievementTrigger` (bingo or greenlog). The reference fields live on `Task`; cycle detection prevents an achievement from watching a board it sits on.

Compound subsumes what used to be modeled as two separate concepts (`Progress` and `Composite`). Conceptually they're the same parent-children-with-completion-rule pattern; the unified `Compound` carries an operator (`AND`/`OR`/`M_OF_N`) and its children always render in `childIndex` order. (The former `isOrdered` "step list vs subtask group" display flag was retired — see the CUSTOM_FREE/in-order removal work.)

**Completion identity is per Task; board evaluation is windowed.** A Task on three boards has one shared *lifetime* completion state (the library view) — but each board renders it against its own window from `task_events`, so an in-window completion reflects on every placement whose window contains it, while a fresh window starts grey. See [`WINDOWED_COMPLETION.md`](WINDOWED_COMPLETION.md) §Semantics.

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

#### Shared counters (linked counting tasks)

One real-world activity can feed **many** Counting tasks from a single running tally (Issue #84, shipped both platforms). A **source** counting task's `currentCount` is the one true accumulator; any other `COUNTING` task can **link** to it as a **derived** task via three fields on `Task`:

- `sharedCounterId?: string | null` — FK to the source Task. Only valid on `type === 'counting'`.
- `baseline?: number | null` — the source's `currentCount` at link time. Required (≥ 0) iff `sharedCounterId` is set. "Inherit" mode links with `baseline = 0` (displayed = full source count); "start from zero" mode sets `baseline = source.currentCount` at that moment (displayed = source count so far *since linking*).
- `lastSyncedCount?: number | null` — **inert legacy field** (only counting tasks carry it): formerly the common-ancestor `currentCount` for the retired additive-merge conflict resolution. Kept in the schema so pre-Windowed-Completion rows still decode; never written or read by live code. Not part of the user-facing model.

**Derived tasks never carry their own count.** A derived task's displayed count and completion are computed, never stored:

```ts
deriveDisplayedCount({ baseline, maxCount }, { currentCount }): { displayed, isCompleted }
// displayed = max(0, currentCount - baseline)   — clamped at the low end only
// isCompleted latches true once reached; re-deriving with a lower displayed value
// never un-completes it (one-way latch)
```

`packages/shared/src/algorithms/sharedCounter.ts` (`deriveDisplayedCount`, `propagateIncrement`) is the source of truth; the Swift twin is `Helpers/SharedCounter.swift`. **No high-end clamp** — a derived task can read `5500 / 5000`; overshoot is intentional (never `Math.min` it away).

**Logging is a single write path.** `incrementSharedCounter(sourceId)` — `AppDatabase+SharedCounters.swift` / web `db/operations/tasks.sharedCounter.ts` — increments the source's `currentCount`, re-derives every linked task on every board it's placed on, recomputes bingo/greenlog per affected board, and enqueues sync, all in one transaction. Logging from *any* member task's square or from the counter's own detail screen goes through this same function.

**A "counter"** (the UX-facing concept) = one source counting task + all tasks linking to it via `sharedCounterId`. `buildSharedCounterGroups({tasks, boardTasks, boards})` (`packages/shared/src/algorithms/sharedCounterGroups.ts`, Swift port `SharedCounterGroups.swift`) is the pure read-model that assembles counter groups for the Counters Hub / Counter Detail UI. `findLinkableCounter({action, unit}, tasks)` (`packages/shared/src/algorithms/linkableCounter.ts`) powers the create-form "counts on your existing **{name}** counter" link suggestion. See [`docs/SHARED_COUNTERS.md`](SHARED_COUNTERS.md) for the full UX design and phasing; [`docs/ARCHITECTURE.md` §"Shared counters (Issue #84 — Phase 0 design)"](./ARCHITECTURE.md#shared-counters-issue-84--phase-0-design) (Decisions 1–7) is the canonical schema/design-decision record.

**Sync**: counts are event-sourced — offline increments on multiple devices survive as separate `task_events` rows (union-by-id, per-row LWW) and the source's `currentCount` cache is recomputed from the event union on pull, so no increments are lost. The earlier `sharedCounterMerge` additive three-way merge (keyed on `lastSyncedCount`) was retired by Windowed Completion (design: [`WINDOWED_COMPLETION.md`](./WINDOWED_COMPLETION.md); neutered in PR B, deleted in PR D) — see [`SYNC_STRATEGY.md`](./SYNC_STRATEGY.md) for the current sync design. `progress_counters` / `ProgressCounter` / `calculateCountingRollup` are vestigial dead — rejected in favor of this per-Task model; do not build against them.

### 3. Compound tasks

**Definition**: composed of other tasks (its *children*) and evaluated by a logical operator. Completion is **derived** from children's global states; never stored on the compound itself.

**Use cases**:
- *"Morning routine"* — `AND` of [shower, brush teeth, journal].
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
  childIndex,        // child ordering (always honored)
  createdAt, updatedAt, version, isDeleted, deletedAt?
}
```

A child can be **any Task** — Normal, Counting, or another Compound. Nesting is natural; depth is bounded by user behavior (typically ≤ 2 in practice).

> **Achievement is a first-class `TaskType` (since Phase 6.3 / PR #54), not a `BoardTask` flag.** The cross-board reference fields (`referencedBoardId` XOR `referencedTemplateId`), `achievementTrigger`, and `requiredCount` live on `Task`; `BoardTask` is placement-only. (The earlier design that put `isAchievementSquare`/`achievementType`/… on `BoardTask` was abandoned during implementation — those legacy columns physically remain in the base schema for migration backfill but are inert.) See [`docs/ARCHITECTURE.md` §Phase 6](./ARCHITECTURE.md#phase-6-recurring-boards--shipped).

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

### Child ordering

Compound children always render in `childIndex` order (the order they were added; editable in the compound editor). There is no separate "ordered vs unordered" mode — the former `isOrdered` display flag was retired.

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

### Why global identity (and how Windowed Completion refined it)

Tasks are **library entities** — definitions a user reuses. The unification refactor made completion a property of the Task (no per-board clones). Windowed Completion then refined *evaluation*: a Monday board and a Tuesday board holding the same task now legitimately show different states, because each evaluates against its own window — that's the shipped, intended behavior, not the confusion the original rationale worried about. What stays "global" is the task's identity and its event history; what's per-board is the window it's judged in.

### Storage

- **Primitives** (`Normal`, `Counting`): the authoritative record is the **`task_events` log**; `Task.isCompleted` / `Task.currentCount` are lifetime caches over it (library/global reads + the derived-counter carve-out only — recomputed from events on pull, never trusted for windowed board grids). See [`WINDOWED_COMPLETION.md`](WINDOWED_COMPLETION.md) §Task caches.
- **Compounds**: completion is **never stored**. Always computed from children's states at evaluation time (windowed on boards via the compound window context).

`BoardTask` rows carry no completion state — they are pure placement records mapping a board to a task at a row/col/center position.

### The derivation pass

When a primitive Task's completion changes, a transaction-scoped derivation pass:

1. Appends/tombstones the `task_events` row(s) and stamps the primitive Task row's lifetime caches.
2. Walks up `compound_children` to find every compound that contains this Task transitively.
3. Resolves the set of affected boards: every board placing the changed task or any transitive parent compound (sealed boards excluded — frozen records).
4. For each affected board, rebuilds the completion grid **against that board's window** (a `WindowEvaluationContext` of events threads through primitive + compound resolution; placements pass the collision resolver first), runs `detectBingos`, diffs against `boards.completedLineIds` for new/lost-bingo signals, writes board stats, and enqueues a Board sync entry.

The implementation lives in `packages/shared/src/algorithms/derivationPass.ts` (with platform wrappers in `apps/web/src/db/operations/orchestration.ts` and the iOS equivalent).

### Cross-board behavior — examples

**Example 1**: Same Counting task on three boards.
- "Run 5 miles" placed on a weekly board, a monthly board, and a Q2-themed board.
- User logs 1 mile → an increment event lands → every board **whose window contains the event** shows "1/5 miles" (all three here, assuming all windows are open; a board spawned next week starts back at 0/5 — that's Windowed Completion working, not a bug).
- User logs 4 more miles → the in-window sum reaches 5 → those boards' squares complete and their bingo grids re-evaluate.

**Example 2**: Compound parent + leaf both on the same board.
- "Wellness routine" compound has children including "Run 5 miles".
- Both placed as separate squares on Board A.
- Logging miles on the "Run 5 miles" square completes that primitive globally → Board A's "Wellness routine" square recomputes (one fewer pending child) → if all children now complete, the compound square fills → bingo detection runs once on the rebuilt grid.

**Example 3**: Counting race across devices — **fixed by Windowed Completion**.
- Device 1 logs +1 (event A). Device 2 (offline) logs +1 (event B).
- Both sync. `task_events` unions by id — **both increments survive** and the windowed sum counts them all. The old per-row-LWW outcome ("the lost increment is lost") was retired with the event log; no CRDT needed.

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
    isOrdered INTEGER,                         -- LEGACY inert column (in-order retired)

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
    childIndex INTEGER NOT NULL,               -- child ordering (always honored)

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
- `action`, `unit`, `maxCount`, `currentCount`, `operator`, `threshold` all forbidden.

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
- Minimum 2 children at save time.
- No duplicate `childTaskId` across `compound_children` rows for the same `compoundTaskId`.
- No circular references — adding a child must not produce a cycle. Validated at creation by walking the descendant tree.

### compound_children

- `childIndex` is unique per `compoundTaskId` (enforced via app code, not a unique index, so reordering can be a swap).
- A `childTaskId` cannot point to its own `compoundTaskId` (self-reference) or any ancestor.

---

## UI interaction patterns

### Library / wizard tabs

Filter chips on the wizard's Tasks step: **All / Normal / Counting / Compound**, plus the contextual **From parent boards** and **From a board…** source pickers. Progress and Composite were collapsed into a single **Compound** chip. The Tasks tab additionally surfaces an **Achievement** chip; Achievement is hidden from the wizard's boardable picker.

### Creating a task

Two entry points, both writing through the same compound-create transaction:

- **+ New Compound task** → opens the compound wizard (operator picker: All of / Any of / At least N of). Creates `Task(type='compound', operator=<chosen>, threshold?)` + children (steps).

Inline-created children (a child whose definition is authored alongside the parent) become their own primitive Task rows in the same transaction — preserves today's step-with-`linkedTaskId` pattern.

### Editing a task

- **Compound editor**: operator picker + child list with add / remove. Runs the compound-structure-edit transaction (mutate `compound_children`, then run derivation pass for affected boards).

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

- [`SYNC_STRATEGY.md`](./SYNC_STRATEGY.md) — push/pull/LWW reconciliation.
- [`OFFLINE_FIRST.md`](./OFFLINE_FIRST.md) — local-first architecture.
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — overall system design (includes the Phase 6 Recurring Boards design that adds the planned specific-board reference mode to achievement squares, and the Shared Counters Decisions 1–7 schema record).
- [`SHARED_COUNTERS.md`](./SHARED_COUNTERS.md) — Shared Counters UX design + phasing (the engine described above already ships; this doc covers the Counters Hub / Detail / board-play polish / arrival-banner UX built on top of it).
