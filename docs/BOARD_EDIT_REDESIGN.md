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
  place. Existing CHOSEN boards migrate to a locked center task. Lock chip is
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
| 1 | Per-square locks (`BoardTask.isLocked`, synced) honored by rearrange; Lock/Unlock in the existing edit tap menu; one cell renderer with lock + dirty chips across play / edit / arrange / wizard preview on both platforms; web Playground demo + iOS snapshots | in progress |
| 2 | Title-row "…" menu; Board details sheet; core-board gating (no name / timeframe / repeats / archive on `isCore`); Archive / Delete / Repeat move out of the panel | planned |
| 3 | Squares editor rebuild: single mode, tap-to-add on empties, hold-to-lift, Shuffle in the save bar, the quick-add picker, CHOSEN retired → locked center, play-mode "+" retired | planned |
| 4 | Close / Reopen / direct late log on closed boards / next-window auto-close | planned |

Independent of the train (bugfix PRs any time): iOS Board Edit rewrites an
achievement task's type (P0); start-date edits on ongoing boards are counted
but never saved (both); zero-placement boards show "Loading…" forever (web);
"Board saved" reported for a board sealed mid-session (both); stale
`repeat-board.spec.ts` describes.

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
