# OYBC Roadmap & Hardening Plan

Canonical output of the full project review run on **2026-07-06** (concept / architecture / workflow / CI-CD survey, end-user feature review, and deep software-architecture dive), plus **Track G** integrating the Play OYBC transition plan from the same-day sibling session (canonical: [`docs/PLAY_TRANSITION.md`](PLAY_TRANSITION.md)). Every finding that warrants action lives here as a defined workstream.

**How to use this doc:** pick ONE workstream at a time (per the standard workflow — user-directed, one feature/refactor per branch). Each workstream below is scoped to the level needed to start; the detailed step-by-step implementation plan is written at pickup time via `/feature`, `/refactor`, or `/bugfix`. When a workstream ships, mark it here with the PR number (same convention as the phase tables in CLAUDE.md).

**Sizing legend:** S = single small PR (< ~200 lines), M = one substantial PR or 2–3 small ones, L = a phased mini-project with its own doc.

**As of 2026-07-08: B-track (B1–B4) COMPLETE; drift fixes #263/#236/#272 shipped; flaky-test race fixed (#283).** **D-track COMPLETE (D1 #293 · D2 #295 · D3 #297); E1 #298 + E3 #301 shipped — the review's directive-ready queue is EMPTY (2026-07-08).** Every remaining item needs a decision or user action: #262 secret (Stephen-only, blocks rules+hosting auto-deploy), E6 dependency majors (Dependabot #249/#251 + red #250), A4 project split, A7 repo-settings half, A8 runner image, E4 issue-hygiene (optional), E5 polish debts, F-track features (F1 Shared Counters P2–P4 remains the active feature directive), and the launch-era items (#300 version skew, web pull-apply tests). **Decision/user-gated:** — A6/C4/C1/B1 all shipped (see below). **Everything remaining needs a decision or user action first:** #262 (missing FIREBASE_SERVICE_ACCOUNT secret — blocks rules+hosting auto-deploy), #263 (LWW edge canon — one-vector fix once decided), A4 (project split), E6 (dependency majors — Dependabot #249/#251 firebase runtime + red #250 vitest 4), B2 (play-surface extraction — sequenced after B1 settles; L-sized, worth a Gate-1 plan), A7's repo-settings half, A8 (runner image), D1–D3 (sync hardening — D1 has UX copy decisions), E-track items, F-track features.

**Shipped 2026-07-06/07 (agentic execution):** the ENTIRE Track G transition — T1 #229 · T2 #233 · T3 #234 · T4 #230 · T5 #238 · T6 #239 — plus A3 #232 (closes #231) and C3 #237 (closes #235; review surfaced web twin bug → #236). The Play Phase-0 architecture spike can now build inside `apps/play`.

---

## Track A — Backend & CI/CD hardening

The review's core CI/CD finding: coverage tracks where the *apps* are, not where the *consequences* are. The client apps have solid workflows; the server-side surface (irreversible deletes, public endpoints, security rules) has none.

