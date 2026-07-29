# Board Edit Mode + Create "Arrange" step

Canonical design doc for the **in-place board-edit flow** and the **create-wizard
arrange step**, ported from design handoff `OYBC Edit handoff.zip`
(`design_handoff_edit/` — gitignored). Both platforms (iOS SwiftUI + web React),
built in 4 phases. Companion to [`docs/RISO_WEB.md`](RISO_WEB.md) /
[`docs/RISO_UI_CHECKLIST.md`](RISO_UI_CHECKLIST.md) for the design system.

## What it is

Replace the cramped "do-everything" **`EditBoardSheet` modal** with a deliberate
**in-place Edit mode** on the Play board: enter via the existing Edit button →
the board screen becomes editable in place (no modal). Two clearly separated
sub-modes + an explicit, staged Save:

- **Edit tasks** (default) — static squares; tap one → a context menu (Replace
  task / Edit task) → bottom sheets.
- **Rearrange** — squares jiggle; reorder by **drag-to-insert** (live FLIP
  cascade) or **tap-to-swap**; the FREE center is pinned.

Chrome: Cancel + "Editing board" gold pill (red dot), board name input,
timeframe segmented, the **Edit-tasks ⇄ Rearrange** sub-mode toggle, a one-line
hint, the editable grid, **Save changes** + a live **edit counter**, and an
**Archive this board** ghost action. Staged draft; Save commits; Cancel confirms
if dirty; Archive confirms.

The same drag-to-insert + tap-to-swap interaction also replaces the create
wizard's read-only Preview with an **arrangeable** board (Preview ⇄ Rearrange +
Shuffle).

## Prototype → real-codebase adaptations (READ FIRST)

The handoff prototype is driven by an **in-memory `cells` array** with per-cell
`{ t, type, done, cur, max, unit, cid }`. **The real app does not work this way**,
and these invariants are locked — adapt, don't copy:

1. **Squares are `BoardTask` placement rows**, one row per occupied cell, keyed by
   `row`/`col` (not a single index, not an array). The grid is reconstructed at
   render from `BoardTask` rows. There is **no `cells` array** and **no per-cell
   completion field**.
2. **Completion identity is per `Task`, evaluated against the board's window**
   (Windowed Completion — the edit grid's windowed reads come from
   `BoardPlayViewModel.windowedIsCompleted(for:)` / the play surface's
   `SquareWindowContext`, never the lifetime caches). **Edit mode gates on
   `!sealedAt`**: a sealed ("Closed") board is a frozen record and cannot
   enter Edit at all — no unseal gesture exists
   ([`WINDOWED_COMPLETION.md`](WINDOWED_COMPLETION.md) §Sealing). So:
   - The prototype's *"Replace task resets progress (done=false, cur=0)"* does
     **not** apply — Replace just repoints `BoardTask.taskId`; completion follows
     the new task's global state (this is exactly what the existing
     `updateBoardTaskAndCascade` already does, honoring the shared-task rule).
   - *"Edit task"* edits the **global** `Task` (name/type/goal) — it changes the
     task everywhere it's placed, same as the Tasks tab. (Not a per-square clone.)
3. **Three capabilities don't exist yet and must be built:**
   - **`archiveBoard`** — set `status = ARCHIVED` (+ version bump + sync). Model
     after the existing soft-`deleteBoard`. (`BoardStatus.ARCHIVED` already exists.)
   - **A reorder op** — write new `row`/`col` (+ `isCenter`) onto moved BoardTask
     rows in one transaction (+ version + sync), then **re-derive the board's
     bingo lines** (`completedLineIds` / `linesCompleted`) since highlights are
     positional. Global Task completion is untouched (it rides with the task).
   - **All drag-and-drop** — no DnD library exists. Web = hand-rolled pointer
     events + FLIP (getBoundingClientRect + Web Animations/CSS transforms);
     iOS = `DragGesture` + `matchedGeometryEffect` (or `.draggable`/`.dropDestination`)
     with a manual jiggle (autoreversing `rotationEffect`).
