# Task/window rework — per-placement parameters (2026-10 → )

Owner-decided direction for the task/window core after the 2026-10-16
architecture audit (claude.ai artifact "Task Window Audit"; memory
`project_audit_task_window_2026_10`). The audit followed the PR #624 incident:
a compound's linked sub-task, stamped with the window of the first daily board
that carried it, read 0 of 10 on every later spawn and was frozen out of
propagation. Six more defects of the same shape were verified. This document
is the spec for removing the cause rather than the symptoms. It is written for
the pre-launch window, when the only data in the system is the owner's and no
third-party client needs protecting. The owner does run two clients (the
deployed web app and the iOS TestFlight lane), so version skew between them is
the one compatibility risk, and the sequencing rules below are built around it.

Owner rulings (2026-10-16): (1) a counter's per-window target is **frozen on
the placement** when the board is made or the square is edited; (2)
board-scoped forks **stay full Task clones but stop copying events**; (3)
sequencing: merge #624 / #625, then this design doc, then `/feature` slices;
(4) a per-board rename of a counter square lives in **`titleOverride` on the
placement**, never a fork; (5) the frozen target carries its **count kind**
(`targetKind`), so a later kind switch never changes how a past board scores.

Revisions: r2 (internal review 1) — fork read-through, hub on placements, no
duplicate placements, heal retired in slice 3, gated post-pull sweep. r3
(internal review 2) — corrected lockstep rule with slices 3 and 6 split,
shadowing-clone fork rule with undo, forward child matching, no tombstones in
the sweep, a defined gate with a terminal outcome, counts-toward boundary,
root reachability helper, `titleOverride` / `targetKind`, wire details,
sweep cost bounds, acceptance made testable.

## The model, stated once

> A **Task** is a library definition (structure, default goal). A
> **Placement** (`BoardTask`) puts a task on a board's grid and may carry
> per-board parameters (lock, target override with its kind, child targets,
> title override). **Events** (`task_events`) are the only authored record of
> what happened; only event-owning tasks (Normal, plain or root Counting)
> have them, and a linked counter reads its root's events. **A square's
> state is a pure function of the task structure, the placement's
> parameters, and the event owner's live events with `occurredAt` inside the
> board's window `[startDate, min(endDate, sealedAt)]`.** Compounds evaluate
> their children over the same host window; Achievements evaluate watched
> boards over it. Counts shown anywhere, on a board or in the library, come
> from events; the completion caches stored on a Task exist for sorting and
> filtering only and are never read by a board. A sealed board stores a
> snapshot that must equal that function over the converged event union.
> Logs from a board's own surface after its end are stamped
> `min(now, endDate)`; logs from anywhere else are stamped `now`.

Every current invariant in `CLAUDE.md` §Windowed Completion follows from this
paragraph except the derived-row ones (freeze, baseline, stamp, heal). The
rework is done when those four no longer exist.

## Why the current shape fails

The model has no place to put a per-board parameter. Every per-board
difference (a counter's window target, a vary roll, a split part, a per-board
goal default, a per-board title) becomes a new `Task` row, and that row then
needs machinery to stay in sync with the library row it shadows:

| Mechanism today | Why it exists | What it costs |
| --- | --- | --- |
| Window-stamped derived counters (`derivedTaskId(board, root)`, three marks `sharedCounterId` + `startDate` + `createdInWizard`) | carry a per-window `maxCount` | identity inferred from overloaded fields; `createdInWizard` doubles as provenance and window mark |
| Derived compounds + derived links (`derivedCompoundId` / `derivedLinkId`) | a compound whose parts have per-window targets | per-window clones of a library compound; Repeat drops them; iOS hand-made wizard compounds match the predicate (audit Major 3) |
| Counter-placement copies (`placementNeedsCopy`) | a root whose timeframe default differs from its own goal | another minted row per board |
| Stamp-in-place (`planLinkedCounterWindowHeal` rule 1) | retrofit per-board windows onto pre-rule placements | a user row becomes an artifact without the artifact's id; the two deletion cascades disagree (Major 6); #624 |
| Propagation + freeze + baseline (`propagateIncrement`, `isFrozenDerivedRow`, `refreshDerivedBaselines`) | keep each copy's `currentCount` / `isCompleted` mirror current | N authored writes per log, LWW races, a freeze and a freeze carve-out |
| Linked-window heal on every pull + migrations v18/v20 ↔ v37/v44 | repair rows the above disagree about | identity rewritten on every pull; a date edit has no owner (Major 4) |

Readers currently choose among six resolution modes (own-window stamped row,
context-window hub-linked row, latch for context-less readers, event-owning,
compound recursion, sealed bound). Commits #537, #539, #581 and #624 are each
one surface choosing wrong.

## Target design

### `BoardTask` gains per-placement parameters

