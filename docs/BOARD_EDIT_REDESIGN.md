# Board Edit redesign (2026-09 — in progress)

Owner-decided model for editing an EXISTING board, replacing the Phase 1–4
Board Edit described in [`BOARD_EDIT.md`](BOARD_EDIT.md) (kept as history of
the shipped surface until each slice below lands). Design source: the
Claude Design handoff at `design_handoff_board_edit/` (gitignored, reference
only; `README.md` there is the frame-by-frame spec and names the existing
views each frame composes from). Deep dive + decision log:
claude.ai artifact "Board Edit Redesign Brief" (2026-09-26).

## The model (decided 2026-09-26)

- **Board Edit is only the squares editor ("Edit squares").** The grid stays
  where it is; edits are staged; a sticky bottom bar shows the count,
  **Shuffle**, and **Save changes** (Cancel top-left). No Rearrange mode, no
  preview step.
- **Title row**: window chip (core boards) · **Edit squares** · a **"…"**
  menu — *Board details…* (ad-hoc) / *Core defaults…* (core) · *Repeat this
  board…* · *Archive* · *Delete*. Ended board: **Close board** first. Closed
  board: **Reopen board** first.
- **Board details** (renamed from "Board settings" — `/profile/board-settings`
  owns that name) = `BoardSetupForm` / `BoardSetupFormView` in edit-active
  mode + the size chip. **Core boards have no details sheet**: name, timeframe,
  repeats and archive are not fields on a core board (its window is
  structural; durable choices live in Board settings → core defaults).
- **Square tap (edit)**: Replace task… · Edit task… ("changes it everywhere
  it's used") · **Lock in place / Unlock** · Remove from board. Center square
  toggles Free space ⇄ task square. **Tap an empty square = add** (staged;
  the play-mode "+" immediate write is retired). Press-and-hold moves a
  square; locked squares don't lift. Shuffle rearranges every unlocked square
  and counts as one staged edit.
- **Picker** (add / replace) = the wizard's quick-add row (typed text → inline
  library matches) + the dashed special-task entry (counting / compound /
  achievement). No Library or Sources tabs — pools and boards are not a supply
  for a live board's squares.
- **Locks** replace the CHOSEN center type: center is Free or Task; any
  square (center included) can be locked so Shuffle and moves keep it in
  place. Existing CHOSEN boards are read as a locked center task
  (read-path normalization, no migration) and converted on disk on the
  user's next squares Save — see §Slice 3. Lock chip is
  red (DS template "Lock a Square"); staged edits show a gold pencil chip.
- **Window**: the timeframe never switches after creation; only dates on
  custom / ongoing boards (Board details).
- **Ended, not closed**: plays and logs normally (late logs stamped at the
  window end, the existing `lateLogOccurredAt` rule); no edit; no "Read-only"
  label; banner + *Close board*.
- **Closed**: BOTH a direct late log (tap a square: normal → "Mark done on
  board"; counting → the counting stepper sheet, partial and overshoot
  allowed; compound → parts list; achievement → no-op; the event is stamped at
  the window end, the board stays closed, `sealedCompletedCells` /
  `completedLineIds` re-derive, streaks and achievement watchers recompute)
  AND **Reopen board** (clears `sealedAt` + the snapshot; completion
  re-derives from events; `.alert` confirm). A manually reopened board never
  auto-closes again — it stays open until Close. This RELAXES
  [`WINDOWED_COMPLETION.md`](WINDOWED_COMPLETION.md)'s "a sealed board authors
  no event" — that doc changes in the same PR as slice 4.
