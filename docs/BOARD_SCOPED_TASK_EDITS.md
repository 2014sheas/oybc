# Board-scoped task edits (copy-on-write from Board Edit)

**Status:** LOCKED 2026-10-08 — the owner accepted every recommendation in the
decision table (D1–D6); the PR train in §9 is authorised. Design opened
2026-10-08 after the owner's ruling:

> "Edits at board level (via Edit board etc.) should ONLY affect the task in the
> scope of that board, even if this means creating a new task upon the edit.
> Editing a task via the tasks sheet keeps all global effects."

Companion docs: [`TASK_SYSTEM.md` §Editing a task](TASK_SYSTEM.md#editing-a-task)
(what each surface writes today), [`BOARD_EDIT_REDESIGN.md`](BOARD_EDIT_REDESIGN.md)
(the square sheet), [`WINDOWED_COMPLETION.md`](WINDOWED_COMPLETION.md) (events,
windows, sealed boards), [`BOARD_SOURCES.md` §Member rules](BOARD_SOURCES.md)
(the per-board copies that linked counters already mint).

## 1. The rule

| Surface | Scope of an edit |
| --- | --- |
| Board Edit → square → **Edit task** (title / action / goal / unit / kind, Simple ⇄ Counting, into Compound, compound rule + sub-tasks) | **This board only.** If the task is placed anywhere else, the edit lands on a **fork** — a new Task that replaces the original on this board's placement. |
| Board wizard → Tasks step → inline row edit | **This board only** (same fork rule, applied at Create). A task *created in this wizard session* is edited in place — nothing else can see it yet. |
| Task Detail (page / sheet), Tasks tab | **Global** — the shared Task row, every placement, as today. |
| Pool editor | **Global** (a pool is a library construct, not a board), as today. |
| Counters hub / Counter Detail | **Global for the root**, as today. (No field-edit UI there yet; the root is edited through Task Detail.) |
| Board Edit → **Replace** square | Placement only (`board_tasks.taskId`), as today. |

Linked counters already obey the board-scoped rule (each placement is a minted
per-board copy of the hub root — `derivedTaskId(board, root)`), so this design
generalises an existing mechanism rather than inventing a second one. Their
copies keep their current shape; see §6.

One sentence for the UI, in the only place a sentence is allowed (a confirm
body, first fork on a board; see §8): *"Applies to this board only. Other
boards keep the original."*

## 2. When to fork — the "other placements" test

A Board Edit edit of task `T` on board `B`:

1. **Edit in place** when `T` has no live placement other than on `B`. A placement
   counts if its `BoardTask` is not deleted and its board is not deleted — **sealed
   and archived boards count** (an in-place edit would rewrite the titles a closed
   board's snapshot shows) **[D1 — ruled yes]**.
2. **Fork** otherwise: mint `T'`, repoint `B`'s placement at `T'`, and apply the
   edit to `T'`. `T` is not written at all.

Pool membership and recurring-template sources are *not* placements: they keep
pointing at `T`, so the next spawn / pull still supplies the unedited task. That
is the behaviour the ruling asks for (a board edit must not leak into future
boards).

**[D1] RULED (recommendation accepted):** confirm that any other placement — sealed boards
included — triggers a fork. Alternative: ignore sealed/archived placements and
edit in place (cheaper, but rewrites history on closed boards).

**[D2] RULED (recommendation accepted):** should a task that is a **pool member** (but placed
nowhere else) still be edited in place? Recommendation: **yes** — the test is
placements only; the pool keeps the row, and the next pull from that pool gets
the edited task, which matches "the task I edited is the task in the pool".
Alternative: fork whenever the task is pool-/template-referenced, which keeps
library tasks pristine at the cost of a fork on nearly every edit.

## 3. What a fork is

```
Task T'  = { ...T,
             id:               uuidv5(FORK_NS, `${B.id}|${T.id}`)   // deterministic (see §7)
             forkedFromTaskId: T.id,                                 // NEW field
             createdInWizard:  true,                                 // hidden from library browse (existing rule)
             version: 1, createdAt/updatedAt: now,
             isCompleted/currentCount/completedAt: recomputed (see §4) }
board_tasks[B, slot].taskId = T'.id      // version bump + enqueue, like Replace
```

- **Library visibility.** `T'` is hidden from library *browse* by the existing
  `computeBrowsableTasks` rule (`createdInWizard` + placed only on … — the rule
  is extended: a fork is browsable only through its board; it never appears in
  the Tasks tab list, pool pickers, the wizard library sheet, or
  `compoundChildPickerCandidates`). It is reachable from its square (tap → Task
  Detail), where its Usage row shows exactly one board and a `Forked from
  {T.title}` is **not** shown (no provenance captions — #548); the original is
  not linked from there **[D3 — ruled no]**.
- **Later edits to `T'`** from Task Detail are "global" for `T'` — which is this
  one board. From Board Edit they are in place (no other placements). A fork is
  never re-forked.
- **Sync.** `forkedFromTaskId` is a plain optional string on `tasks` (Zod + Swift
  `Codable` forward-compatible decode, never cleared — not in
  `CLEARABLE_FIELDS_BY_COLLECTION`). An old client that strips it just sees a
  normal `createdInWizard` task; nothing breaks.
- **Deletion.** `deleteTaskWithCascade(T)` must not touch forks (they are
  independent rows; the field is informational). Deleting a fork tombstones its
  one placement like any task. `computeTaskDeletionImpact` lists forks as
  unaffected.

## 4. Completion history — the sharp edge

`task_events` are per task. A naïve fork starts with no events, so a square the
user already completed this week would flip to incomplete the moment they
rename it. Two options:

- **(a) Migrate in-window events (recommended).** At fork time, copy every
  non-deleted event of `T` whose `occurredAt` lies inside `B`'s window
  `[startDate, endDate ∩ sealedAt]` to new event rows on `T'` (new ids —
  `uuidv5(FORK_NS, eventId)` so a replayed fork is idempotent; `createdAt = now`;
  same `occurredAt`, `kind`, `amount`). `T`'s events are left untouched (they
  still count for the other boards — and for `T` on `B`'s window they are now
  irrelevant because `B` no longer places `T`). Then run the normal cascade for
  `T'` on `B` and for `T` on its remaining boards. **No kernel change.** Cost:
  duplicated in-window rows, bounded by one board window.
- **(b) Read-through to the original.** The kernel resolves `T'` on `B` from
  `T`'s events before the fork instant plus `T'`'s own events after — the
  linked-counter pattern (copies resolve from the ROOT's events). Avoids
  duplication but adds a permanent coupling and a kernel branch for every fork
  on every render; and a later edit of `T`'s history (undo) would silently move
  `T'`'s state.

**[D4] RULED (recommendation accepted):** (a) or (b). Recommendation **(a)**.

Edge cases under (a):
- **Type changes.** Simple → Counting keeps completion events only if the new
  type owns them: completion events on a counting task are not meaningful, so a
  type-changing fork migrates only events the NEW type can own (Counting: increments;
  Simple: completions; Compound: nothing — compounds own no events, same as the
  existing into-Compound rule). This matches today's in-place switch, where the
  old events "become inert".
- **Ended-but-unsealed board.** Window end = `endDate`; the late-log stamp rule
  (`occurredAt = min(now, endDate)`) already keeps new logs inside, so migrated
  events stay inside too.
- **Sealed board.** Board Edit's SQUARES section is gated off on sealed boards
  (`canEditSquares`), so a fork can never happen there. (The late-log path on a
  closed board never edits the task.)

## 5. The shared-task invariant changes — on purpose

Today a task placed on a daily board and on its parent monthly is *the same
Task*: completing it on the daily completes the monthly. Editing that task from
the **daily's** Board Edit will now fork it: the daily gets `T'`, the monthly
keeps `T`, and the daily's future completions no longer reach the monthly.
That is exactly what "scope of that board" means, and the in-window event
migration keeps *past* state consistent on both. It is still worth saying once:

**[D5] RULED (recommendation accepted):** accept this consequence for derived daily/monthly tasks,
and surface it only through the one confirm line in §8 (shown the first time a
fork would happen on a board), never as a standing caption.

The user who *wants* the global change still has it: square → Task Detail →
edit (global). The square menu already offers "Open task"; nothing new is
needed, but the Board Edit sheet's Done button label could read **"Save for this
board"** **[D6 — ruled yes]** so the scope is visible as a control label, not a sentence.

## 6. Interactions with existing per-board machinery

- **Linked counters** (`sharedCounterId` set): unchanged. A placed linked counter
  IS this board's copy, Board Edit already writes only that copy, and a kind /
  type switch stays refused there. The fork test never fires on a copy (it has
  exactly one placement).
- **Root → copy propagation** (open since the counter-kinds train): a root's
  **title / action / unit** edit from Task Detail propagates to every *live*
  copy (sealed/frozen rows untouched); **goal** does not (each board scales its
  own target); **kind** already propagates. This closes the `COUNTER_KINDS.md`
  D5 mismatch ("same cascade as a Goal edit" — there is none today). Ships in
  the same train (§9, PR 3) because it is the global half of the same rule.
- **Compounds.** Forking a compound forks the **parent only** and copies its
  `compound_children` links; children stay shared (they are real tasks). A child
  renamed from the Board Edit compound editor goes through the same test: fork
  the child if it is placed elsewhere (directly, or through a compound that is
  placed elsewhere), else edit in place — a child linked under a compound that
  is placed nowhere is edited in place (D2: placements only). A forked
  child's link under the forked parent is repointed; the original parent keeps
  the original child. PR 2 forks a holder compound that is itself placed
  elsewhere before repointing the copied link.
- **Achievements** (title-only in Board Edit): same rule, trivially.
- **Member rules / dry-run capacity / Sources sheet:** forks are never source
  supply (`isSourceSupplyTask` false — they are board-bound), so the planner and
  the Sources sheet ignore them.
- **Recurring spawn:** reads template sources → originals. A fork on one window's
  board never reaches the next window. (If the owner edits the same square on
  three consecutive weekly boards, that is three forks — the signal that the
  edit should have been global, which is what the Task Detail path is for.)

## 7. Determinism, idempotence, sync

- Fork ids are `uuidv5(FORK_NS, boardId|taskId)` — the same seam the planner uses
  for per-board derived counters — so two devices that both fork the same square
  offline converge on one row (LWW on the fields, union on events, the placement
  repoint wins by version like any Replace).
- Migrated event ids are `uuidv5(FORK_NS, originalEventId)`: replaying the fork
  (a retried commit, a second device) produces the same rows.
- Everything in one transaction with the rest of the Board Edit Save
  (`boardEditCommit.ts` / `+EditCommit.swift`): fork rows, event copies, the
  placement repoint, the override edit, the cascades. A failure rolls the whole
  Save back, as today.

## 8. UI

Nothing new on the grid. In the Board Edit square sheet:

- Done button → **"Save for this board"** when the sheet's task would fork
  (other placements exist), plain **Done** otherwise **[D6 — ruled yes]**.
- The first time a fork would happen on a given board, a confirm with the body
  *"Applies to this board only. Other boards keep the original."* (confirm-dialog
  consequence bodies are an allowed copy category). Remembered per board for the
  session; no standing caption, no "forked from" line anywhere.
- Task Detail opened on a fork: identical to any task; Usage shows one board.

## 9. PR train (both platforms per PR, rule 6)

| PR | Scope |
| --- | --- |
| 1 — foundation (inert) — **shipped (#573)** | `Task.forkedFromTaskId` (shared type + Zod, iOS GRDB v41 nullable column + `Codable`; no Dexie bump — unindexed), `FORK_NS` + `forkTaskId` / `forkedEventId` helpers (shared TS + Swift twin, vector-pinned), `planBoardScopedFork(task, board, placements, events)` pure planner returning `{ mode: 'inPlace' | 'fork', fork?, eventCopies?, childLinksToCopy?, repoint?, onBoardHolderCompoundIds? }` with vectors for the D1/D2 test and the type-change event filter, browse-filter extension, deletion-cascade guard. No UI change. |
| 2 — Board Edit + wizard commit | `boardEditCommit.ts` ↔ `+EditCommit.swift` and `applyStagedTaskEditsForWizardPersist` ↔ `applyStagedTaskEdits` consume the planner inside the existing transaction; cascades for both tasks; sheet button label + first-fork confirm; e2e + XCTest (fork, in-place, compound parent-only, event migration keeps completion, type-change filter, sealed gate, idempotent replay). |
| 3 — root → copy propagation | Task Detail edit of a hub root propagates title/action/unit to live copies (shared `planRootFieldPropagation`, both platforms); fix `COUNTER_KINDS.md` D5 wording. |
| 4 — docs | `TASK_SYSTEM.md` §Editing a task rewritten around the scope table; `BOARD_EDIT_REDESIGN.md:31` ("changes it everywhere") corrected; CLAUDE.md one-paragraph summary. |

**PR 1 implementation notes** (where the shipped code refines the sketches above):

- Ids are `uuidv5` under `OYBC_NAMESPACE` with `fork:*` name prefixes — the
  `derivedTaskId` seam: `forkTaskId(boardId, taskId)` = `fork:task:<board>:<task>`,
  `forkLinkId(forkId, childId)` = `fork:link:<fork>:<child>`, and
  `forkedEventId(forkId, eventId)` = `fork:event:<fork>:<event>` — keyed on the
  fork as well as the event, because one event can lie in two overlapping
  windows (a daily inside its monthly) and be migrated onto two forks.
- `planBoardScopedFork({ task, board, editedType, placements, boards,
  compoundChildren, events, now })` (shared `boardScopedFork.ts` ↔
  `Helpers/BoardScopedFork.swift`, pinned by `boardScopedForkVectors.json`).
  "Other placement" also counts a placement of any transitive parent
  compound (a child shown on another board inside a compound is placed
  there); a board absent from `boards` is not live. The fork's lifetime
  caches are RESET (they depend on the post-edit task) — PR 2 stamps them
  from the fork's events after applying the edit. `isCounter` is cleared on
  the fork. `repoint` is `null` when the task is on this board only through
  a compound; `onBoardHolderCompoundIds` lists the compounds with a live
  placement on this board that contain the task (directly or transitively),
  so PR 2 can repoint the nested copy too — including when the task is
  BOTH placed directly and nested on the board. Compounds return
  `childLinksToCopy` (children stay shared).
- No Dexie version bump: the field is unindexed (the v38 / v39 precedent).

Estimated size: PR 1 small, PR 2 medium (the commit paths are already staged and
transactional — most of the work is the planner + tests), PR 3 small, PR 4 docs.

## 10. Out of scope / explicitly not changing

- Switching **out** of Compound (still not offered).
- Unforking / "apply this edit everywhere" from a fork (use Task Detail on the
  original).
- Pool editor and Tasks-tab edits stay global; no per-pool task copies.
- Linked-counter copy shape, the window heal, member rules.

## Decision summary — all RULED 2026-10-08 ("roll with your recommendations")

| # | Question | Ruling |
| --- | --- | --- |
| D1 | Do sealed/archived placements trigger a fork? | Yes — never rewrite closed-board history. |
| D2 | Does pool membership alone trigger a fork? | No — placements only. |
| D3 | Any link from a fork back to its original in Task Detail? | No (no provenance UI); the original is in the library. |
| D4 | Completion history: migrate in-window events (a) vs read-through (b) | (a). |
| D5 | Accept that a daily-board edit decouples the task from its parent monthly | Yes, with the one confirm line. |
| D6 | Done → "Save for this board" when a fork will happen | Yes. |