4. **The center square is pinned** in the existing render logic on both platforms
   (`isCenter` at the mid row/col): never lifts, never a drop target, cascade
   flows around it.
5. **Reuse the codebase's components**, not the prototype's hand-rolled ones:
   - segmented control → `RisoSegmented` (web `components/riso/RisoSegmented.tsx`;
     iOS `Views/Riso/RisoControls.swift`).
   - task-library picker (Replace sheet) → web `CellSwapModal`, iOS `CellSwapSheet`
     (already the single-pick library picker used for swap/add).
   - type badge → web `TypeBadge`, iOS `RisoTypeBadge`.
   - board-metadata fields (name/timeframe/dates/center + validation) →
     web `BoardSetupForm` (`mode="edit-active"`), iOS `BoardSetupFormView`.

### Token map (prototype → Riso)
`--paper`→`--riso-paper`, `--paper-2`→`--riso-paper-2`, `--ink`→`--riso-ink`
(text/border) / `--riso-ink-static` (inked fills), `--muted`→`--riso-muted`,
`--blue`→`--riso-blue`, `--red`→`--riso-red`, `--green`→`--riso-green`,
`--gold`→`--riso-gold`, `--shadow-ink`→`--riso-shadow-ink`. Dark-contract +
focus-ring + scrim rules from `docs/RISO_WEB.md` apply verbatim (gold fills →
ink-static content; cream rings inset; scrims `rgba(0,0,0,…)`).

## Staged-draft model (DECIDED — applies to phases 2–4)

The flow is **fully staged**, faithful to the prototype: **nothing hits the DB until
"Save changes."** This is a deliberate divergence from the app's usual instant-write
model, justified by the handoff's explicit "staged draft + explicit Save" design.

On entering edit mode, seed a **squares draft** from the board's live `BoardTask`
rows + their `Task`s — a per-cell record `{ boardTaskId, row, col, isCenter,
taskId, + any staged Task-field overrides (name/type/max/unit) }`. While editing:

- **Replace(cell, newTaskId)** → set that cell's draft `taskId` (no DB write); counter++.
- **Edit-task(taskId, fields)** → stage Task-field overrides for that taskId (no DB
  write); counter++. NOTE: a `Task` is global — committing this edits the task on
  **every** board it's on; show a subtle "edits this task everywhere it's used" hint.
- **Rearrange** (Phase 3) → reorder a draft `preview` array; counter += 1 per move.
- The **grid renders from the squares draft** (staged taskId + staged Task fields),
  not the live placements, while in edit mode.

On **Save**, commit in order: metadata patch (Phase 1) → for each cell whose draft
`taskId` changed, `updateBoardTaskAndCascade(boardTaskId, newTaskId)` → for each Task
with staged field overrides, the existing global task-update op → (Phase 3) the
reorder op for changed positions. Then exit + "Board saved" toast. **Cancel**
discards the whole draft (confirm if dirty). The edit counter + `dirty`/`canSave`
already in Phase 1 extend to these staged square edits.

## Phases

