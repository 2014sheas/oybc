# Board Sources — wizard pools & task-selection rework

Design locked 2026-09-04. Handoff: `Reworking pools and task selection.zip`
(gitignored; extracted working copy at `scratch/pools-task-selection-handoff/` —
README is the pixel spec, `Pools rework - decisions.md` the design decision log,
`Board Wizard - Pools Rework.dc.html` the interactive reference, frames 393pt,
built from current SwiftUI metrics against the synced Riso kit). **iOS is the
primary target; web follows in-effort** (locked, see §Locked decisions).

This document supersedes parts of [`POOLS_RECURRING.md`](POOLS_RECURRING.md):
the spawn record's task-source model (`poolIds`/`removedTaskIds` + the
`(union − removals) + manual` mix formula), wizard step 2's pull-in-a-pool
card + provenance subtitles + save-as-pool, and the core-setup chip-strip
pre-fill. The `Pool` entity, the Tasks-tab pool surfaces, the pool edit sheet,
the `CoreBoardDefault` table, pause/resume, and the lazy-spawn machinery all
remain canonical there.

**The one-sentence model:** a board's task list is assembled from *sources* —
pulled **pools** and pulled **boards**, each one row with a two-handle range
(how many of its tasks land on the board), per-board exclusions, and (for
boards) a done/not-done filter — plus hand-added tasks; recurring boards store
the source *references and rules*, never a task list, and every spawn resolves
the live sources fresh.

## Data model

### New shared type: `BoardSource`

```
BoardSource {
  sourceId: string,            // Pool.id, or the pulled Board's id
  kind: 'pool' | 'board',
  min: number,                 // ≥ 0; default 0
  max: number | null,          // null = "all" (tracks the source's live
                               // available count); default null
  excludedTaskIds: string[],   // per-board exclusions; the saved pool/board
                               // is NEVER modified
  filter: 'all' | 'todo'       // boards only; pools always 'all'
}
```

- `max: null` is the **"all" latch**: a source pulled and left alone follows
  its live size (pool edited, squares completed) without storing a stale
  number. Excluding a member while max is at "all" keeps it latched (the
  design's "max follows down / restores back up" falls out of the latch —
  no bookkeeping). A numeric `max` is a deliberate handle drag.
- `expanded` (row open/closed) is **UI state only — never persisted, never
  synced**.
- Default range for a fresh pull is `[0, all]`; **Use all** resets to it.
- **Min cap** (enforced in UI and clamped defensively in validation):
  `min ≤ min(availableCount, fillableCellCount(size, center))`.

### Where sources live

1. **`RecurringBoardTemplate.sources?: BoardSource[]`** — replaces `poolIds`
   + `removedTaskIds` as the task source. `manualTaskIds` **survives
   unchanged** as the hand-added layer. `poolIds` and `removedTaskIds` join
   `seedTaskIds` as retired-but-decode-compat fields (left verbatim on
   migrated records, never read after migration — the `seedTaskIds`
   precedent; see §Migration).
2. **Wizard drafts** — the `Board.recurringDraftMix` JSON column gains a
   **v2 codec**: `{ v: 2, sources: BoardSource[], manualTaskIds: string[] }`.
   v1 blobs (`{poolIds, manualTaskIds, removedTaskIds}`) upgrade on hydrate
   via the same mapping as the template migration. **One-off drafts now
   persist the blob too** (today only recurring drafts do) — without it a
   resumed one-off draft can't rehydrate its source rows. The column name is
   historical; do not rename it (decode compat + sync).
3. **One-off boards, once created, have no sources.** The wizard resolves
   sources into concrete `BoardTask` rows at create; the source rows are a
   wizard-time device. No post-creation sources editing, no re-deal (the
   shipped Board Edit feature is untouched — "locked once made" is about
   sources, not about editing squares).

### Sync surface

No new collections. Changed **fields on existing synced collections**:
`recurringBoardTemplates` gains `sources`; `boards.recurringDraftMix` carries
the v2 blob. Zod schemas extend forward-compatibly (unknown-field-tolerant
decode on both platforms, as ever). The C4 sync-contract fixture (collection
lists) is unaffected, but the shared Zod + Swift decoders change in lockstep.
Standard per-row LWW; the whole `sources` array is one field on its record —
no per-source merge (same stance as `taskIds` on `Pool`).

### Migration (as shipped in P1 — fallback-on-read, no data backfill)

The original sketch here called for a first-launch data backfill; P1
shipped something simpler and strictly safer:

