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
sequencing: merge #624 / #625, then this design doc, then `/feature` slices.

Revision 2 (2026-10-16) folds in the internal design review of PR #626: the
fork read-through rule, the Counters-hub re-model, no duplicate placements,
heal retirement moved to slice 3, an equivalence-gated post-pull migration
sweep, the member-rule input change, counts-toward, titles, and the wire
shape of `childTargets`.

## The model, stated once

> A **Task** is a library definition (structure, default goal). A
> **Placement** (`BoardTask`) puts a task on a board's grid and may carry
> per-board parameters (lock, target override, child targets). **Events**
> (`task_events`) are the only authored record of what happened; only
> event-owning tasks (Normal, plain or root Counting) have them, and a linked
> counter reads its root's events. **A square's state is a pure function of
> the task structure, the placement's parameters, and the event owner's live
> events with `occurredAt` inside the board's window
> `[startDate, min(endDate, sealedAt)]`.** Compounds evaluate their children
> over the same host window; Achievements evaluate watched boards over it.
> Everything stored on a Task about completion is a cache for context-less
> (library) readers and is never read by a board. A sealed board stores a
> snapshot that must equal that function over the converged event union. Logs
> from a board's own surface after its end are stamped `min(now, endDate)`;
> logs from anywhere else are stamped `now`.

Every current invariant in `CLAUDE.md` §Windowed Completion follows from this
paragraph except the derived-row ones (freeze, baseline, stamp, heal). The
rework is done when those four no longer exist.

## Why the current shape fails

