# Board Edit redesign (2026-09 — train complete)

Owner-decided model for editing an EXISTING board, replacing the Phase 1–4
Board Edit described in [`BOARD_EDIT.md`](BOARD_EDIT.md) (kept as history of
the shipped surface until each slice below lands). Design source: the
Claude Design handoff at `design_handoff_board_edit/` (gitignored, reference
only; `README.md` there is the frame-by-frame spec and names the existing
views each frame composes from). Deep dive + decision log:
claude.ai artifact "Board Edit Redesign Brief" (2026-09-26).

## The model (decided 2026-09-26)

- **Edit hosts SQUARES (live boards) + a BOARD section of options** *(Edit
  consolidation, 2026-09-27 — was "Board Edit is only the squares editor
  ('Edit squares')")*. The grid stays where it is; edits are staged; a sticky
  bottom bar shows the count, **Shuffle**, and **Save changes** (Cancel
  top-left). No Rearrange mode, no preview step. Below the squares, a
  **BOARD** section lists every board option as rows. See §Edit
  consolidation.
- **Title row**: window chip (core boards) · **Edit** — no "…" *(Edit
  consolidation; the slice-2/4 "…" menu is retired)*. The options it held —
  *Board details…* (ad-hoc) / *Core defaults…* (core) · *Repeat this
  board…* · *Archive* · *Delete*; ended board **Close board** first, closed
  board **Reopen board** first — are the BOARD section's rows, same builder,
  same order.
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
  auto-closes again — it stays open until Close. Only a late log is undoable
  ("Undo late log" / the counting sheet's undo — identified by `boardId` +
  `createdAt > sealedAt`); every other event inside the closed window stays
  tombstone-immune. *(The handoff README's decision 3 floated a "grace to end
  of day" for a reopened board; the owner ruling is "never auto-closes" —
  slice 4 D1.)* This RELAXES
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
| 3 | Squares editor rebuild: single mode, tap-to-add on empties, hold-to-lift, Shuffle in the save bar, the quick-add picker, CHOSEN retired → locked center, play-mode "+" retired; remove the center selector from Board details; retire the Edit tasks ⇄ Rearrange toggle | shipped (#512) — see §Slice 3 below |
| 4 | Close / Reopen / direct late log on closed boards / next-window auto-close | shipped (#513) — see §Slice 4 below |
| Edit consolidation | Owner request after device test: one title-row **Edit** (no "…"); every board option becomes a row in Edit's **BOARD** section; Edit on every non-draft board; squares hidden behind one muted line when they can't change | this PR (`feature/edit-consolidation`) — see §Edit consolidation below |

Independent of the train (bugfix PRs any time): ~~iOS Board Edit rewrites an
achievement task's type (P0)~~ — **fixed in #514**: `SquareEditTaskSheet`
seeded an achievement's type as `.normal` and `applyingOverride` only guarded
Compound, so a plain rename saved the task as Simple; type switches were
Simple ⇄ Counting only (`boardEditAllowsTypeSwitch`) and the sheet edits an
achievement's title only (web was never affected — its sheet never sent
`type`). **Amended 2026-10-02 (owner):** the sheet now also switches Simple /
Counting **into** Compound and edits a compound's rule + sub-tasks in place
(staged `compound: TaskEditPatch`, the Task Detail editor embedded; never
OUT of Compound, never Achievement), and web's sheet gained the Simple ⇄
Counting switch — see `docs/TASK_SYSTEM.md` §Editing a task. ~~zero-placement boards show "Loading…" forever
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
→ Repeat sheet). ~~iOS press-and-hold-to-move never fired (iOS)~~ — **fixed
in #516**: `SquaresEditGrid` placed each cell with `.offset` and only THEN
attached `.contentShape` / its gestures / its accessibility element;
`.offset` moves rendering, not the layout frame, so every hit region (and
VoiceOver frame) collapsed onto slot 0 and a touch on a visible square landed
on the cell face's own `.onTapGesture` instead. Fix: interaction modifiers
before `.offset`, face `.allowsHitTesting(false)`, lift on hold-complete, a
`@GestureState` revert for cancelled gestures, and `BoardEditPanel` disables
its ScrollView while a square is lifted. Proven by the new `OYBCUITests`
target (web's grid was never affected).

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

- **Title-row "…" menu** *(superseded by §Edit consolidation — same
  builder, now rows in Edit's BOARD section; the trigger is gone)* replaces
  the play surface's Edit / Archive / Repeat row. The trailing slot becomes `Edit squares` (renamed from "Edit" / "Edit
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
    relaxed closed-board rules. *(Superseded by slice 4 D12 — see §Slice 4:
    ended and closed boards now get Close / Reopen first, and ad-hoc closed
    boards get Repeat and Archive back.)*
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
  Cancel discards them. **Compound carve-out (corrected 2026-10-02)**: on WEB the
  special panel writes a compound immediately, so only its placement is
  staged (a compound created in a cancelled session stays in the library);
  on iOS the panel DEFERS it as a pending payload like every other new task
  (its child links are written one by one at Save — the zip-by-index bug that
  dropped an existing-library sub-task's link was fixed 2026-10-02).
- **Save transaction (D15)**, one atomic transaction on both platforms
  (web `commitSquareEdits` in `db/operations/boardEditCommit.ts` ↔ iOS
  `handleEditSave`): `assertBoardEditable` → insert pending tasks →
  `normalizeLegacyChosenCenter` (if still CHOSEN on disk) → replacements →
  removals → **unlocks** → moves → adds (with their lock) → task overrides
  (step 7b, AFTER replacements/adds so each override is remapped from the
  staged library id to the id actually placed — a minted per-window counter
  copy, #537; a compound conversion / structure edit runs here through
  `applyStagedCompoundChildEdits`) → **locks** → the center metadata patch
  (FREE ⇄ NONE, only when changed).
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

## Slice 4 — detailed scope

Plan: `.superpowers/sdd/2026-09-27-board-edit-slice4/plan.md` (Decisions
D1–D18; owner rulings R1–R5 in `owner-rulings.md`, binding; branch
`feature/board-edit-slice4-close`). One PR, web + iOS together (rule 6). This
slice amends [`WINDOWED_COMPLETION.md`](WINDOWED_COMPLETION.md) in the same PR
(§Closed boards, §Lifecycle steps 3–5, the immunity predicate).

- **Ended vs closed.** Ended = past `endDate`, not sealed, not archived
  (`isBoardEnded`); closed = sealed and ACTIVE / COMPLETED (`isBoardClosed`).
  Both are shared pure predicates with Swift twins.
- **`Board.reopenedAt` (D1)** — ISO8601, stamped by every Reopen, never
  cleared. Zod optional; Dexie field only (no store version); GRDB **v35**
  `ALTER TABLE boards ADD COLUMN reopenedAt TEXT`. No `firestore.rules` or
  sync-contract collection change.
- **Clearable board fields (D2)** — `CLEARABLE_BOARD_FIELDS = ['endDate',
  'completedAt', 'sealedAt', 'sealedCompletedCells']` in the shared sync
  contract (+ `syncContract.json` for Swift). Push sends a field delete for
  each absent one; the iOS pull NULLs each one a winning remote row lacks.
  Without it a Reopen never reaches the other device. See
  `SYNC_STRATEGY.md`. (Generalised 2026-09-29 into the per-collection
  `CLEARABLE_FIELDS_BY_COLLECTION`, of which this constant is the `boards`
  entry — `coreBoardDefaults` clears its size/centre overrides the same way.)
- **Close (D3)** = the existing seal transaction (`closeBoard` → `sealBoard` /
  `sealBoardTx`) + achievement-watcher refresh. No confirm. The Boards-tab
  closing-out banner's "Close out" routes through `closeBoard` too.
- **Auto-close (D4, D5, R5)** — `computeAutoCloseDeadlineMs` replaces
  `min(48h, window/4)`: the end of the NEXT window of the board's timeframe
  (daily +1 day, weekly +7 days, monthly end of next month, yearly end of next
  year, custom + its length in whole local days clamped to [1, 31], indefinite
  never), local wall-clock, pinned by `autoCloseDeadlineVectors.json`.
  Reopened boards never auto-close. The pass waits for the session's first
  pull (10 s / offline fallback). Boards sealed under the old rule stay sealed.
- **Reopen (D6)** — `.alert` "Reopen this board?" / "It accepts logs again
  until you close it. Streaks and achievements that watch it will
  recompute." · Cancel · Reopen. One transaction: clear `sealedAt` +
  `sealedCompletedCells`, stamp `reopenedAt`, version + enqueue, live
  re-derivation of the board, watcher refresh. Spawns nothing; hidden from the
  closing-out banner; no expiry notification (its `endDate` is past). iOS
  reconciles notifications after Close / Reopen.
- **Direct late log (D7–D11, R1–R4)** — one DB choke point per platform
  (`lateLog.ts` ↔ `AppDatabase+LateLog.swift`); see WC §Closed boards for
  the event, re-derivation, undo and recovery rules.
- **Menus (D12)** *(now the BOARD section's rows — §Edit consolidation)*, one pure builder per platform (`buildBoardMenuItems` ↔
  `BoardMenuItems.items(…, now:)`):
  - Ad-hoc ended: `Close board` · `Board details…` · `Repeat this board…` ·
    `Archive` · `Delete`.
  - Ad-hoc closed: `Reopen board` · `Repeat this board…` · `Archive` ·
    `Delete`.
  - Core ended: `Close board` · `Core defaults…` · `Delete`.
  - Core closed: `Reopen board` · `Core defaults…` · `Delete`.
  - Archived: unchanged (no Close / Reopen).
  Archive and Repeat use `assertBoardMetadataWritable` (sealed allowed,
  deleted throws); squares / details saves keep `assertBoardEditable`.
- **Ended = no edit (D13)** *(superseded by §Edit consolidation: Edit now
  shows on every non-draft board; this rule survives as `canEditSquares`,
  the SQUARES-section gate)* — Edit squares gated on `status == ACTIVE &&
  !sealedAt && !ended && !editMode`.
- **Chrome (D14)** — header pill ENDED (gold) / CLOSED (paper); **no
  "Read-only" label anywhere**; ended banner "Board ended on {date}. Still
  logging until you close it."; stat card LEFT / Ended / {date} · still
  logging (ended) vs ENDED / {date} / permanent record (closed).
- **Late-log sheets (D15, D16)** — tapping a closed board's square opens a
  sheet headed by the window label, task name and a Closed pill: normal →
  "Mark done on board" (or "Undo late log" when the green came from a late
  log); counting → the sealed-bounded window count with +1 / +2 / +5 /
  Custom… (web stages then "Log"; iOS writes per chip) and "Undo late log";
  compound → the parts list, "Mark done on board" enabled once the rule is
  met; achievement and hub-linked derived squares are not tappable. Closed
  counting cells show the sealed-bounded window count.
- **Mixed-version hazard (D18)** — accepted flag-day, as WC.

With slice 4 the Board Edit redesign train (slices 1–4: #510, #511, #512,
this PR) is complete.

## Edit consolidation (2026-09-27, owner request after device test)

Owner request: *"the 'edit squares' button should just be 'edit'. And all
board editing options should be available from that screen (the three dots
serve no real purpose and just waste space in the UI)."* **Supersedes the "…"
menu parts of slice 2 (title-row trigger, D1/D2) and slice 4 (D12's "menus",
D13's Edit gate).** The builder, its row table and every sheet / confirm are
unchanged — only where they are reached from. Plan:
`.superpowers/sdd/2026-09-27-edit-consolidation/plan.md` (D1–D12). One PR,
web + iOS together.

- **Title row (D1)**: one `Edit` button (visible label `Edit`, accessible
  name **`Edit board`**, pencil icon). The "…" trigger is deleted (web
  `BoardActionsMenu`, iOS `BoardActionsMenuButton`).
- **Edit gate (D2, D7)**: `showsEditButton(board)` = any non-draft board —
  active, ended, closed, completed, **archived** (else Delete / Core
  defaults… would have no entry point). Drafts never reach the play surface.
- **Squares gate (D3)**: `canEditSquares(board, now)` = `status == ACTIVE &&
  sealedAt == nil && !isBoardEnded` (slice 4's D13 rule, now a named pure
  helper `boardMenu.ts` ↔ `BoardMenuItems.swift`). Captured **once at Edit
  entry** (web `editSession.squaresEditable`, iOS `@State
  editSquaresEditable`) — a board that ends / seals mid-session keeps its
  squares section and the Save-time "Board closed" guard owns that race.
- **Squares hidden when not editable (D4)** — no read-only grid; one muted
  line (`squaresLockedReason`), verbatim:
  - ended or closed: "This board has ended, so its squares can't change."
  - archived: "This board is archived, so its squares can't change."
  - completed (still in window): "This board is complete, so its squares can't change."

  The top-left control reads **Done** (web `← Done`, a11y "Done editing"),
  and there is no save bar, Shuffle or squares hint.
- **Pill (D5)**: "Editing squares" → **"Editing"**.
- **BOARD section (D6)**: label `BOARD`, then one row per
  `buildBoardMenuItems` ↔ `BoardMenuItems.items` item (names kept — internal),
  same order / labels / icons / danger styling as the slice-2/4 matrix. iOS:
  `BoardOptionsSectionView` (`RisoProfileRow`s in a `.risoCard()`), inside
  `BoardEditPanel`'s scroll content. Web: `BoardOptionsSection` (the
  renamed `BoardTitleActions`, `RisoCard role="group" aria-label="Board
  options"`), rendered by `BoardEditColumn` in the board column under the
  grid at every width.
- **Save stays squares-only**: Board details keeps its own atomic
  `saveBoardDetails`.
- **Dirty squares draft × row (D8)** — `boardItemDraftPolicy` ↔
  `BoardMenuItems.draftPolicy(for:)`:

  | Rows | Policy | Behavior when the draft is dirty |
  | --- | --- | --- |
  | Board details… · Repeat this board… · Core defaults… | keep | Sheet opens over Edit; draft untouched (both squares commits are field-level; neither draft re-seeds on reload). Pinned by `boardEditWindowPreservation.test.ts` ↔ `test_boardDetailsSave_thenSquaresSave_bothPersist`. |
  | Archive · Delete | discardInConfirm | The existing confirm body gets " Your unsaved square changes will be discarded." appended. |
  | Close board · Reopen board | discardFirst | "Discard changes?" / "Your unsaved changes will be lost." / Keep editing · Discard first, then the row's own path. Only reachable via the D3 race (those rows exist only when squares aren't editable). |

- **After each action (D9)**:

  | Action | Result |
  | --- | --- |
  | Details / Repeat / Core defaults saved or cancelled | Stay in Edit ("Board saved" toast on save — iOS toast raised above the edit overlay, D10). |
  | Close / Reopen success | Exit Edit to the play surface — the CLOSED / ENDED pill flip is the feedback. |
  | Close / Reopen / Archive / Delete failure | Stay in Edit + a failure notice ("Close failed" … "— please try again."). iOS gained a real alert here; its old `bingoMessage` writes rendered nothing. |
  | Archive success | Exit Edit, then leave (ad-hoc → Boards list). |
  | Delete success | Exit Edit **and notify the pager `onEditModeChange(false)` before removal** — on a core board the surface unmounts when its window loses the board, so without the explicit call the pager's chip / paging would stay locked. Web also fires it from an unmount cleanup. |

- **iOS tab bar** stays visible (D10); the non-editable variant drops the
  76pt save-bar clearance.
- **File sizes (D11)**: extraction, not cap bumps — web `BoardEditColumn` +
  `BoardEditButton` out of `BoardPlaySurface.tsx`; iOS
  `BoardPlayView+BoardActions.swift` out of `BoardPlayView.swift`. Both
  allowlist entries lowered.
- **No schema / sync / rules / shared-package change (D12).**
- **Accepted divergences**: the Archive confirm body copy still differs
  between platforms (pre-existing, OQ8 — parity follow-up). Web's BOARD rows
  evaluate "ended" against an instant pinned at Edit entry (react-compiler
  purity), iOS against the render-time clock — so a board whose window ends
  *while* Edit is open offers Close board on iOS immediately and on web after
  re-entering Edit. A seal / status change from sync updates both live.
- **Tests**: pure-helper case tables mirrored line for line
  (`boardMenu.test.ts` ↔ `BoardMenuItemsTests`), `board-options.spec.ts`
  (renamed from `board-actions-menu.spec.ts`) + the touched e2e specs,
  `BoardEditOptionsSnapshotTests`, and `BoardEditOptionsUITests` (an active
  board's BOARD rows; a closed board's hidden squares → Reopen → exits Edit;
  DEBUG seed `-uiTestSeedEditBoardClosed`).
