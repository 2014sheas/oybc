# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OYBC (On Your Bingo Card) — An offline-first, gamified task management app that turns goals into interactive bingo boards. Multi-platform (iOS native + web) with seamless offline functionality and background sync.

**Core Architecture**: Local-first design where local databases (GRDB on iOS, Dexie on web) are the source of truth, with Firestore providing background sync for multi-device support only.

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
├── CreatePage.tsx             ←→                Views/CreateTab/CreateView.swift
├── ProfilePage.tsx            ←→                Views/ProfileTab/ProfileView.swift
├── BoardPreferencesPage.tsx   ←→                Views/ProfileTab/BoardPreferencesView.swift
└── Playground.tsx             ←→                Views/PlaygroundView.swift
```

### Intentional platform divergences (don't treat as parity bugs)

- `Navbar.tsx` / `Home.tsx` are web-only: React Router boots to `/home`, while iOS launches `AuthGateView` → `MainTabView` directly.
- `TabBar.tsx` is an HTML `<nav>` + NavLinks; `MainTabView.swift` uses SwiftUI `TabView`. Same UX, platform-native implementation.
- `authService.ts` exports pure async functions; iOS `AuthService` is an `@ObservableObject` to integrate with SwiftUI's state model. Same behavior and sign-out semantics on both.
- `syncService.ts` uses module-level functions + a React hook for orchestration; iOS embeds orchestration in a `@MainActor ObservableObject` bound to `AuthService`'s lifecycle. Same push/pull/LWW rules, same collection list — when you change one, mirror the other in the same PR.
- **Composite-task mini-wizard** (feature):
  - `components/compositeWizard/{CompositeTaskWizard,CompositeWizardStepper,SetupStep,BuildStep,ReviewStep,SubtaskCard,LibraryPickerSheet,compositeSubtaskDraft}.tsx/.ts` ←→ `Views/Components/CompositeWizard/{CompositeTaskWizardView,CompositeWizardStepperView,CompositeWizardSetupStepView,CompositeWizardBuildStepView,CompositeWizardReviewStepView,CompositeSubtaskCardView,LibraryPickerSheetView,CompositeSubtaskItem}.swift`.
  - Replaced the legacy ~850-line `CompositeTaskForm.tsx` / `CompositeTaskFormView.swift` monoliths with a 3-step Setup → Build → Review flow. Same data model + write path, better UX (live validation, type-switch confirm, threshold clamp toast, library callout).

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

**Tables**: `users`, `boards`, `tasks`, `task_steps`, `board_tasks`, `progress_counters`, `sync_queue`

**Key Design Elements**:

- UUID primary keys (client-generated, enables offline creation)
- Version fields (optimistic locking for conflict resolution)
- Soft deletes (`isDeleted` flag, never hard delete)
- ISO8601 timestamps
- Denormalized stats (`board.completedTasks` for instant reads)

### Type System

**`packages/shared`** is the single source of truth for types: `Board`, `Task`, `TaskStep`, `BoardTask`, `ProgressCounter`, `User`, `SyncQueueItem`. Includes Zod validation schemas and enums (`BoardStatus`, `TaskType`, `Timeframe`, `CenterSquareType`).

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
    try steps.forEach { try $0.save(db) }
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
await db.transaction("rw", [db.tasks, db.taskSteps], async () => {
  await db.tasks.add(task);
  await Promise.all(steps.map((s) => db.taskSteps.add(s)));
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

## Common Pitfalls

- **Don't skip verification gates**: Both gates (plan approval + final review) are mandatory. Playwright validation is mandatory for web changes.
- **Don't skip the Playground**: ALL features go through Playground first with explicit user approval.
- **Don't implement multiple features at once**: ONE at a time, user-directed.
- **Don't copy from old code**: If archived/legacy code exists, it's reference only.
- **Don't use Firestore as primary storage**: Local DB is source of truth.
- **Don't hard delete**: Always soft delete for sync compatibility.
- **Don't trust denormalized values during conflicts**: Recompute from source data.
- **Don't block UI for sync**: All sync operations must be background/async.
- **Counting task field order**: Action → Max Count → Unit (not Action → Unit → Max Count).
- **Counting task title**: Optional and auto-generated from `action + maxCount + unit` if blank. Use `generateCounterTaskTitle()` from `@oybc/shared`. Not required like normal task titles.
- **Progress task step auto-creation**: When a progress task is created, each step automatically gets a standalone `Task` record linked via `TaskStep.linkedTaskId`. This makes steps immediately available as pool-addable tasks and enables cross-board rollup. Applies to `createTask()` (web), playground write blocks (iOS), and `CompositeTaskWizard` inline progress subtasks.
- **iOS `Task` name clash**: OYBC has a `Task` data model (`Database/Models/Task.swift`) that shadows Swift Concurrency's `Task`. When launching an async closure, ALWAYS write `_Concurrency.Task { ... }` explicitly. Plain `Task { ... }` will fail to compile with `trailing closure passed to parameter of type 'any Decoder' that does not accept a closure` because Swift picks the OYBC type's `init(from decoder:)` instead. This bit PR #32; grep `^\s*Task\s*{` before committing new Swift files that launch tasks.

## Performance Targets

- Local reads/writes: < 10ms
- Bingo detection: < 50ms
- Cross-board queries: < 200ms
- Sync: background only, never block UI

## Documentation

- `docs/ARCHITECTURE.md` — Technical plan, development phases
- `docs/OFFLINE_FIRST.md` — Offline-first design and data flow
- `docs/superpowers/specs/` — Feature design specs (created during `/feature` planning phase)
- `docs/SYNC_STRATEGY.md` — Conflict resolution patterns
- `docs/TASK_SYSTEM.md` — Comprehensive task system documentation
- `docs/COMPOSITE_TASKS.md` — Composite/progress task system details

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

**Addressing review comments**: every round of PR review comments — from Copilot or a human reviewer — must be logged as a markdown table in the **PR Review Log** section at the bottom of this file. Never in the commit body. One row per comment, columns: `Comment`, `Severity`, `Remedy`.

- **Comment**: short restatement (≤ 1 sentence) + file/line pointer. Enough for a future reader to find the thread without scrolling the PR.
- **Severity**: one of `Critical` (correctness, security, data loss), `Major` (bug in happy path, significant UX regression, a11y blocker), `Minor` (nit-level bug, stale-state edge case, code-quality smell), `Nit` (style, naming, comment wording).
- **Remedy**: either the fix description in ≤ 1 sentence, or `Declined — <reason>` if we chose not to act. Declining is fine; silent dismissal is not.

Rationale: keeps review outcomes greppable in-tree (CLAUDE.md is always open), makes declined comments explicit instead of invisible, and gives future reviewers a quick read on what the previous round landed on.

**pnpm version**: pinned to 9.15.4 via `package.json#packageManager`. CI uses `pnpm/action-setup@v4` with explicit `version: 9.15.4` (v6 of the action ignores the version input).

## Development Status

**Phase 1**: Local Database Setup — COMPLETE
**Phase 1.5**: Working App Infrastructure — COMPLETE (web + iOS + Playground + BingoSquare)

**Phase 2**: Core Game Loop — COMPLETE (all features playground-tested)

| #   | Feature                                | Status   |
| --- | -------------------------------------- | -------- |
| 1   | 5x5 Bingo Board Grid                  | COMPLETE |
| 2   | Different Board Sizes (3x3, 4x4, 5x5) | COMPLETE |
| 3   | Bingo Detection Logic                 | COMPLETE |
| 4   | Board Randomization                   | COMPLETE |
| 5   | Center Space Logic                    | COMPLETE |
| 6   | Tasks & Task Creation                 | COMPLETE |
| 7   | Celebrations & Polish                 | SKIPPED  |

Playground-tested features: unified task creator, composite tasks, board generator, task square actions, subtask system (SF1-SF4), board task selection, cross-board rollup, board lifecycle (creation → activation → bingo detection → greenlog), timeboxed boards (calendar boundaries, expiry), uncomplete cascade.

**Phase 3**: Authentication & Sync Layer — COMPLETE

| Feature                    | Status   |
| -------------------------- | -------- |
| Firebase Auth (email/pw)   | COMPLETE |
| Google Sign-In             | COMPLETE |
| Sign in with Apple         | COMPLETE |
| Firestore sync (push/pull) | COMPLETE |
| LWW conflict resolution    | COMPLETE |
| Sync queue integration     | COMPLETE |
| Firestore security rules   | COMPLETE |
| Sync playground section    | COMPLETE |

**Phase 4**: Production Integration — COMPLETE

Tab-based app with auth gate. Web + iOS built simultaneously.

**Navigation**: Bottom tab bar — Boards (default), Create, Profile.

| Phase | Feature | Status |
| ----- | ------- | ------ |
| 0 | Synced user preferences (7 preference fields → Firestore) | COMPLETE |
| 1 | Auth shell + tab bar (replace "Hello OYBC" with auth-gated tabs) | COMPLETE |
| 2 | Board list (filtering, progress indicators, tap to navigate) | COMPLETE |
| 3 | Board play (bingo grid, task completion, flash messages) | COMPLETE |
| 4 | Create tab (task pool + BoardCreatorPanel) | COMPLETE |
| 5 | Profile + settings + polish | COMPLETE |

**Routes (web)**: `/boards`, `/boards/:id`, `/create`, `/profile`, `/profile/board-preferences`, `/playground` (dev tool)

**Current Phase**: Phase 5 — Polish & Launch

| Feature | Status |
| --- | --- |
| Sign-out confirmation dialog (web + iOS) | COMPLETE |
| Empty states on Create tab | COMPLETE |
| Display name edit (Firebase Auth + local DB + sync) | COMPLETE |
| Sync status indicator (online/offline, error, Sync Now) | COMPLETE |
| iOS NetworkMonitor (NWPathMonitor) | COMPLETE |
| Pre-phase6 audit (architecture + security + parity) | COMPLETE |

### Pre-phase6 audit outcome

Three parallel audits (architecture/code-quality, security, cross-platform parity) ran before starting Phase 6. Critical findings were fixed in branch `fix/pre-phase6-audit` across four commits:

- **A — LWW delete integrity + Zod pull validation + rules userId pin.** Soft deletes on both platforms now increment `version`. Web pull validates every remote doc via its Zod schema; iOS pull validates version + userId scope. Firestore rules require `payload.userId == path.userId` on user-scoped subcollection writes.
- **B — log userId scrub, dev-gated playground short-circuit, sync abandonment warnings, SyncDashboard relocation.**
- **C — CLAUDE.md parity map updated + `_Concurrency.Task` shadow CI guard.**
- **D3 — iOS `BingoDetection` unit tests** (parity with shared TS coverage).

### Known follow-ups (not blockers for Phase 6)

- `CreatePage.tsx` (972 LOC) and `CreateView.swift` (1030 LOC) violate the "containers stay thin" rule. Tracked as future `refactor/create-page-hooks` + `refactor/create-view-viewmodels` branches — no sync/correctness impact, just makes adding form fields easier.
- Web has no Jest/Vitest harness yet; `packages/shared` covers cross-platform logic. Adding web-layer tests is tracked for the next tooling pass.
- CAPTCHA / rate-limit hardening on auth flows — pre-public-launch only.

## Branching Strategy

- Feature branches: `feature/feature-name`
- Bugfix branches: `bugfix/bug-description`
- Merge to `dev` only after CI passes (web + iOS workflows) and Copilot review is addressed.
- Dependabot PRs: review CI results, resolve lockfile conflicts via `git checkout --theirs pnpm-lock.yaml && pnpm install`, merge in dependency order (Actions bumps first, then lockfile-touching bumps sequentially).
- When pushing to a dependabot branch, dependabot refuses auto-rebase ("edited by someone other than Dependabot") — manual rebase required for subsequent merges.

## PR Review Log

Append tables for each PR that receives review comments. Most recent PR first; multiple review rounds on the same PR get their own table under a **Round N** heading. Leave the fix commit SHA next to the round heading so the mapping from review → code is obvious.

### PR #41 — composite task wizard: 3-step flow + multi-add library sheet

#### Round 1 (fix: `4b0d31c`)

| Comment | Severity | Remedy |
| --- | --- | --- |
| `readyCount` / `canAdvance` don't recompute when a `SubtaskItem`'s `@Published` fields change — status + Next button stick (`CompositeWizardBuildStepView.swift:68`). | Major | Added `CompositeSubtaskList` `ObservableObject` wrapper that re-broadcasts each child's `objectWillChange`; wizard + BuildStep now observe it instead of `[SubtaskItem]`. |
| Inline counting subtask with blank title saves `"Untitled"` instead of the derived `action+max+unit` (diverges from web + primary createTask) (`CompositeTaskWizardView.swift:347`). | Minor | Derive the same `action+max+unit` fallback inside the composite save path. |
| Inline progress subtasks save steps with `linkedTaskId: nil` and `"Untitled Step"`; other create flows make a standalone `Task` per step + link it and derive counting step titles (`CompositeTaskWizardView.swift:377`). | Minor | Mirror the primary `createTask` path: per-step standalone Task, `TaskStep.linkedTaskId` wired, counting-blank titles resolved via `action+max+unit`. |
| `showClampToast` setTimeout never cleared on unmount — setState on disposed component risk (`CompositeTaskWizard.tsx:94`). | Minor | Added `useEffect` cleanup that clears `clampTimerRef.current` on unmount. |

#### Round 3 — user-reported UX (fix: pending)

| Comment | Severity | Remedy |
| --- | --- | --- |
| Threshold stepper on Setup is capped at `max(1, subtaskCount)`, so with 0 subtasks the user is pinned at 1 and the round-2 "clamp on operator change" fires a spurious `Threshold lowered to 1` toast. Users end up bouncing back from Build to Setup just to pick N. | Major (UX) | Removed the subtask-count cap — Setup stepper now accepts any reasonable N upfront (soft cap `max(20, subtaskCount, threshold)`). Threshold becomes a pure user-intent value: no auto-clamp, no toast. Build step instead shows `Add N more subtasks — you picked "At least X of"` and blocks `Next` until the count catches up. Removes the unused clamp effect (web) / `.onChange(of: subtasks.count)` hook (iOS) and all `clampToast` plumbing on both platforms. |

#### Round 2 (fix: `c862663`)

| Comment | Severity | Remedy |
| --- | --- | --- |
| Threshold stepper can render out-of-range (`2 of 1`) if user flips to `M_OF_N` before adding subtasks (`SetupStep.tsx:53`). | Minor | Added `useEffect([subtasks.length, operator])` on web that clamps + fires toast. Mutators stay pure. |
| iOS twin of the same threshold-out-of-range bug (`CompositeWizardSetupStepView.swift:36`). | Minor | Added `.onChange(of: operatorType)` + `.onChange(of: subtaskList.items.count)` on the wizard view that call `clampThresholdAndMaybeToast`. |
| `commitLibraryDiff` reads/writes `threshold` as a side-effect inside `setSubtasks` updater — desync risk under React batching (`CompositeTaskWizard.tsx:232`). | Minor | Pulled the clamp out into the new effect above so `commitLibraryDiff` is now a pure `setSubtasks` update. |
| `removeSubtask` reads `subtasks` from the closure instead of functional setter — stale state risk (`CompositeTaskWizard.tsx:244`). | Minor | Switched to `setSubtasks((prev) => prev.filter(...))`. |
| `TypeBadge` in `letterOnly` mode exposes `"NORM"/"COUN"` as the accessible name — screen readers announce the abbreviation (`TypeBadge.tsx:66`). | Major (a11y) | Added `aria-label="<Type> task"` when `letterOnly` so assistive tech hears "Normal task" etc. iOS already had `.accessibilityLabel` on both branches. |
