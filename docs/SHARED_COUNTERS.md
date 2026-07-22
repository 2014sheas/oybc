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

## Link suggestions — adding a task to an existing counter (SHIPPED, R1)

The handoff's "counters link up on their own" is core, not deferred: without it, adding a task to an existing counter means hunting a dropdown. *(Update — R1 counters refresh, 2026-07-18: this shipped as **auto-link, default ON**, superseding the suggest-confirm design this section originally described.)* Identity is the **(verb, noun) pair** — today's `action` + `unit` key, case-insensitive, trimmed, verb defaulting to "Do" (see [§The model](#the-model-no-schema-change)) — not a single "activity" string. When a new COUNTING task's typed (verb, noun) pair exactly matches an existing counter, the create form links it **by default**: an always-visible `RisoCounterLinkHintView` / `CounterLinkHint` card explains what will happen ("Counts toward your **{name}** counter") with a "Don't link" pill to opt out for that create (toggling back re-enables). No fuzzy matching, no silent merges, no confirm-first step. Accepting (the default) routes through the existing linked-counter create path (`sharedCounterId` + baseline; always **start-fresh** — the baseline is the source's lifetime `currentCount` at link time; the manual "Inherit total" baseline mode was retired in R1). No engine change.

- **Shared:** `findLinkableCounter({action, unit, excludeTaskId?}, tasks) → { counterId, name, lifetime, memberCount } | null` (`packages/shared/src/algorithms/linkableCounter.ts`, Jest-tested). `action` is the **verb** and `unit` is the **noun** — together they form the (verb, noun) pair that identifies a counter (Do·push-ups ≠ Do·sit-ups; Run·miles ≠ Bike·miles by construction). Matches non-derived candidates; most-established counter wins. `name` is the pair-derived display name (`formatCounterName`), falling back to the source's stored title. iOS ports it (`LinkableCounter.swift`).
- **UI (both platforms):** the auto-link hint card renders inline in the counting create sub-fields, wherever counting tasks are created (board-wizard Tasks step special panel + its inline compound-sub counting fields, Tasks-tab New Task sheet, quick-add). Linking is on by default; "Don't link" opts out for that create. Reuses `LinkedCounterInput` / `sharedCounterId`.
- **Suggestion pool caveat:** the match pool must include goal-less hub-born counters (excluded from the browsable task list) and, in wizard contexts, this session's not-yet-persisted pending tasks — otherwise a hub counter or a just-created same-pair task silently fails to link. See `suggestionPool` (iOS `RisoSpecialTaskPanel`/`RisoCompoundFieldsView`; web `BoardWizardTasksStep.effectiveSuggestionPool` / `CreateNewTaskForm`'s `suggestionPool` prop).

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

> **Status: IMPLEMENTED — PR-1 #330 (shared, merged) + PR-2 (platforms, this PR).**
> Gate-2 device verification pending (relayed checklist). Original design record below.
> (Gate-1 decisions locked 2026-07-15; adversarial internal
> review applied — the engine-guard, field-drop, seed-window, and
> delete-blast-radius rules below are review-driven.)
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
  exemption, non-counting rejection), `buildSharedCounterGroups`
  isCounter enumeration branch, `computeBrowsableTasks` pair-keyed exclusion,
  goal-less `generateCounterTaskTitle` variant, seed-sentinel constant,
  classify-match helper (returns matched Task), tests. No behavior change until
  UI sets the flag.
- **PR-2 (platforms):** GRDB migration + Swift model/ports
  (`SharedCounterGroups.swift`, `BrowsableTasks.swift`, `LinkableCounter.swift`),
  engine-guard + latch relaxation ×2 platforms, compound-child write guards via isGoalLessCounter (Zod cannot inspect the referenced row; inline autoCreate children are already schema-safe), web combined create+seed op,
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

## Counters UX refresh (design locked 2026-07-18)

Handoff: `design_handoff_refining_counters/` (gitignored; README + SPEC +
`proto/counters-refined.html`, authoritative sections Turns 8 → 7 → 4 → 3;
Turns 1/2/5/6 are explorations — do not implement). Ground-up UX refresh of
the counters area — Hub, Detail, creation surfaces, board-play touchpoints —
**web + iOS in the same release** (handoff resolved decision 6).

