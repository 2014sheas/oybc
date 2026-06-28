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
2. **Completion is GLOBAL per `Task`** (`Task.isCompleted` / `currentCount`),
   shared across every board the task is placed on. So:
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
| **2b — Center conversion** | FREE center ↔ real task (Edit-task offers "Free" only on center) — touches `centerSquareType` + the center placement, not just a task edit. Deferred from Phase 2. | center type + placement swap |
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
