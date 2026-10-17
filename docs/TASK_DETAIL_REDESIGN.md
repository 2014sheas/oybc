# Task Detail redesign + board square interactions

Status: **SPEC (2026-10-17)**. Owner-decided design from the handoff
`design_handoff_task_detail/` (gitignored; open
`Task Detail Redesign (iOS).dc.html` first — frame ids `2a`…`7k` below refer to
it). Engineering decisions recorded here were ruled by the owner on 2026-10-17.

## The model

1. **Task Detail is one page, two presentations.** The pushed route (Tasks tab)
   and the "Open in library" sheet (from a board square) render the same
   content. A type-coloured **hero** carries the task's one live control; a
   segmented pill (All · Boards · N · Links · Activity) switches between an
   overview and deep sections.
2. **Every square behaves the same way.** Tap = the type's one obvious action.
   Hold = that same action first (highlighted), then the type's other quick
   actions, then Details · Open in library.
3. **One gesture logs.** Tap-to-log chips write immediately; an Undo strip or
   toast replaces confirmation. No pick-then-press anywhere.

## Binding decisions (from the handoff, mirrored into `CLAUDE.md`)

1. No explanatory captions (existing owner rule). Labels, data, status pills.
2. **Completion is windowed.** Any progress shown names its board
   ("12 / 20 pages · Week 42"). Library list rows carry no progress.
3. **Hero anchor:** the soonest-ending active board the task is placed on —
   placements whose board passes `isBoardActiveForList`, in the Boards tab's
   own order (`compareBoardsForList`: soonest `endDate`, open-ended last, then
   most recent activity), board id as the final tie-break (`pickHeroAnchorBoard`). No anchor → the hero shows no
   count and the Boards card shows "Not on a board". Same rule for route and
   sheet.
4. **One-gesture logging:** chips write immediately; Undo replaces
   confirmation. Retires `RisoCountingStepperSheet`'s stepper, the detail
   sheet's counting card, `CompoundChildRow`'s mini stepper and their web twins.
5. **Square contract:** tap = obvious action; hold = that action first, then
   the rest, then Details · Open in library.
6. **Counting children inside a compound are driven, never toggled:** their
   checklist box is a `+` that unfolds the chips inline. "Complete next
   sub-task" skips counting children; if only counting children remain it
   becomes "Log +‹default› · ‹child›".
7. **"Open in library" is board-agnostic:** identical content to the route.
8. **Closed (sealed) boards:** same square sheet, read-only, one "Late log…"
   action; the hold menu collapses write items to "Late log…". A write in
   flight disables controls (45% opacity, hard shadow collapsed) — never hides
   them.

## Engineering decisions (owner, 2026-10-17)

