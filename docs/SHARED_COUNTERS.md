# Shared Counters

Design handoff: `OYBC Shared Counters.zip` (gitignored `design_handoff_shared_counters/`). High-fidelity Riso design. This doc is the canonical implementation plan.

## What it is

One real-world activity (e.g. *push-ups*) feeds **many** bingo-board squares from a single running tally. Log the activity **once, anywhere** — on any board square or the counter's own page — and every task that measures it updates at once, while each task keeps its **own window** (this week / this month / custom), its own goal, and its own start/finish. Above all the windows sits one **lifetime total**.

Four surfaces:
1. **Counters Hub** (Profile → "Shared counters") — Ledger layout: a card per counter with the lifetime number + a row per member task (board · window, logged/goal, progress bar). *(Tiles / Meters are prototype alternates — ship Ledger only.)*
2. **Counter Detail** — lifetime hero, a **Log** stepper, "Appears on" timeframe chips, "Shared by N tasks" list, "Not counting now" (draft/inactive). *(Sparkline / streak / best-window / recent-windows history are P4 — deferred.)*
3. **Board square logging** — a counting square linked to a shared counter shows a **shared marker** (↔ two dots); tapping opens the stepper with an "also counts on…" hint and fires a **credited toast** naming the other boards that changed.
4. **Passive completion** — logging elsewhere flags affected squares as "arrived"; the next board-open shows a gold **arrival banner** + the square pulsing, and may complete a new **bingo** from activity logged somewhere else.

## The engine already exists (don't rebuild it)