```ts
export interface BoardTask {
  // …existing: id, boardId, taskId, row, col, isCenter, isLocked, timestamps, sync meta
  /**
   * A counting placement's goal for THIS board (ruling 1: frozen when the
   * board is made or the square is edited). Absent ⇒ the task's own
   * `maxCount`. Carries the wizard's window-pro-rated auto target, a Vary
   * roll, a Split-up part's share, or the root's timeframe default.
   * Positive and step-aligned for `targetKind` (never 0).
   */
  targetOverride?: number;
  /**
   * The count kind `targetOverride` is expressed in (ruling 5). Written
   * together with `targetOverride`, never alone. When the root's current
   * kind differs, the kernel converts the target into the root's kind with
   * the kind-switch conversion (`max(step, round-to-step)`), at read time,
   * so a kind switch rewrites no placement and touches no sealed board.
   */
  targetKind?: CountKind;
  /**
   * A compound placement's per-child goals for THIS board: an ARRAY of
   * `{ childId, target }` sorted by `childId`, keyed by the compound's own
   * DIRECT child task ids (a linked child by its own id, not its root; a
   * nested compound child keeps its own children's `maxCount`). Absent ⇒
   * each child's own `maxCount`; `[]` is normalised to absent on write.
   * Replaces per-window derived compounds + links. An array, not a map:
   * Firestore writes are `merge: true` and a map deep-merges, so a removed
   * key would survive remotely; an array replaces wholesale, and a
   * whole-field clear rides the clearable-field delete. Stored as canonical
   * JSON text (sorted keys) in GRDB so `rowsGenuinelyDiffer` and LWW compare
   * bytes consistently. When a child is forked, its key is re-keyed to the
   * fork in the same write.
   */
  childTargets?: { childId: string; target: number }[];
  /**
   * A per-board title for a counter square (ruling 4). Absent ⇒
   * `placementTitle` renders the root's templates at the placement's goal.
   * A rename on a counter square writes this and keeps the counter link;
   * it never forks.
   */
  titleOverride?: string;
}
```

- All four fields are optional and absent on every existing row
  (forward-compat decode like `isLocked`). They join
  `CLEARABLE_FIELDS_BY_COLLECTION.boardTasks` (TS constant, Swift map,
  regenerated `syncContract.json`; the C4 fixture pins the wire shape).
  `firestore.rules` checks only `id` / `version` keys and `userId`, so no
  rules change. Zod: `targetOverride > 0`, quantized to `targetKind`'s step;
  each `childTargets[].target` likewise, `childId`s unique; every new field
  parsed with a per-field `.catch(undefined)` so a bad value falls back to
  the default instead of dropping the whole placement on pull.
- A placement points at the **library entity**: the counter root, the user's
  hand-made linked task, or the source compound. Nothing is minted at
  placement time.
- **One placement per (board, task) stays invariant.** `computePlacementIntegrityRepair`
  tombstones same-task duplicates on pull, deterministically, and that is
  kept. Split-up parts that share one root collapse to one placement (R13:
  the first part's roll wins). Two parts on two different linked children of
  one root are two squares completed by the same logs; the planner extends
  counter-family exclusivity to collapse those onto one placement as well,
  so this behaviour change does not reach the user.
- A target edit, a shuffle and a lock now share one LWW row. For a single
  user this is acceptable; noted under Risks.

### One resolution rule

`resolveSquareState(task, placement, window, eventsByTaskId)`:

- **Event owner**: the task itself for Normal / plain / root Counting; the
  root for a linked task (`sharedCounterId`); for a fork, the rule in §Forks.
- **Window**: the host board's `[startDate, min(endDate, sealedAt)]`, always.
  "Host present" means a BOARD window; `LIFETIME_WINDOW` is not a host. A
  task's own `startDate` / `endDate` / `timeframe` are never read by a board.
- **Goal**: `placement.targetOverride ?? task.maxCount`, converted from
  `targetKind` into the root's current kind when they differ; a compound
  child's goal is the parent placement's `childTargets` entry for that child,
  else the child's own `maxCount`.
- **Completion**: one rule for every counting shape — complete iff a goal
  exists and `count >= goal` (a goal-less linked row is never "green at 0").
- Compounds recurse with the same window and the parent placement's
  `childTargets`; Achievements keep their watched-board rule.
- **Title**: `placementTitle(task, placement, root)` = `titleOverride`, else
  the root's templates rendered at the placement's goal (today's
  `counterCopyTitle`), used by every square-title surface (cells, poster,
  previews, late-log sheet, Task Detail usage, arrivals).
- **Root reachability**: one helper on both platforms,
  `placementsReachedByRoot(root)` = root → every task linked to it →
  transitive parent compounds → placements. It replaces
  `withWindowStampedDerived` / the three-mark expansion in
  `boardLifecycle.resolveAffectedBoardIds`, `lateLog`, `sealing`,
  `taskEventPull`, `expandToWindowStampedDerived` and iOS
  `boardIdsReachedByTasks`, and the Sources supply loader uses it for a
  hand-made linked placement's root events.

`resolveLinkedCounterDisplay` becomes a thin wrapper over this rule (display
= kernel, by construction). `countsToward.stateOf` and the Sources sheet's
`resolveBoardSourceSupply` (done-filter, `windowCountByTaskId`) read the same
rule with the placement. Context-less readers (library, compound Task Detail,
`computeTaskCachesFromEvents`, credits for unplaced compounds) compute from
events: a root's lifetime sum; a linked task shows "Linked to ‹counter› ·
‹lifetime total›" plus "goal N per board" (its `maxCount` remains the default
placement goal). The start-from-zero `baseline` display for unplaced linked
rows is retired with it.

### Counters hub, arrivals and the library family row