The model has no place to put a per-board parameter. Every per-board
difference (a counter's window target, a vary roll, a split part, a per-board
goal default) becomes a new `Task` row, and that row then needs machinery to
stay in sync with the library row it shadows:

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
   * A counting placement's goal for THIS board (owner ruling 2026-10-16:
   * frozen when the board is made or the square is edited). Absent ⇒ the
   * task's own `maxCount`. Carries the wizard's window-pro-rated auto target,
   * a Vary roll, a Split-up part's share, or the root's timeframe default.
   * Positive and step-aligned for the root's count kind (never 0: a goal of
   * 0 would be "green at 0").
   */
  targetOverride?: number;
  /**
   * A compound placement's per-child goals for THIS board. An ARRAY of
   * `{ childId, target }`, keyed by the compound's own child task ids
   * (a linked child is keyed by its own id, not its root). Absent ⇒ each
   * child's own `maxCount`. Replaces per-window derived compounds + links.
   * An array, not a map: Firestore writes are `merge: true`, and a map
   * field deep-merges, so a removed key would survive remotely; an array
   * replaces wholesale, and a whole-field clear rides the clearable-field
   * delete like any other.
   */
  childTargets?: { childId: string; target: number }[];
}
```

- Both fields are optional and absent on every existing row (forward-compat
  decode like `isLocked`). They join `CLEARABLE_FIELDS_BY_COLLECTION.boardTasks`
  (TS constant, Swift map, regenerated `syncContract.json`, C4 fixture pins
  the wire shape). `firestore.rules` checks only `id` / `version` keys and
  `userId`, so no rules change. Zod: `targetOverride > 0`, 2-dp quantized;
  each `childTargets[].target` likewise; `childId`s unique.
- A placement points at the **library entity**: the counter root, the user's
  hand-made linked task, or the source compound. Nothing is minted at
  placement time.
- **One placement per (board, task) stays invariant.** `computePlacementIntegrityRepair`
  tombstones same-task duplicates on pull, deterministically, and that is
  kept. Split-up parts that share one root collapse to one placement
  (today's R13 rule: the first part's roll wins); parts on different children
  are different task ids and need no duplicates.
- A target edit, a shuffle and a lock now share one LWW row. For a single
  user this is acceptable; noted under Risks.

### One resolution rule

`resolveSquareState(task, placement, window, eventsByTaskId)`:

- **Event owner**: the task itself for Normal / plain / root Counting; the
  root for a linked task (`sharedCounterId`); for a fork, the rule in §Forks.
- **Window**: the host board's `[startDate, min(endDate, sealedAt)]`, always.
  A task's own `startDate` / `endDate` / `timeframe` are never read by a
  board (they are retired, see below).
- **Goal**: `placement.targetOverride ?? task.maxCount`; a compound child's
  goal is the parent placement's `childTargets` entry for that child, else
  the child's own `maxCount`. The kernel finalizes the goal for the root's
  CURRENT count kind at read time (`finalizeWindowCount` on the goal), so a
  kind switch never rewrites placements (and never touches sealed boards).
- **Completion**: one rule for every counting shape — complete iff a goal
  exists and `count >= goal` (closes the audit's two-rules finding: a
  goal-less linked row is never "green at 0").
- Compounds recurse with the same window and the parent placement's
  `childTargets`; Achievements keep their watched-board rule.
- **Title**: a shared `placementTitle(task, placement, root)` renders a
  counting square's title through the root's templates at the placement's
  goal (today's `counterCopyTitle`), used by every square-title surface
  (cells, poster, previews, late-log sheet, Task Detail usage, arrivals).

`resolveLinkedCounterDisplay` becomes a thin wrapper over this rule (display
= kernel, by construction). `countsToward.stateOf` and the Sources sheet's
`resolveBoardSourceSupply` (done-filter, `windowCountByTaskId`) read the same
rule with the placement. Context-less readers (library, a hub card with no
board) compute lifetime from events: a root's lifetime sum; a linked task
shows "Linked to ‹counter› · ‹lifetime total›" plus "goal N per board" (its
`maxCount` remains the default placement goal).

### Counters hub, arrivals and the library family row

Today a counter is a "root" only because some live task links to it
(`sharedCounterRootIds`), and the hub's member cards ARE linked tasks. After
the migration a board-born root may have no linked task left, so the hub
must be re-modelled in slice 2, before any repoint:

- **Members = placements**: a root's direct placements plus the placements
  of every task linked to it (reached through compound parents too). One
  card per placement, with the placement's goal and the host board's window;
  `pickPrimaryBoard` goes away.
- **Root detection** gains: a counting task placed with a `targetOverride`,
  or placed on more than one board, or `isCounter`. The migration also sets
  `isCounter = true` on every root it repoints to, so detection does not
  depend on the heuristic.
- Arrivals (`useCounterArrivals` ↔ Swift) and the library family row use the
  same root set and placement members. Vectors pin hub groups before and
  after the migration on the owner's export.

### Writers emit parameters, not rows

- `planDerivedTasks` returns `placements: { taskId, targetOverride?, childTargets? }[]`
  instead of `derivedTasks` / `derivedCompounds` drafts. The member-rule
  maths (auto target, vary, split, pool default dice, timeframe defaults)
  is unchanged in form, but **one input changes**: a board-sourced member's
  goal (`goalOf`) must be the supplied placement's effective goal
  (`targetOverride ?? maxCount`), which `BoardSourceSupplyInfo` now carries;
  today it reads the derived row's frozen `maxCount`, and reading the root's
  goal instead would pro-rate from 300 rather than 70. New vectors pull from
  a board that holds overridden placements; the existing `memberRuleVectors`
  are re-expected by hand against that rule, not mechanically.
- Wizard persist, recurring spawn, Board Edit add / replace, quick-add and
  the two placement choke points all write the same `BoardTask` shape. The
  choke points' "resolve to this board's own row" step is deleted in slice 3,
  together with the heal (see §Sequencing).
- **Board Edit edits on a placed counter**: a goal edit writes
  `targetOverride`; a compound child's goal edit writes `childTargets`;
  only a title or structure edit forks (`wouldForkOnBoard` and its vectors
  change in slice 3). Without this, every goal edit on a root placement would
  fork the root and the next spawn's pull from that board would supply
  nothing (forks are excluded from source supply).
- Recurring templates keep storing sources and member rules; spawn resolves
  them into placement parameters per window. **Repeat this board copies a
  placement's frozen override** (ruling 1); spawn re-plans from rules.
- Hand-added compound children get the same per-child goal treatment as
  pulled ones.
- Counts-toward credits at the placement's goal (`crossingEvent` reads the
  placement, compounds read `childTargets`).

### Retired

- Window-stamped derived counters, derived compounds and derived links; the
  three-mark predicate `isWindowStampedDerived`, `isWindowStampedDerivedCompound`,
  `isMintedForBoard`, `isBoardArtifact`, `derivedTaskId` / `derivedCompoundId`
  / `derivedLinkId` minting (the id functions remain for the migration's
  matching only).
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
  copies, count-kind switch fan-out to copies (the kernel finalizes goals
  per kind at read time instead).
- `planLinkedCounterWindowHeal`, its data layers and the post-pull sweep
  (slice 3), and the v18/v20 ↔ v37/v44 re-runs (migration history stays).
- `propagateIncrement`, `writeLinkedRowPropagation`, `isFrozenDerivedRow`,
  `isFrozenRowReachedByEvent`, `reachedFrozenIds`, `refreshDerivedBaselines`,
  `computeWindowBaseline` and the `baseline` field as a read input (column
  kept inert like `lastSyncedCount`); `deleteCounterWithUnlink` seeds the
  unlinked member's snapshot from events, not `currentCount − baseline`. An
  increment is one event write plus one cascade.
- Derived-row deletion cascades (`softDeleteWindowStampedDerived`,
  `windowStampedDerivedOrphanedByBoard`); `deleteCounterWithUnlink` only
  unlinks.
- `tasks.timeframe` / `startDate` as clearable sync fields (added by #624)
  once no writer clears them (after slice 5).

### Forks (owner ruling 2)

Board-scoped forks stay real `Task` rows (title, structure and action
genuinely diverge). The fork is an independent event owner for everything
logged after it exists, so "read the original's events" must be precise:

- **Read-through**: a fork's events are the original's events with
  `occurredAt < fork.createdAt` (following `forkedFromTaskId` to the end of
  the chain, each hop bounded by that hop's `createdAt`), unioned with the
  fork's own events. Writers keep writing to the fork's id. This is the
  D4(b) option in `BOARD_SCOPED_TASK_EDITS.md`, chosen now.
- A fork whose type changed (`editedType`) reads only its own events; the
  original's are of a kind its type cannot own.
- Find-affected-boards and the sealed re-derivation walk forks in both
  directions (an original's new event never reaches a fork, but a tombstoned
  pre-fork event does).
- `planBoardScopedFork` stops cloning events. Existing clones are tombstoned
  by the migration (deterministic `forkedEventId`) **only under the
  read-through rule above**, and only when the board's re-derivation is
  unchanged (the equivalence gate).

### Correctness fixes folded in (audit Majors 2, 5; Minors)

- **One late-log tail per platform**: increment, decrement, undo and the
  compound-child fallbacks all run "cascade → re-derive sealed boards whose
  window contains `occurredAt` → refresh watchers" through one helper (iOS
  already has `reDeriveAfterLateLogWrite`; web gains the equivalent).
- **Closed-board compound late log** maps a linked counting child to an
  increment on its root stamped at the board's late-log instant.
- iOS inline-wizard compounds stop carrying the derived-compound marks
  (moot once the predicate is gone, fixed in slice 0 anyway).
- Drafts never feed window logic; un-placing a task on a board clears its
  placement only.
- Web adapters pass `sealedAt` for compound children; the extra closed-board
  sum implementation is deleted (display = kernel).
- Decrement never completes (iOS behaviour, adopted on web).
- Late-log matching (`selectClosedBoardLateLogs`) by provenance —
  `boardId` + kind + `createdAt > board.endDate` — not by exact instant (a
  sealed board authors no event; a direct late log happens before any seal
  or Reopen), which also removes the cross-zone mismatch.

### Decisions

| Question | Decision / recommendation | Where it lands |
| --- | --- | --- |
| Window evaluation is device-timezone dependent (board bounds are local-ISO). | Accept and document as travel-mode divergence; late logs matched by provenance (above). Revisit instants / per-board offset after launch. | Slice 0 |
| Tasks tab "expired" and hub "show expired" key on a task's own window. | Re-base on placements with the two edges above. | Slice 5 |
| Linked task in the library. | "Linked to ‹counter› · ‹lifetime total›" + "goal N per board". | Slice 2 |
| Hub member model. | Members = placements; root detection widened; migration sets `isCounter`. | Slice 2 |
| Board Edit goal edit on a placed counter. | Writes `targetOverride` / `childTargets`; never forks. | Slice 3 |
| Repointed derived compounds and counts-toward. | A derived compound never copied `countsTowardCounterId`; after a repoint to a flagged source, credit only occurrences at or after the migration instant (`countsTowardSince` semantics), never retroactively. Pinned by a vector. | Slice 4 |
| Live structure on past boards. | After the repoint, a source compound's structure and a root's templates render live on every unsealed past board (the derived rows used to snapshot them). Accepted; sealed boards are protected by the equivalence gate. | Risks |

## Migration (both platforms, deterministic, equivalence-gated)

Not a one-shot. A **state-based sweep** (no completion marker) that runs at
database open (GRDB `v45` / Dexie `v21` as the first trigger) **and after
every clean pull**, until slice 5 has shipped on both clients; it keys on
every placement → task pair in any state, including tombstoned, so rows
minted by a not-yet-upgraded client are still converted when they arrive.
Each board is handled independently:

1. **Compute, don't trust.** Build the board's post-repoint placements in
   memory (steps 2–4), then run `computeBoardGrid` before and after over the
   same event union. **Repoint only when the two are equal** (live boards:
   cell states and stats; sealed boards: equal to `sealedCompletedCells`).
   Otherwise leave the board's rows untouched; slice 2 already reads leftover
   derived rows correctly as plain linked tasks over the host window, so a
   skipped board is correct, merely uncleaned. The gate is the answer to
   "what if the snapshot assertion fails on a device": nothing changes.
2. **Derived counters**: repoint each live placement to the row's
   `sharedCounterId`, set `targetOverride = row.maxCount` (folding a
   later-version edit of the row's `maxCount` if one has arrived), bump
   `version`, enqueue UPDATE; tombstone the derived row (authored). A derived
   row whose title differs from the regenerated copy title (a Board Edit
   rename) is kept as a fork of the root instead of losing the rename.
3. **Derived compounds**: recover the source by **uuidv5 match**
   (`derivedCompoundId(board, candidate) == id` over every compound in the
   workspace, live or tombstoned), following chains (a daily pulled from
   yesterday's daily derives from a derived compound) to a non-derived
   source. Build `childTargets` keyed by the source's child ids
   (`child.sharedCounterId ?? child.id` maps each derived child back).
   **Repoint only when the source's operator, threshold and mapped child set
   equal the derived compound's**; otherwise strip the derived compound's
   window marks and keep it as an ordinary compound (correct under the
   slice-2 kernel).
4. **Stamped-in-place hand-made rows** (three marks, id ≠ any
   `derivedTaskId`): no override write (absent already means `maxCount`);
   the window fields are cleared in slice 5 with the filter re-base.
5. **Stored rules keyed by derived ids**: re-key `BoardSource.memberRules`,
   `parts`, `excludedTaskIds` and `manualTaskVary` on templates, pools and
   draft boards from derived ids to their repoint targets (child-id keys to
   source child ids). Rules are stale-inert by design, so without this step
   the user's targets and exclusions would vanish silently.
6. **Fork event clones**: tombstone events whose id matches
   `forkedEventId(fork, original)`, under the read-through rule and the
   equivalence gate.
7. **Roots**: set `isCounter = true` on every root a placement was repointed
   to.
8. Run the derivation pass for every touched board. Orphaned derived rows
   (no live placement, no live parent link) are tombstoned.

Convergence: content is deterministic and the gate is a pure function of
the converged inputs, so two devices sweeping the same state write the same
rows; a device that swept while stale converges on the next sweep after the
pull that brings the rest. Position edits racing a repoint lose at worst one
move, never a square (the integrity repair keeps one row per task).

## Sequencing

**Lockstep rule**: every slice deploys to the web app and the iOS TestFlight
lane together, and no writer slice (3 onward) ships until both clients carry
slice 1. The owner's two clients are the only version-skew exposure, and a
client on an older build would run the heal and the choke-point resolve
against new-shape data.

| Slice | Scope | Retires / fixes |
| --- | --- | --- |
| **0 — Context window wins** | Kernel: when a host window is present, every linked row resolves over it (`resolveDerivedCounterWindowState` / `resolveLinkedCounterDisplay`, `countsToward.stateOf`, hub member cards; TS + Swift, vectors re-pinned). **The own-stamp branch stays as the context-less fallback** until slice 5, so a hub card or a compound-only derived child with no board still answers from its stamp rather than the latch. Plus: one late-log tail, closed-board late log for linked children, provenance-matched late logs, iOS wizard-compound parity, drafts out of the heal, web `sealedAt` for compound children, decrement latch parity, un-stamp resets `baseline`. Seal re-derivation checked over the owner's export before merge (a board whose dates were edited after minting re-derives differently; the check names any such board). | Audit Majors 1, 2, 3, 5 and the read side of 4; five Minors. No migration. |
| **1 — Placement fields** | `BoardTask.targetOverride` / `childTargets` in shared types + Zod, Dexie (unindexed) and GRDB column, sync contract clearable fields (TS + Swift map), fixture regen. Inert: no reader, no writer. | — |
| **2 — Kernel reads placements** | `resolveSquareState`, `placementTitle`; derivation pass, cells, previews, hub (re-modelled on placements), arrivals, library family row, counts-toward, Sources sheet supply, sealed re-derive and the late-log selectors read the placement; one completion rule; `resolveLinkedCounterDisplay` becomes a wrapper; library lifetime from events. Vectors: `derivationPassVectors`, `taskWindowStateVectors`, `memberRuleVectors` extended with placement params; hub-group vectors. Leftover minted rows read as plain linked tasks over the host window. | Two completion rules; display ≠ kernel; latch reads; `pickPrimaryBoard`. |
| **3 — Writers emit placements** | `planDerivedTasks` output shape + `BoardSourceSupplyInfo` effective goal; wizard persist, spawn, Board Edit add/replace (goal edits write overrides), quick-add; **the choke points' resolve step, the linked-window heal and its post-pull sweep are deleted here**, not in slice 5, or new placements would be re-stamped and re-minted on the next pull. | Minting paths, `placementNeedsCopy`, the heal. |
| **4 — Migration sweep** | The equivalence-gated sweep above, at open and after every pull; seal re-derivation vectors; counts-toward credit boundary. | Every derived row in existing data that can be repointed safely. |
| **5 — Retire the machinery** | Delete propagation, freeze, baseline refresh, derived deletion cascades, three-mark predicates, task-window kernel inputs; clear stamped rows' window fields; re-base the expired filters; drop the sweep once both clients carry it and the owner's export shows no derived rows; docs: replace the `CLAUDE.md` Windowed Completion paragraph with the model statement and move its history into an ADR log in `WINDOWED_COMPLETION.md`; `BOARD_SOURCES.md` §Member rules rewritten in placement terms. | The four derived-row invariants. |
| **6 — Forks read through** | Kernel read-through rule; `planBoardScopedFork` stops cloning events; affected-boards walk; clone tombstones ride the slice-4 sweep. | Duplicate occurrences in the log. |

Slice 0 is independent and ships first. Slices 1–3 are additive and merge one
at a time (3 after both clients carry 1). Slices 4 and 5 are the cut-over.

## Acceptance

- `grep` finds no non-test reference to `isWindowStampedDerived`,
  `isFrozenDerivedRow`, `refreshDerivedBaselines`, `propagateIncrement`,
  `planLinkedCounterWindowHeal` or `placementNeedsCopy` in `apps/` or
  `packages/shared/src`; `derivedTaskId` / `derivedCompoundId` survive only
  in the migration sweep until it is dropped.
- A daily series that re-places one compound with a linked counting child
  completes that child on every spawn from logs inside each day's window
  (the #624 scenario, as a vector on both platforms).
- An increment writes exactly one `tasks` row (the root's lifetime cache) and
  one event; no linked-row writes, no sync items for copies.
- No sealed board's `sealedCompletedCells` changes across the migration on
  the owner's export (the gate guarantees it; the test proves it).
- The Counters hub shows one card per placement with the placement's goal,
  on both platforms, before and after the sweep.
- Every exported shared-algorithm function in the kernel is covered by a
  vector suite run by Jest and the Swift twin (CI guard, new).
- `CLAUDE.md` §Windowed Completion is the model paragraph plus links, not a
  list of amendments.

## Risks

- **Scope**: seven slices across both platforms touching the four ~14k-line
  layers. Mitigation: slices 0–3 are additive and individually revertible;
  the cut-over is two PRs; the sweep is gated and skippable per board.
- **Member-rule inputs**: a board-sourced member's goal changes meaning
  (placement's effective goal, not a derived row's). Mitigation: explicit
  new vectors; existing vectors re-expected by hand.
- **Semantics that move from snapshot to live**: a source compound's
  structure and a root's title templates render live on unsealed past
  boards after a repoint. Accepted; the equivalence gate protects sealed
  boards and refuses a repoint that would change a live board's state.
- **Two-client skew**: the deployed web app and the TestFlight iOS build can
  be on different slices. Mitigation: the lockstep rule; the sweep runs after
  every pull so late-minted rows are still converted.
- **One LWW row for position, lock and goal**: a target edit and a shuffle
  on two devices now conflict where they did not before. Accepted for a
  single user; noted for a future per-field merge if it ever matters.
- **The twin cost**: every slice is TS + Swift. Mitigation: the plan/apply
  pattern (shared kernel returns `{writes, enqueues, cascadeBoardIds}`, data
  layers apply) is adopted for every write path touched, so vectors pin the
  decisions and the Swift side becomes a dumb applier.
