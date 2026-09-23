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

**Second pass (design locked 2026-09-17):** [§Member rules](#member-rules--counting--compound-tasks-pulled-from-sources-design-locked-2026-09-17)
adds per-member rules for counting and compound tasks pulled from sources
(cadence-scaled targets, opt-in variation, One square / Split up), realised
as per-window **derived counters** minted at persist/spawn. It replaces the
undesigned ⋯ member menu from #471 and retires the "From a board…" grid
picker (companion plan A). Read it before touching member rows,
`planDerivedTasks`, or any linked-counter read.

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
  filter: 'all' | 'todo'       // boards only; pools always 'all';
                               // a FRESH pull starts on 'todo'
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
- **Default filter for a fresh pull is kind-scoped: `'todo'`** ("Not done
  yet") **for a board source, `'all'` for a pool** — owner directive
  2026-09-19, so pulling a board supplies what is still outstanding rather
  than re-dealing finished squares, while a pool (no per-board done state
  to filter on) still defaults wide. One definition per platform:
  `newSourceFilter(kind)` (web `wizardSourcesLogic.ts`) ↔
  `BoardWizardViewModel.newSourceFilter(for:)` (iOS). Scoped strictly to
  CREATION: a source already stored on a board or template keeps its saved
  filter, `sourcesFromMixFields` (legacy-trio decode) still mints `'all'`,
  and nothing coerces on decode. No clamp is needed at mint time — `[0,
  all]` is the one range valid against ANY supply, so a narrowed filter
  can't leave a row wider than its filtered supply.
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

**Interactive companion**: the "Board Pool Assembly" artifact
(https://claude.ai/code/artifact/bac50352-1f8f-4402-8e27-66ebb7e11900 —
owner's private Claude artifact) carries the full explainer with live
deal simulators (a verified line-for-line port of `selectBoardTasks`).
Keep it in sync when the mechanics in this doc change.

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
   suffix), quick-add card, dashed **"Add from a pool or board"** row (opens the
   sheet), dashed library row, **"On your board"** list = source rows +
   hand-added task rows, red gate line when short. Source row: letter square
   (pool = ink "P", board = **gold fill + ink-static "B"** — dark-contract
   rule), name, subtitle, chevron (expands), ✕ (removes the source).
   Expanded panel: segmented **All squares / Not done yet** (boards only),
   the range block (two-handle slider, "Use all", note line only when range
   ≠ default), member rows (✕ exclude / UNDO pill / green-✓ filtered-done).
2. **Add from a pool or board sheet (2c, empty state 5c)** — bottom sheet, search,
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
- **Achievements never enter source supply** (owner decision, 2026-09-10):
  watcher tasks are hand-placed only. The pool use case (rotating
  meta-squares) was judged too niche pre-launch, and the spawn/deal path
  runs no cycle check — a dealt achievement watching its own series would
  deadlock its spawn (greenlog trigger) — plus a completed template-mode
  watcher would re-deal as a permanently-green square. Enforced at BOTH
  supply resolvers (`isSourceSupplyTask` in shared `boardSources.ts` ↔
  `BoardSources.isSourceSupplyTask` in Swift — filtered inside
  `poolSourceSupplyById` and the board-supply readers, so legacy pool
  members and synced data are excluded uniformly; capacity, roster
  health, and the deal all read through them) AND in every pool-sheet ADD
  surface (`allowAchievement={false}` on the special-type panel, filtered
  quick-add/library pickers). The wizard's hand-add path still places
  achievements — that path runs `hasCycle` at create/copy time. Revisit
  post-launch if the meta-square use case earns its complexity.
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
| **A** | Retire the "From a board…" grid picker + Copy modal + `SourceBoardsViewModel`/`useSourceBoards` + `copyTask`; strip the Library-sheet chip; docs/memory/snapshots. Keeps `fetchCompoundChildrenByCompoundIds` (B needs it). **SHIPPED** (#487). | lockstep |
| **B0** | §Member rules into this doc (this section); `WINDOWED_COMPLETION.md` carve-out paragraph; CLAUDE.md pointer. **SHIPPED** (#486 — landed with the spec). | docs |
| **B1** | Shared types (`memberRules`, `manualTaskVary`) + Zod + Swift mirrors; draft-blob additive (still v2); GRDB **v31** column; pure helpers (`nominalWindowDays`, `autoTarget`, `varyRange`, `rollTarget`, `applyMemberRules`, `planDerivedTasks`) + mirrored vectors. Inert — nothing writes rules yet. **SHIPPED** (#489). | lockstep |
| **B2** | Resolution + mint + non-authored baseline (mint / local root writes / pull sub-step) + the three deletion cascades (task, counter-hub, board) + `deriveDisplayedCount` read audit + `repeatBoard*` gap fix + spawn `compoundChildren` hoist; wired into wizard persist and spawn. Behaviour change only for counting tasks pulled from *board* sources (auto target). **SHIPPED** (#491). | lockstep |
| **B3** | UI: member rows (stepper / dice / One square–Split up / part lines), hand-added dice, primitives, wizard actions, Preview derived cells, edit-mode note, #471 menu removal, hub expired filter, iOS Library-sheet derive entry stripped; snapshots + Playwright. **SHIPPED** (#492) — the member-rules train (A → B0–B3) is complete. | lockstep |

Each UI phase: implement → independent review → device checklist relayed to
the user → CI-gated merge (the P2–P7 pools cadence). Rule-6 note: P2/P3
iOS-first commits carry the documented parity-gap justification; P4 closes it
within the effort.

#### Plan A — implementation notes (2026-09-17)

Both platforms, one PR. Web deleted `FromBoardPicker`/`FromBoardGrid`/`BoardThumbnail`/`CopyTaskModal` (+CSS), `useSourceBoards`/`useSourceBoardPlacements`, `tasks.copy.ts` (+ its Vitest file) and the Library sheet's `'from-board'` chip; iOS deleted `FromBoardPickerView`/`FromBoardGridView`/`CopyTaskSheet`/`SourceBoardsViewModel`, `AppDatabase.fetchEligibleSourceBoards`, `copyTask`/`copyCompound`, `LibraryFilter.fromBoard`, and the `RisoWizardLibrarySnapshotTests` suite (14 baselines). Kept deliberately: `fetchCompoundChildrenByCompoundIds` (knip-baselined until B0–B3 consume it), the iOS Library sheet's inline "⇲ Derive smaller" (B3 strips it), `RisoDeriveCounterSheetView` (source-row derive), `RisoMiniGrid`/`BoardPreviewCells` (Boards tab). No user-visible change — the Library sheet is dark behind `LIBRARY_ENTRY_ENABLED`/`libraryEntryEnabled` on both platforms.

#### Plan B1 — implementation notes (2026-09-18)

`BoardSource.memberRules` + `RecurringBoardTemplate.manualTaskVary` are additive on both platforms' types/Zod/Dexie/GRDB — nothing writes them yet (inert). GRDB v30 (moved verbatim) + v31 relocated into a new `AppDatabase+Migrations.swift` (`registerBoardSourcesMigrations`) to keep `AppDatabase.swift` under the file-size allowlist (1010 → 1005). Pure helpers live in new `packages/shared/src/algorithms/memberRules.ts` ↔ `apps/ios/OYBC/Helpers/BoardSourceMemberRules.swift` (`extension BoardSources`) — not `boardSources.ts` (1000-line ceiling) — vector-pinned by `packages/shared/tests/fixtures/memberRuleVectors.json` (24 `planDerivedTasks` vectors, synced to `apps/ios/OYBCTests/Fixtures/`, mutation-tested both platforms).

Rulings: **R1** `planDerivedTasks(mode: 'oneOff' | 'recurring')`; `autoTarget` runs only for recurring; a one-off member with no explicit target resolves to `goal`. **SUPERSEDED 2026-09-21 — see §Target math and §Owner ruling: one-off boards pro-rate too.** `autoTarget` now runs for ANY board-sourced member in either mode; `mode` is still on both signatures but is no longer read by `resolveTarget` / `effectiveMemberTarget`. **R2** `applyMemberRules` returns `ExpandedSupply` = supply + `partOf: Record<childId, compoundId>`. **R3** last-part guard: exclusions that would exclude every child leave all children contributing; `split` on a non-compound/childless member contributes the member itself. **R4** a One-square compound with no rule places as-is; it derives only once a counting part has a target (part-level, or member-level `vary` auto on a board source) or `vary > 0`. **R5** `resolvedTarget = clamp(rule/auto/goal, 1, goal)` then roll; members with no `maxCount ≥ 1` place as-is. **R6** one rng sample per roll, `selectedIds` order then `childIndex` order inside a compound; no sample when `lo == hi`. **R7** `nominalWindowDays(CUSTOM)` = inclusive calendar-day span via UTC `YYYY-MM-DD` arithmetic; `null` if a bound is missing; INDEFINITE → `null`. **R8** derived title = `generateCounterTaskTitle(action, target, unit, action ? undefined : title)`. **R-pool** pool-sourced members ignore `target` at both member and part level (vary/split/exclusion only). **R-rename** the planner arg is `sourceWindowByTaskId`, keyed by supplied members AND the children of a One-square compound. **R-round** `varyRange` rounds half-up (`Math.round` ↔ Swift `.rounded()`), pinned by tie vectors. **R11** corrupt `manualTaskVary` levels: TS drops only the bad key, iOS drops the whole map — both converge to "no dice" (unobservable once B3 writes valid levels). **R12** `varyRange`/`rollTarget` for `goal < 1` and the title of an action-less, title-less counting member are unreachable via `goalOf` / real task data — left as-is on both platforms. **R13** two things sharing a shared-counter root collapse onto ONE derived counter, and the dedupe is checked BEFORE the roll, so a collapsed occurrence consumes no rng sample; inside a One-square compound the collapsed parts are additionally deduped by resolved child id (first in `childIndex` order wins, keeping its own `childIndex`/`linkId`), because `derivedLinkId` is a pure function of `(compound, child)` and a repeat is one `compound_children` primary key written twice. **R14** both `childIndex` sorts use a total comparator (`childIndex`, then `childTaskId`) — Swift's `sorted` is not stable, so a duplicate index would otherwise expand/roll (and consume the seeded rng) differently on each platform.

Task 2's test measured a worst-case `RecurringBoardTemplate` (20 board sources × 8 members × 3 parts) at 43,193 bytes; `firestore.rules`' `request.resource.size() < 10000` can't be the byte-size check the spec assumed (Firestore rules expose no byte-size API — the real cap is the 1 MiB/doc platform limit), so the test instead guards a regression ceiling (< 65,536 bytes). B2 item: an emulator rules test that writes a worst-case record to settle what that clause measures and whether it needs to change.

Remaining B2 items surfaced during B1 review: (a) **R9** — iOS has no `fetchCompoundChildrenByCompoundIds` (Plan A's KEEP note is web-only; iOS has `fetchCompoundChildren(compoundTaskId:)`) — B2 adds a batched iOS fetch. (b) two selected *members* sharing a root could yield a duplicate placement id (unreachable via `selectBoardTasks` family exclusivity) — B2's persist dedupes `placementIds` as a guard; the intra-compound twin of this is fixed in B1 (R13). (c) Swift `sort` is unstable — B1 made both comparators total (R14); B2 still adds a write guard for unique `childIndex` per compound. (d) `dayNumber` edge semantics diverge from JS `Date.UTC` for year 0–99 / out-of-range parts — unreachable from real ISO dates. (e) **False alarm, closed:** the B1 review claimed iOS sends the five JSON-TEXT fields of a `RecurringBoardTemplate` as JSON *strings* on the sync wire. It does not — GRDB stores them as strings, but every push goes through `SyncService.writeFirestoreDoc` → `SyncWirePayload.expandJSONStrings`, which turns them into native arrays/objects before Firestore (since #11), and the pull side re-stringifies for GRDB. Web's `RecurringBoardTemplateSchema` therefore sees arrays/records. Pinned by `SyncWirePayloadTests` (iOS) and the pull-validator Vitest (web); issue #488 closed by this fix. B2 is NOT blocked on it. (f) the rules-cap emulator test above.

#### Plan B2 — implementation notes (2026-09-18)

Both platforms, one PR (#491).

- **Landed**: mint at active-only wizard persist and at every recurring
  board creation (`spawnTemplateBoard` ↔ `spawnRecurringBoard`; web
  `db/operations/derivedCounters.ts` ↔ iOS
  `Database/AppDatabase+DerivedCounters.swift`), driven by shared
  `computeWindowBaseline` / `isWindowStampedDerived` / `buildDerivedRows`
  (`memberRules.ts` ↔ `BoardSourceMemberRules.swift`), vector-pinned incl.
  timezone-invariant baseline vectors. `refreshDerivedBaselines` is a
  non-authored cache refresh (no version bump, no enqueue) run before
  propagation in increment/decrement/undo and as a pull sub-step (the
  batch loop and `healMissingCompletionEvents`). Three deletion cascades
  (task-cascade, counter-hub unlink, board-delete) via
  `softDeleteWindowStampedDerived`. Read audit: web
  `pages/tasks/taskCountDisplay.ts` ↔ iOS `Helpers/TaskCountDisplay.swift`.
  A `tasks` pull that lands a window-stamped derived row re-derives that
  row's baseline from the local event union, same non-authored posture
  (`refreshPulledDerivedBaseline` ↔ the Swift twin, called from the pull
  cascade) — without it a stale minting device's short baseline wins by
  LWW and inflates every read on a device whose events are complete.
  `repeatBoard*` now writes `sources: []` + `manualTaskVary: {}`, drops
  derived compounds from the copied roster and records derived counters by
  their root. `deleteCounterWithUnlink` hands the boards of the members it
  retires to the cascade so they re-derive in the same transaction. Roster
  health expands split members. iOS added a batched
  `fetchCompoundChildren(db:compoundTaskIds:)` and a GRDB v32 index on
  `tasks(sharedCounterId)`.
- **Rulings (plan)**: RB1 wizard-side supply expansion deferred to B3.
  RB2 baseline = strictly-before boundary, instants; INDEFINITE → mint now.
  RB3 idempotent mint (live → skip; tombstoned → revive). RB4 (amended by
  the B2 final review) `repeatBoard*` drops derived compounds and records a
  placed window-stamped derived COUNTER by its ROOT id, deduped, skipping a
  root that is missing or deleted — the derived row is retired with its own
  board under RB5, so a record naming it would be skipped for every future
  window (`has_deleted_tasks`) the day that board is deleted; the root is
  durable library content and is what each window re-mints from anyway. The
  per-window target is re-derived at each assembly, not carried. RB5 a live
  placement = a live row on a live board; `deleteBoard`'s own placements
  are untouched. RB6 platform rng. RB7 read audit from the task's own
  mirror. RB8 hub expired filter is B3. RB9 `manualTaskVary = {}` at
  persist until B3. RB10 derived-compound path complete + tested. RB11
  `derivedWindowCounterCount` computed, not rendered. RB12 pull sub-step
  runs per root, in-transaction.
- **Rulings (execution)**: mint only on ACTIVE persist — a draft's window
  can still change and a derived id doesn't encode the window. Refresh
  runs BEFORE propagation — `undoLastCounterLog` can tombstone a
  pre-window event. `spawnTemplateBoard`'s `applyMemberRules`-expanded
  supplies feed validation + `selectBoardTasks` + the planner, not just
  the planner.
  Board-delete candidates are read from ALL placement rows (order-
  independent) but gated on `isMintedForBoard` — counter: exact
  `derivedTaskId` identity; compound: window identity + a confirming
  derived child, else "no live placement elsewhere" (a heuristic that
  errs toward not retiring until B3 stores provenance) — plus RB5. A
  second sweep retires derived counters reachable only as children of a
  retired derived compound. A derived counter is born `completedAt = now`
  when it mints already complete.
- **B3 hand-offs**: wizard-side `applyMemberRules` on `algorithmSupplies`
  ↔ `BoardWizardViewModel+Sources`; `manualTaskVary` wizard state + writer;
  Preview re-roll (`shuffleNonce` ↔ `reseedPlacement`) wiring the planner
  rng; the Counters-hub expired filter; derived-compound provenance (so
  `repeatBoard*` and `isMintedForBoard` stop being heuristic); a
  post-activation Board-Edit window change does not re-derive existing
  rows on either platform (id doesn't encode the window); surfacing
  `derivedWindowCounterCount` in the delete-confirm copy; the rules-cap
  emulator test carried from B1 if still open.
- **Known, out of scope**: `deleteBoard` leaves its ORDINARY placements
  live on BOTH platforms (not a web-only gap) — its window-stamped derived
  placements *are* tombstoned, by `softDeleteWindowStampedDerived`. The
  orphan sweep reads candidates from every placement row, live or
  tombstoned, so it stays correct either way if a future change starts
  tombstoning the ordinary ones too.

#### Plan B3 — implementation notes (2026-09-19)

Both platforms, one PR (#492). This closes the member-rules train (A → B0–B3):
the wizard's member rows now write real rules, the Preview renders a real
dry run of them, and the Counters hub / delete-confirm surfaces read the
window-stamped derived counters B2 started minting.

- **Landed**: the #471 member row ⋯ menu is gone on both platforms (deleted
  `memberHasActions`/`buildMemberMenuItems`/`onDeriveMember`/`onAddTask` and
  `SourceRow.tsx`'s wiring; `memberActionsMenu` and the `RisoSourceRowView.swift`
  call site) and replaced by inline member-row controls: `MemberRuleRow.tsx`
  ↔ `RisoMemberRuleRowView.swift` render the 22pt target stepper + "of N
  unit" caption for a counting member pulled from a **board** source, dice
  only for a counting member pulled from a **pool** source, and for a
  compound member the One square / Split up pill with a "1 square" /
  "N squares" note and one line per part (name, a stepper when the part is
  counting and board-sourced, dice in Split mode, and a ✕ that the last
  remaining part never gets). Dice-on renders the blue range line from
  `varyRange` under the row or part, never on the compound header itself.
  New primitives: `DiceButton`/`riso/DiceButton.tsx` ↔ `RisoDiceButton.swift`
  (22×22 — square, revised 2026-09-21; 0/2/5 pips, `--riso-ink-static`/`risoInkStatic` fill so the pips
  stay visible in dark mode), a compact `CounterStepper`/`CounterStepperView`
  size, and a compact `RisoSegmented` size for the One square / Split up
  pill — all added to the existing kit rather than one-off UI, each with a
  `RisoKitSnapshotTests` baseline (`testMemberRulePrimitivesLight`/`Dark`).
  Hand-added rows get the same dice, before the 32pt edit button, with the
  same range line underneath. The wizard actions
  (`setMemberTarget`/`setMemberVary`/`setMemberSplit`/`setPartExcluded`/
  `setPartTarget`/`setPartVary`/`setManualVary`) are symmetric by name on
  both platforms and write `sources[i].memberRules` /
  `manualTaskVary`; split and part-exclusion re-run
  `refreshSourceSupplies` → `clampAllSourceRanges` so ranges stay honest.
  Web split `useBoardWizard.ts` (1144 → 949 lines, its file-size allowlist
  entry removed outright) into `useWizardSources.ts` (source CRUD, extracted
  first as a behaviour-identical refactor), `useWizardMemberRules.ts` (the
  new rule actions), and `useWizardDerived.ts` (Preview/derived-cell state);
  iOS added `BoardWizardViewModel+MemberRules.swift` alongside the existing
  `BoardWizardViewModel+Sources.swift`. `algorithmSupplies` on both
  platforms now expands compound members into their parts before the
  selection algorithm sees them (web via `childrenByCompoundId`+`tasksById`
  parameters; iOS reads VM state directly — platform-idiomatic, same
  result). `BoardSourceSupplyInfo` gained `windowCountByTaskId` +
  `sourceWindow` (filled in `resolveSupply`/`resolveSupply(db:board:)` from
  the events already read for the done filter) so a one-off pull can prefill
  `target = remaining` idempotently — it skips any source whose rules were
  already hydrated on resume, never overwriting a saved rule.
  The Preview renders a real dry run: `previewDerived.ts` ↔
  `BoardWizardPreviewDerived.swift` derive titles/targets for `DerivedTaskDraft`
  cells without touching the database, and Shuffle re-rolls them via a
  `previewRules = { seed }` nonce that both the placement shuffle and the
  member rolls consume — see the RC6 amendment below. The Counters hub and
  its detail page gained a "Show expired tasks" toggle
  (`ShowExpiredToggle.tsx` ↔ `RisoShowExpiredToggle` in
  `Views/Riso/RisoControls.swift`, the latter shared with the Tasks tab's
  existing toggle rather than a second definition) backed by
  `filterCounterTasks`/`SharedCounterGroups.swift`'s filter and threaded
  through `useSharedCounterGroups({ showExpired })` ↔
  `AppDatabase+SharedCounterGroups` callers — window-stamped derived
  **counter roots** are library content and are never filtered, only the
  per-window rows; web carries the state as `?showExpired=1`, iOS as
  passed-through view state. The delete-confirm line ("`{n} board
  counter{s} made from this one will be removed.`") is centralised as
  `BoardSources.derivedCounterRemovalNote(count:)` on iOS (consumed by both
  `CounterDeleteConfirmView.swift`, newly extracted from `CounterDetailView.swift`
  — 1178 → 1008 lines, its allowlist entry lowered not deleted — and
  `TaskDeleteConfirmView.swift`) and as the one-line web twin
  `components/counters/derivedCounterRemovalNote.ts`, consumed by BOTH web
  confirm dialogs (`CounterDeleteConfirmDialog.tsx` and
  `pages/tasks/TaskConfirmDeleteDialog.tsx`); the task sheet folds the count
  into its "No other rows affected." predicate on both platforms, since the
  derived rows live on OTHER boards and move neither `affectedBoards` nor the
  compound link counts. Driven by `impact.derivedWindowCounterCount`
  throughout. BOTH platforms deleted the Library sheet's inline
  "⇲ Derive smaller…" entry — iOS its sheet too
  (`RisoDeriveCounterSheetView.swift`, one consumer), web the dead
  `LibrarySheet` prop/branch/CSS its caller had stopped passing — now that
  member rows own that job.
- **Rulings (design, locked at planning as RC1–RC14)**: a11y strings exactly
  as spec'd ("Vary: off / a little / a lot" on the dice, "Decrease target" /
  "Increase target" on the stepper); RC12 is the delete-confirm line +
  `CounterDeleteConfirmView` extraction above; RC13 is the out-of-scope list
  carried into Follow-ups below; RC14 is the split/part-exclusion supply
  refresh + last-part refusal (`setPartExcluded` returns `false` and leaves
  every part included rather than removing the last one).
- **Rulings (execution)**: **RC6 amended** — a Preview build must be
  idempotent (two calls with the same seed return equal placements) and must
  not re-roll on an unrelated live-query tick, so `buildWizardPlacement`
  takes `previewRules = { seed }` and builds the rng per call
  (`makePreviewRng`, 2 warm-up samples discarded so adjacent seeds don't
  correlate) rather than accepting a shared generator; the effect that calls
  it is keyed on a plan-inputs key, not on the raw task array. Preview
  stand-ins keep the *original* task id (only title/maxCount/action/unit are
  overridden) because persist re-derives from placement ids, so a synthetic
  preview id would leak into `board_tasks`; derived **compounds** are
  display-only in the Preview (never stood in) so the compound cell shows
  the original title and the children lookup isn't orphaned. **RC10
  amended** — counting *parts* get a stepper in One-square mode too (the
  part's target applies regardless of split state), dice stays split-only.
  `resolveWizardDates` moved verbatim to `wizardDates.ts` (re-exported, to
  break an import cycle). `seededRng`/`makeSeededRng` was promoted to
  `packages/shared/src/algorithms/seededRng.ts`; `bingo-core` cannot import
  it back (shared depends on bingo-core, not the reverse) so it keeps its
  own vector-pinned duplicate LCG — both sides are pinned to the same five
  literals for seeds 0/1/42/2^32−1. iOS's compact stepper commits the typed
  draft before stepping (parity with web's blur→commit→step), fixed in the
  Task 7 review round after the first pass read the stale `value` instead of
  the uncommitted `draft`; web's compact stepper likewise gates its −/+
  `disabled` state on that draft (`compactStepperBase`, the twin of
  `RisoCompactStepperMath.base`). **An empty `manualTaskVary` is never
  written** — on either record (the draft blob and `RecurringBoardTemplate`
  CREATE) and on either platform; decoders read a missing key as "no dice".
  The `RecurringBoardTemplate` UPDATE path is the one deliberate exception:
  there an empty map means "clear the dice", which an omission cannot
  express.
- **Accepted divergences**: web keeps its hand-added row's
  "Derive smaller version…" context-menu entry (iOS has no hand-added-row
  menu to match; noted, not treated as drift). iOS's
  `resolveDeriveLinkTarget` is now test-only dead code from the caller's
  perspective (web's twin is still live) — intentionally kept, not deleted,
  as a parity note for a future knip-equivalent iOS pass. The part-level
  UNDO control renders at part scale on both platforms (web's
  `MemberRuleRow.module.css` `.partUndo` rule, previously defined but
  unused, is now the one `MemberRuleRow.tsx` applies) — this was a
  discovered mismatch, not a design choice, and is recorded here as
  converged rather than as an open divergence.
- **The Preview is a sample, not a promise**: because a dry run and the
  eventual persist both roll from a seed, the numbers a user sees in the
  Preview are one valid outcome from the same range the board will actually
  use — Create re-derives and re-rolls fresh inside that range rather than
  copying the sampled values, so a persisted board's targets can differ from
  the last Preview frame the user looked at while still being a fair result.
- **Follow-ups (RC13 + discovered during B3, out of scope here)**:
  derived-compound provenance (so `repeatBoard*` and `isMintedForBoard` stop
  being heuristic, per the B2 hand-off); a post-activation Board-Edit window
  change does not re-derive existing window-stamped rows on either platform
  (a derived id doesn't encode the window); a Firestore rules-cap emulator
  test for `RecurringBoardTemplate`, carried from B1; splitting
  `CounterDetailContent` out of `CounterDetailView.swift` to bring it back
  under the 1000-line cap without an allowlist entry; an `.nvmrc`/Node-20
  engines pin (local Playwright 1.62's tsconfig loader fails under Node 24;
  CI pins Node 20 and is unaffected); the Preview's plan-inputs key omits
  the wizard's start/end dates on both platforms (safe today — nothing
  date-dependent varies the plan without also varying task selection — but
  worth tightening if that stops holding); device-checklist items for a
  future pass (compact-stepper select-all-on-focus and `.numberPad`'s
  missing Done key are both intentional-for-now, not bugs); promoting web's
  duplicated `nextVary` (`MemberRuleRow.tsx` / `PoolList.tsx`) to a single
  definition (iOS already has one, `VaryLevel.next`); memoising the web
  Split-up expansion the way iOS's `expandedSuppliesCache` does (today it is
  recomputed O(n²) per clamp); dark twins for the new member-row snapshot
  cases (`testSourceCountingMemberRule` and friends are light-only, while
  the sibling `testPoolList*` cases have both).
- **Test inventory**: shared Jest gained `memberRulesDisplay.test.ts` +
  `seededRng.test.ts` (the `display` section of
  `memberRuleVectors.json` kept in sync with the iOS fixture copy under
  `OYBCTests/Fixtures/`); web Vitest added row/hook/helper coverage
  (`MemberRuleRow.test.ts`, `useWizardMemberRules.test.ts`,
  `useWizardSources.test.ts`, `previewDerived.test.ts`,
  `useSharedCounterGroups.test.ts`, `CounterDeleteConfirmDialog.test.ts`,
  `DiceButton.test.ts`, `CounterStepper.test.ts`, `RisoSegmented.test.ts`,
  among others) plus `e2e/member-rules.spec.ts` (5 Playwright specs,
  CI-gated — see the ruling above on why this branch's e2e was validated
  locally by an ad-hoc `tsc` pass rather than a live `playwright test` run);
  iOS XCTest added `BoardWizardMemberRulesTests.swift`,
  `BoardWizardPreviewDerivedTests.swift`, `SeededRngTests.swift`,
  `MemberRuleRowModelTests.swift`, `RisoCompactStepperMathTests.swift`, and
  `DerivedCountersTests.swift`/`SharedCounterGroupsTests.swift` additions,
  plus new snapshot baselines: `RisoKitSnapshotTests`
  (`testMemberRulePrimitivesLight`/`Dark`), `BoardWizardTasksStepSnapshotTests`
  (`testSourceCountingMemberRule`, `testSourceCountingMemberVaryOn`,
  `testPoolSourceCountingMemberHasDiceButNoStepper`,
  `testSourceCompoundOneSquare`, `testSourceCompoundSplitUpWithExcludedPart`,
  `testPoolListHandAddedVaryLight`/`Dark`, and a deliberate re-record of
  `testDenseLibraryWithSourcesPulled` now that the Library sheet's derive
  entry is gone), and `RisoDeleteConfirmSnapshotTests`
  (`testDerivedCountersLight`/`Dark`). The hub and delete-confirm snapshot
  baselines are environment-red on the dev machine (pre-existing font drift,
  ROADMAP A8) — verified instead by "no new reds" plus reading the recorded
  PNGs.

The member-rules train — A (#487), B0 (#486), B1 (#489), B2 (#491), B3
(#492) — is now **COMPLETE**: counting and compound members pulled from
sources carry real per-member rules (target, vary, split), the wizard
surfaces let a user author them, the Preview shows a faithful sample of
what will be rolled, and the Counters hub / delete-confirm surfaces read
and explain the window-stamped derived counters they produce.

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

Member-rules pass (2026-09-17), owner decisions: **target divisor
= window-length ratio** (`ceil(goal × targetDays ÷ sourceDays)`; one-off =
the source's remaining amount — *revised 2026-09-21: the one-off remaining
amount is pro-rated by that same ratio, see §Target math*); **target stepper only on board-pulled
members** (pool / hand-added counters place at their own goal, dice
optional); **derived per-window counters are shown in the library like any
task**; **dead/empty source stays silent stale-inert**; compound rule = the
handoff's One square / Split up; **retire the "From a board…" grid picker
and its vocabulary** (plan A); Library sheet kept flag-hidden, chip
stripped; **deleting a board also deletes its per-window derived counters**
(confirmed after review). Handoff:
`design_handoff_from_board_pool.zip` (gitignored; frames 2a/2b/2c/4a/5a/5b/
5c/0b + `Pools rework - decisions.md` §"Counting & compound tasks pulled
from another board").

## Member rules — counting & compound tasks pulled from sources (design locked 2026-09-17)

### The one-paragraph model

A pulled source's **counting** and **compound** members carry optional
per-member rules on the source entry: a **target** (board sources only —
how much of the counter belongs on *this* board), a **vary** level (dice:
off / a little ±20 % / a lot ±50 %), and for compounds **One square /
Split up** with per-part rules. Hand-added counting tasks get dice too.
Rules are resolved at persist (one-off) or at every spawn (recurring) into
**derived counters** — ordinary `Task` rows linked to the family root by
`sharedCounterId`, stamped with the board's window, with a
**baseline computed from the root's events** so the board shows only what
was logged inside its window. Nothing rolled or resolved is ever stored on
the rule; the recurring board still stores a rule, never a task list.

### Data model (additive; no `Task` schema change)

**`BoardSource.memberRules?`** (`packages/shared/src/types/boardSource.ts`
↔ `apps/ios/OYBC/Database/Models/BoardSource.swift`):

```
type VaryLevel = 0 | 1 | 2                      // off · a little (±20 %) · a lot (±50 %)

BoardSourcePartRule {                           // one compound part
  target?: number                               // counting part only; absent = auto
  vary?: VaryLevel                              // absent = 0
  excluded?: boolean                            // honoured only while the parent is split
}

BoardSourceMemberRule {
  target?: number                               // counting member; absent = auto
  vary?: VaryLevel                              // counting member, or a One-square compound
                                                //   (covers all of its counting parts)
  split?: boolean                               // compound only; absent/false = One square
  parts?: Record<childTaskId, BoardSourcePartRule>   // compound only; keyed by childTaskId, never index
}

memberRules?: Record<taskId, BoardSourceMemberRule>   // new optional field on BoardSource
```

- Keyed by task id / `compound_children.childTaskId` — stable keys, never
  positions.
- `target` is honoured only on `kind: 'board'` sources; a `target` on a
  pool member is ignored (pool members: vary / split / part-exclusion only).
- **Stale-inert**, like `excludedTaskIds`: a rule for a task not in the
  source's live supply this spawn is skipped; a part rule for a part no
  longer in the compound is skipped.
- Zod: `.optional()`; `target` integer ≥ 1; `vary` ∈ {0, 1, 2}. No schema
  version bump.
- Swift: `decodeIfPresent` with nil default (the current decoder
  hard-decodes every key except `max`); the encoder **omits** the key when
  nil/empty, so a rule-less source serializes byte-identically to today.

**`RecurringBoardTemplate.manualTaskVary?: Record<taskId, VaryLevel>`** —
dice for hand-added counters on a recurring board. Also on the Create /
Update inputs. iOS: new JSON-TEXT column on `recurring_board_templates`,
**GRDB migration v31** (v30 is the `sources` column — re-check the tip at
implementation time), encode/decode as `sources`. On the recurring-draft
payload (`apps/web/src/db/recurringDraftMix.ts` ↔
`RecurringDraftMixPayload.swift`) the field is additive and the blob
**stays `v: 2`**; both decoders default to `{}`. One-off boards store none
of this — vary is rolled and materialized at persist.

**Derived counters reuse existing `Task` fields** — no new columns:

| Field | Value |
| --- | --- |
| `id` | `uuidv5('sources:derived:<boardId>:<rootTaskId>')` (`uuidv5.ts` ↔ `Helpers/UUIDv5.swift`, vector-pinned) |
| `type` | `COUNTING` |
| `sharedCounterId` | the family root (`source.sharedCounterId ?? source.id` — always flat) |
| `maxCount` | the auto / overridden / rolled target |
| `baseline` | event-derived (see §Baseline) |
| `title` / `action` / `unit` | `generateCounterTaskTitle(action, target, unit)` |
| `timeframe` / `startDate` / `endDate` | the board's window |
| `createdInWizard` | `true` |
| `currentCount` | **root mirror** (`root.currentCount`) — the convention `propagateIncrement` already writes for every linked task; readers subtract `baseline` via `deriveDisplayedCount` |
| `isCompleted` | `deriveDisplayedCount(derived, root).isCompleted` at mint; one-way latch afterwards, as today |

A **derived compound** exists only for a One-square compound with at least
one counting part carrying a target or vary:
`id = uuidv5('sources:derived-compound:<boardId>:<compoundId>')`,
`operator` / `threshold` / title copied from the source compound;
`compound_children` rows link **derived counting children** for parts with
a target/vary and the **original** child tasks for every other part; link
ids `uuidv5('sources:derived-link:<derivedCompoundId>:<childId>')`.

`createdInWizard: true` + "shown like any task" reconcile because
`computeBrowsableTasks` hides a `createdInWizard` task only while it has no
non-draft placement: a derived counter is browsable the moment its board
exists and drops out of browse if the board goes.

**Never stored:** rolled targets, remaining amounts, resolved source
instances, any task list for a recurring board.

### Resolution pipeline (shared pure steps; TS ↔ Swift twins)

1. **Supply expansion — `applyMemberRules(supply, childrenByCompoundId)`**
   (`boardSources.ts` ↔ `Helpers/BoardSources.swift`). A member with
   `split: true` contributes its non-excluded `childTaskId`s instead of its
   own id. Called at **every** supply-build point: wizard
   (`wizardSources.ts algorithmSupplies` ↔ `BoardWizardViewModel+Sources`),
   spawn (`recurringBoardSpawn.ts` ↔ `AppDatabase+RecurringTemplates.swift`
   — the `compoundChildren` fetch, today made *after* placement, is hoisted
   above the supply loop on both platforms), and roster health
   (`templateHealth.ts` ↔ `RecurringBoardTemplatesViewModel`) so Settings
   attention reasons agree with spawn. `computeSourceCapacity` and
   `selectBoardTasks` consume the expanded supply unchanged, so "of N", the
   subtitle, the slider bound and the header count all move with Split up.
   `fetchCompoundChildrenByCompoundIds` is kept for this (plan A must not
   delete it).
2. **Selection — unchanged.** `selectBoardTasks` runs on member ids (root
   counters, compounds, split parts). Family exclusivity keys on
   `sharedCounterId ?? id` via `buildCounterFamilyMap`; the min-aware
   CHOSEN-center swap in `buildWizardPlacement` is untouched.
3. **`planDerivedTasks`** (new; pure; vector-pinned) — after selection:
   ```
   in:  selectedIds, sources (+memberRules), manualTaskVary,
        board window {timeframe, startDate, endDate}, tasksById,
        childrenByCompoundId, sourceWindowByMemberId, baselineByRootId, rng
   out: { placementIds, derivedTasks: DerivedTaskDraft[], derivedCompounds: DerivedCompoundDraft[] }
   ```
   **Supplying source** = the first source in `sources` order whose
   expanded supply contains the id (the same first-wins rule as
   `memberRules`); its `kind` decides board-vs-pool treatment and only its
   rule applies. A hand-added id that is also in a source is treated as
   hand-added (dedupe already drops the source copy). Per selected id:
   - counting member whose supplying source is a **board** → derived,
     `maxCount` = resolved target;
   - counting member with `vary > 0` (any source, or hand-added via
     `manualTaskVary`) → derived, rolled;
   - split part that is counting with a target/vary → derived;
   - One-square compound with any counting part carrying a target/vary →
     derived compound + derived children. **Effective part rule** for a
     One-square compound: `parts[childId]` merged over the member-level
     rule — a member-level `vary` (the toggle-line dice) is treated as if
     every counting part carried that same `vary` (and, on a board source,
     every counting part gets an `autoTarget`) for both this trigger and
     the per-part `rollTarget`. It is never copied into `parts`; in Split
     mode the member-level `vary` is ignored and only `parts[*].vary`
     applies;
   - hand-added member that is itself a window-stamped derived counter
     (`sharedCounterId != null && startDate != null`) → **re-minted per
     spawn** with target = its `maxCount`, root = its `sharedCounterId`
     (keeps Board Edit → REPEATS working on a board born with targets);
   - everything else → placed as-is.
   Drafts are in-memory only; `buildWizardPlacement` returns them
   alongside `pendingTasks` for the Preview and for persist.
4. **Target math** (`boardSources.ts` + twins):
   - `nominalWindowDays(timeframe)`: daily 1 · weekly 7 · monthly 30 ·
     yearly 365 · CUSTOM = actual span (`endDate − startDate + 1`) ·
     INDEFINITE = `null`. New helper (none exists on either platform).
   - `autoTarget(goal, sourceDays, targetDays)` — four explicit branches,
     in order: `sourceDays == null` → `goal`; `targetDays == null` →
     `goal`; `targetDays ≥ sourceDays` → `goal`; else
     `min(goal, ceil(goal × targetDays / sourceDays))`. Runs for any
     **board-sourced** member, one-off and recurring alike (owner ruling
     2026-09-21, below); pool-sourced and hand-added members never
     auto-target. Inputs: `goal` = the pulled member's own `maxCount` (for a
     member that is itself a window-stamped derived counter that is its
     per-window target, and the root is `member.sharedCounterId`);
     `sourceDays` = `nominalWindowDays` of the **source board's** timeframe
     (`sourceWindowByMemberId`); `targetDays` = `nominalWindowDays` of the
     board being made.
   - One-off: the wizard writes an explicit `target` at pull time, prefilled
     with the source's **remaining, pro-rated to this board's window** —
     `prefilledOneOffTarget = autoTarget(remainingTarget(goal, windowCount),
     sourceDays, targetDays)`, where `windowCount` is the member's count in
     the source board's window (`remainingTarget` floors at 1). Because
     `resolveTarget` is `explicit ?? auto`, that written number IS what the
     board gets — which is why the pro-rating has to happen here too, not
     only in the auto branch.

   **Owner ruling 2026-09-21 — one-off boards pro-rate too.** Reported from
   device testing of PR #493: "the defaults for Counter tasks pulled in from
   boards do not seem to adjust with timeframe" — pulling "Run 30 miles a
   month" from a monthly board onto a **one-off daily** board defaulted the
   target to 30 instead of ~1. Two mechanisms produced that number and both
   changed: (1) `resolveTarget` / `effectiveMemberTarget` gated auto-targeting
   on `fromBoard && mode === 'recurring'` — the gate is now `fromBoard`
   alone; (2) the one-off prefill wrote `remainingTarget(goal, done)`
   unscaled, and `explicit ?? auto` meant that always won — it now writes
   `prefilledOneOffTarget(...)`. **Safety property (pinned by vectors on both
   platforms):** when the source and target windows have the same nominal
   length the ratio is 1, so `autoTarget(x, d, d) === x` via the
   `targetDays ≥ sourceDays` branch — every same-timeframe pull (and any pull
   onto a LONGER window, and any pull whose source window length is unknown:
   INDEFINITE, an unresolved supply, or a CUSTOM window missing a bound)
   behaves exactly as it did before the ruling.
   - `varyRange(t, level, goal) = [max(1, round(t·(1−p))), min(goal, round(t·(1+p)))]`,
     `p ∈ {0, 0.2, 0.5}`; `rollTarget(t, level, goal, rng)` picks a whole
     number uniformly in that range. `t` is clamped 1…goal first.
   - `rng` is the seeded rng `selectBoardTasks` already takes: Preview
     Shuffle re-rolls by re-running the plan (`shuffleNonce` ↔
     `reseedPlacement`); spawn uses the platform default rng.
5. **Persist.** `persistWizardBoard` (`wizardPersist.ts` ↔
   `BoardWizardPersist.swift`) and spawn write derived tasks +
   `compound_children` + their sync-queue items **in the same transaction,
   before `board_tasks`**. `baselineByRootId` is computed by the caller from
   `task_events` (root-owned `increment` rows, `occurredAt < startDate ??
   now`). Deterministic ids ⇒ a retry upserts.
6. **Gap fix.** `repeatBoardAsTemplate` (`AppDatabase+RecurringTemplates.swift`)
   ↔ `repeatBoardAsRecurring` (`db/operations/repeatBoard.ts`) write
   `sources` (and `manualTaskVary: {}`) instead of the legacy trio only.

Edge rules: an empty/dead source contributes nothing (stale-inert, shipped
behaviour); a pulled board that itself pulls is flattened because its live
`board_tasks` are the supply.

### Baseline — a pure function of the root's events

`baseline = Σ root increment events with occurredAt < board.startDate`
(INDEFINITE board → `< mint time`). Kept true at three points:

- **mint** — the only time `baseline` rides an authored write (the derived
  task's initial insert, version 1, enqueued);
- **local root writes** — `incrementSharedCounter` /
  `decrementSharedCounter` / `undoLastCounterLog`
  (`tasks.sharedCounter.ts` ↔ `AppDatabase+SharedCounters.swift`) gain
  `refreshDerivedBaselines(rootId)` for the root's window-stamped derived
  tasks;
- **pull** — a **new, explicit sub-step** after
  `recomputeTaskCachesFromPull(rootId)` in `applyTaskEventsBatch` and
  `healMissingCompletionEvents` (`taskEventPull.ts` + iOS twin): for each
  recomputed root, query its window-stamped derived tasks
  (`sharedCounterId == rootId && startDate != null`) and recompute
  `baseline`. The existing loop does NOT cover this — it iterates
  event-owning tasks (`isEventOwningTask` gate) and derived tasks own no
  events by construction. Closes late-synced backdated increments and keeps
  sealed-board re-derivation deterministic;
- **a `tasks` pull that lands a derived row itself** — `baseline` travels on
  the wire (an authored write to a derived row ships the whole `Task`), so a
  device that minted while missing a pre-window increment pushes a SHORT
  value that overwrites a complete one by ordinary LWW. The pull-apply path
  therefore re-derives the landed row's baseline from the LOCAL event union
  before the board cascade, same non-authored posture. The honest
  convergence claim is *converges once a pull carrying the missing events
  reaches each device* — not "immediately, everywhere".

**Sync rule: after mint, `baseline` is a pure, non-authored cache.** Both
recompute paths follow the `recomputeTaskCachesFromPull` pattern — **no
`version` bump, no sync enqueue**, on both platforms. Every device converges
on the same value from the converged event union, so there is nothing to
win an LWW race over; a versioned write here would rewrite every historical
derived row of a root on every tap, on every device.

This applies only to **window-stamped** derived tasks
(`sharedCounterId != null && startDate != null`). Hub-authored derived
counters (the Counters hub's create sheet, `CreateCounterSheet.tsx` ↔ iOS
counterpart, via `resolveDeriveLinkTarget`) keep today's frozen baseline and
that entry point stays. The two *wizard* entry points to that flow go away
(the #471 member menu in B3, the From-a-board grid in A), and the iOS
Library sheet's derive entry is stripped in B3 for web parity.

**Latch asymmetry, intended.** A refresh RAISES a baseline (a backdated
increment arrives) and therefore lowers the displayed count, but it never
re-evaluates the derived row's `isCompleted`. On the *local* counter paths
the `propagateIncrement` that follows does re-evaluate, so the two paths can
end on different completion states for the same converged data. That is
deliberate: completion is a ONE-WAY latch — it only ever holds *up* — so the
pull path declining to un-complete a square the user already earned is the
conservative direction. Do not "fix" this by making the pull path clear the
latch.

Board reads/writes are unchanged: a derived cell displays
`deriveDisplayedCount(derived, root)`; a tap increments the **root** (the
reject-derived guard stays). `docs/WINDOWED_COMPLETION.md`'s carve-out
paragraph gains: window-stamped derived counters are windowed *through
their baseline*; the v1 cross-window bleed note is closed for them.

**Read audit (B2):** because `currentCount` on a linked task is the root
mirror, every surface that shows a linked task's count must read through
`deriveDisplayedCount` — Tasks tab row, Task detail, Library sheet row,
Counters hub/detail, wizard member rows — on both platforms. Any straggler
is a pre-existing bug that B makes visible; fix it, don't special-case.

### Where derived counters show up

- Tasks tab / wizard Library sheet: like any task, then default-hidden
  after `endDate` by `isTaskExpired` (+ "show expired").
- Counters hub/detail: the same `isTaskExpired` default + "show expired"
  affordance, applied in the **caller hooks** that assemble the `tasks`
  input (`useSharedCounterGroups.ts` ↔ the hub/detail view-model), NOT
  inside the vector-pinned pure `buildSharedCounterGroups`, whose contract
  is unchanged. Roots are never filtered.

### Deletion

- **Board deleted → its window-stamped derived tasks are soft-deleted too.**
  `deleteBoard` (`db/operations/boards.ts` ↔ `AppDatabase+Boards.swift`):
  after tombstoning placements, soft-delete every task placed on that board
  that is window-stamped derived (`createdInWizard && sharedCounterId !=
  null && startDate != null`) and has no other live placement (a per-spawn
  mint is placed on exactly one board, so this is precise).
- Root counter deleted, generic path → `deleteTaskWithCascade` /
  `deleteTaskWithCascadeInTxn` (`tasks.deletion.ts` ↔
  `AppDatabase+Tasks.swift`) also soft-deletes the root's window-stamped
  derived tasks + tombstones their placements; `computeTaskDeletionImpact`
  counts them.
- Root counter deleted, **Counters-hub path** → `deleteCounterWithUnlink`
  (`tasks.counter.ts` ↔ `AppDatabase+Counters.swift`) today unlinks every
  member (clears `sharedCounterId`/`baseline`, freezes the count) *before*
  the cascade, which would turn every historical per-window derived counter
  into a standalone orphan. It special-cases window-stamped members:
  soft-delete them (+ tombstone placements); ordinary hub-derived members
  keep unlink-and-preserve. `counterMembers` / the impact preview reflect
  the split.
- **Every newly-tombstoned derived task and placement bumps `version` and
  enqueues its own sync item**, mirroring the existing loops in the same
  functions — the "soft-delete helper forgot to enqueue → row resurrects on
  pull" class has shipped before (PR #424).
- Recurring board stopped/deleted → spawned boards and their derived tasks
  stay.

### Sync / codec / migration compat

- Derived tasks and derived-compound links are ordinary `tasks` /
  `compoundChildren` rows — **no `SYNC_COLLECTIONS` change**; the C4
  sync-contract fixture and `check-sync-contract-rules.mjs` are unaffected.
- `firestore.rules` validates only `id` / `version` / `userId` and a 10 KB
  document cap — no nested-shape validation of `sources`. Plan step: size a
  worst-case template (~20 board sources each carrying `memberRules` +
  `parts`) against the cap and bump it if needed.
- Derived-compound `compoundChildren` rows arriving before their parent
  Task row hit the existing skip-and-defer posture (`pullApply.ts`), the
  same one WC documents for `taskEvents`; rules' `version >= existing`
  permits the equal-version idempotent re-mint.
- Web: no new Dexie index → no Dexie version bump. iOS: `BoardSource` +
  `RecurringDraftMixPayload` `decodeIfPresent`; `recurring_board_templates`
  gains one TEXT column (v31).
- Old clients ignore unknown keys on decode (Codable / `isBoardSource`
  shape check). An old client that edits and saves a template drops
  `memberRules` / `manualTaskVary` (whole-record LWW) — accepted, the same
  class as any field addition. Concurrent rule edits on two devices race
  whole-record, exactly as `sources` does today.
- **Double-spawn, stated honestly:** spawn mints a random `boardId` per
  device, so two devices racing one window already produce two duplicate
  boards (documented in `spawnTemplateBoard`; "the user deletes one").
  Derived ids embed `boardId`, so each duplicate board mints its own
  derived cluster; the board-delete cascade above is what keeps that from
  leaving a permanent duplicate cluster in the library. Deterministic spawn
  board ids (`uuidv5(templateId + windowStart)`) would remove the race but
  change spawn identity + placement-row convergence — out of scope, noted
  as a follow-up.

### UI contract (frames 2a/2b/4a/5a/5b/5c; both platforms)

**Member rows replace #471's ⋯ menu outright** — delete `memberHasActions`
/ `buildMemberMenuItems` / `onDeriveMember` / `onAddTask` (`SourceRow.tsx`),
`memberActionsMenu` (`RisoSourceRowView.swift`), and the
`setDerivingFromTask` wiring in `BoardWizardTasksStep.tsx`.

**Amended by B3.1** (§Member row at phone width, below): these controls are
no longer *inline after the title* — they sit on a second line revealed by a
disclosure, and the "of 35 mi" caption is folded into the stepper pill. Read
the two together; where they disagree, B3.1 wins.

| Member | Controls (B3.1: on the expanded row's second line) |
| --- | --- |
| Counting, board source | 32pt stepper pill (− / numeric field, `.numberPad`, select-all on focus / ＋) · caption "of 35 mi" · dice |
| Counting, pool source | dice only |
| Compound | 69pt-indent line: **One square / Split up** pill + "1 square" / "2 squares" note + dice (One square only). One line per part: name · [stepper · "of 210" when board source] · dice (Split only) · ✕ (Split only; the last part can't be removed) |
| dice on | blue 10.5/600 range line beneath the row/part with the bare range from `varyRange`: "4–6 mi" / "24–36" — never on the compound itself |

The pill was 22pt (22×22 −/＋, 11pt value) until the owner, device-testing
#493 on 2026-09-22, reported the add-from-a-board/pool inputs — "especially
the stepper inputs for counter task quantity" — as too small to use
comfortably; the pill, its buttons and its type grew together to 32pt /
32×32 / 13pt on both platforms.

Stepper shows `target ?? auto`, step 1, clamp 1…goal, **no reset**
affordance; the unit appears once, in the caption. Excluded rows keep
strikethrough + UNDO; excluding a split compound removes all its parts.
Dice cycles off → a little (blue fill, 2 pips) → a lot (5 pips) → off.

**Removing a source row (owner ruling 2026-09-23).** The row's ✕ removes
the pull **immediately when the source is untouched** and **asks first when
it carries configuration** — the owner repeatedly configured exclusions and
counter targets, then lost them all to a misclick. "Carries configuration"
is the shared, vector-pinned `sourceHasConfiguration` (`boardSources.ts` ↔
`BoardSources`): any excluded task, any **authored** member rule, a range narrowed from the
`[0, all]` mint default, or a filter that differs from the **kind-scoped
creation default** `newSourceFilter(kind)` — never from the Swift
`BoardSource.init` default `.all`, which is the legacy-decode default and
would make every fresh board source look configured. **A member rule counts
only if someone authored it** (amended 2026-09-23, after the first cut
fired the dialog on every fresh board source): on a one-off board,
`prefillRemainingTargets` seeds `memberRules[id].target` for every counting
member the moment a board source is pulled, so a rule whose only field is a
`target` equal to what the prefill would seed *right now*
(`prefilledOneOffTarget` over the same goal / `windowCountByTaskId` /
`sourceWindow` / wizard window) is machine-written and is **not**
configuration. A rule with `vary`, `split`, any `parts`, or a `target` that
differs from that seed is. The gate recomputes the seed at removal time and
passes it to the shared predicate as `seededTargetByTaskId`, recomputed from
the LIBRARY-backed task map the prefill itself read (never the wizard's
staged-edit overlay — an inline goal edit must not turn an untouched source
into a "1 member rule" confirm, since that edit survives the removal). The
recomputation reads live inputs, so three things can make it differ from the
stored target and an otherwise untouched source then asks — all erring the
same safe way, and none of them a bug: the wizard's **timeframe** changed
after the pull (the user did change something, so asking is right); a
**resumed one-off draft**, whose hydrated sources are never re-seeded; and a
**supply re-fetch after a sync pull**, since `windowCountByTaskId` is live
progress. The loss sentence names the filter by its label
(`the "Not done yet" filter`), not as "the squares filter". The dialog names the
loss via the shared `removeSourceLossSentence` ("You'll lose 3 exclusions
and 2 member rules."), appends "Changes apply from the next board." while
editing a repeating board, and offers Cancel / Remove. Web: an
`alertdialog` sharing `CounterDeleteConfirmDialog`'s styles; iOS: a native
`.confirmationDialog` (the two-choice destructive idiom — the kit's own
sheet exists only where members must be listed). Locked by an e2e that
configures a source, taps ✕, cancels, and asserts the row and its exclusion
survive.

**Hand-added rows:** dice on counting rows only, before the 32pt edit
button; the range line sits under the row.

**Primitives (reuse before create):** check `CounterStepper.tsx` ↔
`CounterStepperView.swift` for a compact size before adding one. New
`DiceButton` (28×28, 0/2/5 pips in a 24×24 inner box, blue fill; pips use
`--riso-ink-static` / `risoInkStatic` — adaptive ink on a coloured fill is
the known dark-mode trap; the face was 22×22 with an 18×18 box until the
owner's 2026-09-22 request above — it grew with the stepper pill so it does
not sit visibly smaller beside it, and it now matches the row's 28pt ✕).
A pill toggle only if `RisoSegmented` /
`riso/Segmented` can't be sized down. Kit location `components/riso/` ↔
`Views/Riso/RisoControls.swift`, each with a `RisoKitSnapshotTests`
baseline.

**Wizard state** (`useBoardWizard.ts` ↔ `BoardWizardViewModel+Sources.swift`,
symmetric names): `setMemberTarget`, `setMemberVary`, `setMemberSplit`,
`setPartExcluded`, `setPartTarget`, `setPartVary`, `setManualVary` —
writing `sources[i].memberRules` / `manualTaskVary`. Split and
part-exclusion re-run `refreshSourceSupplies` → `clampAllSourceRanges`. A
one-off pull writes `target = prefilledOneOffTarget(...)` — the remaining
amount, pro-rated to the board's window (owner ruling 2026-09-21). Drafts
ride `commitSources` → `recurringDraftMix`.

**Preview.** 2b one-off: cells render `DerivedTaskDraft` titles (joined
with `pendingTasks`); Shuffle re-rolls via `shuffleNonce`. 5b recurring:
the shipped inline summary is unchanged — targets and variation are not
summarised.

**5a Settings › Sources → no new screen** (re-affirms the P-series
decision): "Edit tasks" already opens the full wizard in edit mode
(`RepeatingBoardWizardOverlay.tsx` ↔ `BoardSettingsView.swift`). Delta: the
Tasks step header shows "Changes apply from the next board." when editing
a recurring board; Save = wizard save. One-off boards stay locked.

**Sheet 2c/5c** shipped — copy audit only.

**Copy** verbatim from the handoff; the §Copy rules apply (never
"deal"/"draw"/"template"/"spawn"). A11y: dice "Vary: off / a little / a
lot"; stepper "Decrease target" / "Increase target".

### Member row at phone width (B3.1 — design locked 2026-09-19)

**Why.** Device-testing #492 showed the B3 member row attempting a desktop
layout on a 393pt screen. Three distinct failures, not one: titles
ellipsized to uselessness ("Att…", "Run 30 M…", "Read 1 Bo…"); the dice at
`.off` — an empty bordered square sitting next to an ✕ — reading as an
unchecked checkbox rather than a die; and the caption restating the title,
because counting titles are auto-generated from action + goal + unit
(`generateCounterTaskTitle`), so "Run 30 Miles a Month · of 30 Miles" says
the goal twice while the ellipsis eats it once.

Measured at 393pt: badge 20 + stepper 78 + caption 48 + dice 26 + ✕ 28 +
five 8pt gaps + 51pt row padding = **291pt of fixed furniture, leaving the
title ~102pt**.

**The model: disclosure, not compression.** Folding the goal into the pill
(dropping the caption, widening the pill) nets only ~27pt — worth doing, but
it does not fix the row. What fixes the row is not rendering the controls
until they are wanted: a collapsed row's furniture is 92pt plus a ~56pt
summary chip, leaving the title **~194pt**.

Three shapes, chosen by what the row actually has:

| Row | Shape |
| --- | --- |
| Normal / achievement / childless compound; any excluded or filtered-done member | Single line, no disclosure — there is nothing to reveal (`isOn` already gates every control). Not *unchanged*, though: the uniform-row-height rule below **lifts** the two shapes that were shorter than 42pt — filtered-done's 22pt ✓ and excluded's ~24pt UNDO pill — to the same height as every other row. |
| Counting member (board **or** pool source) | Collapsed: `badge · title · summary chip · chevron · ✕`. Expanded adds line 2 at the existing 69pt indent: `stepper pill · dice · range`. |
| Compound with parts | Same collapsed line. Expanded reveals the One square / Split up line and the part lines exactly as B3 built them. |

**Rules**

- **Always collapsed on open** — including a member whose rule is already
  stored. Row height then never depends on hidden state, a 20-member source
  stays scannable, and the chip keeps a saved rule legible without
  expanding. (The rejected alternative, auto-expanding rows with a non-empty
  rule, makes list height a function of `memberRules` — which also varies by
  whether the user has resumed a draft.)
- **The chip is the row's current answer**, never a second control: the
  `varyRangeLabel` string in `--riso-blue` when the dice is lit ("24–30
  Miles"), target + unit in `--riso-muted` when it is not ("12 Classes"),
  `splitSquaresNote` for a compound ("3 squares").
- **A collapsed vary range renders as the single value, not `"N–N"`**
  (owner ruling, 2026-09-22): pro-rating a board-pulled target onto a short
  window now makes a collapsed range easy to hit — a weekly 10-rep counter
  pulled onto a daily board targets `ceil(10/7) = 2`, and ±20% of 2 rounds
  right back to `2...2` — so `varyRangeLabel` reads the chip as "2 reps"
  rather than "2–2 reps". It deliberately returns that value instead of
  `null`: `countingSummary` decides `varying: true` by
  `varyRangeLabel(...) !== null`, so a `null` here would render the chip
  muted-grey next to a dice that is still lit.
- **A counting chip that only restates the title is suppressed** (owner
  ruling, 2026-09-19, after seeing the first re-recorded baselines): when
  `vary == 0` **and** `target == goal`, `countingSummary` returns `null` /
  `nil` and the row renders no chip. Rationale: counting titles are
  auto-generated from action + goal + unit
  (`generateCounterTaskTitle`), so a row titled "Run 35 mi" carrying a
  chip reading "35 mi" reproduces — in milder form — the duplicate-caption
  failure this whole section exists to fix. The chip then appears exactly
  when it adds something the title does not: a pro-rated or hand-set target
  (`target != goal`, e.g. "5 Miles" on a daily pulled from a monthly), or a
  vary range. This is a rule on the *values*, not a string comparison
  against the title — a title the user renamed by hand never changes
  whether the chip appears. Compound chips are unaffected: "1 square" vs
  "3 squares" is never implied by the title.
- **Every row in a panel is the same height** — a 42pt floor on the row's
  main line (7pt + 28pt + 7pt), pinned explicitly rather than inherited.
  Before B3.1 it fell out of the inline 28pt ✕; moving that ✕ to an
  overlay on *expandable rows only* would have left their 20pt badge
  setting the height and mixed ~34pt and ~42pt rows in one list. So the
  floor is stated: web `min-height: 42px` on `.disclosure` / `.staticLine`
  (border-box, padding included), iOS `.frame(minHeight: 28)` on the main
  line inside its 7+7 padding. It restores B3 exactly for an included row
  and deliberately **lifts** the two shapes that were already shorter —
  filtered-done's 22pt ✓ and excluded's ~24pt UNDO pill — rather than
  merely preserving them. It is a floor, not a clamp: a counter-clash
  row's two-line title still grows past it. (Three `RisoSourceSnapshotTests`
  baselines were re-recorded for the lift; `e2e/member-rules.spec.ts` pins
  it across all three render paths. That e2e check measures the *inner*
  line element, never the `<li>` — the `<li>` also carries the 1.5px
  hairline that `:first-child` lacks.)
- **The range moves inline** onto line 2 instead of taking a third line, so
  an expanded counting row is exactly two lines — the same height the B3
  handoff already budgeted for its separate vary-range line.
- **Parts stay single-line.** A part line at the 69pt indent still leaves
  ~155pt for the name, and part names are short; splitting them too would
  make a 3-part compound seven lines.
- **The disclosure is the whole row rect, not the text.** The hit area is
  the entire row — full width, full height, the row's 7pt vertical and 40pt
  leading padding included — minus only the ✕'s own 28×28 rect. A row whose
  title is short must still expand when tapped in the empty space after the
  title, and a tap in the padding above or below the title must count.
  Concretely: the row's padding moves *onto* the disclosure control (web:
  `<button aria-expanded>` carrying `width: 100%` and the row's own
  `padding: 7px 11px 7px 40px`, which `.disclosure` then overrides to
  `padding-right: 39px` — the content reserves the whole gutter so the
  chevron never sits under the ✕, while the ✕ itself is absolutely
  positioned at `right: 11px`, so the 11 lives on the control rather than
  on the button's padding; iOS: the same content in a **plain container**
  carrying the padding, then **`.contentShape(Rectangle())`** — the
  paddings must precede it — plus `.onTapGesture`,
  `.accessibilityElement(children: .contain)` and
  `.accessibilityAddTraits(.isButton)`, with the ✕ as a **sibling**
  `Button` in an `.overlay(alignment: .trailing)` **on that padded main
  line**, never nested inside the tappable container and never on the
  outer stack). The overlay's host is load-bearing, not a detail: on the
  outer `VStack` the ✕ would centre on the row *including* its expanded
  second line and drift down past the main line — the exact bug a fix
  round closed by moving it onto the main line. Likewise the
  `contentShape` ruling: a SwiftUI container without it registers taps
  only on its opaque children, which is exactly the "short title, dead
  row" frustration this project has hit before.

  **Why a tap gesture and not a `Button`** (revised 2026-09-19 during
  implementation; this section's first draft said `Button` + `ZStack`):
  `RisoSourceRowView.headerRow` carries a written warning against exactly
  that shape — *"never a Button nested in a Button (unreliable gesture
  arbitration)"* — and uses the tap-gesture form for its own header. Neither
  snapshot tests nor XCTest can prove gesture arbitration, and this repo
  forbids agents driving the simulator, so where the behaviour is untestable
  the construction the codebase already trusts wins.

  **The trailing control's padding must equal the row's own** (7pt vertical,
  11pt trailing) — never a value tuned to the main line's intrinsic height.
  Both axes were got wrong once each during implementation by padding the
  overlay to something other than the row's own values, and each time the ✕
  drifted out of line with the inline ✕ on a non-expandable row directly
  above or below it. `11 = 39 − 28` also makes the reserved gutter exact.

**Surfaces**

- shared `countingSummary(target, level, goal, unit)` (nullable — see the chip-suppression rule above) and
  `compoundSummary(split, partIds, excludedPartIds, level)`, each returning
  `MemberSummary { text, varying }`: they dispatch to the existing
  `varyRangeLabel` / `splitSquaresNote` rather than formatting anything new,
  so the Swift twin and the `display` section of `memberRuleVectors.json`
  stay a thin delta. Two narrow functions rather than one polymorphic
  `memberSummaryLabel`, so each is independently vector-pinnable and neither
  takes arguments the other ignores.
- compact stepper gains an optional `suffix` ("/ 30 Miles"), rendered as
  static text inside the pill border. Back-compatible — `RisoSpecialTaskPanel`
  passes none. Only the number stays editable, so the Task 7 ruling (commit
  the typed draft before stepping) is untouched.
- dice `.off` gains one centred pip — the 20×16 inner box's (10, 8) — at 45%
  `--riso-muted` / `.risoMuted`. The lit faces are unchanged, same 26×22 box
  (the face was squared to 22×22 in a later owner-requested fix — see the
  Primitives note above; this paragraph records the dice-face change as shipped)
  and same pip coordinates. Because this lands in the Riso primitive, the
  hand-added pool rows are fixed for free; nothing else about them changes.
- `MemberRuleRowModel.caption` → `targetSuffix`; the struct gains
  `isExpandable` and `summary`.

**Owner ruling 2026-09-22 — no identical derived clones, and one generic
family row in the library.** Device-testing #493 surfaced that pulling a
counting task from a board always mints a window-stamped derived counter,
even when nothing differs: "Read 1 book" (goal 1, can't be subdivided, vary
off) spawned a second "Read 1 book" with an identical regenerated title,
visible in the Tasks-tab library beside its root. Two rules:

1. **Skip the mint when the derived row would be identical to its root.**
   In `planDerivedTasks` (TS ↔ `BoardSources.planDerivedTasks`), a
   board-sourced counting member — or a split part — that **is itself a
   root** (`sharedCounterId == null`), whose resolved target equals its own
   goal *and* whose vary level is off is **placed as the root task itself**,
   exactly as pool-sourced and hand-added members already are. The root
   condition is load-bearing, not a nicety: a member that is *already* a
   window-stamped derived counter (a daily built from yesterday's daily
   supplies `derivedTaskId(boardA, R)` under its own id) must still be
   re-minted for *this* window, or board B places board A's row and reads
   day A's `baseline` against the root's lifetime — today's square then shows
   yesterday+today's progress and can open already complete (the
   phantom-completion class), and `refreshDerivedBaselines` never heals it
   because it recomputes from the stale row's own `startDate`. The manual
   branch has always guarded this with `isWindowStampedMember`; the board
   branch got it for free by always minting. Pinned by a vector: a
   window-stamped member pulled same-timeframe with vary off is still minted.
   A derived counter exists to carry a *different* target (pro-rated or
   hand-set) or a vary range; when it would carry neither, Windowed
   Completion already evaluates the root against the target board's window
   and the shared-task semantics (an increment on the daily counts on the
   monthly) are the documented intent. Persist, Preview and the deletion
   cascade all tolerate a member with no derived row (`isMintedForBoard`
   matches window-stamped rows only, so a directly-placed root is never
   mistaken for minted content). A later rule edit on a repeating board
   correctly flips root → derived at the next spawn, because each window
   re-plans. Every pre-existing vector pulls cross-timeframe, so the skip
   case is pinned by new vectors: same-timeframe board pull with vary off →
   the root id in `placement`, no derived row; the same with vary on → still
   minted; explicit `target == goal` with vary off → the root.
2. **The Tasks-tab library shows ONE generic row per counter family.**
   Library browse (`computeBrowsableTasks` ↔ `BrowsableTasks`) hides every
   task with a live `sharedCounterId` — window-stamped derived rows *and*
   P5 shared-counter members — and keeps the family root. A root that heads
   a family (≥1 live member links to it, or it is a hub-born `isCounter`
   counter — the same root test `buildSharedCounterGroups` uses, extracted
   into a shared `sharedCounterRootIds(tasks)` helper with a Swift twin)
   renders with the **generic label `formatCounterName(action, unit)`**
   ("Read book", "Run miles", "Push-ups") in place of its stored title, with
   no target count in the title or subtitle, and **tapping it opens the
   Counters hub detail** for that root (web `/profile/counters/:rootId`, iOS
   `CounterDetailView(counterId:)` via a `TasksTabRoute` pushed on the
   existing `NavigationPath`) — the page that already lists the family's
   windows. A standalone counter (no members, not `isCounter`) is unchanged:
   "Read 1 book" keeps its count and opens `TaskDetail`. The wizard's
   Library sheet renders from the same browse set, so members drop out of it
   too and the family root appears there under its generic label; adding it
   adds the root, as before. Owner's words: "do we really need a new task in
   the library for EVERY different target count?" — no; the hub is the home
   for per-window rows, and the library shows the counter once.

**Out of scope, deliberately**: wrapping a title to two lines (full width
fits realistic titles; genuinely extreme ones still ellipsize); any
hand-added-row change beyond the dice face; the B3 follow-up backlog above.

**Test impact**: `e2e/member-rules.spec.ts` reaches into a member row and
drives the stepper and dice directly at three call sites (`:166`, `:196`,
`:237`) — each needs a disclosure click first. Also
`MemberRuleRowModelTests`, `MemberRuleRow.test.ts`, `DiceButton.test.ts`,
`memberRulesDisplay.test.ts`, and re-recorded baselines for
`testSourceCountingMemberRule`, `testSourceCountingMemberVaryOn`,
`testPoolSourceCountingMemberHasDiceButNoStepper`,
`testSourceCompoundOneSquare`, `testSourceCompoundSplitUpWithExcludedPart`,
`testMemberRulePrimitivesLight`/`Dark`.

### Test strategy (B)

Shared TS ↔ Swift vectors, pinned like `TaskEventVectorTests`, each
asserting a hand-computed non-degenerate value (never the degenerate
output, never a pure function compared to itself):

- `nominalWindowDays`; `autoTarget` with all four branches pinned
  separately (daily←weekly 35→5; weekly←monthly 100→24; target ≥ source;
  null source; null target); `varyRange` / `rollTarget` with a seeded rng
  (boundary clamps at 1 and goal).
- `applyMemberRules`: split expansion incl. excluded parts, last-part
  guard, stale rule skipped.
- `planDerivedTasks`: board counting auto; override; vary roll; pool
  counting as-is unless vary; split parts; One-square compound → derived
  compound with mixed derived/original children; window-stamped hand-added
  member re-mint; supplying-source precedence; deterministic ids (all three
  namespaces).
- Codecs: `BoardSource` with/without rules round-trips; an old 6-field blob
  decodes on both platforms; `recurringDraftMix` v2 without
  `manualTaskVary`.
- Web vitest: persist mint atomicity; spawn idempotency (double spawn →
  identical rows); baseline from events; `refreshDerivedBaselines` and the
  pull sub-step leave `version` unchanged and enqueue nothing; root
  deletion via BOTH `deleteTaskWithCascade` and `deleteCounterWithUnlink`
  (window-stamped members soft-deleted, ordinary members unlinked); board
  deletion cascades derived tasks; a sync-queue row per tombstoned derived
  task; the `deriveDisplayedCount` read audit locked on each surface's row
  model.
- iOS XCTest via `makeTestInstance()`: the same seams; migration v31.
- Snapshots: `BoardWizardTasksStepSnapshotTests` gains member-rule states;
  `RisoKitSnapshotTests` for the new primitives. Web Playwright on the
  Tasks step + Preview shuffle.