OYBC shipped a live, production shared-counter **engine** (Issue #84, Phases 0–4, both platforms). The engineering-risky core is done:

- **`sharedCounterId`** FK on `Task` links a *derived* counting task to a *source* task.
- **`incrementSharedCounter(sourceId)`** (`AppDatabase.swift` ~L1467 / web `db/operations/tasks.ts` ~L509) does the **atomic cross-board fan-out** — increment the source, re-derive every linked task on every board, recompute bingo/greenlog, enqueue sync — in one transaction. This *is* the handoff's credit/ripple logic, already working offline + across devices.
- **`deriveDisplayedCount({baseline, maxCount}, {currentCount})`** (`packages/shared/src/algorithms/sharedCounter.ts`, Swift twin `Helpers/SharedCounter.swift`) → `max(0, currentCount − baseline)`, no high-end clamp (overshoot is real), one-way completion latch.
- **Additive-merge sync** — superseded: `sharedCounterMerge` / `lastSyncedCount` were retired by Windowed Completion (union-of-`task_events` makes offline increments unlosable; see `docs/WINDOWED_COMPLETION.md`).
- Inherit-vs-start-from-zero baseline at link time. **Correction (2026-07-15, P5 review):** an earlier revision of this line claimed "cascade delete of source→derived" — that is wrong. Deleting a source leaves derived rows linked to the tombstone, whose steppers then silently no-op. P5's unlink-then-delete (below) fixes the hub deletion path.

**Count is global per Task** (`Task.currentCount`); `BoardTask` is a pure placement record with no count. `progress_counters` / `ProgressCounter` / `calculateCountingRollup` are **vestigial dead** (rejected in ARCHITECTURE.md Decision 1 for the per-Task `sharedCounterId` model) — do not use them.

So **Shared Counters = the UX + a read-model on top of the existing engine.** The handoff's own rule #2 admits its prototype applies the same delta to all active windows and conveys "own window" via independent goals + copy — exactly what the engine already does.

## Model mapping

A **"counter"** = one **source** counting task (a task with ≥1 live task linking to it via `sharedCounterId` — **or, since P5, a task flagged `isCounter`**) + all its linked tasks.

| Handoff concept | OYBC mapping |
| --- | --- |
| `counter.lifetime` | source task's `currentCount` (MVP: as-is, can be decremented; a never-reset accumulator is deferred) |
| `counter.name / action / unit` | source task's `title / action / unit` |
| a `task` in the counter | a member Task (source or linked), with its own board + timeframe + `maxCount` |
| `task.logged` | `deriveDisplayedCount` for that member (source = full count; linked = count − baseline) |
| `task.goal` | member's `maxCount` |
| `task.window` | `formatTimeframeLabel(task.timeframe, task.startDate)` |
| active vs "Not counting now" | member's board is `ACTIVE` vs draft/completed/archived/placeless |

## Scope — MVP = P1–P3 (iOS + web in lockstep)

Each phase lands **both platforms together**. Shared logic in `packages/shared` (TS, Jest-tested) is the source of truth; iOS ports it to Swift (like `SharedCounter.swift`).

### P1 — Counters Hub + Counter Detail
- **Shared:** `buildSharedCounterGroups({tasks, boardTasks, boards}) → SharedCounterGroup[]` (`packages/shared/src/algorithms/sharedCounterGroups.ts`, Jest-tested). Pure read model over the existing graph. **← this PR.**
- **iOS:** `SharedCounterGroups.swift` (Swift port) + `Views/ProfileTab/CountersHubView.swift` + `CounterDetailView.swift` + a Profile row "Shared counters".
- **Web:** `pages/CountersHubPage.tsx` (route `/profile/counters`) + `pages/CounterDetailPage.tsx` (`/profile/counters/:counterId`) consuming `buildSharedCounterGroups` via a `useSharedCounterGroups` hook + a Profile link.
- Detail MVP sections: lifetime hero, **Log** stepper (reuses `incrementSharedCounter`), "Appears on" timeframe chips, "Shared by N tasks" list, "Not counting now". Leave clean seams where the P4 sparkline/streak/best/history will slot in.

### P2 — Board-play polish
- Shared marker (↔ dots) on counting squares whose task is in a shared-counter group.
- Stepper "↔ Shared · also counts on {board} / N others" hint.
- **Credited toast** after the cross-board ripple. Requires `incrementSharedCounter` to **return the affected board names** (a return-value change on both platforms — not a schema change).

### P3 — Passive completion / arrival banner
No engine change: P2's `incrementSharedCounter` already fans the log out to every board's square (marked done, bingo recomputed) in one transaction. P3 is DETECTION + PRESENTATION.
- **Shared:** `detectCounterArrivals({lastSeen, squares}) → { arrivedTaskIds, arrivedCounters[], totalArrivedSquares }` + `snapshotCounterSquares(...)` (`packages/shared/src/algorithms/counterArrivals.ts`, Jest-tested). Increase-only; first view (no baseline) never arrives. iOS ports it (`CounterArrivals.swift`). **← P3-shared PR.**
- Gold `.r-arrival` banner on board-open when ≥1 shared square arrived + square pulse (`arriveGlow`, 2 iters) + tap → Counter Detail + ✕ dismiss + ~5.2s auto-clear. Single: "*{name}* filled in here from your {name} counter — logged on another board · See every board it counts on ›". Multiple: "**N squares** filled in from your counters — logged on other boards."
- **Local last-seen snapshot** per board (`UserDefaults` iOS / `localStorage` web — **not** synced schema): detect on board appear via `detectCounterArrivals`; re-snapshot via `snapshotCounterSquares` on board disappear + after an arrival is shown (so local taps / acknowledged arrivals don't re-fire).
- **Scope = SAME-DEVICE MVP** (log on Detail / another board → open board → banner). Cross-device (another device logs → sync pulls → banner) is a documented follow-up (same last-seen-diff mechanism, needs the sync-pull path).

## Deferred (not in this MVP)

- **P4 rich stats** — 7-day sparkline, counter-level streak, best-window, closed-window history. *(Update 2026-07: the "only real schema addition" this bullet used to require — a per-increment log — has since shipped as `task_events` (`docs/WINDOWED_COMPLETION.md`). P4 is now a pure read-model feature over source-task increment events; hub-born counters (P5) have full history from birth, with seed events identifiable by the far-past `occurredAt` sentinel.)*
- **True per-window resets** ("a fresh weekly task starts at 0 while all-time climbs") — OYBC's already-deferred "Decision 6 / v2"; the prototype only conveys it via copy + independent goals.
- **Never-reset lifetime accumulator** — MVP uses `currentCount`.
- **Fully-automatic grouping by action+unit** (silent link, no prompt) — NOT building. Instead see "Link suggestions" below.

## Link suggestions — adding a task to an existing counter (BUILDING)

The handoff's "counters link up on their own" is core, not deferred: without it, adding a task to an existing counter means hunting a dropdown. We build the **suggest-confirm** version (user chose this over silent-auto and over passive-suggest): when a new COUNTING task's `action + unit` match an existing counter, the create form surfaces a one-tap "Counts on your existing **{name}** counter" suggestion (OFF until tapped — never silent). Accepting routes through the existing linked-counter create path (`sharedCounterId` + baseline; default **start-this-window-at-0**). No engine change.

- **Shared:** `findLinkableCounter({action, unit, excludeTaskId?}, tasks) → { counterId, name, lifetime, memberCount } | null` (`packages/shared/src/algorithms/linkableCounter.ts`, Jest-tested). In OYBC the counting `action` field carries the activity ("Push-ups"), so `action+unit` cleanly identifies a counter (Push-ups ≠ Sit-ups). Matches non-derived candidates; most-established counter wins. iOS ports it (`LinkableCounter.swift`).
- **UI (both platforms):** an inline suggestion in the counting create sub-fields, wherever counting tasks are created (board-wizard Tasks step special panel, Tasks-tab New Task sheet, quick-add). Tap to link (baseline choice), or ignore. Reuses `LinkedCounterInput` / `sharedCounterId`.

## Locked decisions

1. Both platforms every phase (lockstep), shared TS logic + Swift port.
2. Ship **Ledger** hub layout only.
3. `lifetime = source.currentCount`; no new synced schema in P1–P3.
4. Reuse the Riso kits (`Views/Riso/RisoControls.swift`, web `components/riso/`) and the design tokens in the handoff (they equal the existing Riso palette).
5. Log actions reuse the live `incrementSharedCounter` — no second write path.

## Cross-platform file structure

```
Shared:  packages/shared/src/algorithms/sharedCounterGroups.ts  (+ tests)
Web:     apps/web/src/pages/CountersHubPage.tsx        ←→  iOS  Views/ProfileTab/CountersHubView.swift
         apps/web/src/pages/CounterDetailPage.tsx      ←→       Views/ProfileTab/CounterDetailView.swift
         apps/web/src/hooks/useSharedCounterGroups.ts  ←→       Helpers/SharedCounterGroups.swift (port)
         components/counters/* (Ledger card, member row, log stepper)  ←→  Views/ProfileTab/Components/*
```

## P5 — Hub-born counters (design locked 2026-07-15)

> **Status: DESIGN** (Gate-1 decisions locked 2026-07-15; adversarial internal
> review applied — the engine-guard, field-drop, seed-window, and
> delete-blast-radius rules below are review-driven). Not yet implemented.
>
> Create counters directly in the Counters Hub, instead of a counter existing
> only once a second task links to a source.

### Concept

A hub-born counter is a **standalone source counting task**: `isCounter: true`,
`action` + `unit`, auto-generated editable title, **no `maxCount`**, no board
placement. No new entity, no engine rewrite. The counter acquires members the
way counters already do — the create-form link suggestion and the counting
template picker are the intended "put this counter on a board" path (members
carry the goals and windows; the counter is the accumulator).

### Locked decisions (P5)

| # | Decision |
| - | -------- |
| 1 | New optional synced field `Task.isCounter?: boolean` (forward-compatible decode; `Board.isCore` precedent). No new entity — counter identity stays "the source task" per ARCHITECTURE Decision 1. |
| 2 | Hub visibility: one group per source with ≥1 live link **OR** `isCounter === true`. This is a new enumeration branch in `buildSharedCounterGroups` (groups are currently seeded exclusively from link edges — it cannot be a filter tweak). Single-member groups render immediately; member-view math already tolerates goal-less, placeless sources. |
| 3 | Create sheet fields: **Action + Unit + optional Starting count**. Title auto-generates and stays editable — requires a **goal-less variant of `generateCounterTaskTitle`** (the current template interpolates `maxCount` and would render "Push-ups 0 reps"); audit the render-time `?? 0` regeneration call sites while adding it. |
| 4 | Starting count = one seed `increment` TaskEvent with **`occurredAt` = a fixed far-past sentinel** (shared epoch constant), NOT `now`. Lifetime sums include it; no board window ever does. (Review finding: a now-stamped seed leaks the entire starting count into any window covering creation the moment the task later gains a goal or placement.) P4 stats can distinguish seeds by the sentinel. |
| 5 | Library visibility keys on the **pair** `isCounter === true && maxCount == null`: excluded from Tasks-tab browse + wizard boardable picker (via `computeBrowsableTasks`, which both surfaces on both platforms already consume) **and** from compound-child pickers, with rejection at the child-link write layer (a goal-less child can never complete — it would make an AND parent silently unreachable). Keying on the pair, not bare absent-`maxCount`, keeps PR-1 inert and guarantees a row whose flag is stripped by an old client degrades to a *visible library row*, never an unreachable task. |
| 6 | Goal-less counters ARE valid link targets — deliberately kept in the counting template picker and `findLinkableCounter` candidates. |
| 7 | Dedupe at hub-create: classify `findLinkableCounter`'s match — an **established counter** (has links or `isCounter`) → "You already have a **{name}** counter" + jump-to affordance, create disabled; a **standalone task** → one-tap **Promote** (sets `isCounter: true`; keeps its goal, count, placements — it stays library-visible per decision 5). The classify helper returns the matched Task row: `memberCount` alone cannot distinguish a standalone from a flagged single-member counter. |
| 8 | Hub delete = **unlink-then-delete**: clear each member's `sharedCounterId` + `baseline`, mint one snapshot `increment` event per member (`delta` = its displayed count at unlink, `occurredAt = now`) so its squares keep showing what they showed, then soft-delete the source. `computeTaskDeletionImpact` extends to enumerate member tasks/boards for the confirm dialog. (Review finding: `deleteTaskWithCascade` today leaves members linked to a tombstoned source whose steppers silently no-op — and this doc's old "cascade delete of source→derived" claim was false; corrected in §engine above.) |
| 9 | Board-play shared-ness recognizes flagged counters: the `sharedCounterSourceIds` builders (`useBoardPlayData`, `useCounterArrivals`, iOS twins) add an `isCounter` branch so a promoted zero-link counter placed on a board shows the ↔ marker and participates in P3 arrival detection. |

### Engine change (small but required)

`incrementSharedCounter` / `decrementSharedCounter` currently **throw** on a
nil/undefined source `maxCount` ("data integrity error") on both platforms
(web `tasks.sharedCounter.ts`, iOS `AppDatabase+SharedCounters.swift`) — the
hub-born counter's own Log stepper would crash on first tap. Both guards relax
to accept goal-less sources, and the source completion-latch comparisons gain a
`maxCount != null` guard (a goal-less source never auto-completes;
`resolveTaskWindowState` and the lifetime-cache stamp already handle absent
`maxCount` — the engine guards are the only gap). Web also needs a combined
**create-task-plus-seed-event operation**: `createTask`'s transaction doesn't
compose with `appendIncrementEvent`'s ambient-transaction requirement today.
iOS composes both inside one `write` block.

### Validation

`CreateTaskInputSchema`'s counting refine: `maxCount` stays required **except**
when `isCounter === true`. Row-level `TaskSchema` already tolerates absent
`maxCount` on counting rows (no change — good for pull compat). `isCounter` is
forbidden on non-COUNTING types (new refine). Child-link writes reject goal-less
counter children (decision 5).

### Sync & mixed versions

`isCounter` rides the existing whole-payload task push/pull on both platforms —
**no syncService change and no Dexie version bump** (non-indexed field); one
GRDB column migration + Swift Codable/decode update. Accepted mixed-version
edge (same risk class as `isCore`, documented): an old client rewriting the
task doc drops the flag and LWW propagates the loss — the counter leaves the
hub until re-promoted, but decision 5's exclusion key guarantees the task
stays reachable in the library. Not mitigated further in v1.

### Accepted edges

- **Two-device offline duplicate creates** ("Push-ups · reps" on both) → two
  sources, two hub cards, unmergeable by LWW (different ids). Same race class
  as the existing create-and-link flow; accepted. A render-time duplicate badge
  (reusing the classify match) is the recorded v2 seam — no merge UI now.
- **Stale auto-title** if action/unit ever change post-create: moot in v1 —
  goal-less counters have no edit surface (hub create + log + delete only).
- **Doc drift recorded:** `WINDOWED_COMPLETION.md` specced hub decrements as
  "tombstone the latest increment"; the shipped hub Detail stepper appends a
  clamped negative delta instead (seed-safe; correction noted in that doc).

### Out of scope (P5)

- "Add to a board" button on Counter Detail — the template-picker /
  link-suggestion path covers the need; button deferred with a seam.
- Per-window derived display (`WINDOWED_COMPLETION.md` Phase 2) and P4 stats.
- Counter merge UI; counter editing (rename / re-unit).

### Delivery

- **PR-1 (shared, inert):** `Task.isCounter` type + Zod (counting-refine
  exemption, non-counting rejection, child-link rejection), `buildSharedCounterGroups`
  isCounter enumeration branch, `computeBrowsableTasks` pair-keyed exclusion,
  goal-less `generateCounterTaskTitle` variant, seed-sentinel constant,
  classify-match helper (returns matched Task), tests. No behavior change until
  UI sets the flag.
- **PR-2 (platforms):** GRDB migration + Swift model/ports
  (`SharedCounterGroups.swift`, `BrowsableTasks.swift`, `LinkableCounter.swift`),
  engine-guard + latch relaxation ×2 platforms, web combined create+seed op,
  hub "+ New counter" button + empty-state CTA + Riso create sheet (dedupe /
  promote slot), unlink-then-delete + extended impact preview, shared-ness
  id-set branches, Detail single-member copy tweak, Vitest/XCTest + snapshots.

### Testing (delta)

Shared: single-member group enumeration (flag × links truth table); exclusion-key
truth table (`isCounter` × `maxCount`); classify-match (established / standalone /
none); goal-less title variant; seed sentinel never enters any window sum;
latch null-guard vectors. Platforms: create+seed atomicity; Log stepper on a
goal-less source (no throw, lifetime updates); promote flow end-to-end;
unlink-then-delete mints snapshot events + members become plain counting tasks;
flag-stripped row still browsable (regression for the field-drop edge); hub +
create-sheet + single-member detail snapshots.
