# Bingo and Greenlog moments

Full-screen takeovers that replay a board when a write completes a line (Bingo) or the whole board (Greenlog). They replace the old blue corner toast and the all-red greenlog poster. Both platforms ship together; the design source is the gitignored `design_handoff_bingo_greenlog/`.

## Replay kernel (shared logic, written once)

`packages/shared/src/algorithms/boardMoment.ts` (Swift twin `apps/ios/OYBC/Helpers/BoardMoment.swift`), pinned by `packages/shared/tests/fixtures/boardMomentVectors.json` (copied byte-identically to `apps/ios/OYBCTests/Fixtures/`; Jest `boardMoment.test.ts` and iOS `BoardMomentVectorTests` consume the same file).

- `computeBoardMomentReplay(board, boardTasks, childrenByCompound, taskById, eventsByTaskId, allBoards = [])` returns `{ order, freeIdx, lineClosureBeat, completedTasks, totalTasks, size }`.
  - Membership and end state come from `computeBoardGrid` (live) or `board.sealedCompletedCells` / `board.completedLineIds` (sealed), so the replay always ends on what the play grid shows. `allBoards` lets achievement cells resolve.
  - A completed cell's instant is `resolveContributionState(...).completedAt` over the board window (events bounded at `sealedAt` on a sealed board), used ONLY when the state is complete and names a `completingEventId`: a Simple cell's completion event, a Counting cell's goal-crossing increment (a window-stamped derived counter crosses inside its own window, a hub-linked one inside the host window), a Compound's satisfying child event. Anything else - a latched achievement, an empty all-of compound, a sealed cell with no events - has a null instant and sorts after every dated cell, ties by index.
  - `order` excludes the FREE centre; `completedTasks` / `totalTasks` are the rail's numbers verbatim (the kernel counts a FREE centre in `completedTasks`).
- Beats: beat 0 is the empty board; `order[i]` lands at beat `i + 1`; a line closes one beat after its last non-FREE square lands (`lineClosureBeat`); a greenlog's wave reaches cell (r, c) at beat `order.length + 1 + r + c` and lines never flip during its landing pass.
- `momentCellVisual(idx, beat, replay, kind)` returns `{ landed, green, popToken }` for one cell; `momentCounterAt(beat, replay)` is the squares counter (`completedTasks - order.length + landed`, never negative); `momentFinalBeat(replay, kind)` is the clock's last beat.
- Cadence: 175 ms per beat for a bingo, 120 ms for a greenlog. One clock; every cell's frame is derived from the beat, so a re-render never restarts a pop.
- Supporting helpers: `totalLineCount(size)` (`2 * size + 2`, bingo-core / `BingoDetection.totalLineCount`), `streakUnitLabel(timeframe)` ("DAY" / "WEEK" / "MONTH" / "YEAR", `Streaks.swift`).

## Triggers

A bingo moment fires once per write that completes at least one new line (two lines at once is one moment); a greenlog wins over a bingo. The flash payload is typed: web `FlashOutcome { text, kind: 'bingo' | 'greenlog' | 'message', newLineIds }` (`components/boardPlayFlash.ts`), iOS `BoardPlayFlashEvent.moment: MomentTrigger?`. Reactivated / lost-bingo / error flashes stay transient messages. The moment opens after the write commits plus a 0.52 s delay (the cell pop finishes first, both kinds); a greenlog arriving while a bingo is pending replaces it on both platforms, a bingo never replaces anything, and nothing interrupts an open moment. The greenlog's exit is a plain text "Back to board" under "Start a new board". Page-level key / wheel handlers (the core-board pager) bail while any `aria-modal` dialog is open. Both platforms then gate on readiness: after the 0.52 s minimum they wait up to 1.5 s for the board to show the outcome (web `isMomentReady`, iOS `MomentGate`), else open anyway. The replay and end-state cells are snapshotted when the moment opens (web `nextMomentSnapshot`), so a sync landing mid-replay never changes the frames.

## Surfaces

Layout, type, spacing and colours follow the handoff (sections 5a, 5b, 5e, 5f): blue field for Bingo with the kicker "LINE COMPLETE · n OF total", green field plus confetti for Greenlog with "BOARD COMPLETE" and, only on a core recurring timeframe with a streak above 1, the gold "{UNIT} STREAK" chip. The fields are fixed colours in both themes (bingo `#2c44c9`, greenlog `#1f9b6b`). The board frame is static cream and the board (frame and cells) renders in the light palette; the headline and counter are static on-colour; only the buttons and the streak chip adapt. A cell in a completed line is `lineGreen` (green fill, done chrome, no gold ring; FREE keeps its gold star and gains the done shadow); the play grid keeps its gold ring. Reduced motion skips the replay and shows the end state. Dismissal is Back to board / Escape (no tap-to-close); the share sheet opens over the moment (see Share).

