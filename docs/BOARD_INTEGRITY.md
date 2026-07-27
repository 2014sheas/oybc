# Board Integrity — the 2026-07-24 four-auditor audit + the five-PR program

> **Status: ALL FIVE PRs SHIPPED.** PR-1 (#358), PR-2 (#359), PR-3 (#360),
> PR-4 (#361), and PR-5 (#362) are all merged — the board-integrity program
> is closed. See [§The five-PR program](#the-five-pr-program) for what each
> shipped and [§Residual accepted risks](#residual-accepted-risks) for what
> the program deliberately left open.

## Why this doc exists

On 2026-07-24 four independent audit passes over the board/placement pipeline
(sync, derivation, render, and write paths) converged on the same conclusion:
`BoardTask` — the placement junction row linking a `Board` to a `Task` at a
grid cell — was architecturally under-hardened relative to every other synced
entity in the app. Three of the four traces independently rediscovered the
same root defect (below) from different starting points (a user bug report, a
sync-layer code read, and a derivation-kernel audit), which is what elevated
it from "one more bug" to "fix the class, not the instance" and produced this
five-PR program instead of a single patch.

This doc is the concise cross-PR index: the findings matrix, the PR
breakdown, and the "one resolver" direction PR-3 completes. Each PR's own
commit history and code comments carry the implementation detail; this page
is the map, not the territory.

## The root defect (PR-1, this PR)

**`BoardTask` was the only synced collection without an `isDeleted` field.**
Every other collection (`boards`, `tasks`, `compoundChildren`, `taskEvents`,
`pools`, …) represents deletion as a soft-delete tombstone — `isDeleted: true`
+ `deletedAt` + a bumped `version` — because the sync layer has no other way
to represent "this row is gone": it never calls Firestore's `deleteDoc`, only
`setDoc`. `BoardTask` alone did a physical local delete and then pushed a
sync-queue `DELETE` entry carrying the **stale pre-delete snapshot** — same
`version`, same `updatedAt` as what the peer/remote already had.

At push time, `resolveConflict(payload, remote)` (`packages/shared/src/algorithms/lwwResolve.ts`)
sees an **exact version tie** on an already-synced row. Per
`docs/SYNC_STRATEGY.md` rule 3 ("exact tie → remote wins, server authority"),
remote wins — so the very next safety-net pull cycle `table.put`s the
still-live remote row back into local Dexie, silently undoing the user's
delete within roughly one sync interval (~500ms typical). A user removing a
placement would watch it reappear moments later with no error, no conflict
banner, nothing to explain it.

Secondary gap closed by the same PR: pulling a `boardTasks` row (live or
tombstone) triggered **no board re-derivation** on the receiving device. A
remote rearrange left the receiving device's `completedLineIds` (a
*positional* bingo cache) stale until some unrelated cascade happened to
touch the board; a remote tombstone left the removed cell counted toward
`completedTasks` the same way.

**The fix**: `BoardTask` gained `isDeleted`/`deletedAt` (mirroring
`CompoundChild`'s tombstone shape, forward-compat defaulted like `Board.isCore`
so pre-existing remote docs still decode). Every placement "delete" site
converted from a physical delete to a tombstone write with a bumped
`version` — which is what actually flips the tie-break, not the field's mere
existence. Every reader (fetch helpers, hooks, cascade inputs, the shared
derivation kernel itself as defense-in-depth) now excludes tombstones. The
pull path gained a `boardTasks` branch that recomputes the affected board
directly from the pulled row's own `boardId` (not via task→board
reachability, which a tombstone is invisible to) and, for a sealed board,
invokes the deterministic sealed re-derive instead of the live cascade. See
the PR-1 commit history (`packages/shared`, `apps/web`, `apps/ios`) for the
full site-by-site sweep.

## Findings matrix

| # | Finding | Surface | Root cause (short) | Fix owner |
|---|---|---|---|---|
| 1 | **Tombstone defect** — deleted placements self-revert | sync (both platforms) | `BoardTask` had no soft-delete flag; a stale-version DELETE payload loses the LWW tie-break against the still-live remote row | **PR-1 / #358** (this PR) |
| 2 | **Web achievement render bug** — ACHIEVEMENT squares never render complete on web; tapping one runs the normal-task completion handler (no state change, but can auto-activate a DRAFT board) | web render + tap | Web's render adapters (`db/adapters.ts`) have no ACHIEVEMENT branch — falls through to the primitive branch, which reads a lifetime-completion cache that's never written for achievement tasks. iOS already renders these correctly via its own hand-mirror of the resolution logic | **PR-3 / #360 (shipped)** |
| 3 | **Sealed bypass** — the placement mutators (`removeBoardTaskFromBoard`, `addBoardTaskToBoard`, `updateBoardTaskAndCascade`) have no sealed-board guard, unlike the sibling metadata-edit/rearrange cascades PR #357 hardened | write path (both platforms) | The sealed-immutability invariant (docs/WINDOWED_COMPLETION.md §Sealing) was enforced ad hoc per call site rather than uniformly; these three sites were missed | **PR-2 / #359** |
| 4 | **Non-atomic save** — a board's placement set can be written across more than one non-transactional step, risking a partial write (orphaned/missing placements) if interrupted mid-flight | write path | Some board-save call sites predate the current one-Dexie-transaction convention (see CLAUDE.md "Atomic pull-path multi-writes"); not every write site was audited against it | **PR-4 / #361** (single-transaction Board-Edit Save — `useBoardPlay.commitSquareEdits` now wraps the whole staged-edit sequence + board-metadata patch in one `db.transaction(...)`) |
| 5 | **Push race** — concurrent pushes from two devices (or a push racing a coalesced re-enqueue) can interleave in ways the per-item LWW check doesn't fully account for | sync queue | Related to, but distinct from, finding 1's tie-break bug — this is about ordering/interleaving of multiple in-flight sync-queue items rather than a single stale payload | **PR-4 / #361** (pull-path local-wins re-enqueue — a fresher local write that lost a push race re-asserts via a coalesced UPDATE instead of diverging silently; plus `firestore.rules` version-monotonicity split so `allow update` requires `version >=` the stored value) |
| 6 | **Pull-cascade gaps** — a pulled row doesn't always trigger the same re-derivation a local write would | pull path (both platforms) | `boardTasks` pulls triggered no cascade at all (closed by PR-1); other collections' pull cascades were separately hardened by the bingo-pipeline hardening PR (#357, items 1–3: sealed re-derive, wizard-creation derivation, task-delete/counter-unlink cascade) | **PR-1 / #358** (the `boardTasks` slice); prior art in **#357** |
| 7 | **Uniqueness** — no enforced invariant that a board has at most one live placement per cell or per task; duplicate rows from the pre-tombstone era can double-count a cell or alias into the wrong grid position | data integrity (both platforms) | No DB-level uniqueness constraint on `(boardId, row, col)` or `(boardId, taskId)`, and no deterministic collision-resolution rule when duplicates exist | **PR-2 / #359** (repair pass + write-time guards); **PR-5 / #362** closed the last gap in this family — a second live `isCenter: true` row (a different failure mode than a cell/task collision) is now rejected at write time too |

All seven findings are closed as of PR-5. See
[§Residual accepted risks](#residual-accepted-risks) for what remains
open BY DESIGN (accepted, not missed).

## The five-PR program

| PR | Issue | Title | Scope (one line) | Status |
|---|---|---|---|---|
| PR-1 | #358 | Durable BoardTask deletes (tombstones) + the boardTasks-pull cascade | Give `BoardTask` a soft-delete flag like every other collection; fix every deletion site to tombstone instead of physically delete; add the missing pull-cascade branch | **Shipped (this PR)** |
| PR-2 | #359 | Placement-integrity repair + determinism + sealed guards | Repair existing duplicate/out-of-bounds placement rows in the wild (pre-tombstone-era corruption); make placement collision-resolution deterministic everywhere (one shared winner rule, a provably transitive lexicographic (version, updatedAt, id) total order — invalid dates normalize to an oldest-sentinel); enforce the invariants at write time; close the sealed-board placement-mutator bypass (finding 3) | **Shipped** |
| PR-3 | #360 | Unified board resolver — per-cell `computeBoardGrid` | Widen the canonical derivation kernel to return per-cell detail (including achievement badge inputs) and make every render surface on both platforms call INTO it instead of hand-copying the "is this cell complete?" logic — closing the web achievement render bug (finding 2) as the one user-visible behavior change | **Shipped** |
| PR-4 | #361 | Sync + atomicity hardening — reassert, rules monotonicity, atomic saves | Pull-path local-wins re-enqueue (a fresher local write that lost a push race re-asserts instead of diverging silently — finding 5); `firestore.rules` version-monotonicity (separate create/update rules, `allow update` requires `version >=`); single-transaction Board-Edit Save (finding 4) | **Shipped** |
| PR-5 | #362 | Kernel pins + minors sweep | Pin the last unhardened kernels with cross-platform shared vectors (`placeBoard`/`fisherYatesShuffle`/`centerSquare`, previously only hand-copied-array-tested); clamp a TS/Swift shuffle rng-edge divergence; add the last write-time uniqueness guard (a second live `isCenter: true` row, finding 7's remaining gap); a handful of iOS reentry-guard/staleness minors; dead-code + docs sweep (this doc's closing update) | **Shipped** |

## The "one resolver" direction

The audit's complexity map found the "is this cell complete?" computation
hand-copied roughly six times across the two platforms (web render adapters,
web board-preview, web achievement-badge memo, iOS play-grid mirror, iOS
preview mirror-of-mirror, iOS badge builder) alongside the canonical
`computeBoardGrid` kernel in `packages/shared`. The missing seventh copy —
web's render adapters never gaining an ACHIEVEMENT branch — is finding 2 in
the matrix above, and it's a direct consequence of that duplication: one of
six hand-copies drifted from the canonical kernel's behavior, and nothing
forced it back into sync.

PR-3 is the structural fix, not another patch to one of the copies: widen
`computeBoardGrid` to return per-cell detail (not just the aggregate grid +
count it returns today), and make every render surface call into that ONE
function instead of re-deriving completion state locally. After PR-3, "is
this cell complete, and what does it need to render" has exactly one
implementation per platform — the kernel's — with every UI surface a thin
consumer of its output. This is the direction the whole program points at:
PR-1 hardened the sync-layer edge of the pipeline (this doc), PR-2 hardens
the write-time edge (deterministic, invariant-enforced), and PR-3 collapses
the read-time edge onto one resolver. PR-4 rounded out the remaining
write-path atomicity and sync-queue-ordering gaps (findings 4/5), and PR-5
pinned the last unhardened kernels and closed the remaining uniqueness gap
(finding 7).

## Residual accepted risks

The program is closed, but a handful of items were identified during the
audit and PR-5's own sweep and deliberately left unfixed — either because
they're self-healing by a different mechanism already in place, or because
fixing them would cost more than the residual risk warrants. Recorded here
so a future contributor re-discovering one of these doesn't mistake it for
an unnoticed regression.

- **Orphaned `BoardTask` rows after `deleteBoard`** — deleting a board does
  not walk its `BoardTask` rows and tombstone them individually; they become
  unreachable (no live board to join against) but are not soft-deleted
  themselves. This is a storage/GC gap, not a correctness bug: every reader
  in the pipeline resolves placements by joining through a live, non-deleted
  `Board` row first (`computeBoardGrid`, the fetch helpers, the sync
  collections list), so an orphaned `BoardTask` can never render, count
  toward stats, or leak into another board's derivation. It just sits in
  Dexie/GRDB (and Firestore) unreferenced. A future storage-hygiene pass
  could sweep these; not scoped here.
- **Achievement fan-out staleness** — an ACHIEVEMENT square's badge reads
  its watched board/template's CURRENT state at render time
  (`computeBoardGrid`'s achievement branch), not a cached/propagated value.
  A watched board's state can change without every watching board's
  `completedTasks`/`linesCompleted` being eagerly recomputed at that exact
  moment — but because every render always calls the same live resolver,
  the NEXT render of any watching board (including the very next
  interaction) shows the correct state. This is "eventually consistent by
  construction," not a bug to fix: there is no persisted-then-stale
  achievement cache to invalidate, because there is no cache.
- **The pre-txn affected-set staleness edge** — `addBoardTaskToBoard`,
  `removeBoardTaskFromBoard`, and `updateBoardTaskAndCascade` all compute
  `affectedBoardIds` from a snapshot read BEFORE opening their write
  transaction (see each function's own comments in
  `apps/web/src/db/operations/boardTasks.ts`), then re-derive stats for
  each affected board INSIDE the transaction. A concurrent write landing in
  that narrow window (pre-txn read → txn open) that changes which boards
  are "affected" by this same task would not be reflected in this call's
  affected-set — but the sealed-board guard (PR-2) and each board's own
  independent cascade-on-its-own-write still keep every board internally
  consistent; the edge case is "one cascade pass computes a stats update
  for a board that a concurrent second cascade also touches," which the
  safety-net pull cycle and each board's own next local write both
  self-correct. Single-user, mostly-offline usage makes the actual window
  vanishingly rare in practice.
- **`computePlacementIntegrityRepair` does not dedupe a second `isCenter`
  row at a different cell** — the PR-2 repair pass collapses same-CELL
  collisions (two rows claiming the same `(row, col)`) and same-TASK
  duplicates (one task placed twice on a board), but a second live
  `isCenter: true` row at a DIFFERENT, otherwise-valid cell is a distinct
  failure mode the repair pass doesn't target. This is left as write-time
  prevention only (PR-5's `createBoardTask` guard) rather than also adding
  a repair-pass phase, because it's verified render-inert on both
  platforms' current render paths (center-cell rendering is computed
  positionally — `row/col === floor(size/2)` — never by reading the
  `BoardTask.isCenter` field) — so an already-existing stray row from
  before the write guard shipped poses no live rendering risk today, only
  a latent one if a future render path started trusting `isCenter` instead
  of position.
- **Migration tie-break note** — the legacy `composite_tasks` /
  `composite_nodes` / `task_steps` tables (see CLAUDE.md's Task model
  section) are read-only, first-launch-backfill-only; they carry no
  `isDeleted`/version machinery of their own and are never touched by any
  live LWW tie-break. They're mentioned here only because the audit's sync
  trace passed through them on its way to `BoardTask` — they are NOT part
  of this program's scope and needed no change.

## See also

- `docs/WINDOWED_COMPLETION.md` — the event-sourced completion model this
  pipeline derives against (unrelated axis: *when* a task counts as complete
  for a board's window, not *which placement row* wins a cell).
- `docs/SYNC_STRATEGY.md` — the LWW conflict-resolution rules finding 1's
  tie-break bug exploited.
- `packages/shared/src/algorithms/derivationPass.ts` — the canonical
  `computeBoardGrid`/`computeBoardStatsUpdate`/`computeSealedCompletedCells`
  kernel PR-3 widens.
- Issue #357 (bingo-pipeline hardening) — the prior-art PR that hardened three
  other pull-cascade gaps (sealed re-derive, wizard-creation derivation,
  task-delete/counter-unlink cascade) shortly before this audit; finding 6
  in the matrix above is this program's continuation of that work for the
  `boardTasks` collection specifically.
