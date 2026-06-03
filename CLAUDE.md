# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OYBC (On Your Bingo Card) — An offline-first, gamified task management app that turns goals into interactive bingo boards. Multi-platform (iOS native + web) with seamless offline functionality and background sync.

**Core Architecture**: Local-first design where local databases (GRDB on iOS, Dexie on web) are the source of truth, with Firestore providing background sync for multi-device support only.

## Task model — Compound Tasks Unification (shipped)

The core task model is the unified one — **Normal / Counting / Compound** (Progress and Composite were collapsed onto Compound in the unification refactor: PR #43, PR #42, Phase 8 cleanup). Phase 6.3 later added **Achievement**, a cross-board watcher type. Canonical doc: [`docs/TASK_SYSTEM.md`](docs/TASK_SYSTEM.md).

Schema shape:

- `tasks` carries operator + threshold + isOrdered for compounds.
- `compound_children` replaces the retired `task_steps` and `composite_nodes` tables (one row per parent-child link; the child can be any Task, including another compound).
- `composite_tasks` is dropped at the model level; composites live in `tasks` with `type='compound'`.
- `BoardTask` is a pure placement record — no `isCompleted` / `completedAt` / `currentCount` / `completedStepIds`. Completion is **global per Task**, not per-board.

The legacy `composite_tasks` / `composite_nodes` / `task_steps` SQLite tables are still present in old migrations so first-launch backfill on dev/test devices works. They are read only by (a) the GRDB/Dexie first-launch migrations that backfill `compound_children`, and (b) the sync service's known-collections list, which lets the push loop drain DELETE tombstones to Firestore. No live UI reads, no live writes — once a device has migrated and drained, those rows are inert. Build deferred compound playgrounds (`CompoundTaskPlayground` / `GlobalCompletionPlayground`) when a future feature genuinely needs them — the snapshot test target (`OYBCSnapshotTests`) is the primary visual-verification surface today.

## Recurring Boards (Phase 6 — shipped)

Three sub-phases, all merged to `dev`. Canonical design: [`docs/ARCHITECTURE.md` §Phase 6](docs/ARCHITECTURE.md#phase-6-recurring-boards--shipped).

| Sub-phase | Scope | PR |
| --- | --- | --- |
| 6.1 | Timeframe-prompted boards — Boards-tab banner when a new daily/weekly/monthly/yearly window opens; wizard prefill from banner; "From parent boards" filter in the wizard's tasks step. | [#50](https://github.com/2014sheas/oybc/pull/50) |
| 6.2 | Preset-pool recurring boards — `RecurringBoardTemplate` entity carrying a fixed task pool; lazy app-open spawn reuses 6.1's detection hook. | [#52](https://github.com/2014sheas/oybc/pull/52) |
| 6.3 | ACHIEVEMENT as a `TaskType` — cross-board watcher tasks (specific board XOR recurring template) with `achievementTrigger` (bingo / greenlog) + `requiredCount` for template mode. Cycle detection + window-aware spawn fan-out. | [#54](https://github.com/2014sheas/oybc/pull/54) |

Key invariants (so future contributors don't accidentally violate them):

- **Shared task semantics**: a task placed on a daily and on a parent monthly is the *same Task*; completing it on the daily globally completes the monthly. This is intentional — derivation is a UI filter on the wizard's task picker, never a clone path. If a user wants an independent counter, the answer is a separately-named Task.
- **6.1 schema footprint is minimal**: only 4 boolean fields on `UserPreferences` (`recurringDailyEnabled`, `recurringWeeklyEnabled`, `recurringMonthlyEnabled`, `recurringYearlyEnabled`). Detection is computed at read time from existing `Board.timeframe + startDate + endDate`. `mergeUserPreferences()` in `packages/shared/src/types/user.ts` and the iOS `UserPreferences.init(from:)` mirror both decode the fields forward-compatibly.
- **Lazy detection only**: no background scheduling, no notifications. Recurrence is observed when the user opens the Boards tab, never pushed. `BGTaskScheduler` (iOS) and service-worker scheduling (web) are explicit non-goals.
- **No custom-timeframe recurrence**: `Timeframe.CUSTOM` is excluded from the `PARENT_TIMEFRAMES` map and from the recurrence toggles. Re-evaluate if a real use case surfaces.

## Code Quality Standards

- Type hints and docstrings required for all functions and classes. Public APIs must document parameters, return values, and exceptions.
- Functions must be focused and small. PascalCase for classes, camelCase for functions/variables.
- Follow existing patterns within the app exactly.
- **Reuse before creating**: Search for existing utilities/components before writing new code.
- **Extract at three**: Same logic in 3+ places → extract to shared utility.
- **Share across platforms**: Constants, formatting, and validation that must be consistent across web and iOS should be centralised in a single definition.
- Proper error handling and logging for all database and network interactions.
- Evaluate third-party libraries carefully before importing — must be necessary, well-maintained, and not bloat app size.

## Testing Standards

- All new features and bug fixes must include unit tests covering core logic.
- Aim for at least 80% code coverage in all packages.
- Use Jest for TypeScript tests and XCTest for Swift tests.
- Tests should be deterministic and not rely on external services or network calls.

### iOS verification: snapshot tests + relay-to-user, never sim-driving

For iOS UI verification, the only two tools agents should reach for are:

1. **Snapshot tests** (`OYBCSnapshotTests` target) — fast, deterministic, runnable from `xcodebuild`. The default surface for visual regression checks; see the section below.
2. **`xcodebuild test`** for the logic-test scheme — also fine to run from any agent session.

For anything else (interactive flows, real-device behavior, "does this actually work end-to-end on iPhone 16 sim"), **agents must NOT** drive the simulator from the CLI:

- ❌ Don't run `xcrun simctl boot/install/launch` to spin up an interactive sim from this session.
- ❌ Don't open `Simulator.app` and try to script taps via AppleScript / accessibility / `simctl ui`.
- ❌ Don't loop "screenshot → ask user to tap → screenshot again" — the round-trips are slow and brittle.
- ✅ Instead, **relay a numbered list of steps to the user** describing what to tap and what to observe at each step. The user already has Xcode open and can rebuild + interact in seconds (`-bypassAuth YES` arg avoids Firebase signin).

Why: the iOS sim has no native tap CLI (`simctl` doesn't expose touch) and the install/launch overhead per iteration is much higher than just letting the user drive the sim window they're already looking at. The user established this convention explicitly during 6.1d testing.

### iOS snapshot tests (rapid UI verification)

Snapshot tests are the fastest way to visually verify iOS UI changes — no simulator boot, no manual screenshots. Use them whenever a layout, color, typography, or component-rendering change might regress an existing surface.

**Where to find them:**
- Target: `OYBCSnapshotTests` (separate from `OYBCTests` so logic tests stay light)
- Files: `apps/ios/OYBCSnapshotTests/*SnapshotTests.swift`
- Fixtures: `apps/ios/OYBCSnapshotTests/SnapshotFixtures.swift` (mock data builders — reuse, don't duplicate)
- Baselines: `apps/ios/OYBCSnapshotTests/__Snapshots__/<TestClassName>/<testName>.1.png`
- Library: `pointfreeco/swift-snapshot-testing` v1.18+ via SPM

**Workflow:**
```bash
cd apps/ios
xcodegen generate    # only if you added new test files
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project OYBC.xcodeproj -scheme OYBCSnapshotTests \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -derivedDataPath /tmp/oybc-derived test
```

CI pins Xcode to **26.3** (`DEVELOPER_DIR=/Applications/Xcode_26.3.app/...` in `ios.yml`). Use the same Xcode major.minor locally — the runner image keeps multiple Xcodes around, so the precise build of 26.3 may differ slightly from your local 26.3, but the iOS simulator that ships with it is what `OS=latest` resolves to on both ends. If you have multiple Xcodes installed locally, run `sudo xcode-select -s /Applications/Xcode-26.3.app` (or set `DEVELOPER_DIR` per-command as above) so re-recordings happen against the matching toolchain.

Each test runs in ~0.1–0.5s; full suite finishes in ~1–2s after build. Build adds ~10–15s on a clean derived-data dir. End-to-end loop: ~15–20s.

**On failure** (snapshot doesn't match baseline):
- The failure message prints two `file://` URLs — the baseline and the new candidate.
- Candidate lives under `~/Library/Developer/CoreSimulator/Devices/<device-id>/data/Containers/Data/Application/<app-id>/tmp/<TestClassName>/<testName>.1.png`.
- Read both PNGs to compare. If the diff is intentional, delete the baseline and re-run with `record: .missing` to re-record. If unintentional, fix the regression.

**Adding a new snapshot test:**
1. Add a `*SnapshotTests.swift` file under `OYBCSnapshotTests/`.
2. Reuse builders from `SnapshotFixtures.swift` (extend it before duplicating).
3. Use `record: SnapshotTestingConfiguration.Record? = .missing` so first runs auto-record without manual flag-flipping.
4. Render via `assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: <height>)), record: recordMode)`. Avoid `.device(config:)` — explicit fixed dimensions are more stable across machines.
5. If the surface uses `BoardWizardViewModel`, set `controller.isRandomized = false` — randomized placement breaks snapshot determinism.
6. `xcodegen generate` so the new file is picked up.
7. Run once to record the baseline; re-run to confirm green.

**Sharp edges:**
- **Xcode/iOS drift**: simulator iOS upgrades (or jumping Xcode majors) shift font kerning + glyph metrics. CI pins Xcode 26.3 via `DEVELOPER_DIR` in `ios.yml`; `OS=latest` resolves deterministically to whichever iOS ships with that Xcode. Bumping the pin is a deliberate event — change the Xcode path in `ios.yml`, re-record baselines locally on the matching Xcode, commit both in one PR. Re-record locally with `xcodebuild test -scheme OYBCSnapshotTests -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'` after deleting the affected `__Snapshots__/.../*.png` and running `xcodegen generate` (the test target lists baselines as bundle resources — deleting them and re-running while leaving the project stale produces a hard build error).
- **CI override of `record: .missing`**: `.github/workflows/ios.yml` sets `SNAPSHOT_TESTING_RECORD=never` before invoking the snapshot scheme. The library checks the env var ahead of any per-call `record:` setting, so an absent baseline fails loudly on CI instead of silently auto-recording an ephemeral PNG. Don't change this — the per-call `.missing` is the right local default; the env override is the right CI default. On CI failure the `xcresult` bundle is uploaded as the `snapshot-test-results` artifact (7-day retention) so the failure-candidate PNGs can be pulled and compared without re-running.
- **`AppDatabase.shared`**: views that query the production database singleton (e.g., `BoardPlayView`) are not yet covered — they'd need either an injected database or per-test seeding of `.shared`. Until the harness is refactored, prefer snapshotting the leaf views (which take props) over containers that query the DB.
- **`@EnvironmentObject AuthService`**: views that depend on auth state require either the `-bypassAuth` runtime arg or a stub injection via `.environmentObject(...)`. Easiest path is to snapshot inner step views directly rather than the auth-gated wrappers.
- **Counter-suffixed filenames**: baselines use `<test>.1.png` (the `.1` is a per-test counter from swift-snapshot-testing). Don't strip the `.1` — the library uses the full filename to look up baselines.
- **xcodebuild prints "TEST FAILED" on success**: a `simctl` PATH warning at process exit can produce a spurious "TEST FAILED" line even when all tests passed. Trust the per-test "passed (Xs)" lines, not the trailing message.

## Feature Implementation Guidelines

**Playground-first, one feature at a time, user-driven.** Use `/feature` skill for the full workflow.

**Core Principles**:

- ONE feature at a time — user picks what to build.
- Playground before integration — no production code without explicit user approval.
- **Build real components, not demos** — Playground features must use production-ready reusable components from `components/` / `Views/Components/`. The Playground is a testing harness, not a place for throwaway inline UI. If a component doesn't exist yet, create it as a reusable component first, then use it in the Playground.
- Mirror file structure — every playground feature is a separate file on both platforms. Container views stay thin.
- Reuse existing infrastructure — shared constants in `playgroundUtils.ts` / `PlaygroundUtils.swift`, reusable components in `components/playground/` / `Views/Components/`.

**Standard Development Process**: Ask clarifying questions first. Create a branch per feature/bugfix. TDD approach. Plan before implementing.

**Workflow Skills**:

- `/feature` — New feature development (Playground-first, Two-Gate)
- `/bugfix` — Diagnose and fix bugs (systematic debugging, plugin verification)
- `/refactor` — Restructure code without changing behavior (safety verification)
- `/integrate` — Move approved Playground features into production (Two-Gate, highest risk)

## Agent Guidelines

- Simple features (< 100 lines): single agent. Don't over-agent.
- Complex cross-platform features: use `cross-platform-coordinator` to orchestrate `react-web-implementer` (web) + `steve-jobs` (iOS).
- **Two-Gate System**: Gate 1 (plan approval by user) and Gate 2 (final review by user after automated verification). Both mandatory.
- **Plugin-driven verification** replaces manual agent reviews:
  - **Serena**: Code navigation, scope verification (compare implemented symbols vs plan), reusable component discovery.
  - **Playwright**: Mandatory web UI validation — navigate playground, interact, screenshot. Saves to `.playwright-mcp/`.
  - **Context7**: Library documentation lookups during implementation.
- Before delivery: verify BOTH platforms compile, run Playwright validation (web), use `superpowers:verification-before-completion`.
- iOS uses XcodeGen — after adding new `.swift` files, run `xcodegen generate` to regenerate the Xcode project.

### Agents

| Agent                        | Purpose                                                                |
| ---------------------------- | ---------------------------------------------------------------------- |
| `cross-platform-coordinator` | Orchestration, scope control, spec compliance, consistency enforcement |
| `react-web-implementer`      | Web (React) implementation                                             |
| `steve-jobs`                 | iOS (Swift/SwiftUI) implementation                                     |
| `sync-specialist`            | Offline-first sync (Phase 3)                                           |
| `system-design-engineer`     | Complex technical design decisions                                     |
| `ultrathink-debugger`        | Deep root cause analysis for hard bugs                                 |

## Cross-Platform File Structure

Web and iOS must mirror each other's directory and file structure.

```
Web                                                  iOS
apps/web/src/                                        apps/ios/OYBC/
├── pages/
│   └── Playground.tsx          ←→                  Views/PlaygroundView.swift
│       (container only — no feature logic)              (container only)
├── components/
│   └── playground/
│       ├── playgroundUtils.ts  ←→                  Views/Playground/PlaygroundUtils.swift
│       ├── BoardTaskSelectionPlayground.tsx ←→      Views/Playground/BoardTaskSelectionPlayground.swift
│       ├── BoardGeneratorPlayground.tsx ←→          Views/Playground/BoardGeneratorPlayground.swift
│       ├── UnifiedTaskCreatorPlayground.tsx ←→      Views/Playground/UnifiedTaskCreatorPlayground.swift
│       ├── TaskSquareActionsPlayground.tsx ←→       Views/Playground/TaskSquareActionsPlayground.swift
│       ├── CrossBoardRollupPlayground.tsx ←→        Views/Playground/CrossBoardRollupPlayground.swift
│       └── SubtaskDerivationPlayground.tsx ←→       Views/Playground/SubtaskDerivationPlayground.swift
│       (composite-task creation lives in components/compositeWizard/ ←→ Views/Components/CompositeWizard/)
│
└── components/                                     Views/Components/
    ├── Navbar.tsx                 (dev-only)       (no iOS counterpart — iOS launches straight into tabs)
    ├── BingoBoard.tsx          ←→                  BingoBoard.swift
    ├── BingoSquare.tsx         ←→                  BingoSquare.swift
    ├── InteractiveTaskSquare.tsx ←→                 InteractiveTaskSquareView.swift
    ├── TypeBadge.tsx           ←→                  TypeBadgeView.swift
    ├── FilterTabs.tsx          ←→                  FilterTabsView.swift
    ├── TaskTypeSelector.tsx    ←→                  TaskTypeSelectorView.swift
    ├── SelectableTaskItem.tsx  ←→                  SelectableTaskItemView.swift
    ├── PoolItem.tsx            ←→                  PoolItemView.swift
    ├── SubtaskChip.tsx         ←→                  SubtaskChipView.swift
    ├── OperatorSelector.tsx    ←→                  OperatorSelectorView.swift
    ├── CounterStepper.tsx      ←→                  CounterStepperView.swift
    ├── ProgressStepRow.tsx     ←→                  ProgressStepRowView.swift
    ├── CountingStepFields.tsx  ←→                  CountingStepFieldsView.swift
    ├── CountingDerivationPanel.tsx ←→               CountingDerivationPanelView.swift
    ├── ProgressDerivationPanel.tsx ←→               ProgressDerivationPanelView.swift
    ├── CompositeDerivationPanel.tsx ←→              CompositeDerivationPanelView.swift
    ├── AuthGate.tsx               ←→               Views/AuthGateView.swift
    ├── BoardCreatorPanel.tsx      ←→               Views/Components/BoardCreatorPanelView.swift
    ├── BoardStatusBadge.tsx       ←→               Views/Components/BoardStatusBadgeView.swift
    ├── BoardListItem.tsx          ←→               Views/Components/BoardListItemView.swift
    ├── TabBar.tsx                 ←→               Views/MainTabView.swift (SwiftUI TabView — intentionally platform-idiomatic)
    └── SyncStatusIndicator.tsx    ←→               Views/Components/SyncStatusIndicatorView.swift
│
├── firebase/                                       Services/
│   ├── config.ts                  ←→               OYBCApp.swift (FirebaseApp.configure)
│   ├── authService.ts (pure fns)  ←→               Services/AuthService.swift (ObservableObject — platform-idiomatic)
│   ├── AuthContext.tsx            ←→               (AuthService is @ObservableObject)
│   ├── syncService.ts (fns)       ←→               Services/SyncService.swift (ObservableObject — platform-idiomatic)
│   ├── syncStatus.ts             ←→                (inline @Published on SyncService.swift)
│   └── conflictResolver.ts       ←→                (inline in SyncService.swift)
│                                                   Services/NetworkMonitor.swift (iOS only, NWPathMonitor)
│
└── components/playground/
    └── SyncSimulationPlayground.tsx ←→             Views/Playground/SyncDashboardPlayground.swift
```

### Pages ↔ Root Views

Top-level React-Router pages and their iOS root-view counterparts.

```
apps/web/src/pages/                               apps/ios/OYBC/Views/
├── Home.tsx                      (dev-only)     (no iOS counterpart — auth-gate → MainTabView)
├── BoardsPage.tsx             ←→                Views/BoardsTab/BoardListView.swift
├── BoardPlayPage.tsx          ←→                Views/BoardsTab/BoardPlayView.swift
├── CreateHubPage.tsx          ←→                Views/CreateTab/CreateHubView.swift
├── BoardWizardPage.tsx        ←→                Views/CreateTab/BoardWizardView.swift
├── TasksPage.tsx              ←→                Views/TasksTab/TasksTabView.swift
├── TaskDetailPage.tsx         ←→                Views/TasksTab/TaskDetailView.swift
├── ProfilePage.tsx            ←→                Views/ProfileTab/ProfileView.swift
├── BoardPreferencesPage.tsx   ←→                Views/ProfileTab/BoardPreferencesView.swift
└── Playground.tsx             ←→                Views/PlaygroundView.swift
```

### Intentional platform divergences (don't treat as parity bugs)

- `Navbar.tsx` / `Home.tsx` are web-only: React Router boots to `/home`, while iOS launches `AuthGateView` → `MainTabView` directly.
- `TabBar.tsx` is an HTML `<nav>` + NavLinks; `MainTabView.swift` uses SwiftUI `TabView`. Same UX, platform-native implementation.
- `authService.ts` exports pure async functions; iOS `AuthService` is an `@ObservableObject` to integrate with SwiftUI's state model. Same behavior and sign-out semantics on both.
- `syncService.ts` uses module-level functions + a React hook for orchestration; iOS embeds orchestration in a `@MainActor ObservableObject` bound to `AuthService`'s lifecycle. Same push/pull/LWW rules, same collection list — when you change one, mirror the other in the same PR.
- **Create Hub + board wizard**: web `components/wizard/*` + `components/createHub/*` + `pages/createHub/useBoardWizard.ts` ←→ iOS `Views/CreateTab/Components/*` + `ViewModels/BoardWizardViewModel.swift`. Non-obvious bits: `useDrafts.ts` has no iOS twin (iOS inlines the GRDB query in `CreateHubView.reloadDrafts()`, reloading on `.onAppear` + after wizard dismiss, since SwiftUI lacks `useLiveQuery`); `wizardPersist.ts` ←→ `BoardWizardPersist.swift` is a helper not a view (so iOS keeps it in `Views/CreateTab/`, not `Components/`), both exporting `buildWizardPlacement` / `resolveWizardDates` / `persistWizardBoard`.
- **Composite-task mini-wizard**: `components/compositeWizard/*` ←→ `Views/Components/CompositeWizard/*` — a 3-step Setup → Build → Review flow that replaced the legacy ~850-line `CompositeTaskForm` monoliths (same data model + write path). The Build step uses an always-visible inline library section (search + filter tabs + checkbox rows), matching the board wizard's Tasks step; the old modal `LibraryPickerSheet` is retired.
- **Tasks tab**: `pages/TasksPage.tsx` ←→ `Views/TasksTab/TasksTabView.swift` (library list, search + type chips + status/usage/sort). The filter pipeline is shared in spirit but implemented per platform; the `BoardWizardTasksStep` row renderer is intentionally *not* shared (entangled with selection / center-pinning). Achievement shows on the Tasks-tab filter chips even though it's hidden from the wizard row. `TaskDetailPage` ←→ `TaskDetailView` covers per-task stats / inline edit / cascade delete. **Cascade delete**: `deleteTaskWithCascade(id)` (web `db/operations/tasks.ts`, iOS `AppDatabase.swift`) hard-deletes BoardTask rows, soft-deletes CompoundChild links both directions, then soft-deletes the Task — atomically; `computeTaskDeletionImpact(id)` is the read-only preview for the confirm dialog (Achievement tasks reference boards/templates, not tasks, so they skip the task-side cascade). **Quick-add** (`CreateHubQuickAdd*`) now lives atop the Tasks tab, not the Create hub (which is board-creation only).
- **Core board window pager**: tapping a Core board on the Boards screen opens the current window's board (web route `/boards/core/:timeframe/:date` → `CoreBoardWindowPage`; iOS `CoreWindowRoute` → `CoreBoardWindowView`), with prev/next paging windows in place and a `≡ list` button to the existing browser. Empty windows show a lazy setup prompt (no board row until the user acts). **Web extracts `BoardPlaySurface`** from `BoardPlayPage` and reuses it in both the `/boards/:id` page and the pager; **iOS embeds `BoardPlayView` whole behind an `embedded` flag** (the 1350-line view self-loads by `boardId`, so embedding beats extraction). Date-only route params are parsed as local noon, not `new Date(dateStr)` (UTC parse shifts the day west of UTC). See [ARCHITECTURE.md §Phase 6](docs/ARCHITECTURE.md).
- **Wizard "From a board" picker** (in flight, branch `feature/wizard-from-a-board`): Step 2 of the board wizard gets a new `From a board…` filter chip alongside `From parent boards`. Tapping it swaps the list region for a mini-grid source-board picker; tapping a card swaps to that board's actual grid. Per-square: tap = Link (shared completion, no new Task), long-press = context menu reusing the existing `RowContextMenu` / SwiftUI `.contextMenu` vocabulary verbatim, with one new item `⎘ Add a copy of this task…` that opens a type-aware Copy modal (Achievement copies route through `hasCycle` from `@oybc/shared`). Visual state is color/border only — no overlay text on squares. Canonical doc: [ARCHITECTURE.md §Wizard "From a board" picker](docs/ARCHITECTURE.md#wizard-from-a-board-picker).

**Rules**:

1. Container views stay thin — no form logic, no state, no database calls.
2. One file per playground feature, one file per reusable component.
3. Web: `[Name].tsx`. iOS: `[Name]View.swift` (views) or `[Name]Playground.swift` (features).
4. iOS: After adding new Swift files, run `xcodegen generate` to regenerate the Xcode project.
5. Verify both platforms have matching files before claiming completion.
6. **No single-platform commits for shared features.** Every commit that changes user-visible behaviour, shared types, hooks, or services must either (a) land the paired change on both platforms in the same commit, or (b) explicitly justify the gap in the commit message and record the platform-parity follow-up in `CLAUDE.md` (or a tracked note). "I'll do the other platform next" is exactly the drift mode to avoid — during back-to-back UI iterations it is easy to rack up web-only changes and discover hours later that iOS is several commits behind. If you catch yourself doing this, stop and mirror before continuing.

## Commands

### Monorepo (Root)

```bash
pnpm install    # Install all dependencies
pnpm build      # Build all packages
pnpm test       # Run all tests
pnpm lint       # Lint all packages
pnpm clean      # Clean all build artifacts
```

### Shared Package (`packages/shared`)

```bash
cd packages/shared
pnpm build          # Build types and validation
pnpm dev            # Watch mode
pnpm test           # Run tests
pnpm test:watch     # Watch mode for tests
pnpm test:coverage  # Coverage report
```

### Web App (`apps/web`)

```bash
cd apps/web
pnpm dev        # Dev server (http://localhost:5173)
pnpm build      # Production build
pnpm preview    # Preview production build
pnpm typecheck  # Type checking
pnpm lint       # Lint
```

### iOS App (`apps/ios`)

```bash
open OYBC.xcodeproj          # Open in Xcode
# Build: ⌘R  |  Tests: ⌘U
xcodegen generate            # Regenerate project from project.yml
xcodebuild -scheme OYBC build  # CLI build (simulator)
```

### Firebase

```bash
firebase login                           # Authenticate CLI (one-time)
firebase deploy --only firestore:rules   # Deploy security rules
```

**Setup**: Firebase config is in `.env.local` (web, gitignored) and `GoogleService-Info.plist` (iOS, gitignored). Each developer must obtain these from the Firebase console.

## Architecture

### Monorepo Structure

```
oybc/
├── apps/
│   ├── ios/           # SwiftUI + GRDB 6.24 (SQLite), iOS 17+, XcodeGen (project.yml)
│   │                  # + Firebase Auth/Firestore (SPM)
│   └── web/           # React 18 + Vite + Dexie (IndexedDB) + React Router
│                      # + Firebase JS SDK (auth, firestore, sync)
├── packages/
│   └── shared/        # TypeScript types, algorithms, validation
├── firestore.rules    # Firestore security rules (deployed via firebase CLI)
└── docs/              # Architecture documentation
```

### Offline-First Design Principle

**Critical**: Local databases are the **source of truth**, NOT Firestore.

**Data Flow**: User action → Update local DB (< 10ms) → UI updates immediately → Queue sync → Background sync to Firestore when online.

**NOT**: ~~User action → Network request → Wait → Update UI~~

### Database Schema (Identical Across Platforms)

**Tables**: `users`, `boards`, `tasks`, `compound_children`, `board_tasks`, `progress_counters`, `sync_queue`. Legacy `task_steps` / `composite_tasks` / `composite_nodes` linger in old migrations for first-launch backfill only — no live reads/writes (see top-of-doc Task model section).

**Key Design Elements**:

- UUID primary keys (client-generated, enables offline creation)
- Version fields (optimistic locking for conflict resolution)
- Soft deletes (`isDeleted` flag, never hard delete)
- ISO8601 timestamps
- Denormalized stats (`board.completedTasks` for instant reads)

### Type System

**`packages/shared`** is the single source of truth for types: `Board`, `Task`, `CompoundChild`, `BoardTask`, `ProgressCounter`, `User`, `SyncQueueItem`. Includes Zod schemas and enums (`BoardStatus`, `TaskType` = `NORMAL` / `COUNTING` / `COMPOUND` / `ACHIEVEMENT`, `Timeframe`, `CenterSquareType`). Legacy `TaskStep` / `CompositeTask` types persist for migration reads only.

- **iOS**: Swift models mirror TypeScript types using GRDB's `Codable`/`FetchableRecord`/`PersistableRecord`. JSON arrays stored as strings in SQLite.
- **Web**: Dexie uses TypeScript types directly from `@oybc/shared`. Compound indexes match iOS GRDB indexes.

### Sync Strategy

**Conflict Resolution** (MVP): Last-write-wins using version fields. Higher version wins; same version → newer timestamp wins.

**Cross-Board Features**: Achievement squares and bingo lines always recomputed from source data. Task step linking uses additive merge.

See `docs/SYNC_STRATEGY.md` for details.

## Key Conventions

### iOS (Swift)

```swift
// Read
let boards = try AppDatabase.shared.fetchBoards(userId: userId)
// Write
try AppDatabase.shared.saveBoard(board)
// Transaction
try AppDatabase.shared.write { db in
    try task.save(db)
    try children.forEach { try $0.save(db) }
}
```

- JSON arrays stored as JSON strings with custom `Codable` encode/decode
- Don't store derived values — compute from stored values

### Web (TypeScript)

```typescript
// Read
const boards = await fetchBoards(userId);
// Reactive queries
const boards = useBoards(userId); // useLiveQuery from dexie-react-hooks
// Fast compound index query
db.boards.where("[userId+isDeleted]").equals([userId, false]);
// Transaction
await db.transaction("rw", [db.tasks, db.compoundChildren], async () => {
  await db.tasks.add(task);
  await Promise.all(children.map((c) => db.compoundChildren.add(c)));
});
```

### Shared Package

- No platform-specific code (no GRDB, Dexie, Firebase, React, SwiftUI)
- Only pure TypeScript: types, algorithms, validation, constants

## Important Patterns

- **Optimistic Updates**: Always update local DB first, then queue sync in background.
- **Soft Deletes**: Never hard delete. Use `isDeleted=true, deletedAt=timestamp`.
- **Denormalized Stats**: Update stats when source data changes (e.g., `board.completedTasks`).
- **Version Increment**: Always increment `version` field on updates (critical for conflict resolution).
- **Atomic pull-path multi-writes**: When a sync pull does fetch + upsert + cross-board cascade (or any multi-step write), thread the `db: Database` (iOS) / pass-through inside `db.transaction('rw', [...], async () => { ... })` (web) so all writes share one transaction. A cascade-fail then rolls back the upsert; the safety-net pull retries cleanly. Don't run cascade in a separate write block with a `try/catch` that swallows — that's silent divergence with no recovery.

## Common Pitfalls

- **Don't skip verification gates**: Both gates (plan approval + final review) are mandatory. Playwright validation is mandatory for web changes.
- **Don't skip the Playground**: ALL features go through Playground first with explicit user approval.
- **Don't implement multiple features at once**: ONE at a time, user-directed.
- **Don't copy from old code**: If archived/legacy code exists, it's reference only.
- **Don't use Firestore as primary storage**: Local DB is source of truth.
- **Don't trust denormalized values during conflicts**: Recompute from source data.
- **Counting task field order**: Action → Max Count → Unit (not Action → Unit → Max Count).
- **Counting task title**: Optional and auto-generated from `action + maxCount + unit` if blank. Use `generateCounterTaskTitle()` from `@oybc/shared`. Not required like normal task titles.
- **Compound child auto-creation**: creating a compound task with inline subtasks creates a standalone `Task` per subtask, linked via `compound_children.childTaskId`, so subtasks are immediately pool-addable and enable cross-board rollup. Applies to `createTask()` (web), playground write blocks (iOS), and `CompositeTaskWizard` inline subtasks.
- **iOS `Task` name clash**: OYBC has a `Task` data model (`Database/Models/Task.swift`) that shadows Swift Concurrency's `Task`. When launching an async closure, ALWAYS write `_Concurrency.Task { ... }` explicitly. Plain `Task { ... }` will fail to compile with `trailing closure passed to parameter of type 'any Decoder' that does not accept a closure` because Swift picks the OYBC type's `init(from decoder:)` instead. This bit PR #32; grep `^\s*Task\s*{` before committing new Swift files that launch tasks.
- **Recurring-board invariants**: shared-task semantics (completing a derived daily task globally completes its parent monthly — no clones) and lazy detection-only (no `BGTaskScheduler` / service-worker scheduling; the banner appears on Boards-tab open). Both are spelled out in [§Recurring Boards](#recurring-boards-phase-6--shipped) — re-read before touching recurrence.

## Performance Targets

- Local reads/writes: < 10ms
- Bingo detection: < 50ms
- Cross-board queries: < 200ms
- Sync: background only, never block UI

## Documentation

- `docs/ARCHITECTURE.md` — Technical plan, development phases (now includes **Phase 6: Recurring Boards** design)
- `docs/OFFLINE_FIRST.md` — Offline-first design and data flow
- `docs/SYNC_STRATEGY.md` — Conflict resolution patterns
- `docs/TASK_SYSTEM.md` — Comprehensive task system documentation (Normal / Counting / Compound; cross-board square mechanisms live on `BoardTask`, see ARCHITECTURE.md §Phase 6)

The `docs/superpowers/specs/` folder is **not in active use** — design docs for in-flight work live in CLAUDE.md and ARCHITECTURE.md instead. The legacy `2026-04-23-compound-tasks-unification-design.md` was the precursor for the unification work shipped in PR #43; the current canonical doc is `docs/TASK_SYSTEM.md`.

**Not yet configured**: Prettier, SwiftLint.

## CI/CD

Three GitHub Actions workflows run on PRs to `dev` and on merge:

| Workflow | File | Trigger |
| --- | --- | --- |
| **Web** | `.github/workflows/web.yml` | PRs/pushes touching `apps/web/`, `packages/shared/`, lockfile, turbo config |
| **iOS** | `.github/workflows/ios.yml` | PRs/pushes touching `apps/ios/` |
| **Firestore rules** | `.github/workflows/firestore-rules.yml` | Push to `dev` touching `firestore.rules` / `firestore.indexes.json` (deploy only, no PR trigger) |

**Dependabot** (`.github/dependabot.yml`): npm weekly (minor/patch grouped, majors separate), GitHub Actions monthly. SPM not supported — iOS deps bumped manually.

**Copilot code review**: request on PRs via `gh api --method POST repos/{owner}/{repo}/pulls/{n}/requested_reviewers --input - <<< '{"reviewers":["Copilot"]}'`. Address review comments before merging.

**Addressing review comments**: each round of PR review (Copilot or human), **print a markdown table in the terminal response** (columns `Comment | Severity | Remedy`, one row per comment) showing what was flagged and what was done. Display-only and fresh per round — never put it in commit messages, PR descriptions, or CLAUDE.md.

- **Comment**: short restatement (≤ 1 sentence) + file/line pointer.
- **Severity**: `Critical` (correctness/security/data loss) · `Major` (happy-path bug, significant UX/a11y regression) · `Minor` (nit-level bug, stale-state edge, code smell) · `Nit` (style/naming/wording).
- **Remedy**: the fix in ≤ 1 sentence, or `Declined — <reason>`. Declining is fine; silent dismissal is not.

**pnpm version**: pinned to 9.15.4 via `package.json#packageManager`. CI uses `pnpm/action-setup@v6`, which reads the version from `packageManager` and ignores any `version:` workflow input — so the workflows don't set one. To bump the pnpm major across local + CI, change the `packageManager` field; the workflows pick it up automatically.

## Development Status

**Phases 1–6 are complete/shipped:** local DB (1), app infrastructure (1.5), core game loop (2), auth + Firestore sync (3), tab-based production app (4), polish (5), recurring boards (6 — see [§Recurring Boards](#recurring-boards-phase-6--shipped) for the sub-phase table + PRs).

**Navigation**: bottom tab bar — Boards (default), Tasks, Create, Profile.

**Routes (web)**: `/boards`, `/boards/:id`, `/tasks`, `/tasks/:id`, `/create`, `/profile`, `/profile/board-preferences`, `/profile/recurring-templates`, `/playground` (dev tool).

### Known follow-ups

- Web has no Jest/Vitest harness yet; `packages/shared` covers cross-platform logic. Adding web-layer tests is tracked for the next tooling pass.
- CAPTCHA / rate-limit hardening on auth flows — pre-public-launch only.
- **iOS snapshot tests are advisory in CI** (`continue-on-error: true` on the snapshot step in `ios.yml`). The macos-15 runner ships Xcode 26.3 with iOS 26.0/26.1/26.2 simulators (no 26.3), while local dev uses iOS 26.3.x — pixel kerning differs across the iOS minor, so baselines recorded locally don't match CI byte-for-byte. The xcresult artifact still uploads on every snapshot diff, so a developer can pull it and re-record when convenient. To re-enable strict mode: either (a) wait for a macos-15 runner image refresh that ships iOS 26.3, then drop `continue-on-error`; or (b) install iOS 26.2 simulator runtime locally (~5 GB, requires freeing space on `/Library/Developer/CoreSimulator/Volumes/`), re-record on `OS=26.2`, commit baselines, drop `continue-on-error`.

**Next phase**: TBD — no Phase 7 scoped. Pick the next item from Known follow-ups (web Vitest harness, CI snapshot strict-mode, CreatePage/CreateView refactors, pre-launch hardening) by directive, not inferred roadmap.

## Branching Strategy

- Feature branches: `feature/feature-name`
- Bugfix branches: `bugfix/bug-description`
- Merge to `dev` only after CI passes (web + iOS workflows) and Copilot review is addressed.
- Dependabot PRs: review CI results, resolve lockfile conflicts via `git checkout --theirs pnpm-lock.yaml && pnpm install`, merge in dependency order (Actions bumps first, then lockfile-touching bumps sequentially).
- When pushing to a dependabot branch, dependabot refuses auto-rebase ("edited by someone other than Dependabot") — manual rebase required for subsequent merges.