| # | Question | Ruling |
| --- | --- | --- |
| E1 | Platform cadence (handoff said iOS first) | **Every PR lands web + iOS** (rule 6). |
| E2 | Sequencing vs. `TASK_WINDOW_REWORK.md` | **Interleave.** Presentation slices start now; the Boards tab + placement resolution (slice 5 below) waits for rework slice 2c and is built on placements, never on window-stamped derived rows. |
| E3 | Chip amounts | **The existing defaults**: the shared `FIXED` presets the hub and Counter Detail already use — discrete `1 · 10 · 25`, continuous `0.5 · 1 · 5`, duration `15m · 30m · 1h` (`fixedLogChipAmounts`) — plus `+rest ✓` and "Other…". The handoff's `1·5·10` / `1·3.1·5` numbers are **not** adopted. One chip set on every one-gesture surface (square sheet, detail hero, compound child, Counter Detail). Late log keeps `lateLogChipAmounts`. `boardSheetChips` / `goalChipAmounts` retire with the stepper sheet. |
| E4 | Undo coverage | **Every write gets Undo** — Normal toggles and standalone counting logs too, not only writes that credit other boards. Reuses the existing undo kinds (`counterLog`, `uncomplete`, `restoreCount`). One toast at a time, latest wins, each Undo scoped to its square. |
| E5 | Activity tab data | **Derived, no new persisted log** (`buildTaskActivity`): logs / removals / completions from `task_events` (non-deleted); "Placed on ‹board›" from each live placement's `createdAt`; "Missed · ‹board›" = an ended board whose window the task did not complete (the caller computes the set with the kernel); "Created" from `createdAt`. Newest first. **No "edited" row**: `Task.updatedAt` also moves when a log recomputes the lifetime caches, so it is not an edit signal, and a new field is out of scope. |
| E6 | Logging from Task Detail | Stamps `now` (the existing library / Task Detail rule). The hero anchor is active, so the log counts there. |
| E7 | Web "↺ Reset" menu item | **Dropped** (not in the handoff vocabulary; iOS never had it). |
| E8 | "Remove…" | Opens an amount entry (the kind's entry: discrete stepper, decimal, h:m). Chips only add. |

### Tap-to-log chips (E3 detail)

`tapLogChips(kind, goal, windowedCount)` — new shared helper beside
`hubChips` in `logAmounts.ts` ↔ `CounterLogAmount.swift`, pinned by
`logAmountVectors.json`:

- Presets = `fixedLogChipAmounts(kind)`.
- Append the **rest chip** = `goal − windowedCount` when `> 0` and not equal to
  a preset; label `+‹formatCount(rest)› ✓` (compact for duration: `+5h30 ✓`).
  A rest label of 4+ characters takes flex 1.3 at 13pt.
- End with "Other…" (custom entry; reuse `GoalEntryView` / `GoalEntry` —
  h : m wheel for duration, decimal for continuous).
- `persistAsDefault` only for an explicit "Other…" amount (existing rule).
- The hold menu's "Log +‹default›" uses the existing `quickLogAmount`
  (remembered default, else 1 / first preset) — unchanged.
- Counter Detail switches from `hubChips` to `tapLogChips` with no goal (no
  rest chip). It keeps persisting every log as the default (existing rule).

## Surfaces

Visual spec (sizes, colours, copy) is the handoff README + frames; this
section names the code.

### A · Task detail (route) — frames 2a–2d, 4a–4c

Replaces iOS `RisoTaskDetailContentView` (+ `TaskDetailView` shell) and web
`pages/tasks/TaskDetailContent.tsx` (+ `TaskDetailPage`).

- **Hero** per type: Counting (blue: count / goal · anchor, status pill, bar,
  chips, Undo strip, "− Remove…", Edit, Shared counter row → Counter Detail);
  Normal (paper2: status pill, Mark done ↔ Done, Edit, Counts toward row);
  Compound (teal: done-count, segmented bar, checklist with `+` for counting
  children, Edit); Achievement (purple: WATCHING, watched-board card with
  closest line, Open ‹board›, Edit; no manual completion).
- **Segments:** All (overview: On boards now · Subtask of · Activity, each
  with a "›" jump into its tab) · Boards · N · Links · Activity. Switching keeps
  scroll position.
- **⋯ menu:** Place on a board… · Open counter settings (counting) · Delete
  task… (red). Delete leaves the page bottom.
- Data: today's fetches (`fetchBoardTasksForTask`, `fetchCompoundParents`,
  `fetchCompoundChildrenTasks`, `fetchTemplatesReferencingTask`) until slice 5.
  Counting count = the kernel's windowed count for the anchor board.

### B · "Open in library" sheet — frames 5a–5e

Same content as A. Differences: grabber, no back chevron, Done pill grouped
right with ⋯, top padding 22pt. In-sheet navigation replaces content (existing
`onOpenTask` / `innerTaskId`); once swapped, a **return pill** (type letter +
previous name) takes the chevron slot. Board-row tap dismisses then navigates;
the board you came from just dismisses. Counter Detail pushes inside the sheet
(iOS) / closes-then-navigates (web, existing). Delete closes the sheet.

### C · Square tap — frames 6a, 6b, 6d, 6f, 6h

- **Normal:** toggle immediately + Undo toast ("Finish Dune · done" /
  "Week 42 · +1 Books" when it credits a counter).
- **Counting / Compound / Achievement:** open the **square sheet** — one
  surface replacing iOS `RisoCountingStepperSheet` + `detailSheet`
  (`*DetailContent`) and web `DetailModal`. Header: type square · title ·
  "Library ›" pill. Body = the hero control rendered on paper, anchored to
  **this** board. Detents medium / large.
- Compound counting child: `+` box unfolds an 8pt bar + chips + inline Undo;
  the parent's count updates with it.
