# Task/window rework — per-placement parameters (2026-10 → )

Owner-decided direction for the task/window core after the 2026-10-16
architecture audit (claude.ai artifact "Task Window Audit"; memory
`project_audit_task_window_2026_10`). The audit followed the PR #624 incident:
a compound's linked sub-task, stamped with the window of the first daily board
that carried it, read 0 of 10 on every later spawn and was frozen out of
propagation. Six more defects of the same shape were verified. This document
is the spec for removing the cause rather than the symptoms. It is written for
the pre-launch window, when the only data in the system is the owner's and no
client-version gate is needed.

Owner rulings (2026-10-16): (1) a counter's per-window target is **frozen on
the placement** when the board is made or the square is edited; (2)
board-scoped forks **stay full Task clones but stop copying events**; (3)
sequencing: merge #624 / #625, then this design doc, then `/feature` slices.

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
   */
  targetOverride?: number;
  /**
   * A compound placement's per-child goals for THIS board, keyed by child
   * task id. Absent ⇒ each child's own `maxCount`. Replaces per-window
   * derived compounds + derived links.
   */
  childTargets?: Record<string, number>;
}
```

- Both fields are optional and absent on every existing row (forward-compat
  decode like `isLocked`). They join `CLEARABLE_FIELDS_BY_COLLECTION.boardTasks`
  so clearing an override syncs. `firestore.rules` checks only `id` / `version`
  keys and `userId`, so no rules change. Zod: non-negative 2-dp numbers,
  `childTargets` values likewise.
- A placement points at the **library entity**: the counter root, the user's
  hand-made linked task, or the source compound. Nothing is minted at
  placement time.
- Several placements of one task on one board are allowed when they differ
  in `targetOverride` (Split-up parts). Their semantics are unchanged: each
  part counts the root's in-window sum against its own target, so parts
  complete in ascending-target order. The Board Edit duplicate guards become
  "same task AND same override".

### One resolution rule

`resolveSquareState(task, placement, window, eventsByTaskId)`:

- **Event owner**: the task itself for Normal / plain / root Counting; the
  root for a linked task (`sharedCounterId`); the original for a fork
  (`forkedFromTaskId`, followed to the end of the chain — owner ruling 2).
- **Window**: the host board's `[startDate, min(endDate, sealedAt)]`, always.
  A task's own `startDate` / `endDate` / `timeframe` are never read by a
  board (they are retired, see below).
- **Goal**: `placement.targetOverride ?? task.maxCount`; a compound child's
  goal is `placement.childTargets[childId] ?? child.maxCount`.
- **Completion**: one rule for every counting shape — complete iff a goal
  exists and `count >= goal` (closes the audit's two-rules finding: a
  goal-less linked row is never "green at 0").
- Compounds recurse with the same window and the parent placement's
  `childTargets`; Achievements keep their watched-board rule.

`resolveLinkedCounterDisplay` becomes a thin wrapper over this rule (display
= kernel, by construction). Context-less readers (library, Counters hub
member cards without a board) compute lifetime from events as well: a root's
lifetime sum; a linked task shows its counter and the counter's total, not a
pseudo-progress against its own goal.

### Writers emit parameters, not rows

- `planDerivedTasks` returns `placements: { taskId, targetOverride?, childTargets? }[]`
  instead of `derivedTasks` / `derivedCompounds` drafts. The member-rule
  maths (auto target, vary, split, pool default dice, timeframe defaults)
  is unchanged and stays vector-pinned; only the output shape changes.
- Wizard persist, recurring spawn, Board Edit add / replace, quick-add and
  the two placement choke points all write the same `BoardTask` shape. The
  choke points' "resolve to this board's own row" step is deleted.
- Recurring templates keep storing sources and member rules; spawn resolves
  them into placement parameters per window.
- Hand-added compound children get the same per-child goal treatment as
  pulled ones (the audit's "no member rules for hand-added children" Minor
  disappears because the goal is now a placement field either way).

### Retired

- Window-stamped derived counters, derived compounds and derived links; the
  three-mark predicate `isWindowStampedDerived`, `isWindowStampedDerivedCompound`,
  `isMintedForBoard`, `isBoardArtifact`, `derivedTaskId` / `derivedCompoundId`
  / `derivedLinkId` minting (the ids remain only in the migration).
- `Task.startDate` / `endDate` / `timeframe` as kernel inputs. The columns
  stay for decode compatibility and for the Tasks-tab "expired" filter until
  that filter is re-based on placements (E10's "task-level window columns"
  question is answered: they go).
- `createdInWizard` as a window mark. It returns to provenance only
  (draft-board library hiding).
- Counter-placement copies (`placementNeedsCopy`), root-field propagation to
  copies, count-kind switch fan-out to copies.
- `planLinkedCounterWindowHeal` and its data layers, the post-pull sweep,
  and the v18/v20 ↔ v37/v44 re-runs (migration history stays).
- `propagateIncrement`, `writeLinkedRowPropagation`, `isFrozenDerivedRow`,
  `isFrozenRowReachedByEvent`, `reachedFrozenIds`, `refreshDerivedBaselines`,
  `computeWindowBaseline` and the `baseline` field as a read input (column
  kept inert like `lastSyncedCount`). An increment is one event write plus
  one cascade.
- Derived-row deletion cascades (`softDeleteWindowStampedDerived`,
  `windowStampedDerivedOrphanedByBoard`); `deleteCounterWithUnlink` only
  unlinks.
- `tasks.timeframe` / `startDate` as clearable sync fields (added by #624 for
  the un-stamp) once no writer clears them.

### Forks (owner ruling 2)

Board-scoped forks stay real `Task` rows (title, structure and action
genuinely diverge) but `planBoardScopedFork` stops cloning events. The kernel
follows `forkedFromTaskId` to the event owner, so a fork reads the original's
occurrences inside its own board's window. Existing cloned fork events are
tombstoned by the migration (deterministic ids from `forkedEventId`).

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

### Decisions still open

| Question | Recommendation | Why it can wait for its slice |
| --- | --- | --- |
| Window evaluation is device-timezone dependent (board bounds are local-ISO; two zones can derive different sealed snapshots and late-log stamps). | Accept and document as travel-mode divergence; make `selectClosedBoardLateLogs` match late logs by provenance (`boardId` + `createdAt > sealedAt` + kind), not exact instant. Revisit instants/per-board offset after launch. | Orthogonal to placements; a read-side change. |
| Tasks tab "expired" filter and the hub's "show expired" currently key on a task's own window. | Re-base on "has a live placement on an open board"; expired = placed only on ended/closed boards. | Lands with the retirement slice. |
| Linked task in the library: what does its row show? | "Linked to <counter> · <lifetime total>" and no own-goal progress. | UI copy; decided at slice 2. |

## Migration (both platforms, deterministic)

Runs once per user in a GRDB migration (`v45`) and a Dexie upgrade (`v21`),
and is re-runnable (state-based, no marker):

1. For every live `BoardTask` whose task is a window-stamped derived counter:
   repoint `taskId` to the row's `sharedCounterId`, set
   `targetOverride = row.maxCount`, bump `version`, enqueue UPDATE. Tombstone
   the derived row (authored).
2. For every live `BoardTask` whose task is a derived compound: repoint to
   the source compound (`replacesId` is not stored; recover it from the
   derived compound's title + the `derivedCompoundId(board, source)` match
   over the board's candidate compounds), build `childTargets` from its
   derived children's `maxCount` keyed by their roots, tombstone the derived
   compound, its links and its derived children.
3. For every stamped-in-place hand-made row (three marks, id ≠ any
   `derivedTaskId`): clear `timeframe` / `startDate` / `endDate` (authored);
   for each of its direct placements set `targetOverride = row.maxCount`.
4. Fork event clones: tombstone events whose id matches
   `forkedEventId(fork, original event)`.
5. Re-run the derivation pass for every touched board; re-derive sealed
   boards from the event union and assert the snapshot is unchanged (a
   `sealReDerivationVectors` extension pins this on both platforms).

Content is deterministic, so two devices migrating offline converge under
LWW. Pre-launch there is no old client to protect; post-launch this
migration would need a minimum-client-version gate, which is the main reason
to ship it now.

## Slices (each PR lands web + iOS, vectors pinned, Two-Gate)

| Slice | Scope | Retires / fixes |
| --- | --- | --- |
| **0 — Context window wins** | Kernel: every linked row resolves over the host window when one is present; the own-stamp branch is removed from `resolveDerivedCounterWindowState` / `resolveLinkedCounterDisplay` (TS + Swift), vectors re-pinned. Plus: one late-log tail, closed-board late log for linked children, iOS wizard-compound parity, drafts out of the heal, web `sealedAt` for compound children, decrement latch parity, un-stamp resets `baseline`. | Audit Majors 1, 2, 3, 5 and the read side of 4; five Minors. Pure read change on the kernel, no migration. |
| **1 — Placement fields** | `BoardTask.targetOverride` / `childTargets` in shared types + Zod, Dexie (unindexed) and GRDB column, sync contract clearable fields, fixture regen. Inert: no reader, no writer. | — |
| **2 — Kernel reads placements** | `resolveSquareState`; derivation pass, cells, previews, hub member cards, arrivals, sealed re-derive and the late-log selectors read `targetOverride` / `childTargets`; one completion rule; `resolveLinkedCounterDisplay` becomes a wrapper; library lifetime from events. Vectors: `derivationPassVectors`, `taskWindowStateVectors`, `memberRuleVectors` extended with placement params. | Two completion rules; display ≠ kernel; latch reads. |
| **3 — Writers emit placements** | `planDerivedTasks` output shape; wizard persist, spawn, Board Edit add/replace, quick-add, choke points write parameters; no new minting anywhere. Existing minted rows keep working (slice 2 reads them as plain tasks over the host window). | Minting paths, `placementNeedsCopy`, the choke points' resolve step. |
| **4 — Migration** | The deterministic repoint + tombstone sweep above (v21 ↔ v45), seal re-derivation vectors. | Every derived row in existing data. |
| **5 — Retire the machinery** | Delete the heal, propagation, freeze, baseline refresh, derived deletion cascades, three-mark predicates, task-window kernel inputs; re-base the expired filters; docs: replace the `CLAUDE.md` Windowed Completion paragraph with the model statement and move its history into an ADR log in `WINDOWED_COMPLETION.md`; `BOARD_SOURCES.md` §Member rules rewritten in placement terms. | The four derived-row invariants. |
| **6 — Forks read the original's events** | Kernel follows `forkedFromTaskId`; `planBoardScopedFork` stops cloning events; clone tombstones in the migration (can ride with slice 4). | Duplicate occurrences in the log. |

Slice 0 is independent of the rest and should ship first. Slices 1–3 are
additive and safe to merge one at a time. Slices 4 and 5 are the cut-over.

## Acceptance

- `grep` finds no non-test reference to `isWindowStampedDerived`,
  `derivedTaskId`, `isFrozenDerivedRow`, `refreshDerivedBaselines`,
  `propagateIncrement` or `planLinkedCounterWindowHeal` in `apps/` or
  `packages/shared/src`.
- A daily series that re-places one compound with a linked counting child
  completes that child on every spawn from logs inside each day's window
  (the #624 scenario, as a vector on both platforms).
- An increment writes exactly one `tasks` row (the root's lifetime cache) and
  one event; no linked-row writes, no sync items for copies.
- A sealed board re-derived after the migration equals its stored snapshot.
- Every exported shared-algorithm function in the kernel is covered by a
  vector suite run by Jest and the Swift twin (CI guard, new).
- `CLAUDE.md` §Windowed Completion is the model paragraph plus links, not a
  list of amendments.

## Risks

- **Scope**: six slices across both platforms touching the four ~14k-line
  layers. Mitigation: slices 0–3 are additive and individually revertible;
  the cut-over is two PRs.
- **Semantics drift during the cut-over**: Split-up parts, vary, timeframe
  defaults and pool dice must produce the same targets as today. Mitigation:
  the member-rule maths is untouched; only its output shape changes, and the
  existing `memberRuleVectors` are re-expected mechanically.
- **Sealed snapshots**: the migration must not change any closed board.
  Mitigation: the re-derivation assertion is part of the migration test on
  both platforms and runs over the owner's real export before the cut-over
  merges.
- **The twin cost**: every slice is TS + Swift. Mitigation: the plan/apply
  pattern (shared kernel returns `{writes, enqueues, cascadeBoardIds}`, data
  layers apply) is adopted for every write path touched, so vectors pin the
  decisions and the Swift side becomes a dumb applier.
