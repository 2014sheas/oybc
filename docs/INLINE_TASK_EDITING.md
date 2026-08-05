# Inline task editing — board-creation wizard, Step 2 (iOS)

Design spec for the "Inline Task Editing" handoff (`Pool task editing
placements.zip` → `design_handoff_inline_task_editing/`). Canonical design is
`Inline Task Editing.dc.html` in that bundle; the other two placements
(bottom-sheet, preview-grid popover) in `Wizard Task Editing.dc.html` are
context only — **do not implement them**.

## Problem

Today the wizard's Tasks step (`BoardWizardTasksStepView` → `RisoPoolListView`)
lets a user *remove* a pooled task but not *edit* it — fixing a typo or a wrong
counting goal means abandoning the wizard and going to the Tasks tab. This adds
an **inline row editor**: tapping a row's pencil expands that row in place into
an editing panel (title, counting fields, compound steps) with **staged saving**
(no DB write until the board is created), validation, and one level of undo.

## Scope & platform

- **iOS-first (SwiftUI); web tracked as a parity follow-up.** The board wizard's
  Tasks step also exists on web, so inline editing is a shared surface under the
  cross-platform-parity rule (rule 6). Per user decision (2026-08-05) we ship iOS
  first — matching the Riso-redesign precedent — and log the web counterpart as a
  tracked parity follow-up. This is a deliberate, documented rule-6 deferral, not
  drift: record the web follow-up when PR 1 lands.
- **High fidelity.** Colors, type, spacing, radii, shadows, copy, validation
  rules and interaction states in the handoff are final — match them. Where the
  prototype uses a web token (`var(--riso-blue)`) the iOS twin is the matching
  `Color.riso*`. Use the existing Riso SwiftUI vocabulary (`RisoTextField`,
  `RisoNumberField`, `RisoButton`, `RisoTypeBadge`, `.risoCard(fill:)`,
  `.risoHardShadow(_:)`, `.risoSectionLabel()`, `Riso.gutter`) — no one-off styling.

## Relationship to the Pools + Recurring rework

Standalone. `docs/POOLS_RECURRING.md` is a separate 7-PR **web+iOS lockstep**
effort about *pulling pools into* the wizard (provenance, pull-in-a-pool card).
This feature edits individual pool *rows* inline. They share the Step-2 surface
but not the mechanism; build so the inline editor coexists with the pool card.

## Files

Primary:
- `apps/ios/OYBC/Views/CreateTab/Components/RisoPoolListView.swift` — the pool rows
  (row chrome + swap-to-editor in place).
- **new** `apps/ios/OYBC/Views/CreateTab/Components/RisoPoolRowEditorView.swift` —
  the inline editor leaf (prop-driven; title / counting / compound bodies).
- `apps/ios/OYBC/Views/CreateTab/Components/BoardWizardTasksStepView.swift` —
  owns the open-editor id, pool order, undo/toast timer.
- `apps/ios/OYBC/Views/CreateTab/ViewModels/BoardWizardViewModel.swift` — holds
  `poolOrder` + the `stagedEdits` map.
- `apps/ios/OYBC/Views/CreateTab/BoardWizardPersist.swift` +
  `apps/ios/OYBC/Database/AppDatabase+Boards.swift` — apply staged edits inside
  the board-create transaction.

Precedents to read first:
- `apps/ios/OYBC/Views/BoardsTab/SquaresDraft.swift` (`StagedTaskOverride`) +
  `SquareEditTaskSheet.swift` — the closest staging precedent (title/type/action/
  unit/maxCount; **no compound children** — hence a richer patch here).
- `apps/ios/OYBC/Views/TasksTab/EditTaskSheet.swift` — field layout / section rhythm.
- `apps/ios/OYBC/Views/CreateTab/Components/RisoCompoundFieldsView.swift` —
  compound child editing vocabulary.

## Data model

**Pool ordering (prerequisite).** `RisoPoolListView` sorts alphabetically
(`poolTasks` at line ~38), so a renamed task jumps position on save. Replace with
an explicit insertion order:
- Add `poolOrder: [String]` to `BoardWizardViewModel`, maintained alongside
  `selectedTaskIds`: append id on add, drop on remove, re-insert at original
  index on undo-restore. `RisoPoolListView` takes the ordered array and renders
  in that order — no sort. Draft resume rebuilds `poolOrder` from persisted
  placement order (fall back to `selectedTaskIds` iteration if absent).

**Staged edits (view-local editor draft → wizard-level map).**

Per-row editor (view-local in `BoardWizardTasksStepView`):
- `editingId: String?` — at most one open row.
- `draft` — cloned from the task on open:
  `{ title, action, goal, unit, ordered, children: [{ id, title, isProgress, action, goal, unit }] }`.