Today a counter is a "root" only because some live task links to it
(`sharedCounterRootIds`), and the hub's member cards ARE linked tasks. After
the sweep a board-born root may have no linked task left, so the hub is
re-modelled in slice 2, before any repoint:

- **Root detection**: a counting task is a root iff it `isCounter`, or has a
  live linked task, or has a live placement carrying `targetOverride`. (Not
  "placed on more than one board": that would make every recurring plain
  counter a hub counter.) No stored flag is written by the sweep: `isCounter`
  is refused by Zod together with `countsTowardCounterId` and `canContribute`
  returns false for it, so setting it would drop rows on pull and withdraw
  credits.
- **Members = placements**: the root's direct placements plus the placements
  reached through its linked tasks and their parent compounds. One card per
  placement with the placement's goal, title and the host board's window;
  `pickPrimaryBoard` leaves the hub (it survives only to pick the Counter
  Detail "Counts toward" row's representative board — slice 2b). An
  unplaced linked task has no card (owner ruling 2026-10-17); the library
  row still says "Linked to ‹counter›". Card actions: tap opens the board; "remove"
  on a card of a linked task unlinks that task (task-level, as today); on a
  card of the root it clears the override. Counter Detail's unit tasks and
  return ring are task-level and unchanged. Forks are never members (a fork
  has no counter link; renames no longer fork).
- Arrivals (`useCounterArrivals` ↔ Swift) and the library family row use the
  same root set and placement members. Vectors pin hub groups before and
  after the sweep on an anonymised fixture of the owner's export.

### Writers emit parameters, not rows

- `planDerivedTasks` returns `placements: { taskId, targetOverride?, targetKind?, childTargets?, titleOverride? }[]`
  instead of `derivedTasks` / `derivedCompounds` drafts. The member-rule
  maths (auto target, vary, split, pool default dice, timeframe defaults;
  `placementGoalForCounter` / `counterPickGoal` survive with their output
  becoming the override) is unchanged in form, but **one input changes**: a
  board-sourced member's goal (`goalOf`) must be the supplied placement's
  effective goal (`targetOverride ?? maxCount`), which `BoardSourceSupplyInfo`
  now carries; today it reads the derived row's frozen `maxCount`, and
  reading the root's goal instead would pro-rate from 300 rather than 70.
  New vectors pull from a board that holds overridden placements; the
  existing `memberRuleVectors` are re-expected by hand against that rule.
- Wizard persist, recurring spawn, Board Edit add / replace, quick-add and
  the two placement choke points all write the same `BoardTask` shape.
- **Every writer that copies an existing placement** (Repeat this board,
  pulling from a board source, core next-window) resolves a placement that
  still points at a derived row to its root or source compound with the
  equivalent override / `childTargets` / `titleOverride` at write time, so
  no derived row ever gains a new placement.
- **Board Edit edits on a placed counter**: a goal edit writes
  `targetOverride` + `targetKind`; a compound child's goal edit writes
  `childTargets`; a rename writes `titleOverride`; only a structure edit
  forks (`wouldForkOnBoard` and its vectors change in slice 3a). Without
  this, a goal edit on a root placement would fork the root and the next
  spawn's pull from that board would supply nothing.
- Recurring templates keep storing sources and member rules; spawn resolves
  them into placement parameters per window. **Repeat this board copies a
  placement's frozen override and title** (ruling 1); spawn re-plans from
  rules.
- Hand-added compound children get the same per-child goal treatment as
  pulled ones.
- Counts-toward credits at the placement's goal (`crossingEvent` reads the
  placement, compounds read `childTargets`).

### Retired

- Window-stamped derived counters, derived compounds and derived links; the
  three-mark predicate `isWindowStampedDerived`, `isWindowStampedDerivedCompound`,
  `isMintedForBoard`, `isBoardArtifact`; `derivedTaskId` / `derivedCompoundId`
  / `derivedLinkId` survive only in the sweep's matching.