- Achievement: watched-board card + Open board (today a dead tap).

### D · Square hold — frames 6c, 6e, 6g, 7b

Header row (type square · title · meta), first item gold.

| Type | Items |
| --- | --- |
| Normal | Mark done · ─ · Details · Open in library |
| Counting | Log +‹default› · Log +‹next preset› · Log other amount… · ─ · Remove ‹unit›… · ─ · Details · Open in library |
| Compound | Complete next sub-task · ‹first open toggle child› · All sub-tasks… · ─ · Open in library |
| Achievement | Open ‹watched board› · ─ · Details · Open in library |
| Any, closed board | write items → one "Late log…" (lock icon, gold); rest unchanged |

"Details" opens the square sheet. Web gains a menu on closed boards (today
`onContextMenu` returns early there).

### E · Edge states — frames 7a–7k

- Closed board sheet (7a): header shows the board + CLOSED badge, frozen
  window count, a lock row with `Late log…` (routes to the existing
  `LateLogSheetView` / `LateLogSheet`), no Remove. Routable set unchanged
  (`isLateLogRoutable`).
- Write in flight (7c): iOS reads `isProcessing`; **web gains a busy flag** in
  `useBoardPlay` (set around `handleComplete`, shared increment / decrement,
  compound child writes, undo), replacing the `childStepInFlight` ref.
- Counter kinds (7j, 7k): duration renders h:m and the hero count shrinks to
  40pt; continuous takes decimal entry.
- Dark mode (7d–7i): existing tokens; gold stays gold; `inkStatic` on gold and
  on-colour on blue / teal / purple never flip.

## Delivery — PR train, each PR lands web + iOS

| PR | Scope |
| --- | --- |
| **0 · Spec** | This doc + the binding decisions in `CLAUDE.md`. |
| **1 · Kernel** | This doc + `CLAUDE.md`, and the shared pure helpers + Swift twins + vectors: `tapLogChips` (`logAmounts.ts` ↔ `CounterLogAmount.tapChips`, `logAmountVectors.json`), `pickHeroAnchorBoard` / `nextCompoundSubtask` / `buildTaskActivity` (`taskDetail.ts` ↔ `TaskDetailKernel.swift`, `taskDetailVectors.json`). No screen changes. |
| **2 · Tap contract + square sheet** | Kit first (tap-to-log chip row, Undo strip, return pill on both; web `RisoToolbarPill` + undo pill promoted into `components/riso/`) — it lands with its first consumer because knip fails an unused web export. Then the square sheet (new files), Normal Undo toast, compound `+` children, Achievement tap, web busy flag, Counter Detail on `tapLogChips`. Deletes `RisoCountingStepperSheet` / `CountingStepperModel` / `detailSheet` content / `CompoundChildRow` stepper and web `DetailModal` counting branches + `useCountingLogModal`. |
| **3 · Hold menu** | Unified vocabulary + closed-board "Late log…" on both. |
| **4 · Task Detail shell** | Hero per type, segments (All / Links / Activity live; Boards shows today's placement list), ⋯ menu, sheet Done + return pill. |
| **5 · Boards tab + placement resolution** | **Gated on rework 2c.** Active list + Past & drafts, + Place; placements resolved through `placementsReachedByRoot` and compound parents so linked counters and sub-tasks placed via a parent stop reading "On 0 boards". |

### Constraints every PR honours

- **File-size caps:** `BoardPlayView.swift` (0 lines headroom),
  `BoardPlayViewModel.swift` (1), `BoardPlaySurface.tsx` (3). New surfaces go
  in new files (`BoardPlayView+SquareSheet.swift`, `SquareSheet.tsx`, …) and
  each PR moves out at least what it adds. Never bump a cap.
- Snapshots on iPhone 17 / iOS 26.3.1, every recorded PNG read as a design
  review; overlays and sheets get an explicit safe-area + tab-bar check.
- Playwright e2e for each web surface (tap → sheet → chip → Undo; hold menu;
  closed board).
- Self-review against the no-captions rule.
- Merge after #623 (second caption purge), which touches the same surfaces.

## Out of scope

Library list rows (unchanged — no progress); the Tasks-tab layout; Counter
Detail beyond its chip row; web notifications; any new persisted field.
