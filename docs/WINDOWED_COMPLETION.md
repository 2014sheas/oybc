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
| 1 | Past windows freeze | **Yes — boards seal after their window ends**, with a close-out prompt (not a hard cutoff at `endDate`) |
| 2 | Architecture | **Full event log** (`task_events` collection), not latest-timestamp-only, not per-spawn task clones |
| 3 | v1 scope | **Normal AND counting tasks** both event-sourced in v1 (compound derives from children; achievement derives from board state — neither needs events) |
| 4 | Event mutation model | **Soft-deletable rows synced with existing per-row LWW** (like `compound_children`) — NOT pure append-only with compensating events. Union by id, tombstone = undo, zero new sync machinery |
| 5 | Seal trigger | **Prompt-to-seal on next app-open** after a window closes (lazy, user-driven — same philosophy as the recurring banner), with a **timeframe-scaled auto-seal backstop** (`min(48h, windowLength/4)`) |
| 6 | Derived shared counters | **Unchanged in v1** — baseline-based display everywhere; derived tasks are fully carved out of events/backfill/recompute (see [§Derived-task carve-out](#derived-task-carve-out)) |
| 7 | Doc home | This file; pointers from ARCHITECTURE.md + CLAUDE.md when implementation starts |
| 8 | Seal snapshots are re-derivable | Sealed board snapshots are **locally re-derived pure functions of the converged in-window event union** — never LWW-raced between devices (review finding C2) |
| 9 | Undo is window-scoped | Un-complete tombstones **all in-window** events for the viewed context; events inside a sealed board's window are **immune to tombstoning** (review findings M4 + C2 interaction) |

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

Evaluation windows have **a start bound only**. A live board counts events in
`[board.startDate, ∞)`; the upper bound is enforced by *sealing*, not by
filtering. (This deliberately sidesteps `endDate` comparisons — and their
local-ISO vs UTC-`Z` encoding hazards — in the evaluation hot path entirely.)

| Type | State for board B (live) | Notes |
| ---- | ------------------------ | ----- |
| Normal | complete iff a non-deleted `completion` event exists with `occurredAt >= B.startDate` | |
| Counting (plain / source) | `windowCount = max(0, Σ delta of non-deleted increments with occurredAt >= B.startDate)`; complete iff `windowCount >= maxCount` | Low-end clamp only — **overshoot invariant preserved**, sums are never high-clamped |
| Counting (**derived**, `sharedCounterId` set) | **unchanged from today**: `deriveDisplayedCount(baseline, source lifetime count)` — NOT windowed, NOT event-owning | See [§Derived-task carve-out](#derived-task-carve-out) |
| Compound | derived from children as today, but child state is resolved **against the host board's window** | `evaluateCompound` gains a window-context parameter; nested compounds inherit the same host window; derived-counting children resolve via the carve-out row above |
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
  windowStart: string | null,   // null = lifetime (library surfaces, indefinite semantics)
): { isCompleted: boolean; count: number }
```

`isBoardIndefinite()` boards use `windowStart = board.startDate` like any other
board (their window is `[startDate, ∞)` and they never seal — behavior is
continuous with today's).

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
4. **Derivation-pass branch.** `computeBoardStatsUpdate` resolves derived
   counting squares via baseline math (today's behavior), not
   `resolveTaskWindowState`.

**Honest consequence:** a *derived* counter square on a recurring board still
bleeds across windows in v1; a *plain* counting square does not. Phase 2 fixes
this by anchoring derived board-context display to
`Σ source deltas with occurredAt >= max(board.startDate, linkedAt)` — which needs
a `linkedAt` timestamp on the link and is also the natural foundation for
SHARED_COUNTERS Decision 6's deferred timeframe-scoped goals.

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
  event (`occurredAt = now`, `boardId` = context board if any) → stamp caches →
  derivation pass over affected live boards. Completing an already-lifetime-complete
  task from a *new* window appends a new event — this is the "re-complete"
  gesture, and it increments `totalCompletions`.
- **Un-complete is window-scoped** (review finding M4): tombstone **all**
  non-deleted, non-sealed-immune completion events with
  `occurredAt >= context window start` → restamp caches → derivation.
  - Board context: the viewed board's `startDate`.
  - Library context: the toggle acts on the latest event; if that event is
    **sealed-immune** (see below) the toggle is disabled with an explanatory
    affordance ("completed in a sealed window") instead of silently failing.
  - **Sealed-window immunity**: an event is immune iff some non-deleted *sealed*
    board places its task and `sealedBoard.startDate <= occurredAt <= sealedAt`.
    Immune events can never be tombstoned by any gesture — history stays history.
    If tombstoning the non-immune events doesn't flip the square (an immune event
    keeps it green), the UI says why rather than appearing broken.
- **Increment**: append a positive-delta event → stamp caches → derivation.
- **Decrement needs window intent** (review finding M3):
  - **Board context**: append a negative-delta event (`occurredAt = now`), gated
    by windowed count > 0 so the window sum can't go negative from local gestures.
  - **Library / Counters Hub context**: tombstone the **latest non-immune
    increment event** instead of appending a negative delta — a lifetime
    correction removes the occurrence being corrected rather than poisoning the
    current window with a dangling negative. Display sums remain low-clamped at 0
    as a belt against cross-device races.
- **`incrementSharedCounter(sourceId)`**: unchanged contract; internally becomes
  append-event-on-source + propagation-stamp of derived tasks + derivation. Still
  the single logging path for every member task's square and the counter detail
  screen.

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
   the board keeps evaluating events in `[startDate, ∞)` — the
   11:58pm-workout-logged-at-12:04am counts for the closing daily.
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
  for a placed task lands with `occurredAt` in `[startDate, sealedAt]` of a
  sealed board, that board's snapshot is **re-derived locally** inside the pull
  transaction.
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

### Accepted boundary edge

An event logged during a board's post-`endDate` unsealed overtime (e.g. 12:04am)
counts for the closing board **and** for the new window's board (its
`occurredAt` is inside the new window too). With the timeframe-scaled backstop
the overtime is at most 25% of the window (6h for a daily), so double credit is
confined to the boundary hours rather than spanning whole windows. Rare,
self-inflicted, user-favorable; attribution rules would buy complexity for no
real integrity gain. Recorded as intentional.

## Shared counters interaction

- **Source count** = lifetime event sum (cache `currentCount`). `deriveDisplayedCount`
  (baseline math) is unchanged; `buildSharedCounterGroups` unchanged. Derived
  tasks are fully carved out of the event machinery — see
  [§Derived-task carve-out](#derived-task-carve-out).
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
  recompute stamps (pull paths don't author writes).
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
| Cross-platform vectors | Shared JSON test vectors for `resolveTaskWindowState`, backfill ids/timestamps, and seal re-derivation (same pattern as the counter-arrival vectors in PR #304) |
| Manual | Two-device: offline increments on both → union (no loss); complete on A, un-complete on B → converges; **seal divergence: A offline past backstop logs work, B auto-seals grey → after A syncs, both re-derive green**; template respawn across a real date rollover; upgrade a device with live bleed-greens → note shown, squares grey |

## Edge cases (decided)

- **Event during unsealed overtime** counts for both the closing and the new
  window — accepted, user-favorable, bounded by the scaled backstop (see
  [§Sealing](#sealing)).
- **Un-complete vs sealed history**: sealed-window events are tombstone-immune;
  lifetime un-complete stops at the seal boundary and the UI explains a
  still-green state instead of silently eating taps. Sealed pixels change only
  via deterministic re-derivation from late-arriving pre-seal activity.
- **Offline seal divergence**: converges via snapshot re-derivation — no data
  loss, no LWW coin-flip (see the manual test above).
- **Timezone travel**: evaluation uses only `occurredAt >= startDate` (parsed
  compare) — no string equality, no endDate math in the hot path; sealing keys
  off parsed deadlines. Window *identity* hazards remain in detection/matching
  and are the separate `windowKey` change.
- **Compound on indefinite board vs daily board**: same compound legitimately
  differs — indefinite window is `[startDate, ∞)`, daily is `[today, ∞)`-until-
  sealed. No special casing.
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
   a single functional **"Sealed"** badge (Riso `RisoBadge` / `BoardStatusBadge`
   vocabulary) regardless of greenlog outcome; its frozen grid + existing
   progress/bingo meta already convey how much was completed. Rationale:
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
   Accepted-boundary-edge section (the 11:58pm workout logged at 12:04am) only
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