| Phase | Scope | Key new code |
| --- | --- | --- |
| **1 — Edit-mode shell** | In-place edit chrome replacing the modal: Cancel + Editing pill, name, timeframe (+ custom dates), center, immutable-size chip, sub-mode toggle (UI only), Save + edit counter, Archive, confirm dialogs. Grid renders display-only. Retire `EditBoardSheet`. | `archiveBoard` op; edit-mode chrome; gate entry to non-embedded |
| **2 — Edit tasks** | Tap square (Edit-tasks sub-mode) → context menu (Replace / Edit) → bottom sheets. Replace reuses CellSwap (repoint taskId). Edit-task sheet edits the **global Task** (name/type/goal) for normal/counting/compound squares. **Center FREE↔task conversion split out to 2b.** | tap-menu, edit-task sheet |
| **2b — Center Free⇄Task toggle** | **Reframed** (see §Phase 2b): the center toggles between a **free space** (`FREE`/`CUSTOM_FREE`) and a **task square** (`NONE`). Metadata-only — no new op, no schema. The core is a latent-bug fix: the "pinned center" predicate becomes `centerSquareType ≠ NONE` (not positional), so a `NONE` center is a normal editable/rearrangeable cell. `CHOSEN` is left untouched (retired later by the separate **cell-locking** feature). | predicate fix + center toggle |
| **3 — Rearrange** | jiggle + drag-to-insert (FLIP) + tap-to-swap; pinned center. | reorder DB op (+ bingo re-derive); drag/FLIP grid |
| **4 — Create Arrange** | Wizard Preview → arrangeable board (Preview⇄Rearrange + existing Shuffle); pure in-memory placement reorder, persists via existing path. | reuse Phase-3 grid over the wizard `[Task?]` placement |

## Phase 1 — detailed scope

**Entry & layout.** The existing "Edit" button (ACTIVE boards only; **hidden when
embedded** in the core-window pager) toggles **in-place edit mode** instead of
opening the modal. Edit mode is self-contained in the play surface (it also lives
inside the pager, so don't assume the standalone page's header/back-link).
- **Web**: in edit mode the play surface becomes the two-column `.play` layout —
  left rail = the edit panel, right = the board grid. ≤880px the rail stacks above.
- **iOS**: vertical scroll — top bar (Cancel + "Editing board") → name → timeframe
  → Squares header + sub-mode toggle → hint → grid → Archive, with a **sticky
  bottom Save bar** (edit count + "Save changes").

**Chrome (this phase).** Cancel (confirms if dirty) · "Editing board" gold pill
with red dot · board name input · timeframe segmented (+ custom start/end when
Custom) · center editing · **immutable board-size chip** (read-only on active
boards) · **Edit-tasks ⇄ Rearrange** sub-mode toggle (renders + switches the
hint, but neither sub-mode is interactive yet) · one-line hint · the board grid
(display-only) · **Save changes** + live **edit counter** (disabled until dirty
AND name non-empty) · **Archive this board** (ghost) · inline confirm cards for
Cancel-if-dirty and Archive.

**Carry over from `EditBoardSheet` (then retire it):** name + timeframe + custom
dates + center editing with the **same validation** (name required; custom needs
both dates, end ≥ start; CHOSEN center only if `centerTaskId != null` &&
candidates exist; INDEFINITE clears endDate) and the **same save path**
(`updateBoardAndCascade` with `UpdateActiveBoardPatch`). Reuse `BoardSetupForm` /
`BoardSetupFormView` for these fields rather than re-implementing.

**Edit counter (this phase).** Counts staged metadata changes (name, timeframe,
dates, center). `dirty = any staged change`; `canSave = dirty && name.trim()`.
Square edits (phases 2–3) will add to the same counter.

**Save** → commit the metadata patch via `updateBoardAndCascade`, exit edit mode,
show a green **"Board saved"** toast (~2.4s). **Cancel** → if dirty, inline
"Discard changes?" (Keep editing / Discard); else exit. **Archive** → inline
"Archive this board?" (Keep editing / Archive) → `archiveBoard` → leave the board.

**Deferred to later phases (must NOT regress, but not built in Phase 1):** the
grid is display-only — tap-to-edit (Phase 2) and drag-rearrange (Phase 3) are
inert; the sub-mode toggle flips the hint text only.

**New op — `archiveBoard(boardId)`** (web `db/operations/boards.ts`, iOS
`AppDatabase.swift`): set `status = ARCHIVED`, bump `version`, enqueue sync
(UPDATE). Mirror the existing soft-`deleteBoard` shape. Both platforms in the
same PR.

## Phase 3 — detailed scope (Rearrange)

In edit mode + **Rearrange** sub-mode, squares **jiggle** and can be reordered two
ways, each producing **one staged edit**:

