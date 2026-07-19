# Task Pools + Recurring Boards Rework

Design locked 2026-07-19. Handoff: `design_handoff_pool_library/` (gitignored —
README + `source-specs.md` + interactive prototypes; `Pool Library
Prototype.dc.html` is the primary visual reference, deliberately baselined on
the **iOS** implementation). Direction 2a of the explored three; 2b
("Routines") explicitly rejected — core boards stay their own concept.

**The one-sentence model:** Pools live in the Tasks tab and just hold tasks;
any board — one-off, core, or repeating — may *draw from* pools at creation;
recurrence is a board setting chosen at setup (or flipped on later, on the
board); the Profile pages "Recurring templates" and "Default pools" retire in
favor of one "Board settings" page.

## Data model

### New entity: `Pool`

```
Pool {
  id, userId, name,            // user-named ("Morning Kickstart")
  taskIds: string[],           // REFERENCES into the task library, never copies
  createdAt / updatedAt / lastSyncedAt? / version / isDeleted / deletedAt
}
```

- Tables `pools` (GRDB + Dexie), Firestore `users/{uid}/pools`. Standard
  per-row LWW + tombstones; added to `SYNC_COLLECTIONS` +
  `USER_SCOPED_SYNC_COLLECTIONS` → **C4 sync-contract fixture regen on both
  platforms** (`syncContract.json` ×2).
- A task may be in many pools. Deleting a pool never deletes tasks. Deleting a
  pool detaches it from any repeating board's mix and from core defaults.
- **Health is derived, never stored**: resolvable non-deleted `taskIds` count
  vs the consumer's `fillableCellCount` (from `@oybc/bingo-core`). Pool cards
  warn ONLY when a repeating board consumes the pool and it's short
  (`"2 short of a 3×3 — Weekly reset can't spawn"`); warnings on pool cards,
  roster rows, and (while it exists) template rows all derive from the same
  source — fix once, heals everywhere.

### Changed: the spawn record (recurrence as board property)

`RecurringBoardTemplate` **survives internally** as the spawn record — it just
stops being a user-facing noun. Its task source generalizes:

```
seedTaskIds: string[]        → RETIRED (migrated, then decode-compat only)
poolIds: string[]            // pools pulled into the mix (may be empty)
manualTaskIds: string[]      // hand-picked additions (may be empty)
removedTaskIds: string[]     // per-board removals of pool-sourced tasks (locked 2026-07-19)
```

