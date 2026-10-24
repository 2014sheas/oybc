# Shared Counters

Design handoff: `OYBC Shared Counters.zip` (gitignored `design_handoff_shared_counters/`). High-fidelity Riso design. This doc is the canonical implementation plan.

## What it is

One real-world activity (e.g. *push-ups*) feeds **many** bingo-board squares from a single running tally. Log the activity **once, anywhere** — on any board square or the counter's own page — and every task that measures it updates at once, while each task keeps its **own window** (this week / this month / custom), its own goal, and its own start/finish. Above all the windows sits one **lifetime total**.

Four surfaces:
1. **Counters Hub** (Profile → "Shared counters") — Ledger layout: a card per counter with the lifetime number + a row per member task (board · window, logged/goal, progress bar). *(Tiles / Meters are prototype alternates — ship Ledger only.)*
2. **Counter Detail** — lifetime hero (all-time total), a **Log** stepper, "Appears on" timeframe chips, "Shared by N tasks" list, "Not counting now" (draft/inactive). *(Sparkline / streak / best-window / recent-windows history are P4 — deferred.)*
   - **Show expired tasks** (2026-10-09, both platforms) — Counter Detail carries the hub's own toggle (web `ShowExpiredToggle` ↔ iOS `RisoShowExpiredToggle`) over the member cards; expired members (`isTaskExpired`, the kernel's `memberVisibility`) are hidden by default. Session-only, default off, and one setting across the two screens: web keeps it in `?showExpired=1` (`useShowExpiredParam`, used by both pages), iOS passes the hub's `@State` into `CounterDetailView` and Detail reports flips back (`onShowExpiredChange`). The lifetime total is unaffected.
   - **Member cards show the member's in-window count (kernel), the hero shows all-time** (2026-10-09, both platforms): a card's `n / goal` is the same number its board square shows — never the lifetime total. See `task.logged` under §Model mapping.
   - **Edit counter…** (2026-10-09, both platforms) — the "⋯" overflow lists *Edit counter…* above *Delete counter…*; it opens the **counter sheet in edit mode** (web `CreateCounterSheet` with `root` ↔ iOS `NewCounterSheetView` with `root`; pure model `counterEditModel.ts` ↔ `CounterEditModel.swift`) on the counter's ROOT (`counterId` = root task id; the item is absent when the root is missing / deleted). **Owner rule: a counter is edited through the COUNTER sheet, never the task editor** — same fields as create (Kind, "What are you counting?", "Task verb"), prefilled; no Type, Description, goal or "Start from"; title "Edit counter", button "Save". The kind picker carries the edit locks + the shared Continuous → Discrete confirm; a rename is checked against established counters minus the counter's own family. Save goes through the Task Detail write (web `saveTaskEdit` ↔ iOS `applyTaskEditPatch`): an auto title regenerates from the new verb / noun, a custom one is kept; kind / title / action / unit propagate per D5 (`COUNTER_KINDS.md`) + #575 (live per-board copies; goal stays per-board); a Duration counter keeps its noun. The hub list has no per-counter menu, so Counter Detail is the one edit entry. Seams: `counterDetailMenuItems` ↔ `CounterDetailContent.overflowItems`, `CounterDetailView.editSheet`. A shared counter's TYPE is never changeable anywhere (`TASK_SYSTEM.md` §Editing a task).
3. **Board square logging** — a counting square linked to a shared counter shows a **shared marker** (↔ two dots); tapping opens the stepper with an "also counts on…" hint and fires a **credited toast** naming the other boards that changed.
4. **Passive completion** — logging elsewhere flags affected squares as "arrived"; the next board-open shows a gold **arrival banner** + the square pulsing, and may complete a new **bingo** from activity logged somewhere else.

## Current model (2026-10 — settings + counts toward, SHIPPED)