### The model (no schema change)

- **Identity = (verb, noun)** — exactly today's `action` + `unit` key,
  case-insensitive, trimmed. Verb defaults to **"Do"**.
- **Counter display name** = `"{Verb} {noun}"` with "Do" elided:
  Do·push-ups → "Push-ups"; Run·miles → "Run miles". The P5 goal-less
  `"{action} ({unit})"` parenthetical format is **removed** — the goal-less
  title IS the counter name. No unit chips anywhere.
- **Task titles** = `"{Verb} {goal} {noun}"` via `generateCounterTaskTitle`
  unchanged; custom titles still override.
- **Linking** — exact pair match at creation auto-links, always with a
  visible hint card + "Don't link" opt-out. No fuzzy matching, no silent
  merges. Run·miles ≠ Bike·miles by construction.
- **Legacy verb-less counters** — silent display-only "Do" backfill; **no
  data migration** (single-user pre-release).
- **Dedupe at create collapses to one state**: exact pair collision → gold
  "You already have this counter → Open it". The P5 promote/standalone
  classifier UI and green "Use as counter" card are **removed** (Turn 7
  superseded Turn 4). The underlying promote operation may remain as an
  internal seam but has no create-sheet entry point.

### Amount logging

- Chips **1 / default / 25 / #custom** on Counter Detail, the Hub ledger
  card's one-tap "+ Log" pill, and the shared-square quick actions; a plain
  board tap logs the default amount.
- **default = last-used amount per counter** — new persisted
  `defaultLogAmount` (local persistence, synced like preferences; storage
  location decided at R2 planning).
- **Undo reverses the whole log entry**, not −1 — `TaskEvent.delta` already
  carries signed amounts, so a "+10" is one increment event and undo
  reverses that entry. Undo depth = last entry now; full ledger arrives
  with P4 storage.
- Decrement mirrors the add amount and clamps lifetime at 0 (disabled at 0).

### Screens (see handoff README for pixel spec)

- **Hub**: one-line intro; ledger cards keep per-task rows + gain the
  "+ Log" pill; header "New counter" hidden when empty; empty state = single
  CTA. Desktop: 2-up grid.
- **Detail**: kicker "SHARED COUNTER"; hero all-time + 7-day sparkline +
  milestone bar; stat strip Today / Streak / Best week (**P4 data — UI built
  now, fed later**); blue log card with amount chips + −/Add pair; one-line
  explainer; task cards ("Appears on" chip section removed); "Recent weeks"
  history (P4); delete demoted to a quiet red text link. Desktop: two-column
  (sticky log rail left).
- **Creation**: CreateCounterSheet → Verb (default "Do") + "What you count"
  (plural noun) + optional "Start from", live preview card, RisoButton
  footer (ad-hoc button CSS deleted). CountingStepFields → labels
  **Verb\* · Goal\* · Counting\***, live title preview, blue auto-link hint
  card + outlined "Don't link" pill. DeriveCounterModal → "Smaller version",
  inherits the pair, previews derived title, RisoButton footer.