- **Drag-to-insert (default).** Press + move past a ~6px threshold lifts a tile (a
  tilted ghost follows the pointer; its old slot becomes a dashed gap). As you drag
  over other slots the grid **cascades live** (FLIP slide) and the gap follows the
  insertion point; release drops it and everything reflows. Row-major cascade.
- **Tap-to-swap.** Tap a tile to pick it up (gold ring, rest dims); tap another to
  swap; tap the same to cancel.

**Center FREE is pinned:** never lifts, never a drop target, cascade flows around it.

**Staged (per the staged-draft model).** Rearrange reorders a **dense,
position-indexed view** of the squares draft (slot → cell-or-null) — extend Phase
2's `squaresDraft` with a position-keyed projection for the drag. Nothing writes
until Save. The grid renders the staged order. The edit counter increments per
committed move (and stays DERIVED — a drag that returns a tile to its original slot
is net-zero, like the Phase-2 count fix).

**Reorder commit op (NEW).** On Save, after replaces/overrides, commit position
changes: web **`reorderBoardTasks(boardId, [{boardTaskId, row, col}])`** in
`db/operations/boardTasks.ts`; iOS **`AppDatabase.updateBoardTaskPositions(boardId,
[(boardTaskId, row, col)])`**. Each: in ONE transaction, write the new `row`/`col`
(+ keep `isCenter`) + bump `version` + enqueue a `boardTasks` UPDATE per moved row;
then **re-derive the board's positional bingo lines** (`completedLineIds` /
`linesCompleted`) via the existing stats-derivation helper (reuse the cascade block
already in `updateBoardTaskAndCascade`). **Never touch global `Task` completion** —
it rides with the task to its new slot. Apply all moved rows atomically so no two
rows transiently collide on the same `(row,col)`.