- **Mix = union(pools' resolvable tasks) + manual − removals.** Spawn deals
  `min(fillable, mix)` at random per window via the existing
  `placeBoard`/`buildSpawnPlacement` path (loose-fit: extras shuffle in per
  window — the strict-fit `poolStrategy` selector is already gone from dev).
- **Union rule (critical, was a caught prototype bug):** pulling a pool into
  an existing mix unions; untoggling a pool removes only that pool's
  non-manual tasks **and clears its `removedTaskIds` entries**; the manual
  layer is never reset by pool toggles. The saved pool is never modified by
  any board-side action.
- Own-mix (hand-picked, zero pools) repeating boards are first-class.
- `isActive` pause semantics, `lastSpawnedWindowKey`, lazy spawn-on-app-open,
  and soft-delete-keeps-spawned-boards are all unchanged.
- Re-pointing a repeating board's mix affects FUTURE windows only.
- Achievement tasks with `referencedTemplateId` keep working unchanged — the
  id denotes the repeating board's spawn record; pickers re-label from
  "recurring template" to the repeating board's name (P7).

### New entity: `CoreBoardDefault` (locked 2026-07-19: small table, not prefs)

Replaces `DefaultPool`. One row per `(userId, timeframe)`:

```
CoreBoardDefault {
  id, userId, timeframe,       // DAILY/WEEKLY/MONTHLY/YEARLY, immutable
  corePoolIds: string[],       // pools that pre-fill core-board setup
  coreDefaultTaskIds: string[],// individual default tasks
  createdAt / updatedAt / lastSyncedAt? / version / isDeleted / deletedAt
}
```

- Chosen over UserPreferences fields because prefs sync as a single LWW doc
  (concurrent prefs writes would race the whole default set); per-row LWW
  matches the `DefaultPool` precedent it replaces.
- Defaults **pre-fill** core-board setup; they never auto-own the board. The
  "Start every Daily board with 'X'" checkbox persists `corePoolIds` ONLY —
  never the day's one-off tasks.
- Table `core_board_defaults`, collection `coreBoardDefaults` (sync contract
  addition alongside `pools`).

### Migration (hard cutover — single-user pre-release, same stance as the counters refresh)

First-launch backfill on each platform (composite-tables pattern), then the
old rows are inert:

1. Each `DefaultPool` row → a `Pool` named `"<Timeframe> default"` + a
   `CoreBoardDefault` row with that timeframe's `corePoolIds = [newPool]`.
2. Each `RecurringBoardTemplate` → its `seedTaskIds` extracted into a `Pool`
   named `"<template name> pool"`; record gets `poolIds: [newPool]`,
   `manualTaskIds: []`, `removedTaskIds: []`.
3. `DefaultPool` rows soft-deleted (tombstones drain to Firestore via the
   known-collections list, exactly like the legacy composite tables);
   `defaultPools` stays in the sync list for drain, drops from live UI.
4. Routes `/profile/default-pools`(+`/:timeframe`) and
   `/profile/recurring-templates` removed; `/profile/board-settings` added
   (P7 — the old pages survive until then).

Mixed-version note: an old client would still write `DefaultPool`/
`seedTaskIds`. Accepted (single user, own devices, sequential updates).

## Surfaces (see handoff README §Screens for pixel spec)

1. **Tasks tab → Pools segment** — Library/Pools pill segmented ("Pools · N");
   pool cards (name, first-4 chips, "+N more", count, contextual short
   warning); dashed "+ New pool". **NO board actions on pool surfaces**
   (locked): no "use in board", no FEEDS control, no default pinning.
   Starter packs: **deferred** (locked 2026-07-19) — the card design exists,
   ships when curated content does.
2. **Pool edit sheet** — extends iOS `PoolEditSheet`: NAME field replaces
   timeframe keying; TASKS chips w/ ✕; ADD TASKS mirrors the wizard pattern
   (quick-add row + library reuse picker); dashed deck-preview line; Delete
   pool (red text) in edit mode.
3. **Create hub** — ONE primary CTA ("Start a new board" / "One-off or
   repeating — decide in setup"); the separate recurring CTA (issue #71's
   entry point, now shipped) retires, along with `?newRecurring=1` /
   `?editTemplate=` deep links and iOS binding equivalents.
4. **Wizard step 1** — **Repeats** segmented `Once / Daily / Weekly / Monthly
   / Yearly` + one-line note; Timeframe segmented only when Once (a repeating
   board's cadence IS its window); no pool selection here (locked).
5. **Wizard step 2** — shipped layout + "PULL IN A POOL" toggle-chip card
   (unions into selection, freely tweakable, saved pool untouched);
   provenance subtitles ("from Morning Kickstart" / "added by hand"); dashed
   "Save these N as a new pool…" under the list.
6. **Core-board setup** — "Start with a pool — optional" toggle chips
   pre-fill; pre-filled chips plain, hand-added chips blue-tinted w/ ✕ +
   one-off quick-add; "Start every <TF> board with 'X'" checkbox (sole
   default-setting affordance besides Board settings); activate blocks below
   the floor with "Add N more".
7. **Board screen** — spawn-success provenance note ("Dealt 8 of 10 — 9 from
   defaults, 1 added today"); repeating boards get a manage row
   `↻ Repeats daily · from "Morning Kickstart"` with inline Pause/Resume;
   one-off boards get dashed `↻ Repeat this board…` → cadence picker →
   recurrence on with the board's tasks as `manualTaskIds` and
   `lastSpawnedWindowKey` = the board's own window (no Profile trip).
8. **Boards tab** — outline `RisoRecurringBadge`/`RecurringBadge` gains a
   muted `↻ PAUSED` variant (net-new on both platforms); paused boards stay
   visible, dimmed, with a resume route.
9. **Board settings (Profile)** — replaces both old sub-pages: per-timeframe
   core-defaults rows ("No default tasks", never "Not set") + defaults bottom
   sheet; repeating-boards roster (the safety net for paused boards) with
   Edit tasks + Pause/Resume; roster edit sheet (pool toggles UNION with the
   mix — never wipe the manual layer).
10. **Pool picker sheet (shared)** — rows w/ health note; "+ Build a new
    pool…" round-trips back to the launching context with the new pool
    selected.

## Behavior invariants (do not regress)

- **8-task floor everywhere** (core setup, wizard Next, roster Save): red "N
  short" + dimmed blocked CTA + toast. Boards are always exactly filled;
  overfill is the variety mechanism — never underfill-spawn.
- **Lazy detection/spawn only** — recurrence observed on app open; no
  background creation. Unchanged from Phase 6.
- **"↻ Deal again"** on a fresh spawned board re-deals from the same mix —
  offered only while the window has zero completed cells.
- Copy rules (owner-enforced): "No default tasks" not "Not set"; "from" never
  "deals from"; keep "extras shuffle into the mix" / "in the deck" language.
- Riso: platform tokens only; press pattern per kit; dark contract (on-color
  on red/blue/green fills, ink-static on gold).

## Ground-truth notes (recon 2026-07-19 vs dev @ c199526)

- Dealing already lives in `@oybc/bingo-core` `placeBoard` (loose-fit,
  shuffle, extras ignored) — spawn work is mix *resolution*, not dealing.
- `defaultPools` is already a synced collection — its retirement is a
  migration + contract change, not removal of dead code.
- `Board.spawnedFromTemplateId` + `isActive` already model provenance/pause;
  the play-surface manage row is new UI over existing data (board→template
  lookup precedent: the achievement badge path).
- iOS `RisoSegmented` lacks the pill variant web has — small kit addition in
  P2. Neither platform has a paused badge variant.
- Achievement pickers (`RisoSpecialTaskPanel` templates list; web special-task
  panel) currently enumerate templates by name — P7 re-labels them to
  repeating boards, same ids.

## Delivery — 7 lockstep PRs (web + iOS together)

- **P1 — Pool + CoreBoardDefault entities, sync, migration** (mostly inert):
  types/Zod/GRDB/Dexie/Firestore rules, sync contract + C4 fixture regen ×2,
  first-launch migrations (DefaultPool→Pool+CoreBoardDefault;
  seedTaskIds→Pool + generalized spawn record), spawn path reads the mix
  formula (behavior-identical for migrated records).
- **P2 — Tasks tab Pools segment + pool edit sheet** (+ iOS pill segmented;
  health warnings).
- **P3 — Wizard**: pull-in-a-pool card, provenance subtitles,
  save-selection-as-pool.
- **P4 — Setup step**: Repeats segmented one-flow; retire recurring CTA +
  deep links; post-save navigation lands on the spawned board.
- **P5 — Core setup**: pool pre-fill + one-off quick-add + "Start every…"
  checkbox writing `CoreBoardDefault`.
- **P6 — Board screen**: manage row w/ Pause/Resume, "Repeat this board…",
  provenance note, paused badge variants, dimmed paused boards.
- **P7 — Board settings page**: defaults sheet + roster + roster edit sheet;
  delete both old Profile pages/routes/deep-link plumbing; achievement picker
  re-point. Migration cleanup notes.

Locked decisions log: direction 2a; pools are storage-first (no board actions
on pool surfaces); prototype baselined on iOS; `removedTaskIds` field added to
the spawn record; core defaults in a small table; starter packs deferred;
docs-PR-first delivery (this document).
