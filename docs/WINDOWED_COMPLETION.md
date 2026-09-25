# Windowed Completion — task events + board sealing

> **Status: SHIPPED (PRs A–D). Canonical reference for the event-sourced
> completion model.** Gate-1 decisions locked 2026-07-09; the PR train A #316,
> B #318, C #326, D #327 landed the `task_events` collection, windowed
> evaluation, board sealing, and the dead-`sharedCounterMerge` cleanup. See
> [§Phasing](#phasing-suggested-pr-train) for the per-PR breakdown.
> Provenance: the 2026-07-09 task/board design review identified a structural fault
> line — Task completion is a single mutable global bit, while boards are windowed
> temporal artifacts — producing two verified failure modes (respawn bleed, mutable
> history; see [§Problem](#problem)). This doc is the canonical design for the fix.
> Companion (independent) change from the same review: canonical `windowKey` board
> identity — tracked separately, not part of this design.
>
> **Amended 2026-07-09 after adversarial internal review (PR #310):** derived-counter
> carve-out, locally re-derived seal snapshots, window-scoped undo with sealed-window
> immunity, timeframe-scaled backstop, backfill timestamp/id fixes, batched pull
> recompute, honest upgrade-visibility section, sealed × Board-Edit gating.
>
> **Amended 2026-09-24 (root-square end bound — PR #507, `fix/root-window-end-bound`):**
> Decision 1 now bounds a live board at BOTH ends. A board's root squares
> (event-owning NORMAL / plain COUNTING tasks, and compound children resolved
> through the board's context) count only events inside the board's own window
> `[startDate, endDate]` — both bounds inclusive, compared by parsed instant;
> `endDate == null` = open-ended; sealing narrows the upper bound further to
> `min(endDate, sealedAt)`. A log made from an ended-but-unsealed board's own
> play surface is stamped `occurredAt = min(now, endDate)`, so it counts for
> that board and **not** for the next window's board. The pre-amendment
> "overtime counts for both windows" accepted edge is gone — see
> [§Overtime attribution](#overtime-attribution-amended-2026-09-24). The
> original start-bound-only text is kept below only where marked as history.
> Companion ruling (same train): ended boards are never Board Sources
> (`BOARD_SOURCES.md` §Boards as sources).

## Problem

Two failure modes, both verified in code, both consequences of the same root cause:

1. **Recurring respawn bleed.** `spawnTemplateBoard`
   (`apps/web/src/db/operations/recurringBoardSpawn.ts`) places the *same Task ids*
   from `seedTaskIds` — no clone, no reset. A daily template's Tuesday spawn places
   Monday's completed tasks already green; a "daily workout" board completed Monday
   spawns Tuesday pre-greenlogged. The same applies to core boards when the user
   reuses yesterday's tasks. (Bonus inconsistency: the spawned board row is written
   with `completedTasks: 0` and no derivation pass runs at spawn, so stored stats
   and the rendered grid disagree until the first interaction.)

2. **Mutable history.** Completion is global and mutable, and orchestration reverts
   greenlog (`orchestration.ts`: `COMPLETED → ACTIVE` when a task un-completes).
   Decrementing "Read 100 pages" below max today removes *last month's* greenlog;
   since streaks are computed live from board state, the streak retroactively
   breaks. Completing late retroactively *grants* past bingos. History is a live
   view over mutable state, not a record.

The root cause: the model has no concept of a completion **occurrence**. The tell
was already in the schema — `Task.totalCompletions` ("how many times completed")
implies repeated completion, but the model can only represent one, toggled. The
model has in fact prototyped windowed views twice without naming the concept:
shared-counter `baseline` ("count since link time") and achievement host-window
evaluation ("spawns within *this placement's* window").

## Locked decisions (2026-07-09)

| # | Decision | Choice |
| - | -------- | ------ |
| 1 | Past windows freeze | **Yes — boards seal after their window ends**, with a close-out prompt (not a hard cutoff on *logging* at `endDate`). **Amended 2026-09-24:** the live evaluation bound is the board's own `[startDate, endDate]` (inclusive both ends); sealing narrows it further to `min(endDate, sealedAt)`; a log made from an ended-but-unsealed board's own surface is stamped at `endDate` (`min(now, endDate)`) so it lands in that board's window |
| 2 | Architecture | **Full event log** (`task_events` collection), not latest-timestamp-only, not per-spawn task clones |
| 3 | v1 scope | **Normal AND counting tasks** both event-sourced in v1 (compound derives from children; achievement derives from board state — neither needs events) |
| 4 | Event mutation model | **Soft-deletable rows synced with existing per-row LWW** (like `compound_children`) — NOT pure append-only with compensating events. Union by id, tombstone = undo, zero new sync machinery |
| 5 | Seal trigger | **Prompt-to-seal on next app-open** after a window closes (lazy, user-driven — same philosophy as the recurring banner), with a **timeframe-scaled auto-seal backstop** (`min(48h, windowLength/4)`) |
| 6 | Derived shared counters | **Unchanged in v1** — baseline-based display everywhere; derived tasks are fully carved out of events/backfill/recompute (see [§Derived-task carve-out](#derived-task-carve-out)) |
| 7 | Doc home | This file; pointers from ARCHITECTURE.md + CLAUDE.md when implementation starts |
| 8 | Seal snapshots are re-derivable | Sealed board snapshots are **locally re-derived pure functions of the converged in-window event union** — never LWW-raced between devices (review finding C2) |
| 9 | Undo is window-scoped | Un-complete tombstones **all in-window** events for the viewed context; events inside a sealed board's window `[startDate, min(endDate, sealedAt)]` are **immune to tombstoning** (review findings M4 + C2 interaction; end bound amended 2026-09-24) |

## Goals / non-goals

**Goals**

- A task placed on successive windows (recurring templates, core boards, manual
  reuse) starts each window incomplete / at zero.
- A window that has closed (and been sealed) is a permanent historical record.
- Offline completion/increment activity is never lost to LWW — events merge by union.
- Per-task completion history becomes a real, queryable dataset (enables "done 47
  times", calendar heatmaps, persisted GREENLOG history, event-derived streaks —
  *enablement only; those features are out of scope here*).
- `totalCompletions` becomes derivable truth instead of a dead field.

**Non-goals (v1)**

- No history-browsing UI (heatmaps, per-task timelines). Enabled, not built.
- No windowed *derived* (shared-counter-linked) display — Phase 2.
- No timeframe-scoped counter goals ("2000 pushups this month") — this is
  SHARED_COUNTERS Decision 6's deferred feature; the event log makes it buildable
  later.
- No event compaction (fold ancient events into rollups). Growth math says YAGNI
  (see [§Performance](#performance)).
- No editing of historical events. Tombstoning exists only as in-window undo, and
  never reaches inside sealed windows.
- No unseal gesture. A sealed board cannot be edited or have its window extended.
- No change to achievement semantics, board identity/detection (`windowKey` is a
  separate change), or the lazy no-background-write invariants.

## The model

### New entity: `TaskEvent`

One new synced collection. SQLite table `task_events`, Dexie table `taskEvents`,
Firestore subcollection `users/{uid}/taskEvents` (naming matches
`boardTasks`/`compoundChildren` conventions). `firestore.rules` gains the matching
owner-only subcollection rules (PR B).

```ts
interface TaskEvent {
  id: string;                     // UUID (client-generated; deterministic for backfill rows)
  userId: string;
  taskId: string;                 // FK tasks
  kind: 'completion' | 'increment';
  delta?: number;                 // increment only; signed integer, non-zero
  occurredAt: string;             // ISO8601 — the semantic timestamp; windows key on this
  boardId?: string;               // provenance only (where it was logged); NEVER used in evaluation

  createdAt: string;
  updatedAt: string;
  lastSyncedAt?: string;
  version: number;                // per-row LWW, same as every other collection
  isDeleted: boolean;             // tombstone = undo
  deletedAt?: string;
}
```

Indexes: `[taskId+occurredAt]` (evaluation hot path), `[userId+occurredAt]`.

Zod: `delta` required non-zero integer iff `kind === 'increment'`, forbidden on
`completion`. `occurredAt` required. Events are only valid for tasks that **own
their state**: `type === NORMAL`, or `type === COUNTING` with `sharedCounterId`
null/undefined. Events for compound / achievement / **derived** (linked) counting
tasks are rejected at the schema boundary — their state is derived elsewhere.

### Semantics per task type

Evaluation windows are **bounded at both ends** (amended 2026-09-24). A live
board counts events in its own window `[board.startDate, board.endDate]` —
both bounds inclusive, compared by **parsed instant** (board dates are
local-ISO and parse in the evaluating device's time zone; event timestamps are
UTC ISO; never a string compare). `endDate == null` (an indefinite board) is
open-ended. A sealed board's upper bound narrows further to
`min(endDate, sealedAt)` (see [§Seal snapshots](#seal-snapshots-re-derive-from-the-event-union-review-finding-c2)).
*History:* until 2026-09-24 windows had a start bound only (`[startDate, ∞)`,
the upper bound enforced by sealing), which let a log made in one board's
post-`endDate` overtime also complete the NEXT window's square, and let an
ended board's root square pick up activity logged after it ended (the
root-square counter bug). A *window-stamped derived counter* was already
resolved against its own `[startDate, endDate]` (2026-09-23, see
[§Derived-task carve-out](#derived-task-carve-out)); root squares now follow
the same inclusive-both-ends convention.

| Type | State for board B (live) | Notes |
| ---- | ------------------------ | ----- |
| Normal | complete iff a non-deleted `completion` event exists with `occurredAt` in `[B.startDate, B.endDate]` | `B.endDate == null` → no upper bound |
| Counting (plain / source) | `windowCount = max(0, Σ delta of non-deleted increments with occurredAt in [B.startDate, B.endDate])`; complete iff `windowCount >= maxCount` | Low-end clamp only — **overshoot invariant preserved**, sums are never high-clamped |
| Counting (**derived**, `sharedCounterId` set) | hub-linked (no `startDate`): **unchanged from today** — the propagation-stamped cache, NOT windowed, NOT event-owning. **Window-stamped** (`startDate` set, wizard-born): complete iff `max(0, Σ delta of the ROOT's non-deleted increments with occurredAt in [row.startDate, row.endDate]) >= maxCount` | See [§Derived-task carve-out](#derived-task-carve-out) (rule 4, amended 2026-09-23) |
| Compound | derived from children as today, but child state is resolved **against the host board's window** `[startDate, endDate]` | `evaluateCompound` takes a `CompoundWindowContext { windowStart, windowEnd, eventsByTaskId }` (`windowEnd` required, `null` = open-ended); nested compounds inherit the same host window; derived-counting children resolve via the carve-out row above |
| Achievement | unchanged (reads referenced board / spawn-set state) | Sealing makes watched historical state *more* stable |

The same task on two live boards can legitimately show different states: "Drink 8
glasses" reads 8/8 on this month's board and 3/8 on today's board. That is the
feature. Library surfaces (Tasks tab, task detail, Counters Hub) show **lifetime**
state — the cache fields below.

Shared helper (new, `packages/shared/src/algorithms/taskEvents.ts` + Swift twin):

```ts
resolveTaskWindowState(
  task: Task,                   // must be an event-owning task (see Zod rule); callers
                                // branch derived/compound/achievement BEFORE calling
  events: TaskEvent[],          // this task's non-deleted events (caller pre-groups)
  windowStart: string | null,   // null = lifetime (library surfaces)
  windowEnd: string | null,     // inclusive upper bound; null = open-ended
): { isCompleted: boolean; count: number }

boardWindowEnd(board): string | null          // = board.endDate ?? null
lateLogOccurredAt(board, nowIso): string      // = min(now, endDate) — see §Write paths
```

Board surfaces pass `windowStart = board.startDate, windowEnd = boardWindowEnd(board)`
(the derivation pass, compound contexts and every render adapter). Library
surfaces pass `null, null` (lifetime). `isBoardIndefinite()` boards have no
`endDate`, so their window is `[startDate, ∞)` and they never seal — the only
boards still open-ended.

### Derived-task carve-out

Tasks with `sharedCounterId` set (derived counters), and compound/achievement
tasks, **do not own events** and are excluded from every event mechanism (review
finding C1). Explicitly:

1. **No events, ever.** `incrementSharedCounter` appends events on the **source**
   task only. The Zod boundary rejects events for derived/compound/achievement
   task ids.
2. **No backfill.** The migration skips derived tasks entirely — their
   `currentCount` mirrors the source (`propagateIncrement` stamps it); minting
   events from it would double-count the source's history.
3. **No pull-path cache recompute.** The recompute-from-events rule (below)
   applies only to event-owning tasks. Derived-task caches remain
   propagation-stamped (preserving the one-way completion latch); compound /
   achievement cache fields remain never-written/never-read as today.
4. **Derivation-pass branch** (amended 2026-09-23). A *hub-linked* derived
   counting square (`sharedCounterId` set, no `startDate`) resolves from its
   propagation-stamped `isCompleted` cache, not `resolveTaskWindowState`. A
   *window-stamped* derived counter (`isWindowStampedDerived`) resolves from
   its ROOT's events instead — see the next paragraph. Neither reads
   `baseline`.

**Honest consequence:** a *hub-authored* derived counter square on a recurring
board still bleeds across windows in v1; a *plain* counting square does not.

**Window-stamped derived counters (Board Sources member rules, design locked
2026-09-17 — [`BOARD_SOURCES.md` §Member rules](BOARD_SOURCES.md#member-rules--counting--compound-tasks-pulled-from-sources-design-locked-2026-09-17);
kernel rule amended 2026-09-23)** close that bleed for the counters the
wizard/spawn mints. A row with `sharedCounterId != null && startDate != null`
(and `createdInWizard`, the exported `isWindowStampedDerived`) is resolved by
the derivation kernel — `computeBoardGrid` and compound children alike, via
`resolveDerivedCounterWindowState` (`taskEvents.ts` ↔ `TaskEvents.swift`) —
from the **root's** increment events: `max(0, Σ delta of non-deleted root
increments with occurredAt in [row.startDate, row.endDate])` (inclusive both
ends, the `isWithinTimeframe` convention; `endDate == null` = unbounded;
signed deltas summed as-is), complete iff `>= (maxCount ?? 0)`, overshoot
valid. The row's own `isCompleted` latch is **never** read for it: that latch
is one-way and propagation stamps it from *any* later increment, so before
this amendment a past window's cell latched green from a later window and a
sealed board re-derived differently on each device (audit 2026-09-23 finding
#1). On the sealed path the context is also bounded at `sealedAt`
(`boundWindowContextAtSeal`), so a sealed derived cell is a pure function of
the converged in-window root-event union like every other sealed cell, and a
late in-window root event re-derives every sealed board placing a derived row
linked to that root (`reDeriveSealedBoardsForTasks` ↔ `reDeriveSealedBoards`
expand a changed root id to its window-stamped rows). A derived cell ignores
root events logged after its row's `endDate` — its window is the row's own
stamped window (since the 2026-09-24 amendment a plain counting root square
is end-bound the same way, at its board's `endDate`). Context
builders must therefore keep the workspace-wide event map: the root is
usually not placed. A context-less (lifetime) resolution is the only place the
latch still decides.

Carve-out items 1–3 still hold for window-stamped rows: they own no events,
`currentCount` stays the propagation-stamped root mirror, and `baseline =
Σ root increment events with occurredAt < row.startDate` stays a
**non-authored display cache** (no version bump, no enqueue; recomputed on
local root writes and in the pull sub-step after
`recomputeTaskCachesFromPull(rootId)` — `refreshDerivedBaselines` is
unchanged). The kernel does not read `baseline`; propagation to a row whose
window has ended is frozen — `isFrozenDerivedRow(row, now)` (shared
`memberRules.ts` ↔ `BoardSources.isFrozenDerivedRow`, pinned by the
`frozenDerivedRow` vectors in `memberRuleVectors.json`): a window-stamped row
with `now` strictly after its `endDate` (inclusive, `isWithinTimeframe`
convention) gets no authored write, no enqueue and no credit on increment /
decrement / undo. The precise completion statement: an increment or decrement
made off-board (Counters hub, counter detail, library) stamps its new event
`now`, after every frozen window, so it cannot change a frozen row's kernel
sum and the row is also left out of the cascade. One made from an
ended-but-unsealed board's own surface (`incrementSharedCounter` /
`decrementSharedCounter` with that `boardId`) is stamped at the board's
`endDate` (2026-09-24 late-log rule), which CAN fall inside that board's
frozen rows' windows — so those rows are reached cascade-only (no write, no
enqueue), exactly like the undo case below (`propagateToLinkedRows`'s
`reachOccurredAt` ↔ the iOS twin). An
**undo** can — it tombstones an EARLIER event whose `occurredAt` may lie
inside a frozen row's window (log at 23:59:58, undo at 00:00:02) — so undo
additionally cascades, cascade-only (still no write / enqueue / credit), the
frozen rows whose window contains the undone entry's `occurredAt`
(`isFrozenRowReachedByEvent(row, occurredAt, now)`, shared + Swift twin,
`frozenRowReachedByEvent` vectors), and the ended board's stored stats revert
with the undo instead of waiting for a seal or pull. No-`endDate`, hub-linked
and in-window rows propagate as before, and `refreshDerivedBaselines` still
refreshes a frozen row's non-authored `baseline`. The web ops run ONE batched
`runBoardCascadeForTasks` over the root + unfrozen rows (+ undo's reached
frozen rows); iOS batches via `runSharedCounterCascade` (`cascadeOnlyTaskIds`).
**Display (2026-09-23, same train):** every render / filter read of a
window-stamped row — play cell (count text + green), poster / preview cells,
compound detail child rows, the wizard Preview, the Sources done-filter, the
arrival snapshot and the Counters hub row — goes through
`resolveLinkedCounterDisplay` (`taskEvents.ts` ↔ `TaskEvents.swift`, pinned by
`taskWindowStateVectors.json#linkedCounterDisplay`): count AND completion are
the same root-event window sum the kernel uses (hub rows also bounded at the
board's `sealedAt`), so a cell never paints green or reads N/N while board
stats count it incomplete, and a late-synced in-window event moves both. Only
hub-linked rows and context-less (lifetime) readers still show
`currentCount − baseline`. Sealed play cells keep their max/0 snapshot display.
This supersedes the earlier `linkedAt` idea: the board window is the anchor,
and it already lives on the derived task.

### `Task.isCompleted` / `currentCount` / `completedAt` become caches

Kept, still synced, stamped transactionally on every event write — but demoted:

- They now mean **lifetime state**: `isCompleted` = latest lifetime toggle state,
  `currentCount` = lifetime delta sum, `completedAt` = `occurredAt` of the latest
  non-deleted completion event.
- Library/global surfaces keep reading them (no UI churn there).
- Board grids and the derivation pass **stop reading them** for anything windowed.
- **Cache stamps are authored writes**: they ride the same transaction as the
  event append, bump `Task.version`, and enqueue a Task sync entry (older
  surfaces and peers that haven't pulled events yet still see fresh caches). Yes,
  this means an increment pushes two docs; D3 per-entity coalescing absorbs the
  churn. (Review minor: previously unspecified.)
- **On pull, event-owning tasks' caches are recomputed from events, not trusted**
  (see [§Sync](#sync) for batching). This turns the "don't trust denormalized
  values during conflicts" pitfall rule into structure. Pulled Task rows still
  LWW normally for identity fields (title, description, config); the recompute
  then overwrites the completion-cache fields without bumping `version`.

### Write paths (single choke points, as today)

- **Complete** (board square, compound child sheet, library): append `completion`
  event (`occurredAt = min(now, endDate)` from a board context — see the late-log
  bullet below — else `now`; `boardId` = context board if any) → stamp caches →
  derivation pass over affected live boards. Completing an already-lifetime-complete
  task from a *new* window appends a new event — this is the "re-complete"
  gesture, and it increments `totalCompletions`.
- **Late logs are stamped into the board they were made on** (amended
  2026-09-24). A log made from an **ended-but-unsealed** board's OWN play
  surface — normal tap, counting tap, shared-counter increment / decrement
  passed that `boardId`, compound-child fallback — is stamped
  `occurredAt = min(now, endDate)` via the shared pure `lateLogOccurredAt(board, nowIso)`
  (`taskEvents.ts` ↔ `Helpers/TaskEvents.swift`) and the DB helper
  `lateLogStampForBoard(boardId, now)` (web `db/operations/taskEvents.ts` ↔
  iOS `AppDatabase+TaskEvents.swift`). It therefore counts for that board and
  NOT for the next window's board. Comparison is by parsed instant; the stamp
  is re-encoded as a UTC ISO event timestamp; an unparseable `endDate` fails
  open to `now`. Logs made **elsewhere** — the library, Task Detail, the
  Counters hub / counter detail — carry no board and stamp `now`; they are not
  attributed to an ended board. A **sealed** board authors nothing:
  `handleTaskCompletion` / `completeTaskOrchestrated` no-op (no event appended,
  board untouched), as do the compound-child fallback and the shared-counter
  `incrementSharedCounter` / `decrementSharedCounter` given a sealed `boardId`.
- **Compound-child fallback** (child not placed on the host board): writes only
  for an **event-owning** child (NORMAL / plain COUNTING — event append with the
  late-log stamp above). For a non-event-owning child — window-stamped derived
  counter, hub-linked derived counter, nested compound — it is a **full no-op**
  (no latch write, no cascade, no enqueue): a hub-linked latch is propagation
  output from its root, a window-stamped row is never authored (and frozen
  after its window), a nested compound is derived.
- **Un-complete is window-scoped** (review finding M4): tombstone **all**
  non-deleted, non-sealed-immune completion events with `occurredAt` inside the
  context window → restamp caches → derivation.
  - Board context: the viewed board's `[startDate, endDate]` (amended
    2026-09-24 — events after an ended board's `endDate` belong to later
    windows and are never tombstoned from it). An unparseable `endDate` fails
    open (treated as open-ended) on both platforms.
  - Library context: the toggle acts on the latest event; if that event is
    **sealed-immune** (see below) the toggle is disabled with an explanatory
    affordance ("completed in a sealed window") instead of silently failing.
  - **Sealed-window immunity**: an event is immune iff some non-deleted *sealed*
    board places its task and
    `sealedBoard.startDate <= occurredAt <= min(sealedBoard.endDate, sealedAt)`
    — exactly the events the sealed record counted (amended 2026-09-24 with the
    Decision 1 end bound; `buildSealImmuneWindows`). An event in the overtime
    gap `(endDate, sealedAt]` belongs to the next window's board and stays
    tombstonable there. A missing / unparseable `endDate` leaves the bound at
    `sealedAt`.
    Immune events can never be tombstoned by any gesture — history stays history.
    If tombstoning the non-immune events doesn't flip the square (an immune event
    keeps it green), the UI says why rather than appearing broken.
- **Increment**: append a positive-delta event → stamp caches → derivation.
- **Decrement needs window intent** (review finding M3):
  - **Board context**: append a negative-delta event
    (`occurredAt = min(now, endDate)`, the late-log stamp), clamped to the
    board's **window** count (`[startDate, endDate]`) so the window sum can't go
    negative from local gestures — for shared counters too
    (`decrementSharedCounter` with a `boardId`), never just the lifetime count.
  - **Library / Counters Hub context**: tombstone the **latest non-immune
    increment event** instead of appending a negative delta — a lifetime
    correction removes the occurrence being corrected rather than poisoning the
    current window with a dangling negative. Display sums remain low-clamped at 0
    as a belt against cross-device races.
    **As-shipped drift (recorded 2026-07-15, P5 review):** the Counters Hub
    Detail stepper actually ships the *board-context* behavior — a negative
    delta clamped to the lifetime total (`decrementSharedCounter`), not the
    tombstone rule above. Seed-safe and simpler, but a hub decrement on a
    *placed* source task can leave a dangling negative in its live window
    (display stays clamped). Revisit if that surfaces as user confusion.
- **`incrementSharedCounter(sourceId)`**: unchanged contract; internally becomes
  append-event-on-source + propagation-stamp of derived tasks + derivation. Still
  the single logging path for every member task's square and the counter detail
  screen. Takes an optional `boardId` (2026-09-24): a board-surface call passes
  it and gets the late-log stamp; hub / detail calls omit it and stamp `now`.
- **Counter Undo toast** reverses the entry most recently **made**:
  `selectLastIncrementEntry` (shared ↔ `Helpers/LastCounterLogEntry.swift`)
  orders by `createdAt` first, `occurredAt` as the tie-break — a late log
  carries an old `occurredAt` (its board's `endDate`) but is still the newest
  entry.

## Sealing

### Board schema delta

```ts
interface Board {
  // ...existing fields...
  sealedAt?: string;              // ISO8601; set once, never cleared
  sealedCompletedCells?: number[] // cell indexes (row*size+col) green per the event union
}
```

`status` is untouched — sealing is orthogonal to draft/active/completed/archived.
(Whether sealed-but-never-greenlogged boards deserve a distinct visual treatment
is a UI question, listed under [§Open questions](#open-questions).)

### Lifecycle

1. **Detection (lazy, on app-open)** — same hook family as recurring detection:
   boards where `!isDeleted && !isBoardIndefinite(b) && b.status !== DRAFT &&
   endDate < now && !sealedAt` form the **closing-out set**.
2. **Prompt** — a Boards-tab banner row per closing board: *"«name» ended
   ‹window label› — anything left to log?"* with **Log** (opens the board, still
   fully live) and **Seal** actions. This is deliberately the recurring-banner
   pattern: recurrence is observed on app-open; so is closure. While unsealed,
   the board stays playable, but it evaluates only events in its own
   `[startDate, endDate]`: the 11:58pm workout logged at 12:04am **from the
   closing daily's own surface** is stamped at its `endDate` and counts for
   the closing daily (amended 2026-09-24 — previously the board evaluated
   `[startDate, ∞)` and that log also counted for the new daily).
3. **Seal (user action)** — in one transaction: run the derivation pass one final
   time, write `sealedAt = now` + `sealedCompletedCells` (the green cell indexes
   from that final grid), bump `version`/`updatedAt`, enqueue Board sync.
4. **Backstop (auto-seal)** — on app-open, boards past their backstop deadline
   seal silently via the same transaction, no prompt. The deadline is
   **timeframe-scaled** (review finding M2 — a flat 48h gave daily boards a
   three-day scoring window, letting one workout green three consecutive dailies):

   | Timeframe | Backstop = `min(48h, windowLength/4)` |
   | --------- | ------------------------------------- |
   | Daily     | 6h (seals ~6am next day)              |
   | Weekly    | 42h                                   |
   | Monthly / Yearly / Custom ≥ 8 days | 48h          |

   One shared helper owns the formula. The deadline keys off
   `max(endDate, activatedAt)` so a **draft activated after its window already
   expired** still gets one full prompt cycle instead of an instant silent seal
   (review minor). When online, the backstop prefers to run **after the
   session's first pull completes** so it seals from the freshest event set —
   an optimization, not a correctness requirement, because of re-derivation
   (next section). Rationale for the gesture-less write stands as before: an
   ignored prompt must not leave history mutable indefinitely. Flagged for
   Gate-1 sign-off.

### Seal snapshots re-derive from the event union (review finding C2)

Two devices can seal the same board from divergent local event sets (one offline
past the backstop). Racing the snapshots via board-row LWW would permanently
falsify history — the losing device's real logged work would union into the event
log but never reach the frozen record. Instead:

- `sealedCompletedCells` (+ the frozen `completedTasks` / `linesCompleted` /
  `completedLineIds` / greenlog status) are defined as a **pure function of the
  converged in-window event union**: whenever a pulled `taskEvent` (or tombstone)
  for a placed task — or for the ROOT of a placed window-stamped derived row —
  lands with `occurredAt` in `[startDate, min(endDate, sealedAt)]` of a sealed
  board, that board's snapshot is **re-derived locally** inside the pull
  transaction. A derived row's propagated latch is never an input (amended
  2026-09-23). The effective upper bound is `min(endDate, sealedAt)` (amended
  2026-09-24): the context is pre-filtered at `sealedAt`
  (`boundWindowContextAtSeal`) and the kernel then applies the board's
  `endDate`, so a completion stamped after `endDate` (even before `sealedAt`)
  is excluded, one stamped exactly at `endDate` counts, and a `sealedAt`
  earlier than `endDate` narrows further — pinned by `sealReDerivationVectors`.
- Re-derivation is **local-only**: no `version` bump, no sync enqueue. Every
  device converges independently because the input (the event union) converges.
  There is no snapshot LWW fight, and no unbounded mutability — the recompute
  input is bounded by the window.
- A fresh device's initial sync re-derives sealed boards once after its event
  pull completes (folded into the batched pull step, [§Sync](#sync)).
- Because sealed-window events are **tombstone-immune** (Decision 9), post-seal
  re-derivation can only *add* late-arriving offline work, with one exception:
  a tombstone authored *before* the seal on another device (an offline undo)
  merges in and is honored. Both are corrections toward what actually happened
  in the window — the record converges on truth, not on whichever device
  synced last.

### Effects of sealed

- **Excluded from the live derivation fan-out** — `findAffectedBoardIds` (and the
  platform orchestration around it) skips sealed boards. Greenlog can no longer
  revert on them from live activity; re-derivation (above) is the only sanctioned
  mutation and is deterministic.
- **Grid renders from `sealedCompletedCells`** (read-only squares), not from live
  event queries.
- **Not editable** (review finding M6): the Board Edit entry point
  (docs/BOARD_EDIT.md) gates on `!sealedAt` on both platforms — rearranging
  squares under a positional snapshot, swapping tasks, or extending the window
  would all desync the frozen record. No unseal gesture in v1.
- **Streaks / achievements / stats read the frozen row** — final modulo
  re-derivation convergence.
- Sealed boards remain visible everywhere they are today (pager, browser, lists).

### Overtime attribution (amended 2026-09-24)

An event logged during a board's post-`endDate` unsealed overtime (e.g. 12:04am)
is **attributed to the board it was made on**, and counts for exactly one
window:

- Logged from the **closing board's own surface** → stamped at that board's
  `endDate` (`lateLogOccurredAt`), so it counts for the closing board and not
  for the new window's board.
- Logged **anywhere else** (the new board, the library, Task Detail, the
  Counters hub) → stamped `now`, so it counts for the window containing `now`
  and not for the ended board (whose root squares stop at `endDate`).

The overtime itself is still bounded by the timeframe-scaled backstop (at most
25% of the window, 6h for a daily), after which the board seals and locks.

*History:* before this amendment the section was titled "Accepted boundary
edge" and recorded the opposite: with start-bound-only windows an overtime
event counted for the closing board **and** the new board, accepted as
user-favorable double credit. That edge caused the root-square counter bug
(an ended weekly's root square completed by a later daily's log) and is gone.

## Shared counters interaction

- **Source count** = lifetime event sum (cache `currentCount`). Derived tasks
  own no events — see [§Derived-task carve-out](#derived-task-carve-out). A
  HUB-LINKED derived member still displays `deriveDisplayedCount` (baseline
  math) and completes by its latch; a WINDOW-STAMPED member (amended
  2026-09-23) displays and completes from its ROOT's events inside its own
  window via `resolveLinkedCounterDisplay` — on board cells, previews, the
  Sources done-filter and the Counters hub (`buildSharedCounterGroups` takes
  an optional `eventsByTaskId` for this).
- **Retired: `sharedCounterMerge` + `lastSyncedCount` stamping — in PR B, not
  later** (review minor: between an event-writing client and a still-active merge
  branch, the pull path would author merged `currentCount` writes with no backing
  event, fighting the recompute). PR B removes (or hard-bypasses) the merge
  branch and the push-path stamping in the same change that introduces events;
  PR D deletes the dead code. The `lastSyncedCount` field stays in the schema
  (inert) for decode compatibility. `SYNC_STRATEGY.md`'s shared-counter section
  gets a superseded-by pointer to this doc.

## Sync

- New collection `taskEvents` joins the known-collections list on both platforms,
  plus matching owner-only `firestore.rules`. Per-row LWW + soft-delete
  tombstones, exactly like `compoundChildren`. No new conflict-resolution logic —
  union by id; the only mutable bit worth fighting over is `isDeleted`, and LWW
  on it is acceptable (an undo racing a no-op).
- **Batched pull-path recompute** (review finding M7 — per-row recompute × the
  full-workspace cascade would make a fresh device's initial sync of 10–20k
  events quadratic-ish): within one pull cycle, apply all pulled `taskEvents`
  rows first, group by `taskId`, recompute each affected event-owning task's
  caches **once**, then run **one** derivation pass per affected live board and
  one seal re-derivation per affected sealed board — all inside the same
  transaction (per the atomic pull-path invariant). Do not bump `version` on the
  recompute stamps (pull paths don't author writes). A shared-counter ROOT is
  never placed, but its window-stamped derived rows resolve from its events, so
  both passes expand a changed root id to those rows
  (`expandToWindowStampedDerived`); the sealed pass reads the root's events
  bounded at `sealedAt`, never a derived row's latch — a post-seal root
  increment leaves a sealed snapshot byte-stable, a late in-window one
  converges it (pinned end to end by web `derivedCounterSealedPull.test.ts` ↔
  iOS `SyncPullApplyTests.test_sealedBoardPull_windowStampedDerived_…`). The
  per-root `refreshDerivedBaselines` sweep only rewrites window-stamped rows'
  non-authored `baseline`, which no board stat reads, and those rows are
  already in the expanded cascade set.
- **Pull ordering**: a `taskEvent` can arrive before its `Task` row (per-collection
  listeners have no cross-collection ordering). Events whose task isn't local yet
  are applied as rows but skipped by recompute; the safety-net pull picks them up
  once the Task lands — the same skip-and-defer posture the pull path already
  uses for out-of-order parents.
- **Board seal rows** sync as ordinary Board updates for the `sealedAt` marker;
  the snapshot content self-heals via local re-derivation (see
  [§Seal snapshots re-derive](#seal-snapshots-re-derive-from-the-event-union-review-finding-c2)),
  so a stale pulled snapshot is corrected by the next event application on any
  device.
- **Mixed-version hazard (accepted, pre-launch):** an old client toggles
  `Task.isCompleted` directly (no event); a new client's pull recompute then
  reverts it. Both platforms must ship the event-writing version in the same PR
  train (parity rule 6); stale installed builds are a known, bounded risk at
  current user scale. No dual-write compatibility shim — flag-day.

## Migration & backfill

Dexie version bump + GRDB migration (a new `registerMigration` in
`AppDatabase.swift`), same shape on both platforms, one transaction:

1. **Create `task_events`** (+ indexes).
2. **Backfill events** per non-deleted, **event-owning** task (derived tasks
   skipped — carve-out rule 2):
   - `type === NORMAL && isCompleted && completedAt` → one `completion` event,
     `occurredAt = completedAt`.
   - `type === COUNTING && !sharedCounterId && currentCount > 0` → one
     `increment` event, `delta = currentCount`, `occurredAt = completedAt ?? updatedAt`.
   - **Deterministic ids, kind-qualified** (review minor: a task whose type was
     edited between two devices' migrations must not collide across kinds):
     `uuidv5(taskId + '|backfill|' + kind, OYBC_NAMESPACE)`. The migration helper
     in `packages/shared` owns the scheme so both platforms agree. (No non-UUID
     id schemes — id fields are UUID-validated.)
   - **Timestamps from the task snapshot, not migration wall-clock** (review
     finding M1): the backfill event's `createdAt`/`updatedAt` = `task.updatedAt`
     at derivation time. Two devices with divergent pre-migration caches then
     mint same-id rows whose LWW tie-break (same `version: 1`, compare
     timestamps) selects the row derived from the **fresher** task state —
     whichever device migrates first or last is irrelevant.
   - Backfilled events are enqueued for sync CREATE (they must reach Firestore
     or another device's recompute would zero the caches).
3. **Seal expired boards** — every non-deleted, non-draft, non-indefinite board
   past its backstop deadline at upgrade time: compute `sealedCompletedCells`
   from the **current rendered state** (pre-migration semantics — live Task
   caches + compound evaluation), write `sealedAt = migration time`. Boards
   inside the backstop window go through the normal prompt flow instead.
4. Cache fields are already consistent by construction (events were derived from
   them) — no restamp needed at migration time.

### Migration bleed-greens converge to windowed truth (I-1)

Step 3 seals expired boards from the **pre-migration rendered state** (lifetime
`Task.isCompleted` / `currentCount` caches, no window context) — deliberately, so
the seal reproduces exactly what the user last saw. That means a migration-sealed
board can freeze a **bleed green**: a square whose task was completed *before that
board's window opened*, green today only via the global-bit bleed this design
fixes. This is a one-migration artifact, not a permanent falsehood.

It self-corrects on the **first post-migration synced activity**. The pull-path
re-derivation hook (`reDeriveSealedBoardsForTasks` web / `reDeriveSealedBoards`
iOS) recomputes the frozen snapshot from the **windowed** event union bounded at
the board's `sealedAt` whenever a `taskEvent` for a placed task lands — and the
bleed square flips grey, converging the record to windowed truth. Because
re-derivation is a pure function of the converged union (no `version` bump, no
enqueue), every device converges independently; a device that never syncs new
activity for that task simply keeps the (honest, last-seen) migration snapshot.
The convergence flip is covered at the shared-kernel level by
`tests/algorithms/migrationSealConvergence.test.ts` (lifetime seal → windowed
re-derivation, both NORMAL and COUNTING bleed squares).

### What changes visibly at upgrade (review finding M5)

The earlier draft claimed "nothing the user sees changes at upgrade" — that holds
only for boards sealed by step 3. Be honest about the rest:

- **Live windowed boards re-evaluate under windowed semantics immediately.** A
  normal task completed *before* a live board's `startDate` (green today only via
  the global-bit bleed this design exists to fix) goes **grey** on that board;
  `completedTasks` drops, and bingos/greenlogs that depended on bleed-greens
  revert via the existing orchestration branch. This is the bleed fix applied to
  currently-live windows — intended, but user-visible and unexplained without
  messaging.
- **Counting squares are transitional-lumpy**: the whole lifetime count backfills
  as one event at `completedAt ?? updatedAt`, so a live board whose window
  contains that timestamp keeps the full count (bleed preserved once), while one
  whose window starts later shows 0. Windows are accurate from migration forward.
- **Boards still inside their backstop window** re-evaluate the same way before
  the user seals them.
- **Ship a one-time in-app note** with the upgrade ("Boards now track each
  window's work — squares completed before a board started no longer carry
  over") — copy at PR-B design time.

## Heal-on-pull (fresh-install backfill gap — 2026-08)

**The gap.** The event backfill (web Dexie v13 / iOS v20) runs as a DB
*migration*. On a **fresh install** (new browser/device/cleared storage) the
migration runs on an **empty** DB and mints nothing; the sync pull then arrives
*after*. A task pulled `isCompleted=true` whose backing `task_event` isn't in
Firestore therefore has no event locally — and every windowed surface derives it
**incomplete** (with a windowContext the derivation never falls back to the
lifetime cache, by design). The lifetime cache itself survives for such tasks
(the pull recompute only runs for tasks whose *events* were in the pull, so a
zero-event task keeps its pulled `isCompleted=true`), so the completion is
recoverable *from the cache* — but only until something needs it.

**The fix — a post-pull heal sweep.** `healMissingCompletionEvents(userId)` runs
after a pull cycle: for every **event-owning** task (NORMAL / plain COUNTING)
that is lifetime-complete (`isCompleted` / `currentCount > 0`) but has **zero
live events**, it mints the event via the shared `buildBackfillTaskEvent(task)`,
**enqueues a CREATE**, then runs the same recompute + board cascade + sealed
re-derive the event-pull path uses. Properties:

- **Convergent + idempotent.** The event id is the deterministic
  `backfillTaskEventId = uuidv5(taskId|backfill|kind)` — identical to the
  migration's and across platforms — so re-runs, the same-batch race, and a
  peer's later pull all union to one row (no duplicates, no double-count).
- **Self-healing network-wide.** Because it enqueues, the minted event pushes to
  Firestore, so every peer converges (and it replaces the old, silently
  destructive behavior where a completion could be dropped and never restored).
- **Anchor (best-effort, never lose a completion).** `buildBackfillTaskEvent`
  anchors NORMAL at `completedAt ?? updatedAt ?? createdAt` and COUNTING at
  `completedAt ?? updatedAt ?? createdAt` (was: NORMAL required `completedAt`,
  skipping event-less legacy rows). `completedAt` keeps exact-window placement;
  the fallback trades window precision for never dropping a completion.
- **Carve-outs unchanged.** Derived / compound / achievement return `nil` from
  the builder — they don't own events and read caches directly.
- **Respects an explicit undo (LWW, never resurrects).** A candidate has zero
  *live* events, but a soft-deleted **tombstone** (from an un-complete) may still
  sit at the deterministic id. Before minting, heal LWW-checks the mint (as
  "remote") against any existing row and **skips** unless it would win — so a
  version-bumped tombstone stands and undone state is never resurrected (nor is a
  wrong board cascade transiently driven). Same `resolveConflict` semantics as
  `applyTaskEventsBatch`'s upsert.
- **Atomic.** The whole sweep — candidate scan + mint + enqueue + recompute +
  cascade + sealed re-derive — runs in one transaction (the atomic pull-path
  invariant), so a mid-sweep crash rolls back cleanly and re-heals next pull.
- **Ceiling (honest).** It recovers any completion still asserted
  `isCompleted=true` *anywhere* and stops all future loss, but cannot resurrect a
  completion already zeroed to `false` on every device (no data remains).

Both platforms mirror this (web `db/operations/taskEventPull.ts` +
`firebase/syncService.ts` pull-cycle hook; iOS `SyncService.swift`). The v13/v20
migrations stay (they heal in-place upgrades); heal-on-pull is the durable net
for fresh installs, ongoing syncs, and pull races.

## What this closes / retires

| Item | Disposition |
| ---- | ----------- |
| Respawn bleed (review §2a) | Fixed — spawned boards start empty because no events exist in the new window. Spawn path also gains a derivation-pass call so stored stats are computed, not hand-initialized |
| Mutable history / retroactive streak breaks (§2b) | Fixed via sealing + tombstone immunity |
| Lost counting increments under LWW (`TASK_SYSTEM.md` Example 3) | Fixed for all counting tasks — union of events |
| `sharedCounterMerge` + `lastSyncedCount` machinery | Retired in PR B (field inert; dead code deleted in PR D) |
| Greenlog revert on expired boards (`orchestration.ts`) | Impossible once sealed; the revert branch remains for live boards only |
| `totalCompletions` | Becomes real: count of non-deleted completion events (recomputed with caches) |
| Persisted GREENLOG-history / streak log groundwork | Enabled (roadmap follow-up builds on `task_events` + sealed boards) |

## Performance

- Volume: heavy use ≈ tens of events/day ≈ 10–20k/year — trivial for
  SQLite/IndexedDB with the `[taskId+occurredAt]` index.
- Derivation needs each affected board's placed tasks' events since
  `board.startDate` — bounded by (placed tasks × window activity), well within
  the <50ms bingo / <200ms cross-board targets.
- Sync steady-state cost unchanged (watermark-incremental pull). **Fresh-device
  initial sync** is the hot case — covered by the batched pull recompute
  ([§Sync](#sync)); one recompute per task and one cascade per board per pull
  cycle, not per event row.
- Compaction (fold events older than N months into per-task rollups) is recorded
  as a future option; not built.

## Phasing (suggested PR train)

| PR | Scope | Status |
| -- | ----- | ------ |
| A | `packages/shared`: `TaskEvent` type + Zod, `resolveTaskWindowState`, window-context params on `evaluateCompound` / `computeBoardStatsUpdate` (defaulting to lifetime = today's behavior), backfill id/timestamp helpers, backstop formula, tests | **Shipped (#316)** |
| B | Both platforms: `task_events` migrations + backfill, write paths append events + stamp caches, windowed reads in grids/derivation (incl. derived-task carve-out branch), sync collection + `firestore.rules` + batched pull recompute, **`sharedCounterMerge` neutered**, upgrade note UI | **Shipped (#318)** |
| C | Sealing: Board schema fields, closing-out prompt UX (web + iOS), timeframe-scaled backstop, migration sealing, fan-out exclusion, sealed-grid rendering, seal re-derivation hook in the pull path, Board-Edit gating on `!sealedAt` | **Shipped (#326)** |
| D | Delete dead `sharedCounterMerge` / `lastSyncedCount` code (both platforms; `lastSyncedCount` column/field kept inert for decode compat); spawn-time derivation pass (recurring spawn now writes derivation output, not a hand-init 0); doc updates (TASK_SYSTEM, SYNC_STRATEGY, ARCHITECTURE, CLAUDE.md pointers) | **Shipped #327** |
| Phase 2 (separate design pass) | `linkedAt` + windowed derived counters; timeframe-scoped counter goals (Decision 6 unlock) | — |

B before C is required (sealing snapshots windowed evaluation). A is pure prep and
can merge immediately.

## Testing matrix

| Layer | Coverage |
| ----- | -------- |
| Unit (shared) | `resolveTaskWindowState`: normal/counting × in-window / pre-window / tombstoned / negative-sum clamp / lifetime mode; windowed `evaluateCompound` incl. nested + host-window inheritance + derived-counting child branch; `computeBoardStatsUpdate` with events context + derived carve-out; backfill helper determinism (same input → same kind-qualified ids; timestamps from task snapshot); backstop formula per timeframe; seal-cell snapshot builder + re-derivation determinism (same event union → same snapshot on any device) |
| Unit (web, Vitest + fake-indexeddb) | Event write paths (complete / window-scoped un-complete incl. sealed-immunity + multi-event windows / increment / context-split decrement) stamp caches + fire derivation; seal transaction; backstop keyed off `max(endDate, activatedAt)`; migration backfill (derived tasks skipped) + expired-board sealing; **batched** pull-path recompute; events-before-task ordering skip; spawned board starts empty across a window rollover (regression test for the original bug); derived-task pull leaves propagation-stamped caches + latch intact (regression for C1) |
| Unit (iOS, XCTest) | Twins of the above against `makeTestInstance()` |
| Snapshot (iOS) | Closing-out banner (0/1/3 boards); sealed board grid (read-only rendering); disabled-with-explanation un-complete affordance |
| Cross-platform vectors | Shared JSON test vectors for `resolveTaskWindowState`, backfill ids/timestamps, and seal re-derivation (same pattern as the counter-arrival vectors in PR #304). 2026-09-24 end bound: `taskWindowStateVectors` (windowEnd cases + `lateLogOccurredAt`), `sealReDerivationVectors` (post-`endDate` completion excluded; exactly-at-`endDate` counts; `sealedAt` narrows further), `derivationPassVectors` (end-bound root squares); repro pins `derivedCounterCrossWindowCompletion.test.ts` ↔ `DerivedCounterCrossWindowCompletionTests.swift` are real passes |
| Manual | Two-device: offline increments on both → union (no loss); complete on A, un-complete on B → converges; **seal divergence: A offline past backstop logs work, B auto-seals grey → after A syncs, both re-derive green**; template respawn across a real date rollover; upgrade a device with live bleed-greens → note shown, squares grey |

## Edge cases (decided)

- **Event during unsealed overtime** is attributed to the board it was made
  on (amended 2026-09-24): from the closing board's own surface it is stamped
  at that board's `endDate` and counts only there; from anywhere else it is
  stamped `now` and counts only for the window containing `now`. No longer
  counts for both (see [§Overtime attribution](#overtime-attribution-amended-2026-09-24)).
- **Undo on an ended board** is bounded to that board's `[startDate, endDate]`:
  it never tombstones a completion logged after `endDate` (which belongs to a
  later window).
- **Un-complete vs sealed history**: sealed-window events are tombstone-immune;
  lifetime un-complete stops at the seal boundary and the UI explains a
  still-green state instead of silently eating taps. Sealed pixels change only
  via deterministic re-derivation from late-arriving pre-seal activity.
- **Offline seal divergence**: converges via snapshot re-derivation — no data
  loss, no LWW coin-flip (see the manual test above).
- **Timezone travel**: evaluation compares `occurredAt` against `startDate`
  and `endDate` by parsed instant — no string equality. Board dates are
  local-ISO and parse in the evaluating device's zone (the same caveat on both
  bounds); sealing keys off parsed deadlines. Window *identity* hazards remain
  in detection/matching and are the separate `windowKey` change.
- **Compound on indefinite board vs daily board**: same compound legitimately
  differs — indefinite window is `[startDate, ∞)`, daily is
  `[today 00:00, today 23:59:59.999]`. No special casing.
- **Draft boards** never seal while drafts; a draft activated after its window
  expired gets one prompt cycle before any backstop (deadline keys off
  `max(endDate, activatedAt)`). Archived boards seal normally.
- **Achievement tasks** placed on sealed boards: the sealed board's stats are
  frozen modulo deterministic re-derivation — a watched board that seals stops
  reacting to live activity, which is exactly what a watcher wants.

## Open questions

1. Should sealed-but-not-greenlogged boards get a distinct visual treatment
   ("ended" vs "active")? Pure UI; decide at C-PR design time.
   **Resolved (C-PR, slice 2/2): No distinct treatment.** A sealed board carries
   a single functional badge (Riso `RisoBadge` / `BoardStatusBadge`
   vocabulary) regardless of greenlog outcome; its frozen grid + existing
   progress/bingo meta already convey how much was completed.
   **User-facing vocabulary (2026-07-27): "sealed" is internal feature-speak and
   never appears in UI copy.** The badge reads **"Closed"** ("CLOSED" on iOS),
   the closing-out banner's action is **"Close out"** / "Closing…", and prose
   copy says "closed window" / "Board closed — a permanent record". Code,
   docs, and identifiers keep the `sealed` domain term. Rationale:
   consistency with the app's existing single-status-badge pattern (one badge per
   card, mutually exclusive with Active/Expiring), and the doc flags this
   treatment as optional-only. A separate "ended-but-empty" state would add a
   third overlapping visual state for no integrity gain.
2. Is `windowLength/4` (capped at 48h) the right backstop shape, or should the
   divisor differ per timeframe? Tunable constant; revisit with real usage.
3. Should the closing-out prompt batch (one row per board) or collapse ("3 boards
   closed — review")? UI call at C-PR time.
   **Resolved (C-PR, slice 2/2): One banner row per closing board.** Mirrors the
   6.1 recurring-window banner (`RecurringWindowBanner` web /
   `PendingRecurringBoardsViewModel` iOS), which already renders one tappable row
   per pending window. Rationale: the per-board **Log** / **Seal** actions need
   per-board identity, so a collapsed "3 boards — review" row would just have to
   expand back into per-board rows anyway; matching the recurring banner keeps
   the Boards-tab prompt vocabulary uniform. The banner naturally self-limits (a
   user rarely has more than a handful of windows close at once), so no explicit
   cap is added.
4. Should the library/Tasks-tab un-complete toggle survive at all post-events, or
   become a read-only lifetime indicator (with undo living only on live boards)?
   The sealed-immunity rule makes the toggle correct but occasionally inert —
   decide at B-PR UX time.
5. *(Surfaced at C-PR implementation, resolved)* **The pre-existing expiry-based
   play lock conflicted with the Lifecycle's Log flow — resolved: sealing
   REPLACES expiry as the interaction lock.** Both platforms previously disabled
   all play interactions once `endDate` passed; but §Lifecycle step 2 defines
   **Log** as opening the closing board "still fully live", and the
   overtime-attribution section (the 11:58pm workout logged at 12:04am) only
   works if logging during unsealed overtime is possible. Every
   expired-and-playable board is by construction in the closing-out set, so the
   old expiry lock and the new seal lock cover the same boards — the seal lock
   just arrives after the (backstop-bounded) overtime instead of at the stroke
   of `endDate`. Play surfaces on both platforms now lock on `sealedAt != null`
   only (web `BoardPlaySurface`/`useBoardPlay` `playLocked`; iOS
   `isBoardPlayLocked`); expiry remains a display-only signal (badges, banner).

## Cross-platform file map (indicative, PR-B/C scope)

| Web | iOS | Shared |
| --- | --- | ------ |
| `db/schema` Dexie version bump (`taskEvents` table) | new `registerMigration` in `Database/AppDatabase.swift` (migrations are registered inline there — there is no `AppDatabase+Migrations.swift`) | `types/taskEvent.ts`, Zod schema |
| `db/operations/taskEvents.ts` (append/tombstone + cache stamp) | `AppDatabase+TaskEvents.swift` | `algorithms/taskEvents.ts` (`resolveTaskWindowState`, backstop formula, seal re-derivation) |
| `db/operations/orchestration.ts` (windowed derivation + derived carve-out, seal txn, fan-out exclusion) | `CompoundCascade` / `BoardPlayViewModel` write paths | `algorithms/derivationPass.ts`, `compoundEvaluation.ts` (window param) |
| `firebase/syncService.ts` (collection + batched pull recompute + merge-branch removal) | `Services/SyncService.swift` | `algorithms/migrationHelpers.ts` (backfill ids/timestamps) |
| Closing-out banner component + BoardsPage wiring | closing-out slot in `BoardListView.swift` alongside the recurring-window slots (pattern: `PendingRecurringBoardsViewModel` — note there is no standalone `RecurringBoardsBannerView` file) | — |
| — | — | `firestore.rules`: `taskEvents` owner-only subcollection rules |

## See also

- `docs/TASK_SYSTEM.md` — task model this design amends (global completion → lifetime caches + windowed events); update on PR B.
- `docs/SYNC_STRATEGY.md` — shared-counter merge section superseded by union-of-events on PR B/D.
- `docs/ARCHITECTURE.md` §Phase 6 — recurring boards; respawn bleed fixed here.
- `docs/BOARD_EDIT.md` — edit mode; gated on `!sealedAt` from PR C.
- 2026-07-09 design review (conversation record) — problem discovery + option analysis (occurrence log vs per-spawn clones vs windowed-timestamp), plus the adversarial internal review that produced the amendments above.
