# Windowed Completion — task events + board sealing

> **Status: DESIGN (Gate-1 approved decisions locked 2026-07-09; no implementation yet).**
> Provenance: the 2026-07-09 task/board design review identified a structural fault
> line — Task completion is a single mutable global bit, while boards are windowed
> temporal artifacts — producing two verified failure modes (respawn bleed, mutable
> history; see [§Problem](#problem)). This doc is the canonical design for the fix.
> Companion (independent) change from the same review: canonical `windowKey` board
> identity — tracked separately, not part of this design.

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
| 5 | Seal trigger | **Prompt-to-seal on next app-open** after a window closes (lazy, user-driven — same philosophy as the recurring banner), with a **48h auto-seal backstop** |
| 6 | Derived shared counters | **Unchanged in v1** — baseline-based display everywhere. Windowing derived counters is Phase 2 (see [§Shared counters](#shared-counters-interaction)) |
| 7 | Doc home | This file; pointers from ARCHITECTURE.md + CLAUDE.md when implementation starts |

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
- No editing of historical events. Tombstoning exists only as in-window undo.
- No change to achievement semantics, board identity/detection (`windowKey` is a
  separate change), or the lazy no-background-write invariants.

## The model

### New entity: `TaskEvent`

One new synced collection. SQLite table `task_events`, Dexie table `taskEvents`,
Firestore subcollection `users/{uid}/taskEvents` (naming matches
`boardTasks`/`compoundChildren` conventions).

```ts
interface TaskEvent {
  id: string;                     // UUID (client-generated)
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
`completion`. `occurredAt` required. Events for `type === 'compound'` /
`'achievement'` tasks are rejected at the schema boundary (their state is derived).

### Semantics per task type

Evaluation windows have **a start bound only**. A live board counts events in
`[board.startDate, ∞)`; the upper bound is enforced by *sealing*, not by
filtering. (This deliberately sidesteps `endDate` comparisons — and their
local-ISO vs UTC-`Z` encoding hazards — in the evaluation hot path entirely.)

| Type | State for board B (live) | Notes |
| ---- | ------------------------ | ----- |
| Normal | complete iff a non-deleted `completion` event exists with `occurredAt >= B.startDate` | |
| Counting | `windowCount = max(0, Σ delta of non-deleted increments with occurredAt >= B.startDate)`; complete iff `windowCount >= maxCount` | Low-end clamp only — **overshoot invariant preserved**, sums are never high-clamped |
| Compound | derived from children as today, but child state is resolved **against the host board's window** | `evaluateCompound` gains a window-context parameter; nested compounds inherit the same host window |
| Achievement | unchanged (reads referenced board / spawn-set state) | Sealing makes watched historical state *more* stable |

The same task on two live boards can legitimately show different states: "Drink 8
glasses" reads 8/8 on this month's board and 3/8 on today's board. That is the
feature. Library surfaces (Tasks tab, task detail, Counters Hub) show **lifetime**
state — the cache fields below.

Shared helper (new, `packages/shared/src/algorithms/taskEvents.ts` + Swift twin):

```ts
resolveTaskWindowState(
  task: Task,
  events: TaskEvent[],          // this task's non-deleted events (caller pre-groups)
  windowStart: string | null,   // null = lifetime (library surfaces, indefinite semantics)
): { isCompleted: boolean; count: number }
```

`isBoardIndefinite()` boards use `windowStart = board.startDate` like any other
board (their window is `[startDate, ∞)` and they never seal — behavior is
continuous with today's).

### `Task.isCompleted` / `currentCount` / `completedAt` become caches

Kept, still synced, stamped transactionally on every event write — but demoted:

- They now mean **lifetime state**: `isCompleted` = latest lifetime toggle state,
  `currentCount` = lifetime delta sum, `completedAt` = `occurredAt` of the latest
  non-deleted completion event.
- Library/global surfaces keep reading them (no UI churn there).
- Board grids and the derivation pass **stop reading them** for anything windowed.
- **On pull, caches are recomputed from events, not trusted.** This turns the
  "don't trust denormalized values during conflicts" pitfall rule into structure.
  A pulled Task row's `isCompleted`/`currentCount`/`completedAt` are overwritten
  by the local recompute after event rows for that task are applied (see
  [§Sync](#sync)).

### Write paths (single choke points, as today)

- **Complete** (board square, compound child sheet, library): append `completion`
  event (`occurredAt = now`, `boardId` = context board if any) → stamp caches →
  derivation pass over affected boards. Completing an already-lifetime-complete
  task from a *new* window appends a new event — this is the "re-complete"
  gesture, and it increments `totalCompletions`.
- **Un-complete**: tombstone the **latest** non-deleted completion event → restamp
  caches → derivation. If the latest event belongs to a sealed board's era, the
  sealed board does not recompute (it is out of the fan-out); only live boards and
  library state react. UX surfaces should only offer un-complete where it makes
  sense (a green square on a live board; the library toggle).
- **Increment / decrement**: append a signed-delta event → stamp caches →
  derivation. Decrement is a negative event, not a tombstone (preserves the
  trail; keeps +/- symmetric). Decrement affordances disable at 0 *in their
  context* (windowed 0 on a board square; lifetime 0 in the library/hub).
- **`incrementSharedCounter(sourceId)`**: unchanged contract; internally becomes
  append-event-on-source + stamp + derivation. Still the single logging path for
  every member task's square and the counter detail screen.

## Sealing

### Board schema delta

```ts
interface Board {
  // ...existing fields...
  sealedAt?: string;              // ISO8601; set once, never cleared
  sealedCompletedCells?: number[] // cell indexes (row*size+col) green at seal time
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
4. **Backstop (auto-seal)** — on app-open, boards with
   `endDate + SEAL_BACKSTOP_HOURS < now` seal silently via the same transaction,
   no prompt. `SEAL_BACKSTOP_HOURS = 48`, one shared constant. Rationale: an
   ignored prompt must not leave history mutable indefinitely, and two devices
   must converge on sealed-ness within a bounded time. This is a lazy app-open
   write triggered by a *previous* user-visible prompt cycle — it does not violate
   the no-background-creation invariant (nothing is created; a terminal state is
   recorded), but it is the one place this design writes without a same-moment
   user gesture. Flagged for Gate-1 sign-off.

### Effects of sealed

- **Excluded from the derivation fan-out** — `findAffectedBoardIds` (and the
  platform orchestration around it) skips sealed boards. Greenlog can no longer
  revert on them; bingos can no longer appear or vanish.
- **Grid renders from `sealedCompletedCells`** (read-only squares), not from live
  event queries — so a later tombstone of an old event cannot edit sealed pixels.
- **Streaks / achievements / stats read the frozen row** — `completedTasks`,
  `linesCompleted`, `completedLineIds`, `status` are final.
- Sealed boards remain visible everywhere they are today (pager, browser, lists).

### Accepted boundary edge

An event logged during a board's post-`endDate` unsealed overtime (e.g. 12:04am)
counts for the closing board **and** for the new window's board (its
`occurredAt` is inside the new window too). Double credit across a boundary is
rare, self-inflicted, and user-favorable; the alternative (attribution rules)
buys complexity for no real integrity gain. Recorded as intentional.

## Shared counters interaction

- **Source count** = lifetime event sum (cache `currentCount`). `deriveDisplayedCount`
  (baseline math) is unchanged; `buildSharedCounterGroups` unchanged.
- **Retired: `sharedCounterMerge` + `lastSyncedCount` stamping.** Union-of-events
  makes offline increments unlosable for **all** counting tasks — not just
  shared-counter sources — with no three-way merge. The `lastSyncedCount` field
  stays in the schema (inert) for decode compatibility; the pull-path merge branch
  and push-path stamping are deleted. `SYNC_STRATEGY.md`'s shared-counter section
  gets superseded-by pointer to this doc.
- **Deliberately unchanged in v1: derived-task display.** A derived counter's
  displayed value stays `max(0, source lifetime − baseline)` on every surface,
  including windowed boards. Windowing derived counters collides with baseline
  semantics ("inherit" vs "start from zero") and would destabilize the in-flight
  Counters P1–P3 UX. **Honest consequence:** a *derived* counter square on a
  recurring board still bleeds across windows in v1; a *plain* counting square
  does not. Phase 2 fixes this by anchoring derived board-context display to
  `Σ source deltas with occurredAt >= max(board.startDate, linkedAt)` — which
  needs a `linkedAt` timestamp on the link and is also the natural foundation for
  SHARED_COUNTERS Decision 6's deferred timeframe-scoped goals.

## Sync

- New collection `taskEvents` joins the known-collections list on both platforms.
  Per-row LWW + soft-delete tombstones, exactly like `compoundChildren`. No new
  conflict-resolution logic — union by id; the only mutable bit worth fighting
  over is `isDeleted`, and LWW on it is acceptable (an undo racing a no-op).
- **Pull-path cache reconciliation**: after applying pulled `taskEvents` rows for
  a task (inside the same pull transaction, per the atomic pull-path invariant),
  recompute the task's cache fields from local events and run the derivation pass
  for affected live boards. Pulled Task rows still LWW normally for *identity*
  fields (title, description, config); their completion-cache fields are then
  overwritten by the recompute. Do not bump `version` on the recompute stamp
  (pull paths don't author writes) — the stamp rides the pulled row's version.
  **Open detail for implementation:** whether the cache stamp is written with the
  pulled row in one upsert (preferred) or as a follow-up write in the same txn.
- **Board seal rows** sync as ordinary Board updates. Two devices sealing the same
  board race benignly: if their event sets had converged, the payloads are
  identical; if not, LWW picks one snapshot. The 48h backstop bounds how long
  devices can disagree.
- **Mixed-version hazard (accepted, pre-launch):** an old client toggles
  `Task.isCompleted` directly (no event); a new client's pull recompute then
  reverts it. Both platforms must ship the event-writing version in the same PR
  train (parity rule 6); stale installed builds are a known, bounded risk at
  current user scale. No dual-write compatibility shim — flag-day.

## Migration & backfill

Dexie version bump + GRDB migration, same shape on both platforms, one transaction:

1. **Create `task_events`** (+ indexes).
2. **Backfill events** per non-deleted task:
   - `type === NORMAL && isCompleted && completedAt` → one `completion` event,
     `occurredAt = completedAt`.
   - `type === COUNTING && currentCount > 0` → one `increment` event,
     `delta = currentCount`, `occurredAt = completedAt ?? updatedAt`.
   - Backfilled events get **deterministic ids** (see the double-count hazard
     below), `version = 1`, and are enqueued for sync CREATE (they must reach
     Firestore or the other device's recompute would zero the caches).
3. **Seal expired boards** — every non-deleted, non-draft, non-indefinite board
   with `endDate + SEAL_BACKSTOP_HOURS < now`: compute `sealedCompletedCells`
   from the **current rendered state** (pre-migration semantics — live Task
   caches + compound evaluation), write `sealedAt = migration time`. Nothing the
   user sees on old boards changes at the moment of upgrade. Boards inside the
   backstop window go through the normal prompt flow instead.
4. Cache fields are already consistent by construction (events were derived from
   them) — no restamp needed at migration time.

Cross-device: each device runs the same deterministic backfill; the resulting
event rows have *different UUIDs* for the *same historical fact*. **Double-count
hazard:** device A's backfilled "+40 pages" event unions with device B's
backfilled "+40 pages" event → lifetime 80. Mitigation: derive the backfill
event id **deterministically** — `uuidv5(taskId + '|backfill', NAMESPACE)` (or a
fixed `id = 'backfill-' + taskId` scheme) so both devices mint the *same* row id
and union dedupes it. This is the one place event ids are not random; the
migration helper in `packages/shared` owns the scheme so both platforms agree.

## What this closes / retires

| Item | Disposition |
| ---- | ----------- |
| Respawn bleed (review §2a) | Fixed — spawned boards start empty because no events exist in the new window. Spawn path also gains a derivation-pass call so stored stats are computed, not hand-initialized |
| Mutable history / retroactive streak breaks (§2b) | Fixed via sealing |
| Lost counting increments under LWW (`TASK_SYSTEM.md` Example 3) | Fixed for all counting tasks — union of events |
| `sharedCounterMerge` + `lastSyncedCount` machinery | Retired (field inert) |
| Greenlog revert on expired boards (`orchestration.ts`) | Impossible once sealed; the revert branch remains for live boards only |
| `totalCompletions` | Becomes real: count of non-deleted completion events (recomputed with caches) |
| Persisted GREENLOG-history / streak log groundwork | Enabled (roadmap follow-up builds on `task_events` + sealed boards) |

## Performance

- Volume: heavy use ≈ tens of events/day ≈ 10–20k/year — trivial for
  SQLite/IndexedDB with the `[taskId+occurredAt]` index.
- Derivation needs each affected board's placed tasks' events since
  `board.startDate` — bounded by (placed tasks × window activity), well within
  the <50ms bingo / <200ms cross-board targets.
- Sync: events are small immutable rows; initial pull grows over time — pull is
  already watermark-incremental (`_syncedAt`), so steady-state cost is unchanged.
- Compaction (fold events older than N months into per-task rollups) is recorded
  as a future option; not built.

## Phasing (suggested PR train)

| PR | Scope | Risk |
| -- | ----- | ---- |
| A | `packages/shared`: `TaskEvent` type + Zod, `resolveTaskWindowState`, window-context params on `evaluateCompound` / `computeBoardStatsUpdate` (defaulting to lifetime = today's behavior), backfill-id helper, tests | Low — no platform behavior change |
| B | Both platforms: `task_events` migrations + backfill, write paths append events + stamp caches, windowed reads in grids/derivation, sync collection + pull recompute | **High — the flag-day PR**; both platforms in lockstep |
| C | Sealing: Board schema fields, closing-out prompt UX (web + iOS), backstop, migration sealing, fan-out exclusion, sealed-grid rendering | Medium |
| D | Retire `sharedCounterMerge`; spawn-time derivation pass; doc updates (TASK_SYSTEM, SYNC_STRATEGY, ARCHITECTURE, CLAUDE.md pointers) | Low |
| Phase 2 (separate design pass) | `linkedAt` + windowed derived counters; timeframe-scoped counter goals (Decision 6 unlock) | — |

B before C is required (sealing snapshots windowed evaluation). A is pure prep and
can merge immediately.

## Testing matrix

| Layer | Coverage |
| ----- | -------- |
| Unit (shared) | `resolveTaskWindowState`: normal/counting × in-window / pre-window / tombstoned / negative-sum clamp / lifetime mode; windowed `evaluateCompound` incl. nested + host-window inheritance; `computeBoardStatsUpdate` with events context; backfill helper determinism (same input → same event ids); seal-cell snapshot builder |
| Unit (web, Vitest + fake-indexeddb) | Event write paths (complete/un-complete/increment/decrement) stamp caches + fire derivation; seal transaction; migration backfill + expired-board sealing; pull-path recompute-from-events; spawned board starts empty across a window rollover (regression test for the original bug) |
| Unit (iOS, XCTest) | Twins of the above against `makeTestInstance()` |
| Snapshot (iOS) | Closing-out banner (0/1/3 boards); sealed board grid (read-only rendering) |
| Cross-platform vectors | Shared JSON test vectors for `resolveTaskWindowState` + backfill ids (same pattern as the counter-arrival vectors in PR #304) |
| Manual | Two-device: offline increments on both → union (no loss); complete on A, un-complete on B → converges; seal race; template respawn across a real date rollover |

## Edge cases (decided)

- **Event during unsealed overtime** counts for both the closing and the new
  window — accepted, user-favorable (see [§Sealing](#sealing)).
- **Un-complete after seal**: tombstoning the latest event never recomputes sealed
  boards; library state flips, sealed pixels don't.
- **Timezone travel**: evaluation uses only `occurredAt >= startDate` (parsed
  compare) — no string equality, no endDate math; sealing keys off parsed
  `endDate + backstop`. Window *identity* hazards remain in detection/matching and
  are the separate `windowKey` change.
- **Compound on indefinite board vs daily board**: same compound legitimately
  differs — indefinite window is `[startDate, ∞)`, daily is `[today, ∞)`-until-
  sealed. No special casing.
- **Draft boards** never seal (they resume into the wizard); archived boards seal
  normally (their state is already frozen in spirit).
- **Achievement tasks** placed on sealed boards: the sealed board's stats are
  frozen, and sealed boards don't re-derive — a watched board that seals stops
  changing, which is exactly what a watcher wants.

## Open questions

1. Should sealed-but-not-greenlogged boards get a distinct visual treatment
   ("ended" vs "active")? Pure UI; decide at C-PR design time.
2. Pull-path cache stamp: single upsert with the pulled row vs follow-up write in
   the same transaction (implementation detail; decide in PR B).
3. `SEAL_BACKSTOP_HOURS = 48` — right number? (Must be ≥ the longest plausible
   gap between "did it" and "logged it"; 48h chosen to survive a weekend offline.)
4. Should the closing-out prompt batch (one row per board) or collapse ("3 boards
   closed — review")? UI call at C-PR time.

## Cross-platform file map (indicative, PR-B/C scope)

| Web | iOS | Shared |
| --- | --- | ------ |
| `db/schema` Dexie version bump (`taskEvents` table) | `AppDatabase+Migrations` (GRDB `task_events`) | `types/taskEvent.ts`, Zod schema |
| `db/operations/taskEvents.ts` (append/tombstone + cache stamp) | `AppDatabase+TaskEvents.swift` | `algorithms/taskEvents.ts` (`resolveTaskWindowState`) |
| `db/operations/orchestration.ts` (windowed derivation, seal txn, fan-out exclusion) | `CompoundCascade` / `BoardPlayViewModel` write paths | `algorithms/derivationPass.ts`, `compoundEvaluation.ts` (window param) |
| `firebase/syncService.ts` (collection + pull recompute) | `Services/SyncService.swift` | `algorithms/migrationHelpers.ts` (backfill + deterministic ids) |
| Closing-out banner component + BoardsPage wiring | `RecurringBoardsBannerView`-style closing-out view + BoardListView wiring | — |

## See also

- `docs/TASK_SYSTEM.md` — task model this design amends (global completion → lifetime caches + windowed events); update on PR B.
- `docs/SYNC_STRATEGY.md` — shared-counter merge section superseded by union-of-events on PR D.
- `docs/ARCHITECTURE.md` §Phase 6 — recurring boards; respawn bleed fixed here.
- 2026-07-09 design review (conversation record) — problem discovery + option analysis (occurrence log vs per-spawn clones vs windowed-timestamp).
