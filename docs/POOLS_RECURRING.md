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
- A task may be in many pools. Deleting a pool never deletes tasks.
  **Detachment is derived, not cascaded**: mix resolution and core-defaults
  resolution simply skip `isDeleted` pools at read time (matches
  "health is derived" and the spawn path's resolve-at-read precedent) — no
  multi-record cascade write, no LWW race. Removal entries whose only supply
  was the deleted pool become stale-inert per the removals semantics.
- **Health is derived, never stored**: resolvable non-deleted `taskIds` count
  vs the consumer's `fillableCellCount` (from `@oybc/bingo-core`). Pool cards
  warn ONLY when a repeating board consumes the pool and it's short, as a
  single combined board-count line (`"Short on 1 board"` / `"Short on N
  boards"` — owner decision, 2026-07-20); warnings on pool cards, roster
  rows, and (while it exists) template rows all derive from the same
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

- **Mix = (union(pools' resolvable tasks) − removals) + manual.** Evaluation
  order is normative: removals subtract from the pool union FIRST, then the
  manual layer adds — so a task in both `manualTaskIds` and `removedTaskIds`
  is IN the mix (removals only ever suppress pool-sourced supply; manual
  wins). Spawn deals `fillable` tasks at random from the mix per window via
  the existing `placeBoard`/`buildSpawnPlacement` path (loose-fit: extras
  shuffle in per window — the strict-fit `poolStrategy` selector is already
  gone from dev). Below the floor the window **skips and warns**
  (`pool_too_small`) — never an underfilled spawn.
- **Removals semantics (flat `string[]`, no pool attribution):** a removal
  entry suppresses that task from the pool union regardless of which pool(s)
  supply it. Untoggling a pool clears exactly those removal entries whose
  task is **no longer supplied by any remaining pulled pool** (removals for
  still-supplied tasks persist). Removal entries for tasks not supplied by
  any pulled pool are **stale-inert** — harmless, cleaned opportunistically
  on save, never an error. Worked example: pools A{x,y} and B{y,z} pulled,
  `removedTaskIds:[y]`, `manualTaskIds:[w]` → mix = ({x,y,z} − {y}) + {w}
  = {x,z,w} (y suppressed from BOTH supplies at once). Untoggle B → y is
  still supplied by A, so the removal **persists** → mix = {x,w}. Untoggle
  A too → y now unsupplied → removal cleared → mix = {w}. Re-pull A later
  → y is back in the mix (its removal was cleared, not remembered). These
  edge cases are the P1 unit-test vectors.
- **Union rule (critical, was a caught prototype bug):** pulling a pool into
  an existing mix unions; untoggling a pool removes only that pool's
  non-manual tasks (per the removals semantics above); the manual layer is
  never reset by pool toggles. The saved pool is never modified by any
  board-side action.
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
- Defaults **pre-fill** core-board setup — BOTH fields (pool tasks as plain
  chips, `coreDefaultTaskIds` as plain chips too); they never auto-own the
  board. The "Start every Daily board with 'X'" checkbox (shown only when
  pools are attached) persists `corePoolIds` ONLY — never the day's one-off
  tasks. **`coreDefaultTaskIds` is authored only in the P7 Board-settings
  defaults sheet** (chips + quick-add) — the field exists synced-but-unwritten
  from P1 until P7, which is intentional.
- Table `core_board_defaults`, collection `coreBoardDefaults` — added to
  BOTH `SYNC_COLLECTIONS` and `USER_SCOPED_SYNC_COLLECTIONS` (it carries
  `userId`), alongside `pools` in the same C4 fixture regen.

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
   `defaultPools` stays in the sync list for PUSH drain and joins
   `LEGACY_PULL_SKIP_COLLECTIONS` (composite-tables precedent), drops from
   live UI.
4. Routes `/profile/default-pools`(+`/:timeframe`) and
   `/profile/recurring-templates` removed; `/profile/board-settings` added
   (P7 — the old pages survive until then).

**`seedTaskIds` end state**: left VERBATIM on migrated records (decode-compat,
`lastSyncedCount` precedent) and **never read after P1** — no fallback. This
works because P1 also **rewires the legacy template UI's persistence** to the
generalized model while its UI stays visually unchanged: legacy template
CREATE mints a Pool exactly like migration step 2 (`poolIds:[newPool]`);
legacy template EDIT (the `?editTemplate=` wizard flow + Add-tasks) writes
the linked Pool's `taskIds`. **The write-through is scoped by record shape**:
it applies only to legacy-shaped records (exactly one legacy/migration-minted
pool, empty `manualTaskIds` + `removedTaskIds`) — which is TOTAL during
P1→P4, since migration and legacy-create both produce that shape and richer
shapes cannot exist before P4. Defensive rule anyway: a non-legacy-shaped
record reached by the legacy editor saves its flattened list as
`manualTaskIds` and clears `poolIds`/`removedTaskIds` — the legacy editor
never writes a Pool it didn't mint (shared-pool corruption is the failure
mode this forbids; "the saved pool is never modified by any board-side
action" holds). From **P4**, `?editTemplate=` **re-points into the new
wizard's edit mode** (generalized fields native), so every record shape —
P4 wizard records with shared pools, P6 repeat-this-board records with no
pool — stays editable from the still-alive templates page until P7 retires
it. So there is no window where a record is created into, edited into, or
stranded with a dead field. **Deep-link retirement is split**:
`?newRecurring=1` dies at P4 (with the CTA); `?editTemplate=` survives to P7
(re-targeted at P4 as above) and dies with the templates page whose Edit
buttons emit it.

Mixed-version note: an old client would still write `DefaultPool`/
`seedTaskIds`. Accepted (single user, own devices, sequential updates).
Platform divergence within that same accepted risk: web's pull path
applies a winning remote doc **wholesale** (a pulled old-shape
`RecurringBoardTemplate` — no `poolIds` — overwrites the local generalized
stamp until the record naturally re-migrates), while iOS's GRDB column-merge
pull retains locally-stamped columns a stale remote row doesn't carry —
so only web can transiently fall back onto the stale `seedTaskIds` read
path after such a pull. Bounded by the same single-user, sequential-update
acceptance above; not treated as a bug to fix.

## Surfaces (see handoff README §Screens for pixel spec)

1. **Tasks tab → Pools segment** — Library/Pools pill segmented ("Pools · N");
   pool cards (name, first-4 chips, "+N more", count, contextual short
   warning — one combined line, e.g. `"Short on 1 board"` / `"Short on 2
   boards"`, not one line per consuming board — owner decision, 2026-07-20);
   dashed "+ New pool". **NO board actions on pool surfaces**
   (locked): no "use in board", no FEEDS control, no default pinning.
   Starter packs: **deferred** (locked 2026-07-19) — the card design exists,
   ships when curated content does.
2. **Pool edit sheet** — extends iOS `PoolEditSheet`: NAME field replaces
   timeframe keying; TASKS chips w/ ✕; ADD TASKS mirrors the wizard pattern
   (quick-add row + library reuse picker); dashed deck-preview line (e.g.
   `"8 tasks in the deck · fills a 3×3"` when healthy, or `"6 tasks in the
   deck · short on required tasks"` when short — the short branch drops the
   missing-count and board-size detail, owner decision, 2026-07-20); Delete
   pool (red text) in edit mode.
3. **Create hub** — ONE primary CTA ("Start a new board" / "One-off or
   repeating — decide in setup"); the separate recurring CTA (issue #71's
   entry point, now shipped) retires at P4 along with `?newRecurring=1` and
   its iOS binding equivalent; `?editTemplate=` retires at P7 with the
   templates page (see §Migration).
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
   recurrence on, no Profile trip. **Repeat-this-board writes**: spawn record
   with the board's tasks as `manualTaskIds`;
   `lastSpawnedWindowKey = getTimeframeBoundaries(cadence,
   board.startDate).startDate` (the CADENCE window containing the board's
   start — the chosen cadence may differ from the board's timeframe, and a
   misaligned key would double-spawn mid-window); AND back-stamps the source
   board's `spawnedFromTemplateId` (the badge, manage row, and the spawn
   idempotency belt all key off it).
8. **Boards tab** — outline `RisoRecurringBadge`/`RecurringBadge` gains a
   muted `↻ PAUSED` variant (net-new on both platforms); subtitle spells the
   cadence ("repeats daily"); paused boards stay visible, dimmed, with a
   resume route.
9. **Board settings (Profile)** — replaces both old sub-pages: per-timeframe
   core-defaults rows ("No default tasks", never "Not set") + defaults bottom
   sheet; repeating-boards roster (the safety net for paused boards) with
   Edit tasks + Pause/Resume; roster edit sheet (pool toggles UNION with the
   mix — never wipe the manual layer).
10. **Pool picker sheet (shared)** — rows w/ health note; "+ Build a new
    pool…" round-trips back to the launching context with the new pool
    selected.

## Behavior invariants (do not regress)

- **Fillable floor everywhere** (core setup, wizard Next, roster Save): the
  floor is `fillableCellCount(size, center)` from `@oybc/bingo-core` — 8 is
  the 3×3-with-FREE-center case, NOT a constant (3×3 NONE = 9, 4×4 = 16…).
  Red "N short" + dimmed blocked CTA + toast. Boards are always exactly
  filled; overfill is the variety mechanism — a short mix skips the window
  and warns, never underfill-spawns. The prototype stubs non-3×3 sizes and
  non-Daily timeframes (toasts) — **implement them symmetrically with the
  wired paths**, don't hard-code 8/Daily.
- **Lazy detection/spawn only** — recurrence observed on app open; no
  background creation. Unchanged from Phase 6.
- **"↻ Deal again"** on a fresh spawned board re-deals from the same mix —
  offered only while the window has zero **user**-completed cells (the
  auto-completed FREE/CUSTOM_FREE center never counts — it's completed at
  spawn by derivation).
- Copy rules (owner-enforced): "No default tasks" not "Not set"; "from" never
  "deals from"; keep "extras shuffle into the mix" / "in the deck" language.
- Riso: platform tokens only; press pattern per kit; dark contract (on-color
  on red/blue/green fills, ink-static on gold). Where a prototype value
  conflicts with a shipped Riso component, **the shipped component wins**
  (handoff §Fidelity).
- CRUD blueprints: adapt `recurringBoardTemplates.ts` / `defaultPools.ts`
  (web) and their GRDB twins — don't invent new persistence patterns.

## Test strategy (per phase, repo standards apply)

- **P1**: shared unit vectors for the mix formula — the removals worked
  example above IS the vector set (two-pool overlap, manual-wins, untoggle
  persist/clear, stale-inert, deleted-pool skip) — mirrored Jest ↔ XCTest;
  migration idempotency (run-twice = no-op) + shape assertions; C4 fixture
  regen ×2 platforms (shared Jest fails loudly if forgotten); legacy-UI
  write-through covered (create-mints-pool, edit-writes-pool).
- **P2–P7**: snapshot baselines for each new Riso surface (pill segment,
  pool cards/sheet, manage row, paused badges, board-settings) per the
  snapshot-test conventions; wizard/core-setup floor-gating unit tests at
  the VM/hook layer; an e2e lock on the retire steps (old routes gone, new
  route serves) when P7 lands.

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
  formula (behavior-identical for migrated records), **legacy template UI
  persistence rewired** to the generalized model (create mints a Pool; edit
  writes the linked Pool's taskIds — see §Migration `seedTaskIds` end state),
  `defaultPools` → pull-skip.
- **P2 — Tasks tab Pools segment + pool edit sheet** (+ iOS pill segmented;
  health warnings).
- **P3 — Wizard**: pull-in-a-pool card, provenance subtitles,
  save-selection-as-pool.
- **P4 — Setup step**: Repeats segmented one-flow; retire recurring CTA +
  `?newRecurring=1`; `?editTemplate=` survives to P7 but re-points into the
  new wizard's edit mode (all record shapes editable from P4 on); post-save
  navigation lands on the spawned board.
- **P5 — Core setup**: pool pre-fill + one-off quick-add + "Start every…"
  checkbox writing `CoreBoardDefault`.
- **P6 — Board screen**: manage row w/ Pause/Resume, "Repeat this board…",
  provenance note, paused badge variants, dimmed paused boards.
- **P7 — Board settings page**: defaults sheet + roster + roster edit sheet;
  delete both old Profile pages/routes/deep-link plumbing; achievement picker
  re-point. Migration cleanup notes.

Locked decisions log: direction 2a; pools are storage-first (no board actions
on pool surfaces); prototype baselined on iOS; `removedTaskIds` field added to
the spawn record with the `(union − removals) + manual` evaluation order and
supply-based clearing (post-handoff decision, 2026-07-19); core defaults in a
small table; starter packs deferred; docs-PR-first delivery (this document).
Post-handoff additions beyond the prototype (same date, coordinator-recommended,
owner-approved via plan review): the Deal-again zero-user-completed-cells
guard; Repeat-this-board's window-key alignment + `spawnedFromTemplateId`
back-stamp; derived (non-cascade) pool detachment; the P1 legacy-UI
persistence rewire + split deep-link retirement. P2 review follow-up:
combined board-count card warning + count-free deck-preview short line
(owner, 2026-07-20).
