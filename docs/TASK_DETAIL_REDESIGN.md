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
3. **Hero anchor** *(amended 2026-10-18)*: the soonest-ending active board
   (`isBoardActiveForList`, the Boards tab's own order — `compareBoardsForList`,
   board id as the final tie-break; `pickHeroAnchorBoard`) among the squares
   that ARE the task, in this order: **(1)** its own placement; **(2)** for a
   counter root, a linked row's placement (a log there writes the root);
   **(3)** for a Normal or Counting sub-task, the square of a compound it is
   a DIRECT child of — the hero is that child's control (counting: chips
   through the compound child write; normal: the toggle; a sub-compound has
   no single control there and falls through). **(4) No square in play:** a counting task
   gets a **board-less** control — its count is the counter's all-time total,
   chips log "now" through the counter writes the hub uses, with Undo; any
   other type shows no control. Same rule for route and sheet.
4. **One-gesture logging:** chips write immediately; Undo replaces
   confirmation. Retires `RisoCountingStepperSheet`'s stepper, the detail
   sheet's counting card, `CompoundChildRow`'s mini stepper and their web twins.
5. **Square contract:** tap = obvious action; hold = that action first, then
   the rest, then Details · Open in library.
6. **Counting children inside a compound are driven, never toggled:** their
   checklist box is a `+` that unfolds the chips inline. "Complete next
   sub-task" skips counting children; if only counting children remain it
   becomes "Log +‹default› · ‹child›". It toggles only Normal children: a
   nested compound or achievement child completes from its own state, so it is
   never picked and its checklist box is read-only status (2026-10-18).
7. **"Open in library" is board-agnostic:** identical content to the route.
8. **Closed (sealed) boards:** same square sheet, read-only, one "Late log…"
   action; the hold menu collapses write items to "Late log…". A write in
   flight disables controls at once — never hides them — and the count moves
   on the tap (an optimistic delta, rolled back if the write fails). The dimmed
   look (45% opacity, hard shadow collapsed) appears only when the write is
   still in flight after 250 ms (owner, 2026-10-18: the dim on every fast tap
   read as the board reloading).

