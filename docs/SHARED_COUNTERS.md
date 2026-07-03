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
- **Additive-merge sync** (`sharedCounterMerge.ts` + Swift twin) — three-way merge via `lastSyncedCount` prevents lost offline increments.
- Inherit-vs-start-from-zero baseline at link time; cascade delete of source→derived.

**Count is global per Task** (`Task.currentCount`); `BoardTask` is a pure placement record with no count. `progress_counters` / `ProgressCounter` / `calculateCountingRollup` are **vestigial dead** (rejected in ARCHITECTURE.md Decision 1 for the per-Task `sharedCounterId` model) — do not use them.

So **Shared Counters = the UX + a read-model on top of the existing engine.** The handoff's own rule #2 admits its prototype applies the same delta to all active windows and conveys "own window" via independent goals + copy — exactly what the engine already does.

## Model mapping

A **"counter"** = one **source** counting task (a task with ≥1 live task linking to it via `sharedCounterId`) + all its linked tasks.

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

- **P4 rich stats** — 7-day sparkline, counter-level streak, best-window, closed-window history. The only real schema addition (needs a per-day / per-window increment log). The Detail screen is built with seams for these.
- **True per-window resets** ("a fresh weekly task starts at 0 while all-time climbs") — OYBC's already-deferred "Decision 6 / v2"; the prototype only conveys it via copy + independent goals.
- **Never-reset lifetime accumulator** — MVP uses `currentCount`.
- **Auto-grouping by action+unit** — MVP surfaces existing explicit `sharedCounterId` groups only; linking stays via the current "link to counter" flow.

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