Shipped by the shared-counters train (#584–#588, close-out docs PR 5); the spec, rationale and decisions D1–D11 are in [`SHARED_COUNTER_SETTINGS.md`](SHARED_COUNTER_SETTINGS.md). Sections below that predate it describe the engine and the earlier UX rounds; where they disagree, this section and the code win.

**Counter settings** (all optional fields on the counter's ROOT `Task`; absent = derived default, never backfilled, stored only when edited — D3; all clearable on sync):

| Field | Meaning | Resolver (`packages/shared/src/algorithms/counterSettings.ts` ↔ `Helpers/CounterSettings.swift`) |
| --- | --- | --- |
| `counterName` | label the hub, Counter Detail, pickers, link hints, toasts show; a label only — noun/verb stay the generator's inputs (D1) | `counterDisplayName` (else `formatCounterName(action, unit)`, else the stored title) |
| `titleTemplateSingular` / `titleTemplatePlural` | square-title templates with `#N` for the count; goal 1 renders the singular, else the plural; no `#N` renders as-is; the singular defaults to the typed plural (D2) | `renderCounterTitle(root, goal)`; `generateCounterTaskTitle` delegates; `isAutoCounterTitle` is template-aware, so a name/template edit re-renders every auto-titled live copy and keeps custom titles (`planRootFieldPropagation`) |
| `timeframeGoals` | default goal per core timeframe (`daily`/`weekly`/`monthly`/`yearly`); an unset one derives from the nearest set one, shown dimmed, stored only when typed (D4); `CUSTOM` never matches | `resolveCounterDefaultGoal(root, timeframe)` |

The counter sheet (web `CreateCounterSheet` ↔ iOS `NewCounterSheetView`, edit mode via **Edit counter…**) reads Name · Kind · What are you counting? · Task verb (required) · Singular title · Plural title · Defaults (2×2) · Start from (create only). One rule for optional fields: blank = the derived default shown dimmed, typing stores, clearing stores absent (Defaults cells store what was typed, verbatim). Caps: name 100, templates 200.

**Placement defaults** (`counterPlacement.ts` ↔ `CounterPlacement.swift`): every placement path (wizard persist, recurring spawn, Preview, Board Edit add / Replace, quick-add) mints the per-board copy at `placementGoalForCounter` — an existing copy's goal, else the counter's default for the board's timeframe, else the root's goal. A hand-added root whose default equals its goal is placed as-is (no identical clone); a picked LINKED row keeps its own goal; pool pulls honour the default (the vary roll's base) and never pro-rate; the one-off board-source prefill keeps its remaining-based target. The match row shows no goal text (retired 2026-10-12); no default for the board → the row shows a Goal entry and the pick hands the host a pending LINKED counting task (a bare one that is replaced is dropped at persist: `dropReplacedLinkedPendingRows`). Search is one shared matcher (`counterSearchMatches` / `taskSearchMatches`: name, noun, verb, plural template with `#N` removed). **Retired:** "Derive smaller version…" (`DeriveCounterModal`, D6) — a smaller target is a timeframe default or the copy's own per-board goal.

**Counts toward** — any NORMAL, plain COUNTING or COMPOUND task may count toward ONE Discrete shared counter (D7, D9; never a Continuous / Duration counter, another counter root, a linked copy or an Achievement). Fields on the contributor: `countsTowardCounterId`, `countsTowardAmount` (positive integer, absent = 1), `countsTowardSince` (present iff the flag is). When the task's derived state completes, the cascade writes an ordinary `increment` event on the counter ROOT with a deterministic id; un-completing tombstones it. A compound still owns no events — the credit lives on the root. A COMPOUND with zero children is legal only while it counts toward a counter (it stays incomplete until it has children that complete).

One credit per completion OCCURRENCE (D10), not per task lifetime — a repeating weekly board's square credits every week it is completed:

| Contributor | One credit per | Stamped at |
| --- | --- | --- |
| NORMAL | live completion event (keyed by its id) | that event's `occurredAt` |
| plain COUNTING | placement window it is complete in (unplaced → lifetime) — keyed by the increment that crossed the goal there | the crossing increment's `occurredAt` |
| COMPOUND | placement window it is complete in (unplaced → lifetime) — keyed by the completing child's canonical event, scoped by fork-lineage root | that child event's `occurredAt` |
| COMPOUND whose completing child owns no event (latched) | placement board (`board:<id>`) or `lifetime` when unplaced | when its rule was met |

The target ROOT is part of every key. Fork lineage shares credits (an original and its board-scoped fork never double-count; a credit stays while any live flagged lineage member wants it).

- **Counted from flag time (D11a).** A credit is wanted only when its instant is at or after `countsTowardSince`; setting the flag does not back-fill, re-pointing resets the stamp and withdraws the old counter's credits. A late log stamped at an ended board's `endDate` before `since` does not credit (D8 × D11).
- **Sealed windows respected (D11b).** An insert / revise / tombstone whose instant lies in a seal-immune window of a board holding the root or a copy is skipped, except at the closed-board late-log path's own stamp.
- **One write path.** Every set / re-point / clear of the flag goes through `setCountsToward` / `setCountsTowardInTransaction` (`apps/web/src/db/operations/countsToward.ts`) ↔ `AppDatabase.setCountsToward` / static `setCountsToward(db:…)` (`AppDatabase+CountsToward.swift`): it validates (`countsTowardProblem`, transitive cycle guard), stamps `since`, and hands the previous root to the cascade. Guards: `promoteTaskToCounter` refuses a flagged task; the counter's kind switch off Discrete is refused while contributors exist ([`COUNTER_KINDS.md`](COUNTER_KINDS.md)); `deleteCounterWithUnlink` unflags contributors; `deleteTaskWithCascade` tombstones the contributor's credits.
- **What the UI shows.** Counter Detail → **Counts toward** (Discrete roots only): one row per fork lineage with a StatusPill for the current-window state, "× N" only when ≥ 2 credits (a unit task always credits exactly one — ruled 2026-10-10; the "+N" mark is gone and `countsTowardAmount` is an inert column no credit reads — the amount helper returns 1 on both platforms), and **+ New** (the create sheet opened from the counter; the new task counts toward it, one credit per completion, with no field shown). **No task form carries a "Counts toward" field** — the editor row #588 added was retired on 2026-10-10 by owner ruling (the field lives in no user-facing interface; a contributor is a *member* of its counter, created from the counter side — see [`SHARED_COUNTER_SETTINGS.md` §3 amendment](SHARED_COUNTER_SETTINGS.md#3-counts-toward-any-task-as-the-unit-of-a-discrete-counter) for the rulings and the pending design round). A contributing board cell wears the two-dot shared mark while not done. Completing a contributor shows the credited toast only when a credit was actually written and the counter has squares on other boards whose counted window holds it; Undo reverses that exact write.

See [`WINDOWED_COMPLETION.md` §Derived-task carve-out](WINDOWED_COMPLETION.md#derived-task-carve-out) for the event rules and [`TASK_SYSTEM.md` §Counts toward](TASK_SYSTEM.md#counts-toward) for the task-model view.

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
| `task.logged` | the member's **in-window count** — what its board square shows (2026-10-09): a placed linked member = the root's increments inside its board's window (`resolveLinkedCounterDisplay`), a placed source (a counting task other boards link to) = its own events inside its board's window (`resolveTaskWindowState`), both bounded at a sealed board's `sealedAt`. Only an UNPLACED row (no board, no window — the library rule) falls back to `deriveDisplayedCount` (source = full count; linked = count − baseline). The counter's all-time number is `lifetime`, never a member's `logged`. |
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
- Gold `.r-arrival` banner on board-open when ≥1 shared square arrived + square pulse (`arriveGlow`, 2 iters) + tap → Counter Detail + ✕ dismiss + ~5.2s auto-clear. Single: "*{task name}* filled in — you logged {counter name} elsewhere. See every board ›". Multiple: "**N squares** filled in from your counters. Open counters ›" (copy tightened in Counters Refresh R3, #342 — `RisoArrivalBanner`).
- **Local last-seen snapshot** per board (`UserDefaults` iOS / `localStorage` web — **not** synced schema): detect on board appear via `detectCounterArrivals`; re-snapshot via `snapshotCounterSquares` on board disappear + after an arrival is shown (so local taps / acknowledged arrivals don't re-fire).
- **Scope = SAME-DEVICE MVP** (log on Detail / another board → open board → banner). Cross-device (another device logs → sync pulls → banner) is a documented follow-up (same last-seen-diff mechanism, needs the sync-pull path).

## Deferred (not in this MVP)

- **P4 rich stats** — 7-day sparkline, counter-level streak, best-window, closed-window history. *(Update 2026-07: the "only real schema addition" this bullet used to require — a per-increment log — has since shipped as `task_events` (`docs/WINDOWED_COMPLETION.md`). P4 is now a pure read-model feature over source-task increment events; counters created from the hub (P5) have full history from birth, with seed events identifiable by the far-past `occurredAt` sentinel.)*
- **True per-window resets** ("a fresh weekly task starts at 0 while all-time climbs") — OYBC's already-deferred "Decision 6 / v2"; the prototype only conveys it via copy + independent goals.
- **Never-reset lifetime accumulator** — MVP uses `currentCount`.
- **Fully-automatic grouping by action+unit** (silent link, no prompt) — NOT building. Instead see "Link suggestions" below.

## Link suggestions — adding a task to an existing counter (SHIPPED, R1)

The handoff's "counters link up on their own" is core, not deferred: without it, adding a task to an existing counter means hunting a dropdown. *(Update — R1 counters refresh, 2026-07-18: this shipped as **auto-link, default ON**, superseding the suggest-confirm design this section originally described.)* Identity is the **(verb, noun) pair** — today's `action` + `unit` key, case-insensitive, trimmed, verb defaulting to "Do" (see [§The model](#the-model-no-schema-change)) — not a single "activity" string. When a new COUNTING task's typed (verb, noun) pair exactly matches an existing counter, the create form links it **by default**: an always-visible `RisoCounterLinkHintView` / `CounterLinkHint` card explains what will happen ("Counts toward your **{name}** counter") with a "Don't link" pill to opt out for that create (toggling back re-enables). No fuzzy matching, no silent merges, no confirm-first step. Accepting (the default) routes through the existing linked-counter create path (`sharedCounterId` + baseline; always **start-fresh** — the baseline is the source's lifetime `currentCount` at link time; the manual "Inherit total" baseline mode was retired in R1). No engine change.

- **Shared:** `findLinkableCounter({action, unit, excludeTaskId?}, tasks) → { counterId, name, lifetime, memberCount } | null` (`packages/shared/src/algorithms/linkableCounter.ts`, Jest-tested). `action` is the **verb** and `unit` is the **noun** — together they form the (verb, noun) pair that identifies a counter (Do·push-ups ≠ Do·sit-ups; Run·miles ≠ Bike·miles by construction). Matches non-derived candidates; most-established counter wins. `name` is `counterDisplayName` — the root's `counterName` when set (shared counter settings, docs/SHARED_COUNTER_SETTINGS.md §1a), else the pair-derived display name (`formatCounterName`), falling back to the source's stored title. iOS ports it (`LinkableCounter.swift`).

**Naming (shared counter settings PR 1, 2026-10-09).** A counter ROOT may carry `counterName`, `titleTemplateSingular` / `titleTemplatePlural` (`#N` = the count) and `timeframeGoals` (default goal per core timeframe). All four are absent until edited (absent = default, never backfilled) and clearable on sync. Every counter label (hub, Counter Detail, pickers, library rows, link hints, arrival banner, credited toast) reads `counterDisplayName`; square titles render through `renderCounterTitle` (`generateCounterTaskTitle` delegates to it — byte-identical for an untouched counter); `isAutoCounterTitle` is template-aware, and a name / template edit re-renders every live auto-titled copy (`planRootFieldPropagation`). Placement using the defaults and the sheet UI have shipped (see [§Current model](#current-model-2026-10--settings--counts-toward-shipped)).
- **UI (both platforms):** the auto-link hint card renders inline in the counting create sub-fields, wherever counting tasks are created (board-wizard Tasks step special panel + its inline compound-sub counting fields, Tasks-tab New Task sheet, quick-add). Linking is on by default; "Don't link" opts out for that create. Reuses `LinkedCounterInput` / `sharedCounterId`.
- **Suggestion pool caveat:** the match pool must include goal-less counters created from the hub (excluded from the browsable task list) and, in wizard contexts, this session's not-yet-persisted pending tasks — otherwise a hub counter or a just-created same-pair task silently fails to link. See `suggestionPool` (iOS `RisoSpecialTaskPanel`/`RisoCompoundFieldsView`; web `BoardWizardTasksStep.effectiveSuggestionPool` / `CreateNewTaskForm`'s `suggestionPool` prop).

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

## P5 — Counters created from the hub (design locked 2026-07-15)

> **Status: IMPLEMENTED — PR-1 #330 (shared, merged) + PR-2 (platforms, this PR).**
> Gate-2 device verification pending (relayed checklist). Original design record below.
> (Gate-1 decisions locked 2026-07-15; adversarial internal
> review applied — the engine-guard, field-drop, seed-window, and
> delete-blast-radius rules below are review-driven.)
>
> Create counters directly in the Counters Hub, instead of a counter existing
> only once a second task links to a source.

### Concept

A counter created from the hub is a **standalone source counting task**: `isCounter: true`,
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
| 5 | *(Browse half superseded 2026-10-12 — goal-less counters are browsable; placement takes the window default / kind fallback, SHARED_COUNTER_SETTINGS.md §1c amendment. The compound-child exclusion + write guard below still hold.)* Library visibility keys on the **pair** `isCounter === true && maxCount == null`: excluded from Tasks-tab browse + wizard boardable picker (via `computeBrowsableTasks`, which both surfaces on both platforms already consume) **and** from compound-child pickers, with rejection at the child-link write layer (a goal-less child can never complete — it would make an AND parent silently unreachable). Keying on the pair, not bare absent-`maxCount`, keeps PR-1 inert and guarantees a row whose flag is stripped by an old client degrades to a *visible library row*, never an unreachable task. |
| 6 | Goal-less counters ARE valid link targets — deliberately kept in the counting template picker and `findLinkableCounter` candidates. |
| 7 | Dedupe at hub-create: classify `findLinkableCounter`'s match — an **established counter** (has links or `isCounter`) → "You already have a **{name}** counter" + jump-to affordance, create disabled; a **standalone task** → one-tap **Promote** (sets `isCounter: true`; keeps its goal, count, placements — it stays library-visible per decision 5). The classify helper returns the matched Task row: `memberCount` alone cannot distinguish a standalone from a flagged single-member counter. *(The standalone branch was removed in R1 Turn 7 and **restored 2026-10-24** as "Use as counter" — see [§Using an existing task as the counter](#using-an-existing-task-as-the-counter-2026-10-24).)* |
| 8 | Hub delete = **unlink-then-delete**: clear each member's `sharedCounterId` + `baseline`, mint one snapshot `increment` event per member (`delta` = its displayed count at unlink, `occurredAt = now`) so its squares keep showing what they showed, then soft-delete the source. `computeTaskDeletionImpact` extends to enumerate member tasks/boards for the confirm dialog. (Review finding: `deleteTaskWithCascade` today leaves members linked to a tombstoned source whose steppers silently no-op — and this doc's old "cascade delete of source→derived" claim was false; corrected in §engine above.) |
| 9 | Board-play shared-ness recognizes flagged counters: the `sharedCounterSourceIds` builders (`useBoardPlayData`, `useCounterArrivals`, iOS twins) add an `isCounter` branch so a promoted zero-link counter placed on a board shows the ↔ marker and participates in P3 arrival detection. |

### Engine change (small but required)

`incrementSharedCounter` / `decrementSharedCounter` currently **throw** on a
nil/undefined source `maxCount` ("data integrity error") on both platforms
(web `tasks.sharedCounter.ts`, iOS `AppDatabase+SharedCounters.swift`) — the
hub counter's own Log stepper would crash on first tap. Both guards relax
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
- **Stale auto-title** if action/unit change post-create: Counter Detail's
  *Edit counter…* (2026-10-09) edits the root's action / unit in the counter
  sheet (an auto title follows), and #575 regenerates live copies' auto-titles.
- **Doc drift recorded:** `WINDOWED_COMPLETION.md` specced hub decrements as
  "tombstone the latest increment"; the shipped hub Detail stepper appends a
  clamped negative delta instead (seed-safe; correction noted in that doc).

### Out of scope (P5)

- "Add to a board" button on Counter Detail — the template-picker /
  link-suggestion path covers the need; button deferred with a seam.
- P4 stats. (Per-window derived display SHIPPED: member rules 2026-09 for wizard-minted rows; 2026-10-01 for every placed linked row — `WINDOWED_COMPLETION.md` §Derived-task carve-out.)
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
- **Dedupe at create**: an exact pair collision with an established counter
  → gold "You already have this counter → Open it"; with a standalone
  counting task → the same gold card offering **"Use as counter"** (restored
  2026-10-24 — Turn 7 had removed the P5 standalone branch, which left the
  hub minting a second root for a pair the library already had). See
  [§Using an existing task as the counter](#using-an-existing-task-as-the-counter-2026-10-24).

### Using an existing task as the counter (2026-10-24)

Owner finding, 2026-10-24: a counting task created on its own (library, a
board wizard, quick-add) could not be made a shared counter — the only ways
were the accidental ones (a second task with the same pair auto-links to it)
and the hub's "+ New counter" minted a **duplicate root** for a pair the
library already had. Both platforms now offer the promote write
(`promoteTaskToCounter` — flags `isCounter`; the task keeps its goal, count,
events and placements) from two places:

1. **Task Detail ⋯ › "Use as shared counter"** — on a plain counting task
   (`canPromoteToCounter`: live `COUNTING`, no `sharedCounterId`, not
   `isCounter`, no `countsTowardCounterId`; shared predicate in
   `linkableCounter.ts` ↔ `LinkableCounter.swift`). Promotes and lands on the
   task's Counter Detail. Web `DetailMenu.onUseAsCounter` ↔ iOS
   `TaskDetailActions.onUseAsCounter` / `TaskDetailModel.canPromoteToCounter`
   / `TaskDetailViewModel.useAsCounter()`.
2. **Hub "+ New counter" on a standalone match** — Create is disabled (like an
   established match) and the gold card reads "You're already counting
   {noun} · {total} all-time · {task title}" with **"Use as counter"**: the
   task is promoted, then the sheet's typed name / templates / defaults are
   carried onto it through the Task Detail write (`counterAdoptSubmit` ↔
   `CounterEditModel.adoptPatch`: the stored settings only, at the task's
   **own verb, noun and kind** — the typed pair matched case-insensitively and
   never rewrites the task's casing; never a kind switch or the seed; nothing
   typed = no second write), and the caller navigates to its detail like a
   create. While the match stands, the kind picker follows the task's kind and
   locks (so the Defaults cells parse in that kind's grammar) and "Start from"
   hides; moving the pair off the match restores the kind the user had chosen.
   Unit tasks are left out of the dedupe pool (the write refuses them and one
   must never shadow an established counter of the same pair), so a lone unit
   task is no match and Create proceeds. A failed settings write after the
   promote reads "Settings not saved." and leaves the sheet open on the
   counter it made.
   Edit mode is unchanged (a rename onto a standalone pair still saves).

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
  card + outlined "Don't link" pill. DeriveCounterModal → "Smaller version" *(superseded: retired in #585, D6 — timeframe defaults replace it)*.
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
captured by the toast. "Latest" means most recently **made**: ordered by
`createdAt` first, `occurredAt` as the tie-break (2026-09-24 — a late log made
from an ended board is stamped at that board's `endDate`, so its `occurredAt`
is old while its `createdAt` is the newest; see `WINDOWED_COMPLETION.md`
§Write paths). A log arriving from another surface/device inside the
toast window is reversed instead of the displayed one. Accepted for a
single-user product (same-surface re-logs replace the toast); threading the
entry id through the toast payload is the exact-fix if this ever matters.

> **Shipped (2026-10-09/10, #584–#588):** per-counter settings, placement at the board-timeframe default and "counts toward" — see [§Current model](#current-model-2026-10--settings--counts-toward-shipped) and [`SHARED_COUNTER_SETTINGS.md`](SHARED_COUNTER_SETTINGS.md).