**Library rows (owner, 2026-10-18):** every Tasks-tab row opens Task Detail —
a shared-counter family's root included (this reverses the 2026-09-22 rule
that sent it to Counter Detail). Counter Detail stays reachable from Task
Detail's Shared counter row, the Counters hub and Profile; the two pages stay
separate for now.

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
| **0 · Spec** | This doc + the binding decisions in `CLAUDE.md` (rides in PR 1's branch to save a TestFlight build). |
| **1 · Kernel** | Shared pure helpers + Swift twins + vectors: `tapLogChips` (`logAmounts.ts` ↔ `CounterLogAmount.tapChips`, `logAmountVectors.json`), `pickHeroAnchorBoard` / `nextCompoundSubtask` / `buildTaskActivity` (`taskDetail.ts` ↔ `TaskDetailKernel.swift`, `taskDetailVectors.json`). No screen changes. |
| **2 · Tap contract + square sheet** | Kit first (tap-to-log chip row, Undo strip, return pill on both; web `RisoToolbarPill` + undo pill promoted into `components/riso/`) — it lands with its first consumer because knip fails an unused web export. Then the square sheet (new files), Normal Undo toast, compound `+` children, Achievement tap, web busy flag, Counter Detail on `tapLogChips`. Deletes `RisoCountingStepperSheet` / `CountingStepperModel` / `detailSheet` content / `CompoundChildRow` stepper and web `DetailModal` counting branches + `useCountingLogModal`. |
| **3 · Hold menu** | Unified vocabulary + closed-board "Late log…" on both. |
| **4 · Task Detail shell** | Hero per type, segments (All / Links / Activity live; Boards shows today's placement list), ⋯ menu, sheet Done + return pill. |
| **5 · Boards tab + placement resolution** | Active list + Past & drafts; placements resolved through the slice-2c placement reach (`placementsReachedByTasks`) so linked counters and sub-tasks placed via a parent stop reading "On 0 boards"; every row read through the grid's resolvers (`taskPlacementRows`). "+ Place" omitted (owner, 2026-10-18). |

## PR 2 — detailed scope (rides in #634 with PR 1)

**Kit** (lands with its first consumer — knip fails an unused web export):

- `TapLogChipRow` — iOS `Views/Riso/TapLogChipRow.swift` ↔ web
  `components/riso/TapLogChipRow.tsx` (+ `.module.css`, barrel). Input: the
  `tapLogChips` output, `size: regular | compact` (44pt / 34pt), `disabled`,
  `onChip(chip)`. Presets and rest = gold fill, 2pt `inkStatic` keyline, 2pt
  hard shadow, Bricolage 800 15pt `inkStatic`; "Other…" = paper2, flex 1.1;
  a rest label of 4+ characters takes flex 1.3 at 13pt. Disabled = opacity
  0.45 and hard shadow 0, layout unchanged. Press = translate 2pt + shadow 0.
- `UndoStrip` — iOS `Views/Riso/UndoStrip.swift` ↔ web
  `components/riso/UndoStrip.tsx`: paper2 card, green check icon, one text
  line ("Logged +5 pages · Week 42"), Undo pill (iOS reuses `RisoUndoPill`;
  web promotes the undo pill out of `MemberRuleRow.module.css` into the kit).

**Square sheet** — iOS `Views/BoardsTab/SquareSheet/` (view files +
`BoardPlayView+SquareSheet.swift` presenter) ↔ web
`components/boardPlay/squareSheet/`. One `.sheet` / modal keyed by board-task
id; detents medium / large, grabber, paper, 2pt ink top keyline, 12pt radius.

- Header: type letter square (22pt) · title 18pt 800 (`placementTitle`) ·
  "Library ›" pill → the existing open-in-library path (iOS
  `taskDetailSheetTaskId` via the pending-drain; web `setOpenedTaskInLibrary`).
- **Counting:** count 52pt (duration 40pt) + "/ ‹goal› ‹unit› · ‹board›",
  status pill (IN PROGRESS gold / DONE green / none at 0), 12pt bar, "TAP TO
  LOG" eyebrow + "‹rest› to go · ‹board›" (omitted when the goal is met), the
  chip row from `tapLogChips(familyKind, windowGoal, windowedCount)`. A preset
  or rest chip logs immediately through the existing write
  (`handleCountingTap` / `handleSharedCounterIncrement` / web standalone
  `handleComplete({ currentCount })`) with `persistAsDefault = false`;
  "Other…" opens the kind's entry (`GoalEntryView` / `GoalEntry`) and logs
  with `persistAsDefault = true`. After a log the `UndoStrip` shows under the
  chips; Undo reverses that one log (shared: `undoLastCounterLog`; standalone:
  restore the previous windowed count). "− Remove…" opens the same entry and
  decrements. Haptic `.medium` on iOS.
- **Compound:** done-count 52pt + "of ‹n› sub-tasks · ‹board›", status pill,
  segmented bar (one segment per child, 4pt gaps), checklist rows: 28pt box
  (toggle via `handleCompoundChildToggle`; a counting child's box is `+`) ·
  type letter square · name 14pt 700 (0.75 opacity when done) · meta (counting:
  "12 / 20" in blue) · chevron → open that child in library. Tapping a counting
  child's `+` unfolds an 8pt bar + compact chip row + inline `UndoStrip`
  (writes through `handleCompoundChildIncrement` with the chip amount — extend
  it from ±1 / root default to an explicit amount; standalone Undo restores).
  One child open at a time. Retires `CompoundChildRow`'s stepper.
- **Achievement:** watched-board card (paper2, 1.5pt ink keyline): "WATCHED
  BOARD" eyebrow + timeframe badge + "‹n› days left"; board name 22pt 800;
  progress ("0 / 1 bingo", "Greenlog", or "‹met› / ‹required›" for a template
  watcher); gold `Open ‹board›` button → dismiss, then the existing board
  navigation (iOS `MainTabView.pushBoard`; web `coreWindowRouteForBoard`
  routing). **The closest-line row moves to PR 4** (it needs the watched
  board's per-cell completion, which neither platform reads today).
- **Normal** never opens the sheet from a tap; "View Details" (until PR 3
  rewrites the menu) opens it with a Mark done / Done button.
- **Closed board** (`isBoardPlayLocked`): the sheet opens read-only for every
  type — CLOSED badge in the header, the frozen count, chips / checkboxes /
  Remove replaced by a lock row "Closed ‹sealedAt date›" + a small neutral
  `Late log…` button routed to the existing late-log sheet when
  `isLateLogRoutable` (absent otherwise).
- **Busy:** iOS `isProcessing`; web gains `isWriting` state in `useBoardPlay`
  around every write and undo (replaces the `childStepInFlight` ref). Busy
  disables chips / checkboxes / buttons per the kit rule; nothing hides.

**Tap contract:** Normal → toggle + Undo toast (the existing toast slot and
component, extended with an optional second line): "‹title› · done" /
"‹title› · not done", second line "‹board›" plus " · +1 ‹counter›" when the
write credited a counter; Undo re-toggles (`uncomplete` kind). Counting /
Compound / Achievement → square sheet. Closed board → square sheet read-only
(replaces the direct late-log tap). The existing credited-toast for counting
logs is replaced by the inline `UndoStrip` inside the sheet.

**Counter Detail:** the log card's chip row becomes `TapLogChipRow` with
`tapLogChips(kind)` (no goal → no rest chip); a chip logs immediately (still
persisting the amount as the default — existing Counter Detail rule); "−
Remove…" opens the entry and decrements; the existing toast stays.

**Deleted:** iOS `RisoCountingStepperSheet`, `CountingStepperModel`,
`BoardPlayView+CountingStepper.swift`, the `detailSheet` + `*DetailContent`
bodies, `CompoundChildRow`'s stepper (and their tests / snapshot baselines);
web `DetailModal`'s counting / compound branches (and `DetailModal` itself if
nothing else uses it), `useCountingLogModal` / `countingLogModel` if unused.
Every allowlisted file this PR shrinks gets its cap lowered to the new count.

**Tests:** kernel already pinned. iOS: `SquareSheetSnapshotTests` (counting
mid / done / duration, compound with a counting child open, achievement,
closed, busy; light + dark), `TapLogChipRow` + `UndoStrip` in
`RisoKitSnapshotTests`, unit tests for the sheet's view-model glue. Web:
Vitest for the sheet's pure glue + kit; Playwright `square-sheet.spec.ts`
(tap counting → chip → count moves → Undo restores; Normal tap → toast →
Undo; compound `+` child; closed board → Late log…) and existing specs that
drove `DetailModal` updated.

**PR 2 resolutions (implementation, 2026-10-17):** type letters are `N · # · C · A`
on both platforms (web converged from `C / K` to the iOS kit); every write made
inside the sheet suppresses the cross-board credited toast (the strip replaces
it); the sheet's Normal Mark done closes the sheet and raises the tap's Undo
toast; compound child toggles get an inline strip with an explicit revert; a
strip is cleared by any later write and when the sheet closes or switches
square, and shows only for a write that committed, with the amount actually
applied; Remove is available whenever the windowed count is above 0; a
template watcher has no Open button; an absent achievement trigger means
Greenlog; un-completing a completion held by a sealed window is disabled.

## PR 3 — detailed scope (hold menu)

One menu builder per platform — iOS `Views/BoardsTab/SquareMenu/SquareHoldMenu.swift`
(a `contextMenu` body + header preview) ↔ web
`components/boardPlay/squareMenu/` (replacing `FloatingContextMenu`'s
per-type `amountActions` / `sharedAmountActions`), fed by one pure item list
per platform so a unit test pins the vocabulary:

| Type | Items (first gold) |
| --- | --- |
| Normal | Mark done / Mark not done · ─ · Details · Open in library |
| Counting | Log +‹quickLogAmount› · Log +‹next preset above it› (omitted when none) · Log other amount… · ─ · Remove ‹unit›… · ─ · Details · Open in library |
| Compound | ‹nextCompoundSubtask›: "Complete next sub-task" (meta: the child's name) or "Log +‹child quick amount› · ‹child›" · All sub-tasks… (meta "‹done› / ‹n›") · ─ · Open in library |
| Achievement | Open ‹watched board› · ─ · Details · Open in library |
| Closed board | every write item → one "Late log…" (lock icon, gold; only when `isLateLogRoutable`); Details · Open in library unchanged |

"Details" / "All sub-tasks…" / "Log other amount…" / "Remove…" open the square
sheet (the last two straight into its entry). Header row: type square ·
title · meta ("12 / 20", "2 / 3", "Not done", "Watching"). Items single-line
with ellipsis. Web shows the menu on closed boards (today it shows none) and
drops "↺ Reset" (E7). Menu writes give the same Undo the tap gives (Normal →
toast; counting / compound → the toast with the log text, since no sheet is
open). Busy disables write items.

## PR 4 — detailed scope (Task Detail shell)

- **One data seam per platform**, shared by the route and the sheet: iOS
  `Views/TasksTab/ViewModels/TaskDetailViewModel.swift` (DB-injected,
  replacing the duplicated `@State` + `reload()` in `TaskDetailView` and
  `TaskDetailSheetView`) ↔ web `hooks/useTaskDetail.ts` (the
  `useLiveQuery` block lifted out of `TaskDetailContent`). It computes the
  hero anchor (`pickHeroAnchorBoard` over today's placements until PR 5), the
  anchor placement's windowed state through the kernel, and the Activity
  feed (`buildTaskActivity`, missed boards = ended placements whose window the
  kernel scores not done).
- **Hero writes go through the anchor placement** with the same DB ops board
  play uses (iOS `completeTaskOrchestrated` / shared-counter increment /
  `undoLastCounterLog`; web `handleTaskCompletion` / `incrementSharedCounter`),
  so a log from Task Detail is a log on that board (it is active, so it stamps
  `now` — E6). **No anchor → no control**: the hero shows the kicker, title,
  description and Edit; the Boards card says "Not on a board".
- **Hero per type** as surface A, rendered by new view files (iOS
  `Views/TasksTab/Components/TaskDetailHero*.swift`; web
  `pages/tasks/taskDetailHero/`), reusing PR 2's `TapLogChipRow`,
  `UndoStrip` and the compound checklist row. Achievement adds the
  closest-line row: the watched board's per-cell completion read through the
  kernel (one new read per platform: placements + events for that board).
- **Segments** (`RisoSegmented .pill`): All (overview cards with "›" jumps) ·
  Boards · N (today's placement rows: ring · name + CORE badge · "‹window› ·
  ends ‹day› · ‹n› days left" · value · chevron) · Links (shared counter ·
  subtask of · part of repeating board; compound sub-tasks; achievement
  watches) · Activity (feed + footer "Completed ‹n›× all-time · updated
  ‹relative›" — amended 2026-10-18, #384: a Simple task only, since only its
  completions are recorded occurrences; every other type shows "Updated
  ‹relative›"). Selected segment survives content swaps in the sheet.
- **⋯ menu:** Place on a board… (opens the existing placement flow from Task
  Detail if one exists, else the board picker used by the Tasks tab — if none
  exists on a platform the item is omitted and noted) · Open counter settings
  (counting) · ─ · Delete task… (existing confirm). The bottom Edit / Delete
  row is removed; Edit moves into the hero.
- **Sheet:** grabber, Done pill grouped with ⋯, no back chevron; the return
  pill (kit: iOS `Views/Riso/RisoReturnPill.swift` ↔ web
  `components/riso/RisoReturnPill.tsx`, plus web `RisoToolbarPill`) takes the
  chevron slot after an in-sheet swap and returns to the previous task.
- Retires `RisoTaskDetailContentView` / `LinkedCounterCaptionView` usage on
  the page and web `TaskDetailContent`'s section stack (keep any helper still
  used elsewhere).

**PR 4 resolutions (implementation, 2026-10-17):** "Place on a board…" is
omitted on both platforms (no placement flow is reachable from Task Detail
today); the hero reuses board play's read model + writes for the anchor board
(no side effects on mount — verified both platforms); Normal pill reads "NOT
DONE THIS WEEK / TODAY / THIS MONTH / THIS YEAR"; the All overview is Boards ·
Subtask of · Activity; Activity includes the shared-counter root's events for a
linked task; a board is "missed" only once its window has ended (goal > 0 for
counting); iOS swipe-back is kept on the custom-chrome routes by a scoped
`InteractivePopEnabler`. **Carried to PR 5:** achievement values and nested
sub-compound evaluation on non-anchor board rows.

**PR 5 resolutions (implementation, 2026-10-18):** a task's boards are its
placement REACH — its own placements, a counter root's linked rows', and every
containing compound's — scored per board by the shared `taskPlacementRows`
(`taskPlacementRows.ts` ↔ `TaskPlacementRows.swift`,
`taskPlacementRowsVectors.json`): a direct placement through
`resolveSquareState` + its parameters, a member reached through a compound at
the parent placement's `childTargets` (direct children only; deeper levels keep
their own goal), a compound counting its sub-tasks with the full nested link
map (a nested sub-compound evaluates its own children), an achievement read
from its cell in `computeBoardGrid`, a closed board's own cell from
`sealedCompletedCells` and everything else bounded at `sealedAt`. One row per
board: the task's own placement, then a linked row's, then the first through a
compound (ties by member id, then placement id — order-independent so the twins
agree). The data read is one per platform (web `loadTaskDetailPlacements` ↔
`AppDatabase.fetchTaskDetailPlacements`). **The hero still anchors on the
task's OWN placements only** — its control is that square's sheet, so a
sub-task that lives only inside a compound gets Boards rows but no hero count.
"Placed on" Activity rows stay the task's own placements. **"+ Place" is
omitted** (owner, 2026-10-18), as "Place on a board…" was in PR 4 — placing
stays a board-side action.

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