- `Task.startDate` / `endDate` / `timeframe` as kernel inputs. The columns
  stay for decode compatibility; the Tasks-tab "expired" filter and the hub's
  "show expired" are re-based on placements in slice 5 (an unplaced task is
  never expired; a compound child inherits its parents' placements, the
  `computeBrowsableTasks` rule; expired = placed only on ended or closed
  boards; the hub's toggle becomes per placement card). The window columns
  of previously stamped rows are cleared in that same slice.
- `createdInWizard` as a window mark. It returns to provenance only
  (draft-board library hiding). On rows the heal stamped, the original
  provenance is unrecoverable; harmless while the row is linked.
- Counter-placement copies (`placementNeedsCopy`), root-field propagation to
  copies, count-kind switch fan-out to copies (`targetKind` freezes the
  goal's kind instead).
- `planLinkedCounterWindowHeal`, its data layers, the post-pull sweep and
  the choke points' resolve step (slice 3a); the v18/v20 ↔ v37/v44 re-runs
  (migration history stays).
- `propagateIncrement`, `writeLinkedRowPropagation`, `isFrozenDerivedRow`,
  `isFrozenRowReachedByEvent`, `reachedFrozenIds`, `refreshDerivedBaselines`,
  `computeWindowBaseline` and the `baseline` field as a read input (column
  kept inert like `lastSyncedCount`); `deleteCounterWithUnlink` seeds the
  unlinked member's snapshot from events. An increment is one event write
  plus one cascade.
- Derived-row deletion cascades (`softDeleteWindowStampedDerived`,
  `windowStampedDerivedOrphanedByBoard`); `computeTaskDeletionImpact.derivedWindowCounterCount`
  and `derivedCounterRemovalNote` (both platforms); `deleteCounterWithUnlink`
  only unlinks.
- `tasks.timeframe` / `startDate` / `endDate` as clearable sync fields (the
  first two added by #624, the third by the 2026-10-01 heal) once no writer
  clears them (after slice 5).

### Forks (owner ruling 2)

Board-scoped forks stay real `Task` rows (structure genuinely diverges;
title and goal edits on counter squares no longer fork, see above). A fork is
an independent event owner for everything logged after it exists, and
existing forks already carry clones of their pre-fork events, so the rule
must make both shapes evaluate identically:

- **Shadowing clones**: for each event `e` of the original with
  `occurredAt < fork.createdAt` (the converged `createdAt`, after LWW has
  picked between two offline forkers), if a row with id
  `forkedEventId(fork, e)` exists in ANY state, that clone's state decides
  (live counts, tombstoned does not); otherwise the fork reads through to
  `e`. The fork's own non-clone events count as its own. `ForkEventResolver`
  already dedupes this way for counts-toward.
- Existing forks therefore evaluate exactly as today; tombstoning old clones
  is unnecessary and is not done.
- **Undo on a fork** of a pre-fork occurrence writes a tombstoned shadow row
  `forkedEventId(fork, e)` (authored); the original's event is untouched, so
  no other board changes. Late-log undo on a fork does the same.
- A fork whose type changed (`editedType`) reads only its own events.
- A fork is never re-forked, so there is no chain.
- Find-affected-boards and the sealed re-derivation include a fork's boards
  for any original event with `occurredAt < fork.createdAt` (a late log
  stamped at an ended board's `endDate`, or an offline event synced later,
  can arrive after the fork with an earlier `occurredAt`).
- `planBoardScopedFork` stops cloning events in slice 6b, after every client
  reads shadows (slice 6a).

### Correctness fixes folded in (audit Majors 2, 5; Minors)

- **One late-log tail per platform**: increment, decrement, undo and the
  compound-child fallbacks all run "cascade → re-derive sealed boards whose
  window contains `occurredAt` → refresh watchers" through one helper (iOS
  already has `reDeriveAfterLateLogWrite`; web gains the equivalent).
- **Closed-board compound late log** maps a linked counting child to an
  increment on its root stamped at the board's late-log instant.
- iOS inline-wizard compounds stop carrying the derived-compound marks.
- Drafts never feed window logic; un-placing a task on a board clears its
  placement only.
- Web adapters pass `sealedAt` for compound children; the extra closed-board
  sum implementation is deleted (display = kernel).
- Decrement never completes (iOS behaviour, adopted on web).
- Late-log matching (`selectClosedBoardLateLogs`) by provenance —
  `boardId` + kind + `createdAt > board.endDate` — not by exact instant,
  which also removes the cross-zone mismatch.

### Decisions

| Question | Decision | Where it lands |
| --- | --- | --- |
| Window evaluation is device-timezone dependent (board bounds are local-ISO). | Accept and document as travel-mode divergence; late logs matched by provenance. Revisit instants / per-board offset after launch. | Slice 0 |
| Tasks tab "expired" and hub "show expired" key on a task's own window. | Re-base on placements with the two edges above. | Slice 5 |
| Linked task in the library. | "Linked to ‹counter› · ‹lifetime total›" + "goal N per board". | Slice 2 |
| Hub member model. | Members = placements; root = `isCounter` or linked or placed with an override; no stored flag written. | Slice 2 |
| Board Edit edits on a placed counter. | Goal → `targetOverride` + `targetKind`; child goal → `childTargets`; rename → `titleOverride`; structure → fork. | Slice 3a |
| Per-board title (ruling 4). | `titleOverride` on the placement. | Slice 1 |
| Kind switch vs frozen targets (ruling 5). | `targetKind` on the placement; conversion at read time; sealed boards untouched. | Slice 1 |
| Counts-toward on repointed placements. | A repointed placement on a board whose window ended before the contributor's `countsTowardSince` never credits; otherwise credits as any placement. Deterministic (converged data only), applies to counters and compounds. | Slice 4 |
| Live structure on past boards. | After a repoint, a source compound's structure and a root's templates render live on unsealed past boards. Accepted; sealed boards are protected by the gate. | Risks |
| Sweep writes on sealed boards. | Repointing a placement on a sealed board is an explicit, named exception to "sealed boards never mutate", with its own write path (`repointSealedPlacement`): deterministic content, re-derivation proven equal. | Slice 4 |

## Migration sweep (both platforms, deterministic, equivalence-gated)

Not a one-shot. A **state-based sweep** (no completion marker) that runs at
database open (GRDB `v46` / Dexie `v22` as the first trigger; slice 1's
columns are `v45` / `v21`) **and after every clean pull, after
`healMissingCompletionEvents`**, until slice 5 has shipped on both clients.
It never tombstones a task row; it only repoints placements and re-keys
rules. Cost bounds: candidates are found by marks first (rows with the three
marks, derived compounds, fork clones); the sweep exits immediately when
there are none; one uuidv5 index is built per run over `(board, root)` and
`(board, compound)` pairs pre-filtered by title, operator and threshold;
tombstoned placements are scanned only on boards that hold a marked row.

Each board is handled independently:

1. **Compute, don't trust.** Build the board's post-repoint placements in
   memory (steps 2–3), then run the kernel before and after over the same
   event union and compare **`idx → isCompleted`, `completedTasks`,
   `completedLineIds` and status** (bounded at `sealedAt` for a sealed
   board). Titles, ids and hub membership are outside the comparison.
   **Repoint only when equal.** A refused board gets a terminal outcome in
   the same run: its marked rows have their window marks stripped and stay
   as plain linked tasks / ordinary compounds, which the slice-2 kernel
   reads over the host window; nothing else changes. Stored-snapshot drift
   on a sealed board (slice 0's date-edit check names such boards) is
   reported, not blocked on.
2. **Derived counters**: repoint each live placement to the row's
   `sharedCounterId`; `targetOverride ??= row.maxCount` (a slice-3a edit
   wins), `targetKind = row's kind`; a non-auto title (`!isAutoCounterTitle`)
   becomes `titleOverride`; bump `version`, enqueue UPDATE. **The derived row
   is not tombstoned here** (another board or compound placing it may have
   been refused); step 5 retires orphans later.
3. **Derived compounds**: find the source by **forward uuidv5 match**: for
   every candidate `(mintBoard, source)` pair in the index,
   `derivedCompoundId(mintBoard, source) == id`, which identifies both the
   source and the mint board. Then map children forward: for each source
   child `c`, `derivedTaskId(mintBoard, c.sharedCounterId ?? c.id)` must be a
   link child of the derived compound, with collapsed parts allowed (two
   source children on one root map to one derived child). **Repoint only
   when the source's operator, threshold and forward-mapped child set equal
   the derived compound's**; `childTargets` is keyed by `c.id` (collapsed
   siblings get the same target), existing slice-3a entries re-keyed from
   derived ids and preferred; a renamed derived compound's title becomes
   `titleOverride`. Otherwise the terminal outcome of step 1.
4. **Stored rules keyed by derived ids** (`BoardSource.memberRules`,
   `parts`, `excludedTaskIds`, `manualTaskVary` on templates, pools and
   drafts): re-key only rules that resolve against the source's current
   supply, in deterministic order (derived id ascending, first wins when
   several collapse onto one key). Rules are stale-inert by design, so
   without this step the user's targets and exclusions would vanish silently.
5. **Orphans**: a marked row with no live placement and no live parent link
   anywhere is tombstoned (authored).
6. Run the derivation pass for every touched board.

Convergence: content is deterministic and the gate is a pure function of
the converged inputs, so two devices sweeping the same state write the same
rows; a device that swept while stale converges on the next sweep. Position
edits racing a repoint lose at worst one move, never a square (the integrity
repair keeps one row per task).

## Sequencing

**The lockstep rule**: a client may write a field or shape only after every
client reads it and has stopped rewriting it. "Carry" is operational: the
web deploy of a slice happens only after the TestFlight build of that slice
is installed on the owner's device. Slices 3 and 6 are split so that the
"read" half ships to both clients before the "write" half.

| Slice | Scope | Retires / fixes |
| --- | --- | --- |
| **0 — Context window wins** (MERGED #627, 2026-10-16) | Kernel: when a BOARD window is present, every linked row resolves over it (`resolveDerivedCounterWindowState` / `resolveLinkedCounterDisplay`, `countsToward.stateOf`, hub member cards; TS + Swift, vectors re-pinned). **The own-stamp branch stays as the context-less fallback** until slice 5; the context-less readers are listed and vector-pinned. Plus: one late-log tail, closed-board late log for linked children, provenance-matched late logs, iOS wizard-compound parity, drafts out of the heal, web `sealedAt` for compound children, decrement latch parity, un-stamp resets `baseline`. Seal re-derivation checked over the owner's export (local script + anonymised fixture) before merge. | Audit Majors 1, 2, 3, 5 and the read side of 4; five Minors. No migration. |
| **1 — Placement fields** (MERGED #628, 2026-10-16) | `BoardTask.targetOverride` / `targetKind` / `childTargets` / `titleOverride` in shared types + Zod (per-field catch) + the shared `normalizePlacementFields` normaliser (vector-pinned, applied after the web pull parse and in the iOS decoder), GRDB `v45` (no Dexie bump — unindexed), canonical JSON for the array, sync contract clearable fields (TS + Swift map), fixture regen. Inert: no reader, no writer. | — |
| **2a — Kernel reads placements** (MERGED #629, 2026-10-17) | `resolveSquareState`, `placementTitle`, `withPlacementParams` / `withChildTarget`; the derivation pass, cells, previews, late-log selectors and sealed re-derive read the placement; one completion rule in `windowStampedDerivedState`. Vectors: `placementParamsVectors` (new), `derivationPassVectors` extended. | Two completion rules on the kernel path; display ≠ kernel on the play surfaces. |
| **2b — Hub, arrivals, library, credits and supply on placements** (MERGED #630, 2026-10-17) | Counters hub re-modelled: a card IS a placement (`boardTaskId`, `viaCompoundId`; the root's placements + its linked tasks' placements + the placements of their parent compounds at the `childTargets` goal; an unplaced task has no card — owner ruling 2026-10-17); root rule (c) "placed with a `targetOverride`" in `sharedCounterRootIds(tasks, boardTasks)`; arrivals and the iOS library family row use the same rule; counts-toward credits and the Counter Detail "Counts toward" rows score each placement with its parameters; the Sources sheet supply scores "done" at the placement's goal. Vectors: hub-group vectors re-pinned + 3 placement cases, 2 credits cases. `pickPrimaryBoard` stays only for the counts-toward row's representative board. | `pickPrimaryBoard` in the hub; task-level hub cards; lifetime rows for unplaced members. |
| **2c — Reachability + context-less readers** (PR open 2026-10-17 — see §Slice 2c) | `placementsReachedByRoot` replacing `withWindowStampedDerived` / `expandToWindowStampedDerived` / iOS `boardIdsReachedByTasks` in the pull cascade, sealing, late log and the heal; `resolveLinkedCounterDisplay` as a thin wrapper over the kernel; library lifetime from events for the context-less readers; the web library family row reads rule (c) (it stays lookup-only until then). | `withWindowStampedDerived`; the context-less `maxCount ?? 0` completion read. |
| **3a — Writers stop minting (both clients)** (MERGED #638, 2026-10-18) | Delete the heal, its post-pull sweep and the choke points' resolve step; Board Edit writes overrides / `childTargets` / `titleOverride` instead of forking; copy-writers (Repeat, board-source pulls, core next-window) resolve derived rows at write time; `BoardSourceSupplyInfo` carries the effective goal. | The heal, `placementNeedsCopy`, fork-on-goal-edit. |
| **3b — Planner emits placements** (MERGED #639, 2026-10-18) | `planDerivedTasks` output shape; wizard persist, spawn, quick-add write parameters. Gated on both clients carrying 3a. | Minting paths. |
| **4 — Migration sweep** (4a PR open 2026-10-18; 4b next) | The gated sweep above, at open and after every pull; seal re-derivation vectors; counts-toward boundary; `repointSealedPlacement`. | Every derived row that can be repointed safely; the rest stripped to plain rows. |
| **5 — Retire the machinery** | Delete propagation, freeze, baseline refresh, derived deletion cascades, three-mark predicates, task-window kernel inputs, the own-stamp fallback; clear stamped rows' window fields; re-base the expired filters; drop the sweep once both clients carry it and the fixture shows **no marked rows**; docs: replace the `CLAUDE.md` Windowed Completion paragraph with the model statement and move its history into an ADR log in `WINDOWED_COMPLETION.md`; `BOARD_SOURCES.md` §Member rules rewritten in placement terms. | The four derived-row invariants. |
| **6a — Forks read shadows (both clients)** | Kernel: shadowing-clone rule, undo writes shadow tombstones, affected-boards walk includes forks. | — |
| **6b — Forks stop cloning** | `planBoardScopedFork` stops cloning events. Gated on both clients carrying 6a. | Duplicate occurrences in the log. |

Slice 0 is independent and ships first. Slices 1, 2 and 3a are additive and
merge one at a time; 3b after both clients carry 3a. Slices 4 and 5 are the
cut-over; 6a/6b can ride alongside 4/5.

## Slice 2c — detailed scope (2026-10-17)

Mapped against the code after 2b. Today's expansion
(`expandToWindowStampedDerived`) already adds every live linked row of a root
(hub-linked and window-stamped alike, owner rule 2026-10-01), so the reach is
right; what changes is one helper with the right output shape, the
display/kernel split, the context-less readers, and three parity defects.

1. **`placementsReachedByTasks(ids, lookups)` + `placementsReachedByRoot(rootId, lookups)`**
   (shared `derivationPass.ts` ↔ `DerivationPass`), returning
   `{ taskIds, boardIds, placements }`: each id itself, every live task whose
   `sharedCounterId` is that id (derived rows included until slice 5), their
   transitive parent compounds (deleted links AND deleted compound tasks
   skipped), and the live placements of all of those. `taskIds` stays the
   cascade input (counts-toward runs off it); `boardIds` feeds sealed
   re-derive and watchers; `placements` serves the hub. Replaces every reach
   site: web `withWindowStampedDerived` (deleted) and `resolveAffectedBoardIds`'
   body, `sealing.reDeriveSealedBoardsForTasks`, `taskEvents.getSealImmuneWindowsForTask`,
   `lateLog.applyLateLogSideEffects`, `taskEventPull` (batch + heal backfill),
   `linkedCounterWindowHeal`; iOS `withWindowStampedDerived`,
   `boardIdsReachedByTasks`, `sealImmuneWindows`, `reDeriveSealedBoards`,
   `PullApply` (batch, backfill, watchers). `expandToWindowStampedDerived` is
   deleted; its four vectors move to a `placementsReached` section with new
   cases (compound parent of a linked child, a root's own override placement,
   deleted link / compound / placement, non-root pass-through, a linked row's
   own id).
2. **Parity defects fixed here:** the web Sources supply loader
   (`supplyEventTaskIds`) loads the root's events for EVERY counting linked
   row, not only window-stamped ones (iOS already does; hub-linked supply was
   never "done"); the iOS heal re-derives touched roots' boards like web.
   The increment / undo paths' frozen-row narrowing (`isFrozenRowReachedByEvent`)
   is untouched — it is retired machinery (slice 5).
3. **Display = kernel.** `resolveLinkedCounterDisplay(task, events, sealedAt?, window?, placement?)`
   becomes a thin wrapper over `resolveSquareState` (optional placement;
   `sealedAt` applied through `boundWindowContextAtSeal`). Re-pin
   `linkedCounterDisplay` vectors.
4. **Context-less readers read events, not the latch or `baseline`.** New
   shared `contextlessCounterState(task, tasksById, eventsByTaskId)` ↔ Swift:
   a linked row reads its ROOT's lifetime increment sum; a root / plain
   counter its own; complete iff `maxCount != null && sum >= maxCount`
   (never green at 0). The kernel's context-less linked branch
   (`resolveSquareState` with no board window) and `resolveLinkedCounterDisplay`'s
   fallback use it, so the `currentCount − baseline` display and the latch are
   no longer read by any board, preview or library surface. Library readers
   (web `taskCountDisplay`, `useTasksFilters` in-progress / completed; iOS
   `TaskCountDisplay`, `TasksTabViewModel`) use it. **Library rows carry no
   progress** (Task Detail redesign binding decision 2; the rework's
   "Linked to ‹counter› · ‹lifetime total›" row copy is superseded by the
   no-provenance-copy rule — rows already carry the counter tag): the web
   row's "cur / max" / "Completed" status label is removed (iOS shows none).
   `countsToward.stateOf`'s latch keeps reading the latch until slice 5 but
   stops treating a goal-less linked row as complete (`maxCount != null`
   required) — the credit set must not move otherwise. Writers
   (`propagateIncrement`) are untouched.
5. **Web library family row on rule (c):** `familyRootIds` computed from
   `sharedCounterRootIds(tasks, boardTasks)` in the browse hook
   (`useBrowsableTasks`), fed to TasksPage and the wizard Library sheet;
   `useTaskLibrary` stays lookup-only.

**Gate 1 rulings (2026-10-17):** (a) the hub is rewired onto the reach
helper now — `buildSharedCounterGroups` consumes `placementsReachedByRoot`'s
`placements` (member placement + `viaCompoundId`) instead of its own parent
walk, so the hub, the cascade and the sealed re-derive share ONE reach;
(b) the library's context-less readers load the whole workspace event log
(the existing `eventsByTaskId` loaders), not a roots-only subset.

**Implementation notes (2026-10-17, as built):** the reach's `taskIds` is the
seeds plus their live linked rows — parent compounds are returned separately
as `compoundIds` (the cascade already walks parents itself and counts-toward
must not see a compound twice); `resolveLinkedCounterDisplay` with NO event
map reads as no events (`0`, incomplete) — every caller supplies the map;
`contextlessCounterState(task, eventsByTaskId)` needs no task lookup (the
owner is `sharedCounterId ?? id`); web `familyRootIds` leaves `TaskLibrary`
for a sibling browse hook (`useBrowseFamilyRootIds`), which subscribes to
`boardTasks` like `useBrowsableTasks` does.

**Slice 3a Gate 1 rulings (2026-10-18):** (a) Repeat's copy of a placement's
frozen override and title defers to 3b — a `RecurringBoardTemplate` has no
per-task target field, and 3b adds it next to the planner's placement
output; 3a's Repeat records an overridden root placement by its root id, as
it already records a derived counter. (b) Board Edit parameter edits (goal,
title, a compound child's goal) ALWAYS land on the placement — the library
keeps the task's own goal and title; Task Detail / Tasks-tab edits stay
global. (c) A mixed Save splits: parameter fields go onto the `BoardTask`,
every other field (action, unit, kind, type, structure) takes the existing
board-scoped path and forks only when the task is placed elsewhere.
`wouldForkOnBoard` is unchanged (its vectors stand); the sheet label and the
commit decide fork-or-not from the patch's non-parameter fields. There is no
separate "core next-window" writer in the code — core windows go through the
wizard prefill, so that item is covered by the supply's effective goal.
(d) Folded in: the closed-board late log's "hub-linked derived counter is a
no-op" rule (OQ2) is retired on both platforms — since slice 0 every linked
square resolves over its board's window, and since 3a a linked placement is
never stamped, so a late log on ANY linked square authors on its root at the
board's `endDate` and the sheet routes to it (`lateLogIncrement`,
`undoLateLog`, `readClosedBoardSquareState`, `isLateLogRoutable` ↔
`lateLogEventOwningTaskId`).

**Slice 3b Gate 1 rulings (2026-10-18):** (a) the wizard's quick-add of a
shared counter places the ROOT with a placement override — no per-board copy
row is minted; (b) a hand-added counter row's edited goal (and the member-rule
target stepper's result) is a placement override too — `counterRowEditCopy` /
`restampPendingCounterCopy` and their pending-copy rows are retired; the
wizard carries per-cell placement parameters in its state and persist writes
them. Drafts keep placing original ids with no parameters; parameters are
planned at the activating save, as the mint was. `RecurringBoardTemplate`
gains `manualTaskTargets` (per hand-added task: target, kind, optional title)
so Repeat copies a placement's frozen override and spawn applies it to
hand-added members; sourced members re-plan from rules. Merging 3b is not
lockstep-gated (both clients read every placement field since 2a); the WEB
DEPLOY of 3b waits for the TestFlight build carrying 3a.

**Slice 3b implementation notes (2026-10-18, as built):** the planner's
`param` rule emits `targetOverride` only when the rolled target differs from
the PLACED task's own goal, which subsumes the old "no identical clone"
shortcut; a hand-added linked member is placed as itself (no per-window copy,
the kernel reads the host window), so a stale stored title on such a member
now renders as stored rather than through the root's templates until the
root's next propagation (`counterPlacementVectors` "a hand-added linked row
keeps its own goal" re-pinned); two split parts sharing one root no longer
collapse onto one square — each child rolls its own target (one
`memberRuleVectors` rng count re-pinned); a pool source's stray `goalByTaskId`
is ignored (board sources only). The old-vs-new equivalence check (every
former draft's `maxCount` == the placement's effective goal, titles through
`placementTitle`) held for every other vector.

**Slice 4 Gate 1 rulings (2026-10-18):** (a) two PRs — 4a repoints derived
COUNTERS (plus rule re-keys, orphans, the sealed write path, the triggers and
the counts-toward boundary), 4b repoints derived COMPOUNDS by forward uuidv5
matching with `childTargets`; both land before slice 5. (b) The anonymised
owner fixture comes from a dev-only "Export anonymised workspace" action on
the web Developer settings (ids hashed, titles replaced) that the owner runs
after a clean pull and commits under `packages/shared/tests/fixtures/`; a
Jest test runs the sweep planner over it and asserts no sealed board's
re-derivation changes. (c) The sweep runs on EVERY app open and after every
clean pull (idempotent, exits fast with no marked rows); GRDB v47 / Dexie v21
are only the first open.

**Slice 4a implementation notes (2026-10-18, as built):** orphans are the
marked rows that were unplaced and unlinked BEFORE a run — a row a run
repoints away from retires on the NEXT run (after the pull has converged
every device's placements), so two devices never race a tombstone against a
placement; a row repointed on one board and refused on another is not
stripped in that run (the next run settles it once nothing repoints it);
the gate compares cell completion, `completedTasks` and sorted bingo lines
(stored `status` is not part of it); the owner fixture keeps ids verbatim
(UUIDs carry no personal data and 4b's forward uuidv5 match needs the real
pairs) and anonymises text only.

## Acceptance

- After slice 5: `grep` finds no non-test reference to `isWindowStampedDerived`,
  `isFrozenDerivedRow`, `refreshDerivedBaselines`, `propagateIncrement`,
  `planLinkedCounterWindowHeal` or `placementNeedsCopy` in `apps/` or
  `packages/shared/src`; `derivedTaskId` / `derivedCompoundId` survive only
  in the sweep until it is dropped.
- The #624 scenario as a vector on both platforms: a daily series re-places
  one compound with a linked counting child, and the child completes on
  every spawn from logs inside each day's window.
- An increment writes exactly one `tasks` row for the root's lifetime cache
  plus whatever the counts-toward credit path writes for contributors; no
  linked-row writes, no sync items for copies.
- The anonymised owner fixture (committed; produced by a local export
  script) shows no sealed board whose kernel re-derivation changes across
  the sweep, and after slice 5 **no marked rows**.
- The Counters hub shows one card per placement with the placement's goal
  and title, on both platforms, before and after the sweep.
- Fork vectors: read-through with and without shadows, undo of a pre-fork
  occurrence, a late log arriving after the fork.
- Counts-toward vectors: no retroactive credit on a repointed placement of
  an ended board.
- A two-client skew test per split slice (3a/3b, 6a/6b): the older client's
  reads of the newer client's rows are correct.
- Every exported function of the kernel modules (`taskEvents`,
  `compoundEvaluation`, `derivationPass`, `memberRules`, `placementResolution`,
  `boardScopedFork`, `countsToward`) is covered by a vector suite run by Jest
  and the Swift twin (CI guard, new).
- `CLAUDE.md` §Windowed Completion is the model paragraph plus links, not a
  list of amendments.

## Risks

- **Scope**: nine PRs across both platforms touching the four ~14k-line
  layers. Mitigation: slices 0–3a are additive and individually revertible;
  the cut-over is two PRs; the sweep is gated and skippable per board with a
  terminal outcome.
- **Member-rule inputs**: a board-sourced member's goal changes meaning
  (placement's effective goal, not a derived row's). Mitigation: explicit
  new vectors; existing vectors re-expected by hand.
- **Semantics that move from snapshot to live**: a source compound's
  structure and a root's title templates render live on unsealed past
  boards after a repoint. Accepted; the gate protects sealed boards and
  refuses a repoint that would change a live board's state.
- **Two-client skew**: the deployed web app and the TestFlight iOS build can
  be on different slices. Mitigation: the lockstep rule with split slices;
  the sweep runs after every pull so late-minted rows are still converted.
- **One LWW row for position, lock, goal and title**: edits on two devices
  now conflict where they did not before. Accepted for a single user; noted
  for a future per-field merge if it ever matters.
- **The twin cost**: every slice is TS + Swift. Mitigation: the plan/apply
  pattern (shared kernel returns `{writes, enqueues, cascadeBoardIds}`, data
  layers apply) is adopted for every write path touched, so vectors pin the
  decisions and the Swift side becomes a dumb applier.