- `toast: String?` + `undo: (() -> Void)?` — single-level undo, **6s** auto-dismiss.

Wizard-level (`BoardWizardViewModel`):
- `stagedEdits: [taskId: TaskEditPatch]` — applied **inside the board-create
  transaction only, never while the board is a draft**. Modeled on
  `StagedTaskOverride` but richer:
  - `TaskEditPatch { title; action; goal; unit; ordered; children: [ChildPatch] }`
  - `ChildPatch { childTaskId: String?; title; isProgress: Bool; action; goal; unit; markedDeleted: Bool; isNew: Bool }`
- `centerTaskId` — unchanged semantics.

A pool task may be **pending** (created this session, deferred persist — Bug #85)
or an existing **library** task. Both stage identically.

## Apply-at-create (the one persist change)

Staged edits are applied inside the existing single atomic transaction owned by
`AppDatabase.saveWizardBoard(board:boardTasks:pendingTasks:isUpdate:now:)` — so a
failure rolls back the board record too, and the safety-net pull retries cleanly.

- **Pending task** → merge its `TaskEditPatch` into the `PendingTaskPayload`
  before it is written (in-memory; no extra write). Renamed compound children are
  merged into the payload's child list; new/deleted steps adjust it.
- **Library task** → mutate the existing `Task` row + `compound_children` links,
  each with a `SyncQueueItem` enqueue, in the same transaction:
  - **rename a step** = a **global** edit to that child `Task` (compound children
    are Tasks — see `RisoCompoundFieldsView`).
  - **delete a step** = remove the `compound_children` link only; if the child
    task lives on another board it stays in the library (**orphans are
    acceptable**, per product decision).
  - **add a step** = create a new child `Task` (+ its progress/counting fields)
    and a `compound_children` link.
  - **in-order toggle** = `Task.isOrdered` on the parent compound.

Thread these into `saveWizardBoard` via a new parameter (e.g.
`stagedEdits: [String: TaskEditPatch]`) rather than a separate write block, so
they share the transaction. Version-bump every mutated row.

## View & interactions

**Resting row** (`RisoPoolListView.poolRow`):
- **Type badge** (24×24) doubles as the center-square control in `.chosen` mode
  (tapping toggles center; a 15×15 gold marker with ★ notches at top-right of the
  marked task's badge — replaces the old leading star column, which left no room
  for a pencil at 393pt). Elsewhere the badge is a plain indicator.
- **Title + detail** (1 line each). Detail strings:
  counting → `"Run · goal 5 km"`; compound → `"3 steps · 1 with progress · in order"`
  (progress clause only when >0); achievement → `"Watch a board · First Bingo"`;
  shared simple → `"On 2 other boards"`; center → prefix `"Center square · "`.
- **Pencil button** (32×32, ≥44pt hit area via `.contentShape` + padding) —
  editable tasks only; pressed fills `--riso-blue`. Label "Edit task".
- **Achievement rows** get no pencil — a dashed **"TASKS TAB"** marker in its
  place (read-only here; trigger/target edited in the Tasks tab).
- **Remove ✕** (26×26) — label "Remove from board".

**Inline editor** (`RisoPoolRowEditorView`, replaces the resting row in place):
- Accent header bar (`--riso-blue`): pencil glyph + `"EDITING · SIMPLE TASK"` /
  `"· COUNTING TASK"` / `"· COMPOUND TASK"`.
- **Title** — always present, autofocused on open.
- **Counting** — Action / Goal / Unit (flex 1.4 / 0.7 / 1) + live
  `"Reads as: Run — 5 — km"` (`--riso-blue`), same builder as
  `SquareEditTaskSheet.countingPreview`.
- **Compound** — "STEPS" label + **In order** pill toggle; per-step card (index
  chip · title field · type indicator S/C · delete ✕); a **progress step** expands
  indented with Action/Goal/Unit + a "Reads as:" line; two dashed buttons
  **+ Simple step** / **+ Progress step**; the note "A step's type is fixed once
  added. Deleting a step unlinks it — if it lives on another board it stays in
  your library."
- **Staging hint** (shield glyph): shared → "Staged until you create the board.
  It then changes here and on 2 other boards."; not shared → "Staged until you
  create the board, then applied everywhere this task is used."
- **Validation line** (`--riso-red`) above the buttons when blocked.
- **Actions**: **Discard** (paper) / **Save task** (red, hard shadow;
  `.disabled(true)` when blocked so VoiceOver reports it).
- **Keyboard/scroll**: on open, focus the Title field and `ScrollViewReader`
  `scrollTo(rowID, anchor: .top)`. Action row stays in normal flow (a sticky
  version was rejected); a tall compound panel taller than the viewport is
  accepted — the user scrolls to reach Save.

**Behavior:**
- Pencil → that row becomes the editor; any other open editor closes.
- **Discard** → closes; if the draft differs, toast "Edit discarded" + **Undo**
  reopens the row with typing intact.
- **Save task** → writes to `stagedEdits` (no DB write), closes, toast
  "Staged · saves when you create the board" or "Staged · updates N boards when
  you create" (shared count + 1). **Undo** reverts the staged edit to the previous
  snapshot.
- **Remove ✕** → row leaves the pool immediately; toast `Removed "Stretch"` +
  **Undo** restores it at its original index. Removal keeps routing through
  `onToggleSelection` so it also purges any `pendingTasks` payload.
- **Step delete** gets no toast (Discard covers it — the panel is one transaction).
- **No type changes** here (a task's type and a step's type are fixed — hence two
  add-step buttons). Time window, description, achievement trigger/target →
  Tasks tab only.

**Validation** (blocks Save, message above the buttons):
- empty title → "A title is required."
- counting, goal ≤ 0 or unparsed → "Set a goal above zero."
- counting, empty unit → "Add a unit, like km or pages."
- compound with < 2 non-empty steps → "A compound task needs at least two steps."
- progress step missing goal/unit → `Progress step "Stretch" needs a goal and a unit.`
- Blank-titled steps are dropped on save.

**Dark mode** ("night press") via tokens alone — no per-element overrides. Text
on colored fills uses static foregrounds (`--riso-on-color` on red/blue/green,
`--riso-ink-static` on gold) so it doesn't flip. Verify the toast, accent header,
and center-square marker in both themes.

## Design tokens

Light / dark (already in the app's Riso palette — use `Color.riso*`, not literals):

| Token | Light | Dark |
|---|---|---|
| paper | #f1e9d9 | #171310 |
| paper-2 | #fbf6ea | #221c15 |
| ink | #18120b | #f1e9d9 |
| muted | #7e7460 | #a39781 |
| blue | #2c44c9 | #6678f2 |
| red | #eb4d2e | #ff6a4a |
| green | #1f9b6b | #3bcb92 |
| gold | #ffc21f | #ffc21f |
| on-color | #fbf6ea | #fbf6ea |
| ink-static | #18120b | #18120b |

Shape: card/field/button radius 8px; small chips 5–7px; pills 999px. Keylines:
2px ink; dashed 2px for add-step + read-only markers. Hard shadows: 2px chips /
3px rows+small buttons / 4px open panel+toast. Spacing: row gap 8 · field gap 11
· in-row gap 10 · step gap 6 · gutter 18. Type: Bricolage Grotesque (head),
Archivo (body); min panel text 10.5px. Glyphs from SF Symbols (no image assets).

## Delivery — 2 iOS PRs

Compound step editing is the hard, separable part; isolating it de-risks review
and device testing.

| PR | Scope | Screens |
|---|---|---|
| **1** | Pool ordering (`poolOrder`) + row chrome (pencil, gold center-marker on the badge, "TASKS TAB" marker, detail strings) + `RisoPoolRowEditorView` for **simple & counting** + `stagedEdits` map + apply-at-create + validation + undo/toast + snapshots (light+dark) | 1, 2, 3, 5, 6 |
| **2** | **Compound** step editing (step cards, +simple/+progress, delete/unlink, in-order toggle, progress children, its validation) + snapshots | 4, 7 |

## Testing

iOS Playground was removed (#119), so the playground-first equivalent is: build
`RisoPoolRowEditorView` as a prop-driven leaf against `SnapshotFixtures`, snapshot
every state, then wire it into the wizard.

- **Snapshot baselines** (`OYBCSnapshotTests`, light + dark) for: resting-row
  variants (simple/counting/compound/achievement/center), counting editor,
  validation-blocked, compound editor, toast+undo.
- **VM unit tests** (`OYBCTests`, `makeTestInstance()`): `poolOrder`
  maintenance (add/remove/undo-restore-at-index); `TaskEditPatch` apply for
  pending vs library tasks; compound child CRUD (rename = global, delete =
  unlink, add = new child+link); validation rule matrix.
- **Device pass** (relay numbered steps to the user — no sim-driving): open
  editor, edit each type, validation, discard+undo, save+undo, remove+undo, create
  the board and confirm edits landed + shared task changed everywhere.

## Invariants (don't regress)

- **No DB write while editing.** Staged edits apply only inside the board-create
  transaction. A draft board never carries a task edit.
- **Compound children are Tasks.** Renaming a step edits it globally; deleting a
  step unlinks only (orphans acceptable).
- **Removal routes through `onToggleSelection`** so `pendingTasks` payloads are
  purged (no wizard-orphan library leak — Bug #85 / `pendingPayloadsToPersist`).
- **Row order is insertion order**, not alphabetical.
- **One editor open at a time.**