| Web | iOS |
| --- | --- |
| `components/play/RisoMomentOverlay.tsx`, `useMomentReplay.ts`, `Moment.module.css` | `Views/BoardsTab/Components/RisoMomentOverlay.swift`, `MomentReplayClock.swift` |
| `components/play/useBoardMoment.tsx`, `boardMomentUi.ts` (open, ready check, snapshot, cell models) | `Views/BoardsTab/BoardPlayView+Moment.swift`, `Helpers/MomentGate.swift`, `ViewModels/BoardPlayViewModel+Moment.swift` |
| `components/board/RisoBoardCell.tsx` (`lineGreen`, `pop`), `RisoBoardGrid.tsx` (`frame="moment"`) | `RisoBoardPlayCell.swift` (`isLineGreen`, external pop token) |
| `hooks/useBoardPlay.ts` + `boardPlayFlash.ts` | `BoardPlayViewModel` flash builders |
| `components/share/ShareBoardSheet.tsx`, `SharePoster.tsx`, `sharePosterModel.ts` | `Views/BoardsTab/Components/ShareBoardSheet.swift` |

`RisoBingoToast` and `RisoGreenlog` (web) / their iOS twins are retired.

## Share

The moment's two share buttons open the share sheet in a kind: "Share this bingo" -> `kind: 'bingo'` ("Share bingo", blue poster), "Share my board" -> `kind: 'greenlog'` ("Share greenlog", green poster). It is the only entry point to the sheet (the rail and Edit do not open it); it opens over the moment (web z 300 / iOS `.sheet`) and Done returns to the moment.

- **End-state cells, shared.** `momentPosterCells(replay, cells, kind)` (Swift `BoardMoment.posterCells`, vectors in the `posterCells` family of `boardMomentVectors.json`) takes `PosterCellInput { idx, label, type, isFree }` per grid cell and returns `PosterCell` with `state` `undone | done | green`, each read from `momentCellVisual` at `momentFinalBeat` (green wins over landed; the FREE centre is `undone` unless a closed line or the greenlog wave reaches it). The poster never re-derives completion; it draws what the moment held.
- **Poster** (`components/share/SharePoster.tsx` + `.module.css`, iOS `ShareBoardSheet.swift`): static hex only, story 9:16 at 236 x 420, exported at 2x (472 x 840). Blue (bingo) / green (greenlog) card, gold kind badge, OYBC wordmark, board name (2 lines max), a cream grid inset with `boardSize` columns (never fixed at 5), end-state cells (undone cream; done normal red, counting blue, compound teal; green; FREE ink with a gold star), the SQUARES stat card (`completedTasks/totalTasks`, the rail's numbers) and, on a recurring timeframe with a streak above 1, a STREAK card (the BINGO streak for a bingo poster, the GREENLOG streak for a greenlog one; `computeStreak(tf, trigger, ...)`), tagline "What's on your bingo card". One card spans the row. Stats are always on.
- **Controls:** one "Show task names" switch (default on; labels at `clamp(6.5, 0.165 x cell, 14)` px, 2-line clamp; FREE keeps its star), then Share and Save image. Share text: bingo "Bingo on {board}! {n} of {lines} lines." (`n` = lines completed, `lines` = `totalLineCount(size)`), greenlog "I crushed every square. GREENLOG on On Your Bingo Card!". Share title "{board} - BINGO" / "{board} - GREENLOG"; filenames `{slug}-bingo.png` / `{slug}-greenlog.png`. Pure model: web `components/share/sharePosterModel.ts`.
- **Divergence:** iOS keeps its "Copy link" row and four share targets; web has neither (no shareable URL; the Web Share API's sheet picks the destination).
- Retired: `includeStats`, the three-stat trio (BINGOS stat), the 280 px card, the hard-coded 5x5 grid, "OWN YOUR BINGO CARD".

## Follow-ups

- `apps/web/src/components/riso/RisoMiniBoardArt.module.css:26` references the global `risoCellPop` keyframe by name. A CSS module localizes animation names, so the reference points at a keyframe that does not exist and the animation never plays (the moment's own copies in `RisoBoard.module.css` / `Moment.module.css` avoid this). Not fixed here; define a local keyframe there or move the keyframes into a global stylesheet.