- **Auto-close** moves from `min(48h, window/4)` to *when the next window of
  that timeframe ends* (yesterday's daily closes at the end of today).
- iOS keeps the tab bar visible in edit mode (save bar above it). Discard,
  Archive and Delete share the same alert shape.

## Delivery: a PR train, every PR lands web + iOS together (rule 6)

| Slice | Scope | Status |
| --- | --- | --- |
| 1 | Per-square locks (`BoardTask.isLocked`, synced) honored by rearrange; Lock/Unlock in the existing edit tap menu; one cell renderer with lock + dirty chips across play / edit / arrange / wizard preview on both platforms; web Playground demo + iOS snapshots | shipped (#510) |
| 2 | Title-row "…" menu; Board details sheet; core-board gating (no name / timeframe / repeats / archive on `isCore`); Archive / Delete / Repeat move out of the panel | shipped (#511) |
| 3 | Squares editor rebuild: single mode, tap-to-add on empties, hold-to-lift, Shuffle in the save bar, the quick-add picker, CHOSEN retired → locked center, play-mode "+" retired; remove the center selector from Board details; retire the Edit tasks ⇄ Rearrange toggle | in progress — see §Slice 3 below |
| 4 | Close / Reopen / direct late log on closed boards / next-window auto-close | planned |

Independent of the train (bugfix PRs any time): iOS Board Edit rewrites an
achievement task's type (P0). ~~zero-placement boards show "Loading…" forever
(web)~~ — **fixed in slice 3**: `BoardPlaySurface` gated its grid on
`sortedBoardTasks.length === 0`, conflating "query unresolved" with "loaded,
no squares"; it now gates on `boardTasksLoaded` from `useBoardPlayData`
(tri-state `useBoardTasksQuery` → `resolveBoardPlacementsQuery`). iOS was
never affected (it gates on `board != nil`). ~~start-date edits on ongoing boards are counted but never saved
(both)~~ — **fixed in slice 2** (D12/B1: `buildBoardDetailsPatch` /
`BoardDetailsDraft.patch()`). ~~"Board saved" reported for a board sealed
mid-session (both)~~ — **fixed in slice 2** (D11/B2: `assertBoardEditable`
throws inside the transaction instead of silently returning). ~~stale
`repeat-board.spec.ts` describes~~ — **fixed in slice 2** (T5: the two
describes that targeted the retired play-surface row now drive the "…" menu
→ Repeat sheet).

## Slice 1 — detailed scope

**Data.** `BoardTask.isLocked` (optional boolean, decoded forward-compatibly
like `Board.isCore`; absent = false). Web: Dexie field only (no index, no
store version). iOS: GRDB migration v34
`ALTER TABLE board_tasks ADD COLUMN isLocked INTEGER NOT NULL DEFAULT 0`,
`decodeIfPresent ?? false`. Sync: rides the `boardTasks` collection under the
existing per-row LWW; `firestore.rules` validates no per-field shape for
`boardTasks`, so no rules change.

**Kernel.** A locked placement never changes position: `reorderBoardTasks`
(web) / `updateBoardTaskPositions` (iOS) refuse a move set that relocates a
locked row (the whole staged reorder is rejected, nothing partial); the edit
slot builders (`arrangeSlots` ↔ `buildRearrangeCells`) treat locked cells like
the pinned center (not draggable, not a drop target). The wizard's pre-persist
shuffle is untouched (no locks exist before a board is persisted).

**Lock / Unlock.** One new item in the existing edit tap menu on both
platforms (`SquareTapMenu` ↔ the `.confirmationDialog`), staged in the edit
draft as a per-cell override and committed inside the atomic Save
(`setBoardTaskLocked` op: version bump + sync enqueue; sealed/deleted guard
like every other placement write). Each lock change counts as one edit.

**Renderer.** Web: `BoardCellModel` gains `locked` / `dirty`; `RisoBoardCell`
draws the corner lock chip (red) and gold pencil chip; the three duplicated
cell-model mappings (`BoardPlaySurface`, `useBoardPlay`, the wizard's
`taskToModel`) collapse onto one mapper next to `buildRisoBoardCells`;
`RisoBoard` is the grid layout the play surface uses (replacing the inline
`repeat(n, 90px)` grid). iOS: `RisoBoardPlayCell` gains `showsLockChip` /
`showsDirtyChip` (its existing `isLocked` tap-gate is renamed
`isInteractionLocked`); the private `BoardEditStaticGrid`/`Cell` and the
`RearrangeGrid` cell face are replaced by `RisoBoardPlayCell` behind a shared
`RisoBoardGrid` layout, so play, edit and the wizard preview draw the same
square (FREE included).

**Verification surface.** Web: `BoardGridPlayground` (top of `/playground`)
showing the shared grid in play / edit / arrange states with locked, dirty,
FREE, counting and compound cells at 3×3 and 5×5, light + dark, Playwright
screenshots; Vitest for the reorder guard and the cell mapper; an e2e that
locks a square, saves, reloads, and fails to drag it. iOS: XCTest for the
reorder guard + v34 decode; snapshot tests for the chips and the unified edit
grid (the `BoardEditCenterToggle` baselines re-record, they are standing
reds today).

**Out of slice 1**: everything in slices 2–4; the wizard's shuffle honoring
locks; any change to the tap-menu's other items; the pre-design bugfixes.

## Slice 2 — detailed scope

Plan: `.superpowers/sdd/2026-09-26-board-edit-slice2/plan.md` (worktree
`/Volumes/Stephen/oybc-worktrees/board-edit-slice2`, branch
`feature/board-edit-slice2-menu`, base `dev` 59e9ca75 / #510). One PR, web +
iOS together (rule 6).

- **Title-row "…" menu** replaces the play surface's Edit / Archive / Repeat
  row. The trailing slot becomes `Edit squares` (renamed from "Edit" / "Edit
  board") + a "…" square that opens a `Menu` (iOS) / Riso popover (web). The
  `Edit squares` gate is unchanged (`status == active && sealedAt == nil &&
  !editMode`); the "…" menu is hidden while `editMode` is true.
- **Menu items per board kind**, from one pure builder mirrored on both
  platforms (`buildBoardMenuItems` / `BoardMenuItems.items`):
  - Ad-hoc, active and unsealed: `Board details…` · `Repeat this board…`
    (only when repeat-eligible: a repeating board needs a resolved source
    template, a one-off board needs a center other than CHOSEN) · `Archive`
    · `Delete`.
  - Core (`isCore`): `Core defaults…` · `Delete` only — name, timeframe,
    repeats and archive are not fields on a core board.
  - Sealed (closed) boards: `Core defaults…` (core only) · `Delete` only.
    Repeat and Archive both write to the sealed board row (back-stamp /
    status), so they're deferred to slice 4 alongside Reopen and the
    relaxed closed-board rules.
  - Draft boards: no menu (the draft-resume prompt replaces the header).
- **Board details** is a new sheet with its own Cancel · "Board details" ·
  Save, committed independently via `saveBoardDetails` (a metadata-only
  patch, not part of the squares draft) — opening it is only possible
  outside edit mode, so the two drafts never coexist. Fields: the immutable
  size chip, name, dates (**only for custom / ongoing boards** — calendar
  timeframes show the existing read-only window note), and the center
  selector (Free / Choose / None). **No timeframe control** — the timeframe
  never switches after creation. The center selector stays here only for
  this slice; it's the only way off a CHOSEN center until slice 3 migrates
  CHOSEN to a locked task, and is removed from Board details in slice 3.
- **"Repeat this board…"** opens a Repeat sheet (Cancel · "Repeat this
  board" · Save) that reuses the existing staged REPEATS logic unchanged
  (web `BoardEditRepeatSection` + `buildRepeatSavePlan`; iOS the panel's
  former `repeatsSection` markup, extracted). Hidden under the same rules
  the old panel used.
- **Archive / Delete** get `.alert`-shaped confirms (Cancel / Archive,
  Cancel / Delete-destructive), reusing existing copy. After Archive or
  Delete: a standalone board pops back to the Boards list; a core board
  inside the window pager stays in the pager and the window falls back to
  its lazy setup prompt (keyed on `board.isCore`, not on `embedded`).
- **Core defaults…** opens the existing `CoreDefaultsEditSheetView` /
  `CoreDefaultsSheet` for the board's timeframe, wrapped in a new
  data-loading host mounted only while open (reuses the same pools / tasks
  / templates / roster-mix / library loads `BoardSettingsView` /
  `BoardSettingsPage` already do).
- **The squares panel after slice 2** keeps: Cancel, the gold pill (now
  "Editing squares"), the Edit tasks ⇄ Rearrange toggle + hint, the
  edit/rearrange grid, the tap menu (Replace / Edit / Lock / Remove / center
  Free⇄Task), and the save bar. It **loses**: the size chip,
  `BoardSetupForm`/`BoardSetupFormView`, REPEATS, and "Archive this board" —
  those moved to Board details / the Repeat sheet / the "…" menu. Its Save
  still commits the squares draft plus, when changed, a center-only metadata
  patch (`{ centerSquareType }`) in the same transaction. The Edit tasks ⇄
  Rearrange toggle itself is untouched here — it's retired in slice 3, not
  slice 2.
- **Sealed / deleted mid-session is a typed error, never "Board saved."** A
  new `assertBoardEditable` guard runs first inside every edit transaction
  (squares save, details save, repeat-start). If the board is sealed or
  deleted it throws (`BoardNotEditableError` / `BoardEditError
  .boardNotEditable`), the whole transaction rolls back (staged task
  overrides included), and the UI shows "This board has been closed, so
  your changes weren't saved." and exits edit mode / closes the sheet. Until
  slice 4, sealed boards' menu is Delete-only (+ Core defaults… on core) —
  Repeat and Archive return to the sealed menu once slice 4 relaxes the
  closed-board rules.
- **File-size budget**: `BoardPlayView.swift`, `BoardPlaySurface.tsx` and
  `BoardPlayViewModel.swift` must end strictly smaller than their slice-1
  caps; the new UI lands in new files under `boardActions/` /
  `Views/BoardsTab/BoardActions/`.
- **No new Playground demo.** Slice 2 recomposes shipped sheets; it's
  verified in-route with Playwright (393 + 1440, light + dark) and iOS leaf
  snapshots.

## Slice 3 — detailed scope

Plan: `.superpowers/sdd/2026-09-26-board-edit-slice3/plan.md` (Decisions
D1–D20; branch `feature/board-edit-slice3-squares`). One PR, web + iOS
together (rule 6).

- **CHOSEN is retired by a read-path normalization, not a migration (D1–D3).**
  Sealed rows must never mutate, and a non-authored write of synced
  user-visible state would diverge across peers, so no GRDB/Dexie migration
  runs. Two pure kernels (`packages/bingo-core/src/centerSquare.ts` ↔
  `Services/CenterSquare.swift`): `effectiveCenter(type)` maps CHOSEN → NONE,
  and `isLegacyChosenCenterLocked(type, row, col, size)` makes the positional
  center placement read as locked. Effective lock = `bt.isLocked ||
  isLegacyChosenCenterLocked(...)`. `CenterSquareType.CHOSEN` stays in the
  enum and Zod (old peers, sealed rows, wizard drafts still carry it; iOS
  would otherwise decode unknown values as FREE).
- **On-disk conversion happens on the next squares Save (D2)** — an authored
  write inside the Save transaction: `normalizeLegacyChosenCenter(boardId,
  keepLocked)` sets `centerSquareType = NONE`, clears `centerTaskId`, and
  writes the ORIGINAL center placement's `isLocked = keepLocked, isCenter =
  false` (version bumps + sync enqueue; `assertBoardEditable` first, so a
  sealed board is never touched). The conversion itself is not an edit; an
  untouched CHOSEN board has 0 edits and Save stays disabled.
- **Board creation (D4)**: the wizard's Center step ("Choose") is unchanged
  in memory; the ACTIVE persist writes a CHOSEN pick as NONE + a locked center
  placement (no `centerTaskId`). Drafts keep CHOSEN so resume restores the pick.
- **Repeat (D5)**: every one-off board is repeat-eligible; the template's
  center is `effectiveCenter(...)` (FREE | NONE). Locks do not carry into
  templates (no positional data).
- **Board details (D6)** no longer has a center selector; the center changes
  only in the squares editor (Free ⇄ task square, plus Lock/Unlock).
- **One grid (D7–D9)**: tap a task square → the square menu (Replace task… ·
  Edit task… · Lock in place / Unlock · Remove from board, + "Make it a free
  space" on the center); tap an empty square → the picker; tap the FREE center
  → "Make it a task square"; tap an EMPTY center → "Add a task…" / "Make it a
  free space". Press-and-hold (350 ms) lifts a movable square into the
  existing drag cascade; dropping on an empty square is a straight swap;
  locked squares and the FREE center never lift and are never drop targets.
  Web: a movement past 6 px or a browser `pointercancel` before the hold fires
  cancels it (page scroll wins). Keyboard / VoiceOver: Alt+Arrow (web) and
  "Move up/down/left/right" accessibility actions (iOS) swap one step, with
  the same announcement copy ("Moved {title} to row R, column C", "{title} is
  locked", "Already at the edge of the board").
- **Shuffle (D10)** = `shuffleUnlockedSlots` (bingo-core ↔ `Shuffle.swift`),
  Fisher-Yates over the non-fixed slots (empties included); fixed = locked
  placements + the FREE center. Pinned by `shuffleUnlockedVectors` in
  `placementVectors.json` (synced to the iOS fixture). Disabled with fewer
  than 2 unfixed task squares.
- **Edit count (D11)**, derived: replacements + adds + removals + task
  overrides + lock changes (existing placements only — an add's lock is part
  of the add) + center change + position edits, where position edits are 0
  when nothing moved, else 1 if the session shuffled, else the number of moved
  placements. The shuffle flag clears once every placement is back on its
  baseline slot. **One user action = one edit**: the center Free toggle is ONE
  edit even though it also tombstones the center placement (the implied
  removal is folded into the center-change term; Save still writes it).
- **Gold pencil chip (D12)** on any square holding a placement that differs
  from saved (task, staged task override, position, lock); never on an empty
  square or the FREE center; rendered side by side with the lock chip.
- **Picker (D13/D14)** = the wizard's quick-add row + the collapsed
  special-task panel (Replace: kicker "Replace square"; Add: "Add square" /
  "Empty square"). New normal / counting / achievement tasks are staged and
  written only at Save, with `createdInWizard = false` (children too);
  Cancel discards them. **Compound carve-out**: the special panel writes a
  compound immediately (web parity), so only its placement is staged — a
  compound created in a cancelled session stays in the library.
- **Save transaction (D15)**, one atomic transaction on both platforms
  (web `commitSquareEdits` in `db/operations/boardEditCommit.ts` ↔ iOS
  `handleEditSave`): `assertBoardEditable` → insert pending tasks →
  `normalizeLegacyChosenCenter` (if still CHOSEN on disk) → replacements →
  task overrides → removals → **unlocks** → moves → adds (with their lock) →
  **locks** → the center metadata patch (FREE ⇄ NONE, only when changed).
  Unlocks run before moves because the move op rejects a row locked on disk
  ("Unlock → hold-drag → Save" in one session); locks run after moves.
- **"Remove from board" leaves a dashed empty square (D16)**; "Make it a
  free space" on a task center also stages the center placement's removal, so
  derivation can auto-fill FREE.
- **Play-mode "+" retired (D17)**: empty squares in play are plain dashed
  squares; the only add path is the squares editor.
- **Deviation**: `ArrangeGrid.tsx` / `RearrangeGrid.swift` are NOT deleted —
  they remain the board-creation wizard's Preview ⇄ Rearrange grid.
  `SquaresEditGrid` (web ↔ iOS) is the board-edit fork. `CellSwapModal.tsx` /
  `CellSwapSheet.swift` are deleted.