- **GRDB v30 is column-only** (`ALTER TABLE recurring_board_templates ADD
  COLUMN sources TEXT`); **Dexie needs no version bump at all** (the field
  is unindexed — Dexie stores are schemaless beyond indexes). **No row is
  rewritten by migration.**
- Instead, every read goes through **`sourcesForRecord(record)`**
  (`algorithms/boardSources.ts` / `BoardSources.swift`): the stamped
  `sources` array when present, else
  `poolIds.map(id => ({sourceId: id, kind: 'pool', min: 0, max: null, excludedTaskIds: [...removedTaskIds], filter: 'all'}))`
  derived on the fly. Every write stamps `sources` going forward. This
  covers pre-P1 rows AND rows later pulled from an old client, forever —
  no backfill idempotency to test, no mixed-version window to reason about.
- **Excludes are NOT distributed by supply** — the FULL flat
  `removedTaskIds` list is copied to every derived source. Semantically
  identical to the old global suppression (an exclude for a task the pool
  doesn't supply subtracts nothing — stale-inert by design) and needs no
  pool lookups, so the mapping is pure and synchronous.
- Result is **behavior-identical**: `[0, all]` ranges + full-list excludes
  reproduce the old mix exactly, so existing records spawn unchanged until
  the user touches a slider (locked by the shared behavior-identity tests).
- v1 draft blobs decode forward the same way (`sources` derived from the
  trio inside the codec); write-back happens on the next save.
- **Dual-write during P1:** every template/draft write stamps BOTH
  `sources` (canonical) and the legacy trio (`poolIds`/`removedTaskIds`
  mirrored via `mixFieldsFromSources`; `manualTaskIds` is live in both
  models), so every pre-rework reader — roster health, provenance, an old
  client build — keeps working untouched. P2 migrates those readers to
  sources natively and retires the trio to decode-compat (the
  `seedTaskIds` precedent).

## The selection algorithm (shared, both platforms)

Lives in `packages/shared` (successor to `resolveMix` in
`algorithms/poolMix.ts`), consumed by wizard create, spawn, and preview
shuffle. Deterministic given a seed. Mirrored Jest ↔ XCTest vectors are the
P1 acceptance gate.

**1. Resolve each source's available list:**
- `pool` → the pool's non-deleted, resolvable `taskIds` − `excludedTaskIds`.
- `board` → resolve the **instance** (see §Boards as sources), take its
  non-deleted `BoardTask` rows' task ids − `excludedTaskIds`; when
  `filter: 'todo'`, drop tasks whose cell is complete **in that instance's
  window** (the unified per-cell resolver from BOARD_INTEGRITY — never the
  lifetime cache).

**2. Candidates & dedupe:** each source's available list in row order,
then any manual-only ids appended — the same deterministic order the old
`resolveMix` produced (pool union first, manual extras last), so the
non-randomized path slices the identical first-N the old spawn did;
**dedupe first-seen by task id**. A task present in two sources, or by
hand and in a source, counts once and appears once. (Note: `placeBoard`
itself does no dedupe — it must never be fed duplicates; dedupe is this
layer's job.) Selection honors the template's `isRandomized` via a
`randomize` flag: shuffled picks when true, candidate-order picks when
false — preserving the `isRandomized: false` determinism contract.

**3. Header math / gate** (as shipped, `computeSourceCapacity`): capacity =
`min(uniqueCandidateCount, cappedBound)` where `uniqueCandidateCount` =
|dedupe(manual ∪ all availables)| and `cappedBound` = Σ per-source effective
max (`max ?? availableCount`, capped at availability) **plus only the manual
tasks no source supplies** — a manual task inside a source counts toward
that source's membership cap, not separately (see step 4). Short when
capacity < `fillableCellCount(size, center)` → red gate ("N more to fill the
board"), Next/Create disabled. **Sum of maxes, not mins** — mins express
"guarantee at least n from this source", not supply. With numeric caps AND
heavy cross-source overlap this is an upper-bound estimate (exact
feasibility is a matching problem); the fill is the final arbiter and never
underfills.

**4. Fill** (as shipped, `selectBoardTasks`): ranges are **membership**
constraints — for every source i, `min_i ≤ |board ∩ available_i| ≤
effectiveMax_i`. No pick is "attributed" to one source: a task supplied by
two sources counts toward both memberships (and may satisfy two mins at
once); a hand-added task that a source also supplies counts toward that
source's cap. Mins are satisfied first (sources in row order, random picks
within the source, clamped to availability — never an error), then the
remaining cells fill at random from all remaining admissible candidates.
Boards are **always exactly filled** (unchanged invariant): capacity short
at create is gated; a short pick at spawn skips the window and warns (the
existing `pool_too_small` path) — never an underfilled spawn. Overfill
remains the variety mechanism; extras rotate. Exact semantics are pinned by
the shared vector set (`boardSourceVectors.json`, Jest ↔ XCTest over the
identical seeded LCG).

**5. Shuffle** (one-off preview only): re-run the fill with a fresh seed.
Ranges, excludes, and filters never change; only which tasks are picked
within them.

Variety stays **memoryless** (locked): no rotation ledger, no
least-recently-used state — per-spawn randomness, as today.

## Counter-family exclusivity + honest capacity (owner directive 2026-09-08)

Two post-ship rules layered onto the selection algorithm, both platforms,
vector-pinned:

- **One square per shared-counter family.** A counting root and its
  derived versions (`sharedCounterId`) are distinct tasks that tick
  together — two of them on one board makes no sense, so the fill places
  at most ONE member of a family (`buildCounterFamilyMap`:
  `sharedCounterId ?? id`, counting tasks only). Collision priority:
  **pinned CHOSEN center** (its mates are pruned before the draw, so the
  center swap can never collide) > **hand-added** (source-only mates are
  pruned) > **covering an unmet min** (Phase A reaches those first) >
  the draw. The wizard shows a "shares a counter with 'X' · one per
  board" hint on colliding rows, and the capacity/unique counts count a
  family once. Enforcement is the SELECTION PATH (wizard create + every
  spawn); Board Edit / add-to-live-board surfaces are a tracked
  follow-up.
- **The gate never overpromises.** `computeSourceCapacity().capacity` is
  now a deterministic DRY-RUN of the actual fill (uncapped, unshuffled —
  `computeAchievablePoolSize`), honoring caps, cap overlap, the family
  rule, and the pin — the real pool size, computed before any
  preview/deal. A short RANDOMIZED deal retries once in that same
  deterministic order, whose bounded pick is a prefix of the dry-run:
  **gate-passed ⇒ the board fills**, closing the old upper-bound gap
  (pathological cap overlap could previously pass the gate and then
  come up short / fall back with caps ignored). The one-off flat
  fallback also keeps one-per-family now.

## Loose-ends sweep (owner directive 2026-09-09 — "resolve everything")

Beyond the two rules above, the same sweep closed every remaining gap in
the pool-generation surface, both platforms:

- **Series binding implemented** (see §Boards as sources — previously a
  shipped-vs-design gap) + parents-first spawn ordering.
- **Roster health went sources-native**: the Board-settings repeating
  roster resolved via the legacy trio, so a board-source-only record
  showed a spurious badge and "0 tasks", and ranges/families were
  invisible. Now: web `fetchTemplateSupplyResolution` +
  `computeRosterHealth` + `useTemplateRosterHealth`; iOS
  `RecurringBoardTemplatesViewModel.computeRosterHealth` — counts and
  previews use the achievable pick; the badge is the spawn's static twin,
  `source_board_missing` included. The dead legacy layer
  (`useTemplateMix(es)`, `computeTemplateAttention`/`Mixes`) is retired.
- **Board-play add/swap guard**: `CellSwapModal`/`CellSwapSheet` exclude
  tasks already placed and family-mates of placed counters — with the
  outgoing square's slot replaceable (swapping "Read 20" → "Read 50" is
  legitimate). Pure predicate `isSwapCandidate` unit-locked.
- **Spawn note sources-native**: `summarizeSpawnProvenanceFromSupplies`
  (TS + Swift) computes "of M" as the achievable size; copy "pulled in"
  (not "from the pool" — squares can come from pulled boards).
- **Dead-source rows** name themselves ("Deleted pool"/"Deleted board")
  instead of rendering blank; roster/card copy drops "template"/"Spawn".
- Considered and deliberately excluded: a compound whose CHILD shares a
  counter with a placed square (a checklist referencing the counter, not
  a second counter square), and double-pinning a family in the defaults
  sheet (the wizard hint + the deal already resolve it).

## Boards as sources (new capability)

- **Binding is to the series, resolved live** *(implemented in the
  2026-09-09 loose-ends sweep — the initial P3/P4 ship bound to the stored
  instance)*. Pulling a board that belongs to a recurring series
  (`spawnedFromTemplateId` set) binds to the series: every resolution
  (wizard, roster, spawn, the play-screen note) hops the stored id to the
  series' **live instance** — the one whose window contains the reference
  instant (the spawn's window start; "now" elsewhere), else the newest
  started live instance — via `resolveSourceBoard` (web
  `db/operations/boardSources.ts` / iOS `AppDatabase+BoardSources`). An
  archived old window never kills the pull. Pulling a plain one-off board
  binds to that board itself. The source sheet lists **active boards
  only**. Two supporting rules: the spawn pass runs **parents first**
  (yearly → monthly → weekly → daily, stable within a tier —
  `findTemplatesPendingSpawn`'s tail sort) so a child board pulling a
  parent series sees the parent's fresh window in the same pass; and
  `removeMissingBoardSources` treats a source as missing only when the
  resolver finds nothing live.
- **Flatten one level:** a pulled board contributes its concrete `BoardTask`
  rows — never a recursive walk into that board's own sources.
- **Completion is just windowed completion.** A pulled square is the same
  Task; finishing it anywhere counts everywhere it appears. No linked-square
  indicator, no clone (the shared-task semantics from Phase 6 hold).
- **Source with nothing left** (all excluded / all done under 'todo' / pool
  emptied): contributes nothing, the board fills from its other sources —
  **never blocks the spawn, no notice**.
- **Ask on the next spawn only when nothing live resolves.** With series
  binding, the ask (`source_board_missing` → the Boards-tab prompt: Remove
  that source / Pause this board / Not now; copy "…a board that's no
  longer available") fires when the resolver finds NO live instance: a
  gone/archived one-off source, or a series whose every instance is
  deleted/archived. No board row is written until the user answers
  (lazy-spawn invariant intact). The same rule surfaces statically as the
  Board-settings roster badge.

## Surfaces (handoff README §Screens is the pixel spec; frame ids in parens)

1. **Tasks step (2a)** — content order: pool header card (count/progress =
   §3 header math; copy "N more to fill the board. Widen a pool's range or
   add tasks." / "✓ Fills your board · N extras rotate in" — no "min"
   suffix), quick-add card, dashed **"Add a pool or board"** row (opens the
   sheet), dashed library row, **"On your board"** list = source rows +
   hand-added task rows, red gate line when short. Source row: letter square
   (pool = ink "P", board = **gold fill + ink-static "B"** — dark-contract
   rule), name, subtitle, chevron (expands), ✕ (removes the source).
   Expanded panel: segmented **All squares / Not done yet** (boards only),
   the range block (two-handle slider, "Use all", note line only when range
   ≠ default), member rows (✕ exclude / UNDO pill / green-✓ filtered-done).
2. **Add a pool or board sheet (2c, empty state 5c)** — bottom sheet, search,
   POOLS then BOARDS sections, tap-to-toggle check circles; empty state
   "Nothing to pull from yet" with the dashed mini-grid.
3. **One-off Preview (2b)** — the grid + full-width **↻ Shuffle** (exists
   today; chrome per spec: no kicker, no caption). Rearrange survives
   unchanged.
4. **Recurring Preview (5b)** — **no grid**: summary card (name, cadence
   line, one row per source with its range line — "up to 7" / "3–5" / "4" /
   "not done · up to 2" — every hand-added task as its own row, SQUARES
   count green when filled), footer Back / Create. Replaces today's deck
   list.
5. **Post-creation source editing (5a — via the wizard, locked decision):**
   NOT a new screen. "Edit" on a repeating board keeps opening the **wizard
   in edit mode** (the shipped board-split re-entry); its reworked Tasks
   step *is* the sources UI, and edit mode gains the one-line note
   **"Changes apply from the next board."** Frame 5a's chrome maps onto
   wizard edit mode; changes affect future windows only (already true of
   wizard edit save). One-off boards get no sources editing (§Data model 3).

### Removed from the wizard (with current homes, recon 2026-09-04)

| piece | web | iOS |
| --- | --- | --- |
| Pull-in-a-pool chip card | `BoardWizardTasksStep.tsx` ~600–624 | `RisoPoolPullCardView.swift` |
| Core-default chip strip | `BoardWizardTasksStep.tsx` ~626–664 | `RisoCoreDefaultChipStripView.swift` (⚠️ also used by `CoreDefaultsEditSheetView` — it stays there; remove the wizard usage only) |
| "Start every \<TF\> board with…" checkbox | `BoardWizardTasksStep.tsx` ~665–676 + `useCoreBoardDefaults` write | `BoardWizardTasksStepView.swift` ~252–291 + VM write |
| "Save these N as a new pool…" | `BoardWizardTasksStep.tsx` ~783–792 | `BoardWizardTasksStepView.swift` ~507–530 |
| Provenance subtitles ("from X" / "added by hand") | `classifyChipProvenance`/`deriveTaskProvenance` (`poolPullLogic.ts`) | row subtitle logic |
| Core floor gate as a separate control | `computeCoreFloorGate` render sites | `RisoCoreFloorGateView.swift` | 

(The in-wizard recurring toggle the handoff also removes is already gone —
the board creation split retired it; only stale comments remain.)

**Core defaults (locked): pre-pull as sources.** A fresh core-board wizard
session pre-pulls each `CoreBoardDefault.corePoolIds` entry as a source row
at `[0, all]` and adds `coreDefaultTaskIds` as hand-added rows. The wizard
never writes `CoreBoardDefault` anymore — the Board-settings defaults sheet
becomes the **sole** author surface. The table, its sync collection, and the
defaults sheet are unchanged.

## Copy rules (owner-enforced)

- Never **"deal"** or **"draw"** in UI text (the design-tool iterations used
  "Deal again" — the shipped control is **Shuffle**).
- Never **"template"** or **"spawn"** in UI text (standing rule from the
  board split).
- No provenance subtitles, no explanatory footers. Minimal text.
- Gate copy: "N more to fill the board." Header extras: "N extras rotate in".

## Invariants (do not regress)

- Boards are **always exactly filled** — gate at create, skip-and-warn at
  spawn, never underfill.
- **Lazy detection/spawn only** — no background creation; the
  deleted-source prompt blocks, it doesn't auto-resolve.
- **The saved pool/board is never modified by any board-side action** —
  excludes, ranges, and filters are all on the *pulling* board's source
  entry.
- Dedupe by task id before placement — `placeBoard` must never receive
  duplicates.
- Riso: platform tokens only; gold fills take **ink-static** content; where
  a handoff value conflicts with a shipped Riso component, the shipped
  component wins.
- Sealed/windowed-completion rules unchanged: the 'todo' filter reads the
  per-cell resolver, never lifetime caches.

## P2 implementation notes (iOS, as shipped)

- **The wizard VM went sources-native**: `BoardWizardViewModel.sources`
  (+ `supplyInfoBySourceId` cache and UI-only `expandedSourceIds`) is the
  state; the legacy trio became *computed* mirrors (`pulledPoolIds` /
  `removedTaskIds`), so the P1 dual-write falls out for free. All sources
  behavior lives in `BoardWizardViewModel+Sources.swift` (the VM god-file
  SHRANK 1118→909 and left the allowlist). `poolOrder` now orders
  hand-added rows only — source members render inside their row's panel.
- **Library-sheet deselect of a source-supplied task excludes it from
  EVERY supplying source** (the sheet has no per-source scope) — this
  reproduces the old flat-removal outcomes exactly, including the
  untoggle-persist/clear worked example, now pinned end-to-end in
  `BoardWizardPoolMixActionsTests`. The panel's ✕ is per-source.
- **One-off creates honor ranges**: `buildWizardPlacement` picks via
  `selectBoardTasks` when sources exist (randomize = the template flag;
  a CHOSEN center is swapped into the pick if the draw skipped it; a
  short pick falls back to the flat selection — can only overfill toward
  `placeBoard` truncation, never underfill).
- **Core prefill filters to resolvable entries** (a deleted pool/task
  never seeds a dead row on a FRESH wizard) — draft/template hydration
  deliberately keeps unresolvable references instead (a sync-restored
  source returns).
- **Genuinely un-migrated template edit** (every generalized field
  absent) hydrates `seedTaskIds` as hand-added rows — preserving the
  P1-era M2 rule (`poolIds: []` resolves to an empty mix; only
  fully-absent fields fall back).
- **Board-source "done"** uses the `windowedIsCompleted` predicate
  (event-owning → windowed; compound/achievement/derived → lifetime
  cache), via `AppDatabase.fetchBoardSourceSupply`.
- **The recurring Preview interim**: until P3's summary card, the deck
  list renders collapsed read-only source rows above the hand-added rows
  so the full mix stays visible.
- The "Changes apply from the next board." note renders under the wizard
  stepper whenever `editingTemplateId != nil` (the frame-5a vehicle).
- New kit pieces: `RisoRangeSlider` (two-handle, "all"-latch re-latch at
  the top stop), `RisoSourceRowView`, `RisoSourcePickerSheetView`;
  `RisoTaskKind.init(taskType:)` extracted (4th duplicate).

## P3 implementation notes (as shipped)

- **The recurring Preview is the frame-5b summary card** — name, a
  cadence line reusing the shipped Repeats copy ("Every week · first
  board Aug 17 – 23"), one row per source with its range line ("up to 7"
  / "3–5" / "4" / "not done · up to 2"), the hand-added rows, and the
  SQUARES total (green when filled). It absorbs the board-split's 3-row
  Repeats/Size/Pool card (Setup/Pool edits stay reachable via the
  stepper). No grid, no shuffle, no deck list.
- **One-off Preview chrome is unchanged** — the shipped centred-header +
  Preview⇄Rearrange bar wins over frame 2b's header-less minimalism
  (§Fidelity: the shipped component wins), and Rearrange survives by
  prior lock.
- **Board-kind sources now resolve at SPAWN on both platforms** (the P1
  stub supplied `[]`): the source board's live placed squares, with the
  `'todo'` filter applied against THAT board's window via the shared
  windowed predicate; batched reads inside the spawn transaction. The
  wizard-time and spawn-time resolutions share the same code path
  (`AppDatabase.resolveSupply` / web `resolveBoardSupply`).
- **The deleted-source ask**: spawn skips with the new
  `source_board_missing` reason when ANY pulled board is missing,
  soft-deleted, or archived (checked before supply resolution — distinct
  from the silent empty-source rule, which covers a LIVE board with
  nothing left). iOS surfaces a Boards-tab alert — "Remove that source"
  (drops dead board-kind entries via
  `AppDatabase.removeMissingBoardSources`, keeps the P1 mirrors
  consistent, re-runs the pass so the window fills from the remaining
  sources) / "Pause this board" / "Not now" (re-asks next tab open;
  lazy, never background). Web SKIPS identically (spawn semantics stay
  lockstep) and shows roster attention copy; its ask UI lands in P4.

## P4 implementation notes (web, as built)

The web wizard is now sources-native, mirroring the iOS P2/P3 shape:

- **Hook** (`useBoardWizard.ts`): `sources` is the state; `pulledPoolIds`/
  `removedTaskIds` are DERIVED memos (the P1 dual-write). Pool supplies
  resolve synchronously from the live `pools`/`tasksById` props; board
  supplies via an async `fetchBoardSourceSupply` effect (the one
  structural divergence from iOS's sync GRDB reads). The selection-union
  recompute effect never purges (transient-empty live-query hazard during
  hydration) — purging of center/pending/staged state is ACTION-driven
  (`commitSources`), mirroring iOS. Hydration: draft v2 blob > template
  `sourcesForRecord` (with the un-migrated `seedTaskIds`-as-manual M2
  fallback) > empty; the core-defaults prefill lands as sources + manual
  with dead refs filtered. The controller's ~350-line type surface moved
  to `boardWizardTypes.ts` (re-exported — no import-site churn) to keep
  the hook under its size cap.
- **Pure helpers** (`pages/createHub/wizardSources.ts`): the web port of
  `BoardWizardViewModel+Sources.swift`'s testable core —
  `algorithmSupplies` / `sourceCapacity` / `selectionUnion` /
  `excludeFromEverySupplier` (library-sheet deselect = exclude from EVERY
  supplier; manual wins on reselect) / `toggleExcludeInSource` / clamps /
  `sourceRangeLine`. Unit-locked in `wizardSources.test.ts`.
- **Board-supply resolution** (`db/operations/boardSources.ts`):
  `resolveBoardSourceSupply` is pure over caller-supplied reads and shared
  verbatim with the spawn path (the P3 wizard-time = spawn-time lock);
  `fetchBoardSourceSupply` + `fetchSourceSheetBoardEntries` (ACTIVE-only)
  are the async wrappers. Loaded off-render at `BoardWizardPage` (the same
  batching rule as iOS's off-main `loadPools`).
- **Components**: `RangeSlider` (pointer-driven two-handle slider, "all"
  latch on the top stop, nearer-handle grab with ties-to-min),
  `SourceRow` (header + expanded panel: board segmented filter, range
  block, member ✕/UNDO/✓ rows), `SourcePickerSheet` (dashed entry +
  bottom sheet, POOLS/BOARDS search, empty state) — all CSS-module +
  Riso-token styled, following `LibrarySheet`'s sheet chrome. `PoolList`
  gained `countOverride`/`leadingRows` (iOS parity); `TasksPoolHeader`
  takes `capacity` with the design's short/filled copy; the step's gate is
  capacity-based with the red "! Add N more" line.
- **Preview 5b**: `BoardWizardPreviewStep` renders the summary card
  (name, cadence, per-source range lines, hand-added rows, SQUARES
  `capacity/required`) for recurring; the one-off header is hidden in
  recurring mode (the card carries name + cadence). The old 3-row
  Repeats/Size/Pool card and the deck list are retired.
- **Placement**: `buildWizardPlacement` runs the shared `selectBoardTasks`
  ranged pick when sources exist (short-pick fallback places the flat
  selection — can only overfill), with the min-aware CHOSEN-center swap
  ported from iOS. Persist writes native `sources` (template verbatim +
  draft-blob v2); locked in `wizardPersist.test.ts`.
- **Deleted-source ask**: `MissingSourceDialog` on `BoardsPage`
  (Remove that source → `removeMissingBoardSources` op + spawn-pass
  `rerun()`; Pause; Not now re-asks next tab open). The op mirrors iOS
  (drop dead board sources, recompute trio mirror, bump + enqueue, one
  transaction); `useRecurringBoardSpawn` gained the `rerun` trigger.
- **Removals**: the "PULL IN A POOL" chip card, the P5 core chip strip +
  "Start every…" checkbox + floor-gate copy, "Save these N as a new
  pool…", and ALL provenance subtitles (`taskProvenance` is gone from the
  controller; `TaskRow`/`LibrarySheet`/`PoolList` no longer render
  provenance). e2e: `pool-pull-wizard.spec.ts` rewritten for the sheet +
  source-row + exclude/UNDO flow; `pool-row-editor.spec.ts` hand-adds via
  the library sheet (source members are not inline-editable).

## P5 close-out (cleanup, as shipped)

- **Web dead code retired:** the P3 pull/untoggle/manual-bookkeeping/
  provenance/chip-classification/`syncPoolOrder` layer is gone —
  `poolPullLogic.ts` keeps only `applyCoreBoardDefaultPrefill` (the
  Board-settings defaults summary's resolver; its pull fold is now a
  private helper) and `computeCoreFloorGate` (the Preview Activate gate).
  `rosterEditLogic.ts` (caller-less since the roster edit sheet retired)
  deleted with its test. `TaskRow`'s `readOnly` deck variant removed.
  ~30 orphaned CSS rules pruned from the Tasks-step + Preview modules.
- **iOS dead code retired:** `RisoCheckboxRow` (caller-less since the
  "Start every…" checkbox removal) deleted from `RisoControls.swift`
  with its five snapshot baselines. `RisoCoreFloorGateView` and
  `RisoCoreDefaultChipStripView` deliberately KEPT (live callers:
  Preview core gate; `CoreDefaultsEditSheetView`).
- **Copy-rule sweep:** the spawn-provenance note's "Dealt N of M" →
  "Picked N of M" (shared `formatSpawnProvenanceNote` + iOS mirror +
  tests + e2e); the Achievement subtitle's "Watch a template" → "Watch a
  repeating board" (both platforms) and the iOS detail fallback likewise.
  (`isFreshlyDealtBoard` and other identifiers keep their names — the
  copy rules govern user-facing strings.)
- **e2e locks:** `pool-pull-wizard.spec.ts` asserts the removed
  affordances are GONE (pull-chip card, save-as-pool, provenance
  subtitles) alongside the new source-row flow; draft/template source
  hydration is unit-locked (`wizardPersist.test.ts` round-trips,
  `recurringDraftMix` codec tests) rather than e2e'd.
- **Allowlist shrinks locked in:** `useBoardWizard.ts` 1191→1120,
  `BoardWizardTasksStep.tsx` 1041→888 (with P1/P2's schemas.ts +
  BoardWizardViewModel.swift removals, the rework retired four god-file
  entries' worth of debt in total).
- Deferred (recorded, not done): `@oybc/shared`'s
  `clearRemovalsForUntoggle`/`resolvePoolUntoggleRemovals` still exist
  for the legacy `resolveMix` spawn path shared with iOS — they retire
  whenever `resolveMix` itself does (post-migration horizon).

## Delivery — phases (docs-PR-first; iOS-first UI, web in-effort — locked)

| Phase | Scope | Platforms |
| --- | --- | --- |
| **P0** | This document; POOLS_RECURRING.md supersession banner; CLAUDE.md pointer; ROADMAP F11. **SHIPPED** (#457). | docs |
| **P1** | `BoardSource` type + Zod + Swift mirror; `sources` on the template; draft-blob v2 (incl. one-off drafts); GRDB v30 column + `sourcesForRecord` read-fallback (no data backfill, no Dexie bump); the selection algorithm + mirrored vectors; spawn + template persist read/write sources with the legacy-trio dual-write (UI unchanged, behavior-identical for existing records). **SHIPPED** (#458). | lockstep |
| **P2** | Tasks step rework (2a) + source sheet (2c/5c) + the §Removals + core-defaults pre-pull + edit-mode note line. **SHIPPED** (#459, device-checked). | iOS |
| **P3** | Preview rework (5b summary; 2b chrome kept as shipped) + deleted-source spawn ask + spawn-side board-supply resolution (BOTH platforms — spawn semantics lockstep). **SHIPPED** (#460). | iOS (+web spawn) |
| **P4** | Web parity for P2–P3 (frames 1a/1b + sheet + edit-mode note). **SHIPPED** (#463). | web |
| **P5** | Cleanup: retire dead components, e2e/snapshot locks, allowlist shrinks, copy-rule sweep, docs close-out. **SHIPPED** (see §P5 close-out). | both |

Each UI phase: implement → independent review → device checklist relayed to
the user → CI-gated merge (the P2–P7 pools cadence). Rule-6 note: P2/P3
iOS-first commits carry the documented parity-gap justification; P4 closes it
within the effort.

## Test strategy

- **P1**: the vector set is the contract — pool/board sources, `[0, all]`
  vs numeric ranges, min satisfaction incl. shared-task double-counting,
  excludes with the "all" latch, 'todo' filtering, dedupe across sources,
  capacity/gate math, migration mapping (run-twice idempotent,
  behavior-identity against `resolveMix` for migrated shapes), v1→v2 blob
  upgrade. Mirrored Jest ↔ XCTest.
- **P2–P4**: snapshot baselines per new Riso surface (source row collapsed/
  expanded, slider states, sheet, empty state, recurring summary);
  VM/hook-layer gating unit tests; e2e update for the new step-2 layout.
- **P5**: e2e lock that the removed affordances are gone and drafts (both
  kinds) resume their source rows.

## Ground-truth notes (recon 2026-09-04 vs dev @ f1b82dd4)

- No range/min/max concept exists anywhere today — the only quantity is the
  single floor `tasksRequired`/`fillableCellCount`.
- `removedTaskIds` is flat per-record by design (no pool attribution) — the
  per-source `excludedTaskIds` is a semantic change; migration distributes.
- Wizard pull state today: `pulledPoolIds` + `manualTaskIds` +
  `removedTaskIds` + derived `poolOrder` (web `useBoardWizard.ts` /
  `poolPullLogic.ts` + shared `poolMix.ts`; iOS `BoardWizardViewModel`).
- Spawn (`recurringBoardSpawn.ts` / `AppDatabase+RecurringTemplates.swift`)
  already resolves live at spawn via `resolveMix` → `buildSpawnPlacement` →
  `placeBoard`; sources slot into the resolution layer, dealing is untouched.
- Preview shuffle already exists for one-offs (web `shuffleNonce`, iOS
  `reseedPlacement`); recurring preview currently renders a deck list.
- The recurring edit re-entry (roster "Edit tasks" → wizard with
  `editingTemplate`) shipped in the board split and is the 5a vehicle.
- The three frozen god-files this rework rewrites
  (`BoardWizardTasksStep.tsx` 1041, `useBoardWizard.ts` 1191,
  `BoardWizardViewModel.swift` 1159) should **shrink** via extraction of the
  source-row machinery into new files — shrink the allowlist, don't bump it.

## Locked decisions log

Sources model per the handoff (2026-09-04). Owner decisions at scoping
(2026-09-04): **core defaults pre-pull as sources** (defaults sheet = sole
author surface; wizard never writes `CoreBoardDefault`); **no separate
Settings › Sources screen — reuse the wizard edit re-entry** (its reworked
Tasks step is the sources UI; edit mode gains the "Changes apply from the
next board" note); **iOS-first delivery with web parity in-effort**;
one-off boards locked = no post-creation sources editing (Board Edit
untouched); variety stays memoryless; `max: null` "all" latch
(coordinator-proposed representation of the design's max-follows-all
behavior).