**Implementation refs (translate, don't copy):** web prototype
`web/board-edit.jsx` (`reorderToSlot`, `captureSlots`, `slotAt`, the FLIP
`useLayoutEffect`, `onCellPointerDown`, `rearrangeTap`) + `web/arrange-board.jsx`
(the trimmed reusable version) + `web/board-edit.css` (`wb-jiggle`, `wb-hole`,
`wb-ghost`, `wb-sel`, `wb-tgt`, `wb-dim`, `wb-sorting`). iOS prototype
`proto/arrange-board-ios.jsx` + `proto/create-arrange-ios.css`. Web uses
hand-rolled pointer + FLIP (no DnD lib); iOS uses `DragGesture` +
`matchedGeometryEffect` (FLIP-equivalent) + an autoreversing `rotationEffect`
jiggle. **Static slot-rect hit-testing** (capture slot rects at drag start; map
pointer→fixed slot) — NOT `elementFromPoint` on live tiles — to avoid cascade
flicker. Suspend the jiggle while sorting so it doesn't fight the FLIP transform.

This phase's grid component is **reused by Phase 4** (create-arrange), so build the
drag/FLIP as a self-contained, controlled piece (cells + onReorder), gated by a
`rearrange` flag.

## Phase 2b — detailed scope (center Free⇄Task toggle)

**Why this shape (architecture):** the center square bundles two *orthogonal*
properties — (1) *is it a free space?* (`FREE`/`CUSTOM_FREE`, auto-completed, no
task) vs a real task cell, and (2) *is a task pinned there during randomization?*
(`CHOSEN`). Property #2 only serves the create-wizard's Shuffle; **in edit mode
there's no randomization, so the pin is inert** — a `CHOSEN` center is just a task
that happens to sit in the middle. So the only edit-relevant center property is #1:
free space or task square. That maps to `FREE`/`CUSTOM_FREE` ⇄ `NONE`. (The general
"pin any cell" idea — a per-cell **lock** that Shuffle/rearrange skip — is the right
long-term replacement for `CHOSEN`, but it's a separate, schema-bearing feature
being spec'd elsewhere; **do not build locking here.**)

**1. Pinned-center predicate fix (the core).** Today the edit/rearrange guards key
off the *positional* center (`gridSize odd && row==col==mid`), which wrongly locks a
`NONE`-center middle cell. Change the predicate everywhere to **`isPinnedCenter =
(positional center) && centerSquareType ≠ NONE`** (i.e. `FREE`/`CUSTOM_FREE`/`CHOSEN`
are pinned; `NONE` is not). Effect: a `NONE` center becomes a fully normal cell —
tappable (Replace/Edit), a valid place/`+` target, and **rearrangeable** (drag/swap;
no longer pinned, cascade includes it). Apply to every guard the recon listed:
web `BoardPlaySurface` (`isEditTapTarget`, the swap context-menu `swapEligible`, the
rearrange `newPositions`/counter filters, the `ArrangeSlot` `isCenter` flag); iOS
`BoardPlayView`/`BoardEditPanel`/`RearrangeGrid` (the `.contextMenu` guards, the
`buildRearrangeCells`/reorder/`countPositionMoves` `isCenter` checks).

**2. The center toggle (the affordance).** In edit-tasks mode, the center cell gets a
quick action to flip its free-ness:
- **Free space → task square:** `FREE`/`CUSTOM_FREE` → `NONE`. The cell becomes a
  normal (empty) editable cell; the user fills it with the existing place/replace
  flow. (UX decision: convert to an *empty* editable cell, not auto-open a picker.)
- **Task square → free space:** `NONE` → `FREE`. The cell becomes a free space.
- Both are **metadata-only** — stage the `centerSquareType` change in the existing
  edit draft (the same draft Phase 1's chrome already tracks) and commit via the
  existing `updateBoardAndCascade` patch. **No new DB op, no schema change.** A
  task-holding center converted to free leaves its placement exactly as the chrome's
  `CHOSEN→FREE` does today (consistent pre-existing behavior; the cascade handles it).

Surface the toggle wherever it reads cleanly per platform (a center-cell tap menu
item / long-press action), alongside the normal Replace/Edit items when the center
holds a task. `CHOSEN` is **not** part of the toggle and is not normalized — the
chrome's center selector remains the way out of `CHOSEN`, and the future locking
feature will retire it.

## Cross-platform file map

| Concern | Web | iOS |
| --- | --- | --- |
| Play surface (edit entry + edit mode) | `components/BoardPlaySurface.tsx` | `Views/BoardsTab/BoardPlayView.swift` |
| Edit-mode chrome | new `components/boardEdit/*` (or inline) + CSS module | new `Views/BoardsTab/BoardEdit*.swift` |
| Retired modal | `components/EditBoardSheet.tsx` (delete) | `Views/BoardsTab/EditBoardSheet.swift` (delete) |
| Metadata form (reuse) | `components/wizard/BoardSetupForm.tsx` | `BoardSetupFormView` |
| Archive op | `db/operations/boards.ts` | `AppDatabase.swift` |
| Library picker (Phase 2) | `components/CellSwapModal.tsx` | `Views/BoardsTab/CellSwapSheet.swift` |
| Reorder op (Phase 3) | `db/operations/boardTasks.ts` | `AppDatabase.swift` |
| Create arrange (Phase 4) | `components/wizard/BoardWizardPreviewStep.tsx` | `Views/CreateTab/Components/BoardWizardPreviewStepView.swift` |

## Risks
- **#1 — cells↔BoardTask mapping** (Phase 3): a rearrange must translate to
  `row`/`col` writes + a positional bingo re-derive, never touch global Task
  completion, and keep the center pinned out of the move set. The create-step
  arrange (Phase 4) is far safer (in-memory `[Task?]`, no DB until save).
- **Pager embedding** (web): edit chrome renders inside `CoreBoardWindowPage` too
  — gate the Edit entry to non-embedded (mirrors iOS `!embedded`).
- **iOS**: `_Concurrency.Task` clash; `xcodegen generate` after new files;
  `BoardPlayView` isn't snapshot-coverable (snapshot the new leaf chrome views).