- **Board-play**: RisoCreditedToast amount-aware ("**+10 push-ups** — also
  counted on Daily Grind.") + Undo pill; RisoArrivalBanner tightened copy;
  square modal/context menu gains the same amount options.

### P4 contract

The P4 storage plan must include **counter-level** closed-window rollups
(not just per-task) — "Best week" / "Recent weeks" / sparkline feed from it
(handoff resolved decision 5).

### Delivery (lockstep PRs, web + iOS together)

- **R1 — identity & creation surfaces**: shared counter-name formatter
  (Do-elision + verb-less backfill) replacing the parenthetical branch;
  CreateCounterSheet/NewCounterSheetView refit (fields, preview, gold-only
  dedupe, promote UI removed, RisoButton footers); CountingStepFields relabel
  + link-hint card + "Don't link"; derive modal retitled to "Smaller
  version" **and** now LINKS the created task to the source counter via the
  shared `resolveDeriveLinkTarget` (no chained links — a derive-of-a-derive
  links to the resolved ROOT source, never to the intermediate derived task;
  baseline = the root's lifetime `currentCount ?? 0`, i.e. always
  start-fresh) — this fixed a pre-existing iOS TODO'd bug where "Derive
  smaller version…" created a standalone, unlinked duplicate task despite
  the modal's own copy promising "same counter, lower goal"; Swift-mirror
  vector updates.
- **R2 — Hub + Detail refresh**: ledger card + "+ Log" pill; empty state;
  Detail hero / stat strip / log card with amount chips; `defaultLogAmount`
  persistence; last-entry Undo; delete-as-link; desktop layouts; P4 stub UI.
  Also in scope: edit/copy task sheets adopt the Verb/Counting vocabulary
  (still Action/Unit after R1) + a same-pair standalone-vs-hub-counter
  disambiguation note (editing/copying a task whose pair matches both a
  standalone counting task and an established hub counter needs a rule for
  which one wins — R1 shipped creation-time auto-link only, not this case).
- **R3 — board-play touchpoints**: amount-aware toast + Undo; banner copy;
  square quick-action amounts; board tap logs default; decrement mirrors
  amount. Also in scope: toasts/arrival banners switch from stored task
  titles to pair-derived counter names (`formatCounterName`) — R1 only
  changed the Hub/Detail/creation surfaces; `RisoCreditedToast` /
  `RisoArrivalBanner` still read `task.title` today.

### Resolved (2026-07-20)

Four decisions locked at R2 planning time (owner), recorded here per the R2
Task 1 brief:

1. **Default log amount lives on the source Task** — new additive optional
   `Task.defaultLogAmount?: number` (positive int), synced per-row LWW like
   every other task field, forward-compat like `isCounter`. NOT a new table,
   NOT a preference.
2. **Sparkline/Today are fed for REAL, rollups stay stubbed** — the
   Counter Detail 7-day sparkline and "Today" stat derive from the source
   task's real `task_events` (`deriveCounterDailyTotals`,
   `src/algorithms/counterDailyTotals.ts`); Streak / Best week / Recent
   weeks remain placeholder UI pending genuine P4 counter-level rollup
   storage (§P4 contract above).
3. **Reusable log toast + whole-entry Undo** — a single "Logged +N · Undo"
   toast component is shared across Hub, Detail, and the R3 board-play
   surfaces; Undo reverses the WHOLE last log entry (tombstone the last
   increment `TaskEvent` on the source, correct `currentCount`, re-cascade)
   via the pure selector `selectLastIncrementEntry`
   (`src/algorithms/lastCounterLogEntry.ts`), not a flat −1.
4. **Milestone helper lifted to shared** — `nextCounterMilestone` /
   `counterMilestoneProgress` (`src/algorithms/counterMilestone.ts`) replace
   the two drift-prone per-platform copies (web `nextMilestone` in
   `CounterDetailPage.tsx`, iOS `milestone` in `CounterDetailView.swift`);
   both platforms delete their local copy in favor of the shared export.

### R3 — accepted platform divergence (context-menu packaging)

The board square's amount quick-actions are packaged platform-idiomatically
(R3 final review adjudication, 2026-07-21): **web**'s context menu offers
`+1 / + Add {default} / # Custom…` (custom routes to the detail modal's chip
row); **iOS**'s context menu offers single `+ Add {N}` / `− Remove {N}`
quick-actions with the full `+1 / +{default} / #` chip row one tap away in
the stepper sheet (SwiftUI context menus can't host a text-entry chip). Same
capability set — one-tap default log, +1, custom amount, custom-persists-
default — different idiomatic packaging, like TabBar vs bottom-nav. What IS
contract-bound on both: the decrement mirrors the add amount, labels
disclose the amount, and plain tap logs the default without persisting it.

**Undo race (accepted, all surfaces)**: Undo reverses the counter's *latest*
live entry at tap time via `selectLastIncrementEntry` — not an entry id
captured by the toast. A log arriving from another surface/device inside the
toast window is reversed instead of the displayed one. Accepted for a
single-user product (same-surface re-logs replace the toast); threading the
entry id through the toast payload is the exact-fix if this ever matters.