### A1 — Firestore rules emulator tests + PR-gated validation — SHIPPED [#242](https://github.com/2014sheas/oybc/pull/242)
> 25 emulator tests now gate the deploy. Bonus finding: the believed "10KB size cap" rule is a **no-op** (`request.resource.size()` without `.data`) — pinned in a test, decision tracked in [#243](https://github.com/2014sheas/oybc/issues/243).
- **Why:** `firestore.rules` deploys straight to the live project on any push to `dev` touching it, with zero test gating. No `@firebase/rules-unit-testing` tests exist anywhere. One over-permissive edit is an auto-shipped data exposure. Best safety-per-effort investment available.
- **Scope:** new `firestore-rules-tests/` (or `functions/test/rules/`) package using `@firebase/rules-unit-testing` + the Firestore emulator. Cover: cross-user read/write denial, `userIdMatchesPath` spoof rejection, unknown-collection denial, `signups` client-denial, user-doc delete denial, the id/version/size validation. Add a PR-triggered job to `firestore-rules.yml` (rules currently deploy with **no PR trigger at all**) and make the existing push-deploy job depend on the tests passing.
- **Acceptance:** a deliberately over-permissive rules edit fails CI on the PR; the deploy job cannot run on a red test.

### A2 — Cloud Functions CI + tests + Dependabot coverage — SHIPPED [#245](https://github.com/2014sheas/oybc/pull/245)
> functions.yml (adopts T6's esbuild build) + 6 emulator tests (purge isolation, subscribe contract) + /functions Dependabot (which immediately opened 5 bumps; the new lane caught vitest-4 breaking → left red deliberately).
- **Why:** `functions/` (account-deletion purge, public `subscribe` endpoint) has **zero** CI — no build, lint, or test — and no test files. Its npm deps are not in `.github/dependabot.yml` (only `/` is listed). Highest-blast-radius code in the repo, least verified.
- **Scope:** (1) `functions.yml` workflow: `npm ci && npm run build` + lint on PRs touching `functions/`; (2) emulator tests for `purgeUserData` (creates nested docs, asserts recursive delete) and `subscribe` (happy path, honeypot rejection, sha256 doc-id, malformed email); (3) add `directory: "/functions"` npm entry to dependabot config; (4) optional: a manual-dispatch deploy job so functions deploys stop being hand-run from a dev machine.
- **Acceptance:** a PR breaking the functions build goes red; `purgeUserData` and `subscribe` behavior is asserted under the emulator.

### A3 — Gate `/playground` behind `import.meta.env.DEV` — SHIPPED [#232](https://github.com/2014sheas/oybc/pull/232)
- **Why:** confirmed still open: `apps/web/src/App.tsx:144` mounts the playground publicly with no auth (it includes a "Clear Test Data" button that wipes the real Dexie DB), and `ProfilePage.tsx` links to it. Long-standing known follow-up; one-line-ish fix.
- **Scope:** conditionally register the route and the Profile "Developer" section on `import.meta.env.DEV`. Leave the playground itself un-Riso'd (per existing decision).
- **Acceptance:** production build serves no `/playground` route and no Developer link; dev build unchanged.

### A4 — Prod/dev Firebase project split (pre-launch decision) — `L` (decision `S`)
- **Why:** `oybc-dev-e2668` is simultaneously dev and prod: rules auto-deploy on push, hosting and functions deploy manually, all against the one project real users will hit. Fine pre-launch; untenable after. Splitting *before* launch avoids a data migration.
- **Scope:** decision first (naming, billing, when). Execution: second Firebase project, `.firebaserc` targets (`dev`/`prod`), per-target `GoogleService-Info.plist` / `.env` files, deploy workflows target dev on push and prod on tag/release/manual approval.
- **Acceptance:** nothing deploys to the user-facing project without an explicit release action.

### A5 — iOS CI caching (SPM + DerivedData) — SHIPPED [#255](https://github.com/2014sheas/oybc/pull/255)
> Warm-cache validated: 10m02s vs 17–20m baseline. DerivedData build-product caching deliberately deferred (in-file note).
- **Why:** every run cold-installs xcodegen, resolves all SPM deps, and clean-builds twice (OYBC scheme + snapshot scheme) — already 17–20 min on a 10×-cost macOS runner; timeout was bumped to 30.
- **Scope:** `actions/cache` keyed on `Package.resolved` for `SourcePackages`; evaluate caching DerivedData keyed on source hash (accept partial wins); cache the xcodegen brew bottle or pin a binary download.
- **Acceptance:** warm-cache PR runs measurably faster (target: under ~12 min); cache misses degrade gracefully to today's behavior.

### A6 — Hosting deploy automation (coming-soon page) — SHIPPED [#260](https://github.com/2014sheas/oybc/pull/260) (deploy blocked on [#262](https://github.com/2014sheas/oybc/issues/262) — missing secret)
- **Why:** the only live public surface (oybc.com email capture) deploys by hand via `firebase deploy --only hosting` — easy to forget, easy to ship a stale/broken build.
- **Scope:** workflow on push to `dev` touching `apps/coming-soon/**`: build, then deploy hosting using the existing `FIREBASE_SERVICE_ACCOUNT` secret pattern from `firestore-rules.yml`. Sequence after/with A4 if the project split lands first.
- **Acceptance:** merging a coming-soon change publishes it without manual steps.

### A7 — Security/dependency scanning depth — `S`
- **Why:** no `pnpm audit` step, no secret scanning, and iOS SPM deps (Firebase, GRDB, GoogleSignIn) have no automated CVE coverage (Dependabot doesn't support SPM).
- **Scope:** add a non-blocking `pnpm audit --prod` report step to web CI (blocking on `high`+ once the baseline is clean); enable GitHub secret scanning + push protection in repo settings; add a quarterly reminder (existing dependabot-sweep cron is the natural home) to hand-check SPM dep releases/CVEs.
- **Acceptance:** a high-severity npm advisory or a pushed secret surfaces automatically instead of never.

### A8 — Snapshot-test strict mode in CI — `S` (blocked on environment)
- **Why:** the snapshot step is `continue-on-error: true` (`ios.yml:96`) because the CI runner's iOS simulator minor differs from local; visual regressions currently produce a green check.
- **Scope:** already documented in CLAUDE.md — either wait for a macos-15 image shipping iOS 26.3, or install the iOS 26.2 runtime locally, re-record baselines on `OS=26.2`, and drop the flag. Track the runner-image state in the dependabot-sweep reminder.
- **Acceptance:** a genuine snapshot diff fails the PR.

---

## Track B — Architecture refactors

The deep-dive's core finding: both platforms systematically bypass their own layering (iOS: 136 direct `AppDatabase.shared` calls from Views/ViewModels; web: hooks and 18 component files read raw Dexie around `db/operations`), and the two play surfaces are god-files precisely where the layering broke down. **Order matters: B1 → B2 → B3** (they touch the same files; split mechanically first, then extract logic, then inject).

### B1 — Mechanical file splits along existing seams — SHIPPED [#266](https://github.com/2014sheas/oybc/pull/266)
> AppDatabase 3,118→626-line core + 9 extensions (zero visibility widenings); tasks.ts → 5 modules + barrel; code-motion proven by sorted-line diff. B2 unblocked.
- **Why:** `AppDatabase.swift` is 3,118 lines (schema + 18 migrations + every query domain + the shared-counter engine); `db/operations/tasks.ts` is 1,304. Both are the hottest data-layer files; every schema change and counter bug touches them; 3,000-line files are merge-conflict and context-window poison.
- **Scope:** zero-behavior-change splits. iOS: `AppDatabase+Migrations`, `+Boards`, `+Tasks`, `+BoardTasks`, `+SharedCounters`, `+CompoundChildren`, `+RecurringTemplates`, `+DefaultPools`, `+Users`, `+Sync` extensions — the existing `MARK:` sections already draw exactly these boundaries. Web: `tasks.ts` → `tasks.crud.ts`, `tasks.sharedCounter.ts`, `tasks.deletion.ts`, `tasks.steps.ts`, `tasks.copy.ts` with `tasks.ts` (or the barrel) re-exporting so no import site changes. Run `xcodegen generate` after adding Swift files.
- **Acceptance:** builds + full test suites green on both platforms with an empty behavioral diff; no file in the data layer over ~800 lines.

### B2 — Play-surface extraction (the god-file pair) — SHIPPED (6 slices, [#271](https://github.com/2014sheas/oybc/pull/271) [#273](https://github.com/2014sheas/oybc/pull/273) [#274](https://github.com/2014sheas/oybc/pull/274) [#275](https://github.com/2014sheas/oybc/pull/275) [#276](https://github.com/2014sheas/oybc/pull/276) [#277](https://github.com/2014sheas/oybc/pull/277), issue #270)
> Web: BoardPlaySurface 1,801→1,088 (render+toast shell over useBoardPlayData + useBoardPlay + toggleTaskCompletionAndCascade op); **first web unit tests** (Vitest+fake-indexeddb, E2 seeded). iOS: BoardPlayViewModel (DB-injected, 20 unit tests) owns loading (+reloadToken guard), all 10 interaction writes (one-shot flashEvent), and the edit-draft layer ($viewModel panel bindings; BoardEditPanel zero-diff). Zero write-path DB access left in either play surface. Found along the way: #272 (flash gating), completedAt divergence (doc'd in the toggle op).
- **Why:** `BoardPlayView.swift` (3,076 lines) is the only major screen with **no ViewModel** — ~25 direct DB calls including all shared-counter writes. `BoardPlaySurface.tsx` (1,801 lines) is its exact web mirror: business logic, a hand-rolled five-table `db.transaction`, and a direct `addToSyncQueue` call inside a React component. Highest-churn business logic in the app; zero tests today.
- **Scope:** iOS: introduce `BoardPlayViewModel` (ObservableObject) owning load/complete/increment/decrement/compound-toggle/edit-commit; view keeps rendering + overlay state. Web: move the write handlers into `db/operations` functions (the five-table transaction becomes an operation; the component-level `addToSyncQueue` disappears into it) and a `useBoardPlay` hook owning them + the reactive reads. Do it per-handler in reviewable slices, not one big-bang PR. The `embedded` flag behavior (core-window pager embeds the whole view) must survive.
- **Acceptance:** neither play surface imports the raw DB (`AppDatabase.shared` / Dexie `db`) directly; the extracted ViewModel/operations have unit tests for complete/increment/edit-commit paths; snapshot baselines unchanged.

### B3 — Database access seams (dependency injection) — SHIPPED [#285](https://github.com/2014sheas/oybc/pull/285) + [#286](https://github.com/2014sheas/oybc/pull/286) (issue #284)
> iOS: all 13 ViewModels DB-injected (defaulted seam, zero call-site changes; ViewModelInjectionTests). Web: raw Dexie behind `db/internal.ts`, ~17 files rerouted, boundary double-enforced (ESLint bite-verified + tree-walking Vitest test).
- **Why:** everything is concrete. iOS ViewModels hard-code `AppDatabase.shared` internally, so the existing `makeTestInstance()` seam (`AppDatabase.swift:79`) can't reach them — which is why only pure services have tests. Web exports the raw `db` instance from the `db/index.ts` barrel, so nothing even nudges components toward the operations layer.
- **Scope:** iOS: pass the `AppDatabase` instance (concrete is fine; a protocol only if test ergonomics demand it) into ViewModel inits, defaulting to `.shared` so call sites migrate incrementally; Views stop calling the DB directly as their logic moves into VMs (B2 does the biggest one). Web: stop exporting `db` from the barrel — move it to `db/internal.ts` imported only by `db/operations/*` and the read-hook layer; add the missing read helpers to operations so hooks stop hand-rolling queries; fix the 18 component-level raw-`db` import sites to use operations/hooks.
- **Acceptance:** iOS ViewModels are constructible against `makeTestInstance()` in tests; web components have zero raw-Dexie imports (greppable: `from '@/db/internal'` appears only under `db/` and `hooks/`).

### B4 — Enforce the sync-enqueue choke point — SHIPPED [#290](https://github.com/2014sheas/oybc/pull/290) (issue #289)
> SyncQueueBuilder referenced only inside Database/; zero raw write{} in Views/ViewModels; bpv* helpers absorbed; 10 enqueue-content assertion tests; web addToSyncQueue lint-restricted. Leftover: AuthService.persistUserMutation (user-domain, already atomic) → future pass. **B-track (B1–B4) COMPLETE.**
- **Why:** "every local write must also enqueue" is the most correctness-critical convention in the app, and it's maintained by hand at ~20 scattered sites: iOS has `*AndEnqueue` methods *plus* 8 hand-built enqueue sites in `BoardWizardPersist.swift` *plus* 11 raw `write {}` blocks in Views; web calls `addToSyncQueue` from operations *and* from two components. Literal reminder-comments exist because the structure doesn't.
- **Scope:** route every write through an operations/`*AndEnqueue`-style function that owns its enqueue. iOS: absorb the `BoardWizardPersist` and `BoardPlayView` hand-enqueue blocks into `AppDatabase` methods (B1's `+Sync`/domain extensions are the home); make `SyncQueueBuilder` internal to the Database layer. Web: after B3, `addToSyncQueue` is only importable inside `db/operations`. Add a lightweight test per platform asserting each public write op leaves a matching queue row.
- **Acceptance:** `SyncQueueBuilder`/`addToSyncQueue` are unreferenced outside the data layer (greppable); every public write operation has an enqueue assertion in tests.

### B5 — Error-handling policy — `M`
- **Why:** no policy exists. iOS has **79 `try?` sites**, several on *write* paths (e.g. `AuthService.swift:582` silently drops a failed write) and reads collapsing failure into `?? []` (failed read indistinguishable from empty). Web throws plain `Error`s that callers wrap into generic "Something went wrong" toasts. For an offline-first app, a silently failed local write is the worst possible failure.
- **Scope:** (1) audit all `try?` sites; every *write* gets do/catch + log + user-visible surface (or an explicit "best-effort, here's why" comment); reads may keep fallbacks but log. (2) Define the one-paragraph policy in CLAUDE.md (writes never silent; reads log; user copy stays generic but errors always reach the console/log). (3) Web: same pass over the empty-catch/toast sites. No typed-error-model rewrite — YAGNI until a concrete need.
- **Acceptance:** zero `try?` on write paths; grep-audit documented; policy paragraph in CLAUDE.md.

---

## Track C — Cross-platform drift closure & port-pattern protection

The port pattern (TS source of truth → hand-mirrored Swift twin) is faithful where it exists but protected purely by convention. These make it mechanical, and fix the drift already found.

### C1 — Shared JSON test vectors for ported algorithms — SHIPPED [#268](https://github.com/2014sheas/oybc/pull/268)
> 10 algorithm pairs fixture-driven; flip-test proven; byte-identity guard auto-covers future fixtures.
- **Why:** the single best improvement available for the port pattern. Test parity today means hand-transcribed cases ("same 6+ cases" comments). No mechanism catches a missing or diverged port. Would have mechanically caught every gap in C2/C3.
- **Scope:** `packages/shared/tests/fixtures/*.json` — golden input/expected vectors for each ported algorithm (start: streaks, sharedCounter, sharedCounterMerge, bingoDetection, compoundEvaluation, cycleDetection, derivationPass, linkableCounter, sharedCounterGroups, calendarBoundaries). Jest suites load and assert them (replacing/augmenting inline cases); a new `SharedFixtureTests.swift` loads the same files (added to the test bundle via `project.yml`) and runs them through the Swift twins. Date-valued fixtures use fixed ISO strings (the suites already share `NOW = Jun 15 2026`).
- **Acceptance:** changing an expected value in a fixture fails BOTH Jest and XCTest; adding a vector to a fixture requires no test-code change on either platform.

### C2 — Close the port gaps — SHIPPED [#253](https://github.com/2014sheas/oybc/pull/253) + [#257](https://github.com/2014sheas/oybc/pull/257)
> propagateIncrement ported (2 inline AppDatabase copies deleted, zero-discrepancy check), SharedCounterMerge 21 vectors, longest-streak parity, TaskExpiry/BrowsableTasks/TaskTitle helpers extracted (66 new iOS tests total). Leftover preview-label duplicates noted on #246.
- **Why:** found drift-shaped holes: `propagateIncrement` (TS) has no Swift twin — the cross-device counter math is reimplemented inline **twice** in `AppDatabase.swift` (~`:1682`, `:1805`) with no unit test; `SharedCounterMerge.swift` (the algorithm that prevents sync data loss) has **no XCTest**; `computeLongestStreak` has 5 TS cases and zero Swift cases; `taskExpiry`/`browsableTasks`/`taskTitle` are shared TS functions that iOS reimplements inline in ViewModels.
- **Scope:** (1) port `propagateIncrement` to `Helpers/SharedCounter.swift`, delete both inline copies, cover via C1 fixtures; (2) `SharedCounterMergeTests.swift`; (3) `computeLongestStreak` + `compactStreakLabel` Swift cases; (4) extract iOS `TaskExpiry.swift` / `BrowsableTasks.swift` / `TaskTitle.swift` helpers from the ViewModel inlines, matching the TS signatures, covered by C1 fixtures.
- **Acceptance:** every TS algorithm consumed by iOS-equivalent logic has a named Swift twin with fixture-backed tests; no counter math lives inline in `AppDatabase`.

### C3 — Fix the two live divergences — SHIPPED [#237](https://github.com/2014sheas/oybc/pull/237) (web twin bug → [#236](https://github.com/2014sheas/oybc/issues/236))
- **Why:** confirmed, current bugs-in-waiting: `Streaks.swift:78` guards only `.custom` where `streaks.ts:85` guards `CUSTOM` **and** `INDEFINITE` (Swift survives only because `computeTimeframeBoundaries` happens to return nil); Swift's `DefaultTimeframe` enum omits `indefinite` (`User.swift:29-35`) while TS accepts it — a web-set `defaultTimeframe: indefinite` silently degrades to `.custom` on iOS after sync.
- **Scope:** add the INDEFINITE guard to `Streaks.swift`; add `.indefinite` to `DefaultTimeframe` + wherever the wizard consumes it; regression tests for both (fold into C1 fixtures if concurrent).
- **Acceptance:** a synced `indefinite` default round-trips iOS unchanged; streaks INDEFINITE guard tested on both platforms.

### C4 — Sync contract into `packages/shared` — SHIPPED [#264](https://github.com/2014sheas/oybc/pull/264)
> Found latent LWW edge divergence → [#263](https://github.com/2014sheas/oybc/issues/263).
- **Why:** collection lists, user-scoped sets, legacy pull-skip sets, and LWW rules are duplicated literals in `syncService.ts` and `SyncService.swift`. They agree today; the half-finished `progress_counters` retirement (C5) proves this duplication style does drift. You can't share the Swift implementation, but you can share the contract.
- **Scope:** export `SYNC_COLLECTIONS`, `USER_SCOPED_COLLECTIONS`, `LEGACY_PULL_SKIP` as constants from `packages/shared`; web consumes them directly; a Swift test asserts `SyncService`'s lists match a checked-in JSON copy of them (generated into the fixture dir by the shared build or hand-synced with a Jest guard). LWW tie-break rules become C1 fixture vectors run against both `resolveConflict` implementations.
- **Acceptance:** adding a collection on one platform without the other fails a test somewhere.

### C5 — Finish the `progressCounters` retirement on iOS — `S`
- **Why:** web dropped the Dexie store at v11 and de-exported the type; iOS still declares `progress_counters` (`Schema.sql:150`) and row-wipes it (`AuthService.swift:536`); `packages/shared/src/types/progressCounter.ts` is orphaned (exported nowhere, imported nowhere). A half-retired entity is a trap for the next contributor.
- **Scope:** iOS migration dropping the table (or, if kept inert for old-device compatibility like the other legacy tables, an explicit comment saying so and why); remove the wipe call; delete the orphaned shared type file; confirm the sync known-collections list treatment matches the other legacy tables.
- **Acceptance:** `progress_counters`/`ProgressCounter` references are either gone or carry an explicit legacy-inert comment matching the `task_steps` convention; grep is clean otherwise.

### C6 — Web draft-board containment parity — `M` (pre-existing follow-up, absorbed here)
- **Why:** already tracked in CLAUDE.md: iOS shipped draft-task library hiding (`createdInWizard`) and drafts-never-playable; web still browses wizard-born draft tasks and opens draft boards as playable.
- **Scope:** per the existing CLAUDE.md follow-up note (set + filter `createdInWizard` in web wizard/library; route draft opens to wizard-resume). Part of the broader parity-audit effort (see memory `project_web_ios_parity_audit`).
- **Acceptance:** behavior matches iOS PR #202/#203 semantics.

---

## Track D — Sync hardening

Sync atomicity is verified solid (same-transaction enqueue, atomic pull+cascade with rollback, watermark-after-clean-pull). The gaps are recovery and observability — what happens after things go wrong.

### D1 — Dead-letter surfacing for exhausted retries — SHIPPED [#293](https://github.com/2014sheas/oybc/pull/293) (issue #292)
- **Why:** after `MAX_SYNC_RETRIES` (5), a queue item is abandoned in FAILED forever with only a `console.warn`. The local row stays correct; Firestore silently never learns of it; the user has no signal. On multi-device accounts that is slow, invisible divergence.
- **Scope:** count permanently-FAILED items into the sync status on both platforms; the iOS sync row and web `SyncStatusIndicator` show a "N changes couldn't sync — Retry" affordance that resets `retryCount` and re-promotes (keep copy minimal per the #151 three-state convention — no raw error text). Consider auto-re-promoting exhausted items on network-regain as the cheap first step.
- **Acceptance:** an item exhausting retries becomes user-visible and user-recoverable on both platforms; test covers promote-after-reset.

### D2 — Make `lastSyncedCount` advancement reliable — SHIPPED [#295](https://github.com/2014sheas/oybc/pull/295) (issue #294)
> Folded atomically into push completion; advances to the PUSHED value (concurrent increments survive).
- **Why:** the post-push bookkeeping write that maintains the additive-merge ancestor is best-effort — it swallows its own failure (`syncService.ts:175-179`, mirrored iOS). If it fails, the next counter conflict silently degrades from additive merge to LWW, which is exactly the increment-losing behavior the merge exists to prevent.
- **Scope:** retry the advancement (it's idempotent — it sets ancestor to the pushed value) or fold it into the push-completion transaction; log loudly on final failure; unit-test the degradation path on both platforms (pairs naturally with C2's `SharedCounterMergeTests`).
- **Acceptance:** a transiently-failing ancestor write no longer silently changes merge semantics; the failure path is tested.

### D3 — Coalesce queue rows per entity — SHIPPED [#297](https://github.com/2014sheas/oybc/pull/297) (issue #296)
> Attempt-gated CREATE+DELETE drop; found+converted 16 web bypass sites; iOS 53 sites → one enqueue choke point. **D-track (D1–D4) COMPLETE.**
- **Why:** N edits to one task enqueue N full-snapshot rows → N Firestore writes. Correct under LWW (full snapshots), but wasteful and it widens any per-item failure's blast radius.
- **Scope:** at enqueue, if a PENDING row exists for the same `(entityType, entityId)` with a compatible op, replace its payload/timestamp instead of appending (delete-op supersedes pending create/update; never coalesce across an IN_PROGRESS row). Same logic both platforms; lands cleanly after B4 centralizes enqueueing.
- **Acceptance:** burst-editing one task yields one pending row; op-precedence cases (create→update, update→delete) unit-tested on both platforms.

### D4 — Watermark safety-net: keep it, document it — SHIPPED [#256](https://github.com/2014sheas/oybc/pull/256)
- **Why:** the pull watermark is a local-clock ISO string vs server `_syncedAt` — a clock-skew window exists by design, recovered by the 5-minute safety-net re-pull. Risk is someone "optimizing away" the safety net later.
- **Scope:** a do-not-remove comment at both safety-net sites naming the skew window it exists to close + one line in `docs/SYNC_STRATEGY.md`.
- **Acceptance:** the invariant is written down where it would be deleted.

---

## Track E — Docs, tests & workflow debt

### E1 — Docs accuracy pass — SHIPPED (this PR)
- **Why:** confirmed staleness: `ARCHITECTURE.md` documents a `bingo_lines` table that exists on **neither** platform (state actually lives on `board.linesCompleted` + recompute); CLAUDE.md calls `BoardPlayView` "~1350-line" (it's 3,076); `ARCHITECTURE.md`/`TASK_SYSTEM.md`/`SYNC_STRATEGY.md` (Jun 23) predate the shared-counters work (Jul 2–3).
- **Scope:** delete/correct the `bingo_lines` claim; fix the BoardPlayView figure (or better, land B1/B2 first and write the new truth); add shared-counter model coverage to TASK_SYSTEM/SYNC_STRATEGY (much of it can lift from `SHARED_COUNTERS.md`); add this ROADMAP.md to CLAUDE.md's Documentation list.
- **Acceptance:** no doc describes a table, size, or model the code contradicts.

### E2 — Web unit-test harness (Vitest + fake-indexeddb) — `M`
- **Why:** web has **zero** unit tests; all web logic rides on 7 Playwright specs no workflow even runs. Long-standing follow-up. Sequenced deliberately: it pays off most *after* B2/B3 give it a layered surface to test.
- **Scope:** Vitest + fake-indexeddb wired into `apps/web` with a `test` script (web CI picks it up automatically — turbo runs `test` where defined); first targets: `db/operations` (post-B1 split modules), `wizardPersist`, `useBoardWizard` reducer logic. Optionally add a CI job (or scheduled job) that runs the Playwright suite.
- **Acceptance:** `pnpm -w test` runs web tests in CI; the shared-counter and deletion-cascade operations have direct coverage.

### E3 — Test the seams (the PR #202 lesson, generalized) — SHIPPED [#301](https://github.com/2014sheas/oybc/pull/301) (issue #299)
> 12 iOS seam tests: cascade-delete (incl. the impact-preview contract) + sync pull-apply (rollback proven via a production-realistic poison; additive-merge gate integration). Found #300 (version-skew retry loop). Remaining E-track debt: web cascade-delete tests (fillable), web pull-apply (firebase-coupled, needs mocks).
- **Why:** the highest-blast-radius code has the least coverage: iOS `SyncService` orchestration, `AppDatabase` cascade delete (only the counter-decrement path is tested), web `db/operations`, `useBoardWizard`. The recorded lesson from PR #202 — "the wizard→persist→resume→play seam was untested" — generalizes: bugs live between the well-tested pure units.
- **Scope:** iOS: cascade-delete tests (board delete → placements/tasks/compound links) against `makeTestInstance()`; a `SyncService` pull-apply test using a fake remote-doc source (needs the B3 seam). Web: covered by E2's target list. Add per-seam as the B-track refactors expose each one — not a single mega-PR.
- **Acceptance:** cascade delete and pull-apply-LWW have direct tests on the platform where they run.

### E4 — Follow-up tracking hygiene — `S`
- **Why:** CLAUDE.md's "Known follow-ups" prose bullets don't close the loop (at least one was already stale — the sync-error-leak item shipped without the note being updated). Issue #157 showed the better pattern.
- **Scope:** convert the open CLAUDE.md follow-ups and this roadmap's workstreams into GitHub issues with track labels (`track:cicd`, `track:arch`, …); CLAUDE.md keeps one pointer line per area instead of full prose; this doc records PR numbers as things ship.
- **Acceptance:** every open workstream is a queryable issue; CLAUDE.md follow-ups section shrinks to pointers.

### E6 — Dependency majors pass — `M`
- **Why:** the health audit found two deliberate-upgrade candidates: `zod` pinned to v3 in `packages/shared` (v4 is out; it's the shared package's only runtime dep, so the migration touches every schema) and iOS `GRDB` on 6.x (7.x is out; SPM deps are hand-bumped with no automated CVE coverage — see A7). The web stack is otherwise current-to-bleeding (React 19 / Vite 8 / TS 6).
- **Scope:** one PR per major, not a combined sweep: zod 4 migration (run the shared Jest suite as the safety net — this is exactly what its 34 test files are for), then GRDB 7 (read the migration guide; the `Codable`/record conformances are the risk surface; full iOS test + snapshot suites gate it).
- **Acceptance:** both majors current or an explicit pin-with-reason comment where staying back is the right call.

### E5 — Pre-existing small polish debts (absorbed for completeness) — `S` each
- Blip mood picker persistence (needs shared `UserPreferences.blipMood`, both platforms per rule 6).
- DEBUG-gate the ~29 ungated iOS `print()` calls.
- `autoArchiveCompleted` — wire it or remove the pref.
- CAPTCHA / auth rate-limit hardening — pre-public-launch gate, tracked not scheduled.

---

## Track F — Product / feature roadmap (end-user)

From the end-user review. Theme: the deep machinery is built — most opportunity is making it **visible, reachable, and pre-loaded**, not adding new kinds of depth. Order below is the recommended sequence.

### F1 — Shared Counters P2–P4 — `L`, **in flight**
- Canonical doc: `docs/SHARED_COUNTERS.md`. P2 board-play polish (shared marker, credited toast), P3 arrival banner (also closes the unwired `counterArrivals.ts`), P4 rich stats. This is the differentiator — finish making the engine visible before starting new tracks.

### F2 — Starter board gallery + tutorial rework (#157) — `L`
- **Why:** the biggest funnel risk is cold start — empty library + a 24-square authoring lift before any fun. Starter templates and the tutorial rework are the same "first session" problem; do them as one design effort.
- **Scope:** a dozen curated pre-filled boards ("Sunday Reset", "Reading habit", …) adoptable in one tap during onboarding and from the Create hub. Plumbing largely exists — this is the preset-pool template mechanism (Phase 6.2) with shipped content. Content authoring (task lists per template) is the real work. Fold in the #157 tutorial revamp so the tutorial hands you a real board.
- **Acceptance:** a new user can be playing a full board within a minute of signup without authoring a single task.

### F3 — iOS widgets + lock-screen quick-log — `L`
- **Why:** for a daily-cadence app, a today-board widget / lock-screen counter-log button is the single biggest retention feature available on iOS.
- **Scope:** requires moving the GRDB database into an App Group container (a real but well-trodden refactor — do it as its own prep PR); WidgetKit timeline for the current core board; an interactive increment button (App Intents) feeding `incrementSharedCounter`. Respects the no-background-writes invariant (widget reads; interactive intents are user actions).
- **Acceptance:** home-screen widget shows the live daily board; lock-screen button logs a counter without opening the app.

### F4 — Greenlog history / recap — `M`
- **Why:** the most under-served motivation loop — when a window expires its story vanishes. Streaks exist; *looking back* doesn't. Already noted as a follow-up idea in CLAUDE.md.
- **Scope:** a browsable archive (per core timeframe: which windows greenlogged/bingoed, streak timeline) computed live from existing boards — no new schema (same philosophy as `computeStreak`). Entry points: Profile streaks card + core-board browser. A shareable "month recap" poster in the existing share-poster visual language is the stretch goal.
- **Acceptance:** a user can answer "how did my March go?" inside the app.

### F5 — Siri / Shortcuts App Intents for counter logging — `S/M`
- **Why:** "log 20 push-ups" by voice, feeding the shared-counter fan-out — small surface, disproportionate delight. Shares App Intents groundwork with F3.
- **Acceptance:** a Shortcuts/Siri phrase increments a chosen counter and all linked boards update.

### F6 — HealthKit-fed counters — `L`, decision-gated
- **Why:** steps/workouts flowing automatically into shared counters is a perfect conceptual fit. Constraint: must respect the lazy no-background-writes invariant — reconcile HealthKit deltas **on app-open** (same pattern as recurring detection), accepting that squares fill in when the app opens, not in real time.
- **Scope:** per-counter HealthKit source binding (opt-in), an app-open reconcile that reads deltas since last anchor and routes them through `incrementSharedCounter`. iOS-only by nature (documented rule-6 exception like notifications).
- **Acceptance:** a steps-bound counter updates on app open with no background execution and no server involvement.

### F7 — Progressive task-type disclosure — `S/M`
- **Why:** concept density is the #2 friction — four task types + operators + derivation is fog for a casual user. Purely presentational; no model change.
- **Scope:** new accounts see Normal + Counting in creation surfaces; Compound/Achievement unlock via a settings toggle and/or a gentle "ready for more?" moment. A `UserPreferences` boolean (shared type, synced) drives it.
- **Acceptance:** a fresh account's create flow shows two types; the full set is one toggle away; existing accounts unaffected.

### F8 — Reward squares — `S/M`
- **Why:** converts abstract payoffs into personal ones ("bingo = takeout night"). Trivial data model; fits the center-square vocabulary.
- **Scope:** an optional reward text on a board (or its center square) surfaced in the bingo/greenlog celebration. One shared field, both platforms.

### F9 — Template sharing (the cheap social step) — `L`
- **Why:** bingo's name creates a social expectation; live multiplayer breaks the architecture, but *template* sharing doesn't — recipient gets their own copy with their own completion state, per-user isolation intact. Combined with the share poster it's a viral loop at a fraction of multiplayer's cost.
- **Scope:** export a board as a shareable template (link/QR encoding the task pool + layout — likely a Cloud Function + public template doc, or an encoded deep link to stay serverless); import creates local copies. Decisions needed: link format, whether templates live server-side, abuse surface. Warrants its own design doc at pickup.
- **Acceptance:** user A shares a board; user B taps the link and plays their own copy.

### F10 — Live shared boards / challenges — deferred, decision-gated
- **Why deferred:** maximum appeal, maximum cost — breaks per-user data isolation, LWW sync, and the "only you write your data" assumption. Phase-sized, not feature-sized. Sequencing: ship F9 and let demand prove whether real-time social justifies the bill. Revisit only by explicit directive.

### Explicit non-goal: AI board generation
"Describe a goal, get a board" demos well but fights the app's soul (offline-first, no server dependency, user-owned data), and F2's starter templates capture most of the same "help me begin" value with zero infrastructure. If ever, a launch-later cloud nicety — recorded here so it isn't re-litigated from scratch.

---

## Track G — Play OYBC enablement (cross-product)

Play OYBC — the real-time, collaborative party-bingo sibling product — was specced in a separate session. **Canonical plan: [`docs/PLAY_TRANSITION.md`](PLAY_TRANSITION.md)** (six PR-sized tasks, T1–T6, complete code + verification per task; execution not started). This track does not restate that plan; it records how it interlocks with the rest of this roadmap.

**Decision recorded:** Play lives in this repo as `apps/play`, with the product boundary enforced by the **package dependency graph, not repo topology**: `apps/play` depends ONLY on domain-free packages (`@oybc/bingo-core`, `@oybc/riso-tokens`), never `@oybc/shared`.

### The standing guardrail (binds Tracks B and C)

Any refactor in this roadmap must respect the Play/Do boundary:

- `packages/bingo-core` stays **primitives-only** — no Do entities (Board/Task/BoardTask), no Play session types. Anything wanting to cross the line either is pure game math (→ moves into bingo-core) or belongs to exactly one product.
- A rework that has Play importing `@oybc/shared`, or Do domain types drifting into bingo-core, is **breaking the design, not evolving it**.
- Do-only shared machinery (the C4 sync-contract constants, entity types, Zod schemas) stays in `@oybc/shared` — that package is Do-domain by definition.

### G1–G6 — the transition tasks (T1–T6 in PLAY_TRANSITION.md) — **ALL SHIPPED 2026-07-06/07**

T1 [#229](https://github.com/2014sheas/oybc/pull/229) · T2 [#233](https://github.com/2014sheas/oybc/pull/233) (golden-parity: 48-case seeded matrix, identical Jest/XCTest arrays) · T3 [#234](https://github.com/2014sheas/oybc/pull/234) · T4 [#230](https://github.com/2014sheas/oybc/pull/230) · T5 [#238](https://github.com/2014sheas/oybc/pull/238) (boundary lint verified to bite; play.yml lane live) · T6 [#239](https://github.com/2014sheas/oybc/pull/239) (`validateWin` is emulator-only — NOT deployed; A2's CI must adopt its esbuild build).

| Task | One-liner | Interacts with |
| --- | --- | --- |
| T1 `packages/bingo-core` | bingoDetection, shuffle, centerSquare + enums move out of shared (shared re-exports; zero web import changes); `MIRRORS.md` maps TS↔Swift twins; web.yml paths widen to `packages/**` | **C1, C2** — see below |
| T2 `placeBoard<T>` | one placement core collapses the four duplicated board-generation sites (web/iOS wizard persist + shared/iOS spawn); golden-parity seeded-LCG tests in Jest **and** XCTest | **E3** — this *is* the wizard→persist seam purification the PR #202 lesson asked for; **C1** — the golden-parity mechanism is the same shared-vector idea |
| T3 `packages/riso-tokens` | riso.css extracted ("extract at three": web + coming-soon + Play); coming-soon keeps its copy + gets a CI drift-check | none (A6 hosting automation unaffected) |
| T4 Governance | root CLAUDE.md "two products, one repo" scoping section; design doc → `docs/play/PLAY_OYBC.md` (pending Stephen's canonical-home decision) | **E4** — land the scoping section in the same hygiene pass or before it |
| T5 `apps/play` scaffold | Vite/React, deps = bingo-core + riso-tokens only, ESLint import ban on `@oybc/shared`, `play.yml` CI lane, throwaway demo board proving the chain | new CI lane joins Track A's world |
| T6 Functions esbuild + `validateWin` | functions get esbuild bundling (workspace deps inlined) + an emulator-only callable running the same `detectBingos` server-side | **A2** — see below |

### Roadmap workstreams this changes

- **A2 (Functions CI)** — build step must use T6's esbuild pipeline (`tsc --noEmit` + bundle), not plain `tsc`; T6's emulator `validateWin` harness is the natural seed for A2's emulator tests. If A2 lands first, write it so T6 slots in; if T6 lands first, A2 inherits its build.
- **C1 (shared JSON test vectors)** — after T1, fixtures for bingoDetection/shuffle/centerSquare/placeBoard live in **bingo-core**, not shared; `MIRRORS.md` becomes the authoritative TS↔Swift pairing list that C1/C2 audit against. T2's golden-parity seeded tests are the C1 mechanism applied to placement — build C1 as the generalization of T2's pattern, not a parallel invention.
- **C2 (port gaps)** — `MIRRORS.md` (T1) is where the "every TS algorithm has a named Swift twin" inventory lives from then on; C2's acceptance criteria update to "MIRRORS.md is complete and fixture-backed".
- **E3 (seam tests)** — T2 delivers the placement-seam purity; E3 drops that item and keeps cascade-delete + pull-apply.
- **A4 (project split)** — gains a future consumer: Play's realtime backend and `play.oybc.com` hosting will multiply whatever project topology A4 picks. Factor Play into the A4 decision even though Play's backend itself is out of scope here.
- **B-track** — no conflict: `BoardPlaySurface`/`BoardPlayView` are explicitly NOT reused by Play, so B2's extraction is free to reshape them; B1's `tasks.ts`/`AppDatabase` splits don't touch the bingo-core surface. T2 does touch `wizardPersist.ts`/`BoardWizardPersist.swift` — if B-track and T2 are in flight together, T2 goes first (it shrinks what B has to move).

### Open item needing Stephen

Canonical home of the Play design doc (`docs/play/PLAY_OYBC.md` vs mastered elsewhere with a pointer) — the only unconfirmed T4 decision.

---

## Sequencing summary

- **Priority lane (Play demo target ~Halloween):** G-track T1 → T2 → (T3 ‖ T4) → T5 → T6 per `PLAY_TRANSITION.md`. T1+T2 are worth doing even if Play stalls — they close a real 4-site duplication and purify the PR #202 seam.
- **Now / next small PRs (interleave with G-track):** A3 (one-liner), A1, C3 (small, live bugs), A2 (after or with T6 — shared build pipeline), C2.
- **Then:** B1 → B2 → B3 (in order; B4 rides B3's coattails; if T2 is still in flight, it lands before B touches the wizard-persist files), C1 alongside (generalizing T2's golden-parity pattern; fixtures split bingo-core vs shared per Track G).
- **Then:** D1–D3 (after B4 centralizes enqueueing), E2 → E3 (after B-track exposes the seams; T2 already covered the placement seam), F2.
- **Pre-launch gates:** A4 (project split — factor in Play's future backend) and E5's CAPTCHA item before public web launch; A8 when the runner image allows.
- **By directive only:** F6, F9, F10.
