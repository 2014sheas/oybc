# OYBC Native Migration Plan - Offline-First Architecture

> **Note (2026-04-30):** Sections describing the task data model (the "Schema Design" table list, the "Composite task system" bullet, the Phase 2 implementation checklists) pre-date the Compound Tasks Unification (PR #43, 2026-04-29). The current model is the unified 3-type one (Normal / Counting / Compound) with a `compound_children` junction table replacing `task_steps`/`composite_nodes`/`composite_tasks`, and per-`Task` (not per-`BoardTask`) completion. For the canonical schema and types, see [`TASK_SYSTEM.md`](TASK_SYSTEM.md). Tech-stack, sync, and architectural-principle sections of this doc remain accurate.

## Executive Summary

Build OYBC (On Your Bingo Card) from scratch with **offline-first, local-first architecture**. Local databases are the source of truth (GRDB on iOS, Dexie on web), Firestore syncs in background for multi-device support.

**Timeline**: 14-16 weeks to production (includes composite task system)

**Key Principles**:

- ✅ **Local-first**: All reads from local DB (< 10ms), instant UX
- ✅ **Offline by default**: Full functionality without network
- ✅ **Background sync**: Firestore syncs when online, seamless multi-device
- ✅ **Fresh design**: No MVP code reuse, simplified architecture
- ✅ **Future-proof**: Schema designed for recurring boards, templates

**What Changed from MVP**:

- ❌ No copying types, utilities, or code from MVP (fresh start)
- ✅ Composite task system with logical operators (AND/OR/M-of-N)
- ✅ Tree-based task composition for complex workflows
- ✅ Firestore is sync layer only, NOT primary storage
- ✅ Instant offline UX (no loading spinners, no "waiting for network")
- ✅ Robust conflict resolution (last-write-wins with version fields)

---

## Tech Stack

### iOS

- **UI**: SwiftUI
- **Local DB**: **GRDB.swift** (SQLite + Swift type safety)
  - Best performance (< 10ms reads)
  - Full schema control
  - Simple migrations
- **Sync**: Firebase iOS SDK (Auth, Firestore background sync)
- **State**: Combine + @Observable

### Web

- **Framework**: Next.js 14 (App Router)
- **Local DB**: **Dexie.js** (IndexedDB wrapper)
  - Modern async/await API
  - TypeScript-first
  - Small bundle (~30KB)
- **Sync**: Firebase JS SDK v10
- **State**: Zustand
- **Styling**: Tailwind CSS + shadcn/ui

### Shared

- **Package**: `@oybc/shared` (TypeScript only)
- **Contains**: Types, algorithms, validation (NO database code, NO Firebase code)
- **Reuse**: 30-40% (pure logic only)

### Sync Backend

- **Platform**: Firebase (new project)
- **Role**: Sync layer ONLY (not primary storage)
- **When**: Background, on reconnect, periodic
- **Conflict resolution**: Last-write-wins with version fields

---

## Database Architecture

### Local DB as Source of Truth

**Core Principle**: All operations hit local database first, sync to Firestore in background.

**Read Flow**:

```
User opens board → Read from local DB (< 10ms) → Display instantly
                 → (Background: Check Firestore for updates)
```

**Write Flow**:

```
User completes task → Update local DB immediately (< 10ms) → UI updates
                    → Add to sync queue
                    → (Background: Sync to Firestore)
```

### Schema Design (Ground-Up, No MVP Copy)

**Tables** (identical structure on iOS SQLite and web IndexedDB; current shape, post-unification):

```
users                   -- Cached user profiles
boards                  -- Board documents
tasks                   -- Task definitions (reusable across boards). Compounds carry
                           operator + threshold + isOrdered here. Completion is
                           global on the Task row (not per-board).
compound_children       -- Parent-child links for compound tasks. One row per
                           link; the child can be any Task, including another
                           compound. Replaces the retired task_steps and
                           composite_nodes tables.
board_tasks             -- Junction: board ↔ task placement (no completion state —
                           that lives on the Task itself post-unification).
progress_counters       -- Counting-task progress state (per user × counter).
bingo_lines             -- Completed lines (denormalized for performance).
sync_queue              -- Pending Firestore operations.
```

The legacy `task_steps`, `composite_tasks`, `composite_nodes`, and `board_composite_tasks` tables are still present in old migration scripts so first-launch backfill works on dev/test devices, but they receive no live writes and no UI reads. See [`TASK_SYSTEM.md`](TASK_SYSTEM.md) for the canonical schema.

**Key Design Decisions**:

- **UUID primary keys** (enable offline creation, no server-generated IDs)
- **ISO8601 timestamps** (Firestore compatibility)
- **Version fields** (optimistic locking for conflict resolution)
- **Soft deletes** (`isDeleted` flag, not hard delete - prevents data loss)
- **Denormalized stats** (board.completedTasks stored directly for instant reads)
- **Global per-Task completion** (post-unification): a Task is either complete or not, regardless of how many boards reference it. `compound_children` rows record the parent-child structure; the parent's completion is derived from its children's completion via the operator/threshold on the parent Task.
- **Cross-board task reusability** (same task can appear on multiple boards; completing it once propagates to every placement)

**Example: Board Table**:

```sql
CREATE TABLE boards (
    id TEXT PRIMARY KEY,              -- UUID (offline-generated)
    user_id TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    status TEXT NOT NULL,             -- draft, active, completed, archived
    board_size INTEGER NOT NULL,      -- 3, 4, or 5
    timeframe TEXT NOT NULL,          -- daily, weekly, monthly, yearly
    start_date TEXT NOT NULL,         -- ISO8601
    end_date TEXT NOT NULL,
    center_square_type TEXT NOT NULL, -- free, custom, none
    is_randomized INTEGER NOT NULL,

    -- Denormalized stats (instant reads, no joins)
    total_tasks INTEGER NOT NULL DEFAULT 0,
    completed_tasks INTEGER NOT NULL DEFAULT 0,
    completion_percentage REAL NOT NULL DEFAULT 0,
    lines_completed INTEGER NOT NULL DEFAULT 0,

    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    completed_at TEXT,

    -- Sync metadata
    last_synced_at TEXT,
    version INTEGER NOT NULL DEFAULT 1,  -- Optimistic locking
    is_deleted INTEGER NOT NULL DEFAULT 0,
    deleted_at TEXT
);
```

---

## Development Workflow (Offline-First Approach)

### Phase 1: Local Database Setup (Weeks 1-2)

**Goal**: Get local DBs working, NO sync yet

**Week 1: iOS Database**

- [ ] Install GRDB.swift via SPM
- [ ] Define SQLite schema (boards, tasks, board_tasks, sync_queue tables)
- [ ] Create GRDB models (Board, Task, BoardTask structs)
- [ ] Implement database service (CRUD operations)
- [ ] Write database migrations
- [ ] **Test**: Create board, add tasks, complete tasks (all offline, < 10ms)

**Week 2: Web Database**

- [ ] Install Dexie.js
- [ ] Define IndexedDB schema (mirrors iOS)
- [ ] Create TypeScript interfaces (Board, Task, BoardTask)
- [ ] Initialize Dexie database
- [ ] Implement database service (CRUD operations)
- [ ] **Test**: Same operations as iOS (all offline, < 10ms)

**Shared Package**:

- [x] Design TypeScript interfaces from scratch (NO MVP copy)
- [x] Create `@oybc/shared` package
- [x] Define enums (BoardStatus, TaskType, Timeframe)

**Success Criteria**:

- ✅ iOS: Create board, add 9 tasks, complete 5 tasks (airplane mode, < 10ms each operation)
- ✅ Web: Same operations as iOS
- ✅ No network calls, no Firestore yet
- ✅ Shared types compile without errors

---

### Phase 2: Core Game Loop & Task System (Offline-Only) (Weeks 3-7)

**Goal**: Complete bingo game with comprehensive task system working entirely offline

**Week 3: Board Creation UI**

**iOS**:

- [ ] `CreateBoardView.swift` (name, size, timeframe pickers)
- [ ] `TaskEntryView.swift` (create/select tasks)
- [ ] Calendar boundary logic (Swift implementation)
- [ ] Board randomization (Fisher-Yates in Swift)
- [ ] Save to GRDB → display in board list

**Web**:

- [ ] `app/boards/create/page.tsx` (form)
- [ ] Task entry components
- [ ] Calendar boundary logic (import from shared)
- [ ] Board randomization (import from shared)
- [ ] Save to Dexie → display in board list

**Shared**:

- [ ] Implement calendar boundaries algorithm (TypeScript)
- [ ] Implement board randomization (Fisher-Yates TypeScript)
- [ ] Write tests (Jest)

**Week 4: Board Grid & Interaction**

**iOS**:

- [ ] `BoardGridView.swift` (LazyVGrid, 3x3/4x4/5x5)
- [ ] `BoardSquareView.swift` (task display)
- [ ] Tap gestures (single tap → modal, double tap → complete, long press → force complete)
- [ ] `TaskInfoSheet.swift`, `CountingTaskSheet.swift`, `ProgressTaskSheet.swift`
- [ ] Update local DB on completion → UI updates instantly

**Web**:

- [ ] `BoardGrid.tsx` (CSS Grid)
- [ ] `BoardSquare.tsx`
- [ ] Click handlers (single, double click)
- [ ] Task modals (normal, counting, progress)
- [ ] Update Dexie on completion → UI updates instantly

**Week 5: Bingo Detection & Celebrations**

**iOS**:

- [ ] Implement bingo detection (8 lines: 4 rows, 4 cols, 2 diagonals)
- [ ] Insert into `bingo_lines` table on detection
- [ ] `BingoCelebrationView.swift` (animation)
- [ ] `GreenlogCelebrationView.swift` (full board completion)
- [ ] Update denormalized board stats (completedTasks, linesCompleted)

**Web**:

- [ ] Implement bingo detection (import from shared)
- [ ] Insert into Dexie bingo_lines
- [ ] `BingoCelebration.tsx` (CSS animations)
- [ ] `GreenlogCelebration.tsx`
- [ ] Update board stats in Dexie

**Shared**:

- [ ] Bingo detection algorithm (TypeScript)
- [ ] Comprehensive tests (all 8 line types, edge cases, 3x3/4x4/5x5 boards)

**Success Criteria** (Basic Game Loop):

- ✅ Full game loop works on iOS (offline): create board, complete tasks, get bingos, greenlog
- ✅ Full game loop works on web (offline)
- ✅ All operations instant (< 10ms from local DB)
- ✅ Bingo detection identical on both platforms
- ✅ Airplane mode works perfectly

**Week 6: Composite Task Data Layer**

**Goal**: Add database tables and evaluation algorithm for composite tasks

**iOS**:

- [ ] Add `composite_tasks`, `composite_nodes`, `board_composite_tasks` tables to Schema.sql
- [ ] Create Swift models (CompositeTask, CompositeNode, BoardCompositeTask)
- [ ] Implement GRDB migrations for new tables
- [ ] CRUD operations for composite tasks
- [ ] Swift implementation of tree evaluation algorithm

**Web**:

- [ ] Add composite task tables to Dexie schema
- [ ] TypeScript interfaces (import from `@oybc/shared`)
- [ ] CRUD operations for composite tasks
- [ ] Dexie queries and indexes for tree traversal

**Shared**:

- [ ] Define CompositeTask, CompositeNode TypeScript types
- [ ] Define CompositeOperator enum (AND, OR, M_OF_N)
- [ ] Implement `evaluateCompositeTask()` algorithm (recursive tree traversal)
- [ ] Zod validation schemas for composite tasks
- [ ] Circular reference detection algorithm
- [ ] 100+ unit tests for evaluation algorithm

**Testing**:

- [ ] Create composite task with AND operator (all children must complete)
- [ ] Create composite task with OR operator (any child can complete)
- [ ] Create composite task with M_OF_N operator (threshold-based)
- [ ] Nested composite tasks ((A AND B) OR C)
- [ ] Circular reference validation prevents invalid trees
- [ ] All operations < 50ms for 20-node trees

**Week 7: Composite Task UI & Integration**

**Goal**: Build tree builder UI and integrate into main app

**iOS Playground**:

- [ ] Tree builder UI (nested operators and tasks)
- [ ] Operator picker (AND/OR/M_OF_N)
- [ ] Task reference selector (existing tasks)
- [ ] Auto-create task flow (inline → real task)
- [ ] Visual tree preview with completion state
- [ ] Demo: Simple AND ("Exercise AND Meditate")
- [ ] Demo: Simple OR ("Run 3 miles OR Bike 10 miles")
- [ ] Demo: M_OF_N ("2 of [Read, Journal, Meditate]")
- [ ] Demo: Nested ("(Exercise OR Yoga) AND (2 of [tasks])")

**Web Playground**:

- [ ] Mirror iOS tree builder functionality
- [ ] Drag-and-drop tree builder (optional enhancement)
- [ ] Form-based tree construction
- [ ] Real-time evaluation display
- [ ] Same demo scenarios as iOS

**Integration** (Both Platforms):

- [ ] Add composite task option to board creation
- [ ] Composite task completion UI (show tree structure)
- [ ] Evaluation runs when sub-tasks complete
- [ ] Auto-complete composite when all conditions met

**Success Criteria** (Complete Task System):

- ✅ Normal, Counting, Progress, and Composite tasks all work
- ✅ Composite evaluation < 50ms for complex trees
- ✅ Tree builder UI functional on both platforms
- ✅ Auto-task-conversion working (inline → real tasks)
- ✅ Cross-platform task parity (web and iOS identical)

---

### Phase 3: Authentication & Sync Layer (Weeks 8-10) -- COMPLETE

**Goal**: Add Firebase auth and background sync for multi-device support

**Week 8: Authentication**

**iOS**:

- [x] Install Firebase iOS SDK (Auth only for now)
- [x] Create new Firebase project
- [x] `AuthService.swift` (sign up, sign in, sign out)
- [x] `LoginView.swift`, `RegisterView.swift`
- [x] Store userId in local DB (associate boards/tasks with user)

**Web**:

- [x] Install Firebase JS SDK
- [x] Auth service (sign up, sign in, sign out)
- [x] Login/register pages
- [x] Auth context provider
- [x] Store userId in Dexie

**Testing**:

- [x] Sign up on iOS → account exists in Firebase console
- [x] Sign in on web with same credentials
- [x] User's boards isolated by userId (can't see other users' data)

**Week 9: Sync Queue & Background Sync**

**iOS**:

- [x] Add Firebase Firestore SDK
- [x] Implement `SyncService.swift`:
  - Read from `sync_queue` table
  - Sequential processing (batching deferred to future optimization)
  - Send to Firestore (create, update, delete)
  - Remove from queue on success, retry on failure
- [x] Trigger sync: on app launch, on reconnect, every 5 min

**Web**:

- [x] Implement `SyncService.ts` (mirrors iOS)
- [x] Same queue pattern
- [x] Trigger sync: on load, on reconnect, periodic

**Testing**:

- [x] Create board on iOS (offline) → goes to sync_queue
- [x] Connect to internet → sync processes → board appears in Firestore console
- [x] Disconnect again → operations queue locally
- [x] Reconnect → all operations sync

**Week 10: Pull Sync & Conflict Resolution**

**iOS & Web**:

- [x] Implement pull sync (fetch changes from Firestore since last sync)
- [x] Query Firestore: `where('_syncedAt', '>', lastSyncedAt)` watermark approach
- [x] For each remote change:
  - Get local version
  - Compare version fields
  - If remote.version > local.version → update local DB
  - If local.version > remote.version → keep local (will push next sync)
- [x] Update `lastSyncedAt` timestamp

**Testing**:

- [x] Create board on iOS → syncs to Firestore
- [x] Pull on web → board appears
- [x] Complete task on web → syncs to Firestore
- [x] Pull on iOS → task shows completed
- [x] **Conflict test**: Edit same board on both devices offline → reconnect → higher version wins

**Success Criteria**: ALL MET

- ✅ Create board on iOS → appears on web within 5 seconds
- ✅ Complete task on web → updates on iOS within 5 seconds
- ✅ Works offline, syncs when back online
- ✅ Conflicts resolve correctly (last-write-wins)

---

## Repository Structure

```
oybc/                           # Monorepo root
├── .github/workflows/          # CI/CD
├── apps/
│   ├── ios/                    # Xcode project (SwiftUI + GRDB)
│   │   ├── OYBC.xcodeproj
│   │   ├── OYBC/
│   │   │   ├── App/            # App entry, root views
│   │   │   ├── Features/
│   │   │   │   ├── Auth/       # Login, register
│   │   │   │   ├── Boards/     # Board CRUD, grid view
│   │   │   │   └── Tasks/      # Task modals, components
│   │   │   ├── Database/       # GRDB setup, models, queries
│   │   │   ├── Sync/           # Firebase sync service
│   │   │   ├── Models/         # Swift data models
│   │   │   └── Utils/          # Swift utilities
│   │   └── README.md
│   ├── web/                    # Next.js app (Dexie + Zustand)
│   │   ├── src/
│   │   │   ├── app/            # Next.js App Router
│   │   │   ├── components/     # React components
│   │   │   ├── db/             # Dexie setup, schema
│   │   │   ├── sync/           # Firebase sync service
│   │   │   └── lib/            # Utilities
│   │   └── README.md
│   └── android/                # Future: Jetpack Compose + Room
├── packages/
│   ├── shared/                 # TypeScript only (NO DB, NO Firebase)
│   │   ├── src/
│   │   │   ├── types/          # Interfaces (Board, Task, etc.)
│   │   │   ├── algorithms/     # Bingo detection, randomization, calendar
│   │   │   ├── validation/     # Zod schemas
│   │   │   └── constants/      # Enums, configs
│   │   └── tests/              # Jest unit tests
│   └── design-tokens/          # Colors, spacing (JSON)
├── docs/
│   ├── ARCHITECTURE.md         # THIS PLAN (detailed technical doc)
│   ├── CLAUDE_GUIDE.md         # How Claude Code works with this repo
│   └── OFFLINE_FIRST.md        # Offline architecture explanation
├── firebase/
│   ├── firestore.rules         # Security rules (design fresh)
│   └── firestore.indexes.json  # Composite indexes
├── scripts/
│   └── setup.sh                # Monorepo + Firebase setup
├── turbo.json                  # Turborepo config
├── package.json                # Workspace root
├── pnpm-workspace.yaml         # pnpm workspaces
└── README.md
```

---

## Next Steps

### Immediate (Today)

- [x] Archive MVP codebase
- [x] Create monorepo structure
- [x] Set up shared package
- [x] Design data models (TypeScript)
- [x] Create documentation

### Next Session (iOS Database)

- [x] Create Xcode project (SwiftUI)
- [x] Add GRDB.swift via SPM
- [x] Define SQLite schema
- [x] Implement GRDB models
- [x] Test offline CRUD operations

### Following Session (Web Database)

- [x] Create web project
- [x] Set up Dexie.js
- [x] Mirror iOS schema in IndexedDB
- [x] Implement database service
- [x] Test offline CRUD operations

---

## Resources

### Documentation

- [GRDB.swift](https://github.com/groue/GRDB.swift)
- [Dexie.js](https://dexie.org/)
- [Firebase iOS SDK](https://firebase.google.com/docs/ios/setup)
- [Firebase JS SDK](https://firebase.google.com/docs/web/setup)

### MVP Reference (Algorithm Patterns Only)

- Calendar boundaries: `oybc_v1.archive/src/utils/calendarBoundaries.ts`
- Bingo detection: `oybc_v1.archive/src/services/firebase/boards.ts` (lines 696-778)
- Board randomization: `oybc_v1.archive/src/utils/boardRandomization.ts`

**Important**: Reference for patterns only, NOT for copying code!

---

## Success Metrics

### Phase 1 (Weeks 1-2)

- ✅ Local DB operations < 10ms (measured)
- ✅ Offline CRUD works on both platforms
- ✅ Shared package builds without errors

### Phase 2 (Weeks 3-7)

- ✅ Full game loop works offline
- ✅ Bingo detection identical on iOS and web
- ✅ All task types working (Normal, Counting, Progress, Composite)
- ✅ Composite task evaluation < 50ms
- ✅ All operations instant (no loading spinners)

### Phase 3 (Weeks 8-10)

- ✅ Multi-device sync < 5 seconds
- ✅ Conflicts resolve correctly (including composite tasks)
- ✅ No data loss in offline scenarios
- ✅ Composite task trees sync correctly

### Phase 4: Production Integration — COMPLETE

Replaced the playground-only app with a real production UI. Tab-based navigation, auth-gated, web + iOS simultaneously.

**Navigation**: Bottom tab bar — Boards (default), Create, Profile.

- [x] Phase 4.0: Synced user preferences (7 fields → Firestore, Profile + Board Preferences UI)
- [x] Phase 4.1: Auth shell + tab bar (replace "Hello OYBC")
- [x] Phase 4.2: Board list (filtering, progress, navigation)
- [x] Phase 4.3: Board play (bingo grid, completion, flash messages)
- [x] Phase 4.4: Create tab (task pool + BoardCreatorPanel)
- [x] Phase 4.5: Profile + settings + polish (display-name edit, sync indicator, sign-out confirm, empty states)

**Key files**:

- `TabBar.tsx` ↔ `MainTabView.swift` — bottom tab navigation
- `BoardsPage.tsx` ↔ `BoardListView.swift` — board list
- `BoardPlayPage.tsx` ↔ `BoardPlayView.swift` — board play
- `CreatePage.tsx` ↔ `CreateView.swift` — board creation
- `ProfilePage.tsx` ↔ `ProfileView.swift` — settings + sign out
- `SyncStatusIndicator.tsx` ↔ `SyncStatusIndicatorView.swift` — online/offline + sync controls
- `NetworkMonitor.swift` — iOS NWPathMonitor wrapper (no web equivalent; uses `navigator.onLine`)

**Principle**: Extract from `BoardLifecyclePlayground` into production pages. Don't rebuild.

### Phase 5: Polish & Launch — COMPLETE

**CI/CD & repo automation**:

- [x] Web CI workflow (build + test + lint on PRs to dev)
- [x] iOS CI workflow (build + test on PRs to dev)
- [x] Firestore rules auto-deploy on merge to dev
- [x] Dependabot (npm weekly, GitHub Actions monthly)
- [x] PR template with test plan + parity checklist
- [x] Copilot code review on all PRs
- [x] ESLint 10 flat config migration
- [x] TypeScript 6 upgrade
- [x] pnpm 9 upgrade (8.15 deprecated)

**Polish work** (shipped via the pre-phase6 audit, see `CLAUDE.md`):

- [x] Cross-platform parity audit (architecture + security + parity passes)
- [x] Sign-out confirmation dialog (web + iOS)
- [x] Empty states on Create tab
- [x] Display name edit (Firebase Auth + local DB + sync)
- [x] Sync status indicator + iOS `NetworkMonitor`

**Achievement squares** shipped subsequently in Phase 6.3 (PR #54) as the `TaskType.ACHIEVEMENT` first-class type. `ProgressCounter` schema exists but has no UI consumer — open question whether to surface it later or drop the entity.

### Launch readiness (separate gate, not a Phase 5 sub-task)

These are pre-public-launch milestones that overlap Phase 6 + future work, tracked here for visibility:

- [ ] TestFlight beta (5-10 users)
- [ ] No sync bugs (1 week testing)
- [ ] Performance targets met (< 10ms reads, < 50ms composite evaluation)
- [ ] Security verified (can't access other users' data)
- [ ] CAPTCHA / rate-limit hardening on auth flows (see `CLAUDE.md` Known follow-ups)

### Phase 6: Recurring Boards — shipped

> Design captured 2026-05-01; all three sub-phases shipped 2026-05-13. The design content below is preserved as the canonical record — useful for understanding *why* the shipped shape is what it is. For the shipped state of any sub-phase, follow the PR link in the status table.

OYBC's primary use case is "user opens the app, creates a board for what they want to track in this window, completes squares throughout the window." Phase 6 closes the friction loop at the natural rollover points (start of each day, week start, month start, year start) by surfacing a banner the moment the user opens the Boards tab inside a new window. This section is the canonical design — written before code landed, kept in sync as decisions evolved.

#### Motivation

Today every board is a one-shot creation. The user must remember to spin up a fresh daily/weekly/monthly board at every transition; if they forget, the window passes without tracking. The friction is highest at exactly the moments the user most needs the prompt. Recurring Boards turns that friction into a banner: when the user opens Boards on a new day (or week/month/year), pending creations are listed, ranked longest-window-first so parent boards exist before children. Tapping a banner row opens the existing wizard prefilled with the right timeframe + window dates.

The architecture investigation that preceded this design (April 2026) established that most of the infrastructure already exists post-Compound Tasks Unification: per-board `startDate`/`endDate`, the `getTimeframeBoundaries()` helper family, and the global per-Task completion model. The missing piece is _orchestration_ — detecting elapsed windows and surfacing prompts. Phase 1 of the rollout adds only that orchestration. Phases 2 and 3 layer richer features (preset task pools, board-completion-as-a-task) on top, sharing the Phase 1 detection hook.

**Non-goals (Phase 1)**: no automatic background creation, no notifications, no reminders, no shared boards across users, no recurring custom-timeframe boards. Each is in scope for a later phase if real usage demands it; speculating now buys nothing.

#### Three-phase vision

| Phase                          | Scope                                                                                                                    | Net-new infrastructure                                                                                                                | Status / PR |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- | ----------- |
| 1 — Timeframe-prompted         | Daily/weekly/monthly/yearly recurrence prompts via Boards-tab banner; wizard prefill; "From parent boards" wizard filter | 4 prefs fields, detection algorithm, banner UI, wizard prefill, parent-tasks filter                                                   | SHIPPED [#50](https://github.com/2014sheas/oybc/pull/50) |
| 2 — Preset-pool                | Boards that auto-instantiate from a fixed task pool each window                                                          | `RecurringBoardTemplate` entity, lazy spawn on app-open (no banner)                                                                   | SHIPPED [#52](https://github.com/2014sheas/oybc/pull/52) |
| 3 — ACHIEVEMENT TaskType       | Cross-board watcher squares as a first-class `TaskType` (specific board XOR recurring template)                          | `TaskType.ACHIEVEMENT`, `referencedBoardId` / `referencedTemplateId` / `achievementTrigger` / `requiredCount` on `Task`, cycle detection, window-aware spawn fan-out | SHIPPED [#54](https://github.com/2014sheas/oybc/pull/54) |

> **Note on Phase 3 scope drift:** Originally designed as "extend achievement squares with a `BoardTask.referencedBoardId` field" (additive on the existing aggregate-counter mechanism). During implementation, manual testing surfaced that this design had no first-class creation path — users had to place a throwaway task then convert. The shipped design pivoted to ACHIEVEMENT-as-a-TaskType: reference fields moved onto `Task`, `BoardTask` reverted to a pure placement record, aggregate-counter mode dropped entirely. See PR #54's description for the full design-pivot story.

#### Phase 1 detailed design

##### Decisions captured (2026-05-01)

| Decision                      | Choice                            | Implication                                                                                                                                        |
| ----------------------------- | --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Derivation semantics          | Shared task across both boards    | Completing a daily-derived task auto-completes it on the parent monthly. "Derive from parent" is a wizard filter, not a clone path. No new schema. |
| MVP scope                     | Timeframe-prompted only first     | Lowest-risk first ship; phase 2 + 3 wait for real usage data.                                                                                      |
| Multi-window UX (e.g., Jan 1) | Non-blocking banner on Boards tab | Each pending entry has its own row; "Create" / "Dismiss" per row; permanent suppression via the corresponding pref toggle.                         |
| Pool board trigger (Phase 2)  | Lazy: spawn on next app-open      | No background scheduling infrastructure; reuses Phase 1's detection hook verbatim.                                                                 |

##### Architecture readiness

**Ready for reuse, no changes needed:**

- `Timeframe` enum + `Board.startDate` / `Board.endDate` (per-window distinct records — `packages/shared/src/types/board.ts:25,55-66`).
- `getTimeframeBoundaries(timeframe, ref?, weekStartDay?)` and friends in `packages/shared/src/algorithms/calendarBoundaries.ts:53-142`. Boundaries are deterministic local ISO8601 strings (`toLocalISO`) so string equality is safe for "is there a board for this exact window?" comparisons.
- `isTimeframeExpired(endDate, now?)` (`calendarBoundaries.ts:161`) and `isWithinTimeframe()` (line 149) — already implemented but not currently called from any orchestration point.
- `formatTimeframeLabel(timeframe, startDate)` (`calendarBoundaries.ts:187`) — the banner row label generator we'll reuse for "Today", "Week of May 4 – 10, 2026", "May 2026", "2026".
- `useBoardWizard` (web) / `BoardWizardViewModel` (iOS) — already accept `timeframe + startDate + endDate` via `CreateBoardInput`; prefill is purely an init-arg path.
- Synced user preferences pipeline (Phase 4.0) — extending `UserPreferences` with 4 booleans is a one-line schema change per platform plus matching forward-compatible decoders (`mergeUserPreferences` in `packages/shared/src/types/user.ts:57` and the Swift `UserPreferences.init(from:)` mirror).
- Global per-Task completion (post-unification) — gives us "shared task across boards" semantics for free; no derivation code at all.

**Net-new for Phase 1:**

1. 4 user-preference fields (one boolean per recurring timeframe).
2. `findPendingRecurringBoards()` — pure function in shared package.
3. `getParentBoards(timeframe, allActiveBoards, now, weekStartDay)` — pure function used by the wizard's filter.
4. `PARENT_TIMEFRAMES` constant — the parent hierarchy.
5. App-open detection on the Boards tab (web `useEffect` over `useLiveQuery`, iOS `.task` over the existing observed-board store).
6. `RecurringBoardsBanner` component — web + iOS, identical structure.
7. Wizard prefill via URL params (`/create/board?timeframe=daily&start=...&end=...`) and iOS init args.
8. Wizard task-step "From parent boards" filter chip.
9. Toggle switches in `BoardPreferencesPage` / `BoardPreferencesView`.
10. Sync mapping update for the 4 new prefs fields (existing user-prefs sync; no new collection).

##### Data model

**No `Board`, `Task`, or `BoardTask` schema changes.** The iOS `User` GRDB model needs a small migration to add 4 boolean columns (default `0` / `false`); the four `boards` / `tasks` / `board_tasks` tables are untouched. Four new fields appended to `UserPreferences` (in `packages/shared/src/types/user.ts`):

```ts
export interface UserPreferences {
  // ...existing 7 fields...
  recurringDailyEnabled: boolean; // default false
  recurringWeeklyEnabled: boolean; // default false
  recurringMonthlyEnabled: boolean; // default false
  recurringYearlyEnabled: boolean; // default false
}
```

Defaults extend `DEFAULT_USER_PREFERENCES` with `false` for all four. `mergeUserPreferences()` must validate each field as `typeof === 'boolean'` (mirroring `defaultRandomize` at line 93–95) and fall back to default otherwise. The Swift `UserPreferences.init(from:)` decoder (in iOS) needs the same forward-compatible pattern so a peer running an older client doesn't poison the local record.

**Detection rule** (no persistence). A "pending" board for timeframe T at time `now` exists if and only if:

1. `prefs.recurring${T}Enabled === true`, AND
2. No `Board` row exists where `b.userId === me && b.timeframe === T && !b.isDeleted && b.startDate === getTimeframeBoundaries(T, now, prefs.weekStartDay).startDate`.

String equality on `startDate` is safe because both sides come from the same `toLocalISO()` formatter — bit-for-bit identical.

##### Algorithms (new shared file)

**File**: `packages/shared/src/algorithms/recurringBoards.ts`

```ts
export const PARENT_TIMEFRAMES: Record<Timeframe, Timeframe[]> = {
  [Timeframe.DAILY]: [Timeframe.WEEKLY, Timeframe.MONTHLY, Timeframe.YEARLY],
  [Timeframe.WEEKLY]: [Timeframe.MONTHLY, Timeframe.YEARLY],
  [Timeframe.MONTHLY]: [Timeframe.YEARLY],
  [Timeframe.YEARLY]: [],
  [Timeframe.CUSTOM]: [], // intentionally empty for Phase 1
};

export interface PendingRecurringBoard {
  timeframe: Timeframe;
  startDate: string; // local ISO8601 from getTimeframeBoundaries()
  endDate: string; // local ISO8601 from getTimeframeBoundaries()
  suggestedName: string; // formatTimeframeLabel(timeframe, startDate)
}

// Note: findPendingRecurringBoards reads weekStartDay from `prefs` (it needs
// `prefs` anyway for the recurring*Enabled flags). getParentBoards has no other
// reason to take prefs, so its weekStartDay is an explicit parameter.
// The asymmetry is intentional — don't refactor for false consistency.
export function findPendingRecurringBoards(
  boards: Board[],
  prefs: UserPreferences,
  now: Date,
): PendingRecurringBoard[];

export function getParentBoards(
  childTimeframe: Timeframe,
  allActiveBoards: Board[],
  now: Date,
  weekStartDay: WeekStartDay,
): Board[];
```

**`findPendingRecurringBoards`** iterates `[DAILY, WEEKLY, MONTHLY, YEARLY]`, skips disabled timeframes via the prefs flags, computes `getTimeframeBoundaries(t, now, prefs.weekStartDay)`, and returns one `PendingRecurringBoard` for each timeframe whose `startDate` doesn't match an existing non-deleted board's. Returned in **longest-window-first order** (yearly → monthly → weekly → daily) so banner consumers can render directly without resorting.

**`getParentBoards`** filters `allActiveBoards` to those whose `timeframe` is in `PARENT_TIMEFRAMES[childTimeframe]` AND whose window currently contains `now` (`isWithinTimeframe(now, b.startDate, b.endDate)`) AND `b.status === BoardStatus.ACTIVE`. Used by the wizard's "From parent boards" filter to surface candidate tasks.

Both functions are pure and trivially unit-testable. Mirror the existing pattern in `packages/shared/tests/algorithms/calendarBoundaries.test.ts` — table-driven cases for each timeframe + edge dates (year boundary, leap year, week-start variation).

##### UX flows

**Banner shape** on the Boards tab (web + iOS):

```
┌──────────────────────────────────────────────────┐
│ Pending boards                                   │
│  📆 Monthly — May 2026         [Create] [Dismiss]│
│  🗓 Weekly — Apr 27 – May 3    [Create] [Dismiss]│
│  📅 Daily — Today              [Create] [Dismiss]│
└──────────────────────────────────────────────────┘
[ existing board list below ]
```

- **Order**: longest window first (yearly → monthly → weekly → daily) so creating top-down builds the parent chain before children. The wizard's "From parent boards" filter then has something to surface.
- **"Create"**: navigates to `/create/board?timeframe=daily&start=2026-05-01T00:00:00.000&end=2026-05-01T23:59:59.999` (web) or constructs `BoardWizardView(prefilledTimeframe: .daily, prefilledStart: ..., prefilledEnd: ...)` (iOS). The wizard's setup step shows the timeframe + dates as a read-only chip; the name field is pre-filled with `formatTimeframeLabel()` output but editable. Other fields (size, center type, randomize) come from existing prefs.
- **"Dismiss"**: hides that row for the rest of the app session via local component state. No persistence — banner reappears next launch. Permanent suppression = disable that timeframe in `BoardPreferencesPage` / `BoardPreferencesView`.
- **Reactive removal**: after a successful board creation, the banner row disappears automatically because `useLiveQuery` (web) / `@ObservedObject` (iOS) recomputes pending list against the new board state.

**"From parent boards" filter** in wizard tasks step:

- New filter chip rendered next to existing tabs ("All" / "By type" / etc.).
- When active, the task-list source switches from `useTasks(userId)` (web) / the equivalent iOS observed query to `useParentBoardTasks(currentTimeframe)` / `ParentBoardTasksViewModel(timeframe:)`. The hook/view-model:
  1. Calls `getParentBoards(currentTimeframe, allActiveBoards, now, weekStartDay)` to find currently-active parents.
  2. Fetches `BoardTask` rows for those parent board IDs.
  3. Resolves `BoardTask.taskId` → `Task` and dedupes (a task appearing on multiple parents shows once).
- Selecting a task and confirming places it on the new board via the standard placement path: one new `BoardTask` row, same `taskId`. **No clone, no schema change.** Per the locked decision, completing on the new daily board globally completes the task — including on the parent.
- **Empty state**: if no currently-active parent boards exist (common on the first-ever app open after enabling prefs, or for yearly boards which have no parents), the filter chip's task list shows "No parent boards found — create a longer-window board first." The filter remains tappable so the user can confirm what they're seeing isn't a bug.

##### Edge cases

- **Multi-window rollover** (Jan 1 = new day + new week + new month + new year all at once for a user with all four prefs enabled): banner lists all four entries in longest-first order. User creates them one at a time; each creation removes its banner row.
- **Dismissed but not created**: re-prompts on next app-open (session-only dismissal). Acceptable because users who really don't want it disable in prefs.
- **Permanent disable mid-week**: banner stops surfacing the disabled timeframe immediately (reactive query depends on prefs).
- **Two boards manually created for same window**: detection still finds at least one matching board → prompt suppresses correctly.
- **User deletes today's board mid-day**: re-prompt on next app-open (detection finds no non-deleted match).
- **Week-start preference Monday vs Sunday**: detection respects `prefs.weekStartDay` by passing it through `getTimeframeBoundaries(t, now, prefs.weekStartDay)`. Switching the pref mid-week could mean a previously-matched weekly board now falls outside the new week's bounds — banner re-prompts, which is correct.
- **DST transitions / leap year**: `getTimeframeBoundaries()` uses local `Date` arithmetic and already handles these. Detection inherits correctness for free.
- **Timezone change mid-period**: if the device timezone shifts after a board is created (user travels across timezones), `getTimeframeBoundaries(now)` may produce a `startDate` string that doesn't byte-match the stored `Board.startDate`. Detection treats the window as pending and re-prompts. Acceptable for MVP — the user can dismiss the duplicate prompt or simply not enable timezone-affected timeframes (daily is the most exposed; yearly is essentially immune). A more sophisticated comparison (e.g., compare by parsed date components rather than string) is a Phase 2+ refinement if real users hit this.
- **Two devices, one creates a board**: Device A creates → push to Firestore → Device B's banner reflects the creation after pull. No new sync mechanism needed; this is just standard offline-first.
- **Board placed inside a future window** (user backdates by accident): detection compares `startDate` for exact equality, so a board with a different `startDate` (even within the same conceptual window) won't match. In practice the wizard always uses `getTimeframeBoundaries()` so this can only happen via direct DB manipulation.
- **Custom timeframe boards exist**: `Timeframe.CUSTOM` is intentionally absent from `PARENT_TIMEFRAMES` and from the recurrence toggles — custom boards never satisfy or trigger the recurrence machinery in Phase 1. They remain fully usable as one-off boards.

##### Sync semantics

**Phase 1 introduces zero new sync collections.** The 4 new boolean fields ride the existing user-prefs sync (which already pushes/pulls the entire `preferences` object on each user-doc write). LWW resolution is unchanged; no new conflict-resolution logic. `mergeUserPreferences()` and the Swift mirror are forward-compatible decoders, so a peer on an older client that doesn't include the new fields decodes successfully (defaults to `false`); a write from the older client drops the new fields (no data loss because the fields are absent, not invalid).

##### Verification matrix

| Layer                | What to verify                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Unit (shared)        | `findPendingRecurringBoards`: enabled with no boards → all enabled timeframes pending; one daily exists for today → daily not pending; daily exists for yesterday's window → daily _is_ pending; week-start variation (Monday vs Sunday); year-boundary edge (Dec 31 → Jan 1 ⇒ all four pending if all enabled). `getParentBoards`: daily → returns active weekly+monthly+yearly; yearly → returns empty; deleted parents excluded; archived parents excluded. `PARENT_TIMEFRAMES` snapshot test. |
| Unit (web/iOS hooks) | Banner reactivity to board CRUD + pref changes; correct rerender on dismissal; cleanup of session-dismissal state on unmount.                                                                                                                                                                                                                                                                                                                                                                     |
| Snapshot (iOS)       | `RecurringBoardsBannerView` with 0 / 1 / 3 / 4 entries (4 = Jan 1 case); wizard setup step with prefilled chip variant; tasks step with "From parents" filter active; `BoardPreferencesView` with the new toggles section.                                                                                                                                                                                                                                                                        |
| Playwright (web)     | Empty banner with all prefs off; enable all four prefs → 4-entry banner; click "Create" on Daily → wizard opens prefilled → submit → banner shrinks to 3 entries; "From parents" filter returns expected tasks from active parents.                                                                                                                                                                                                                                                               |
| Manual               | Date-mock single rollover (`new Date(2026, 4, 2)` after creating a daily for May 1); year-boundary rollover; offline creation of a recurring board → reconnect → confirm sync push; cross-device banner update via two simulators.                                                                                                                                                                                                                                                                |

##### Files to create + modify

| File                                                                       | Action | Notes                                                                                                   |
| -------------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------- |
| `packages/shared/src/algorithms/recurringBoards.ts`                        | CREATE | `PARENT_TIMEFRAMES`, `findPendingRecurringBoards`, `getParentBoards`, `PendingRecurringBoard` interface |
| `packages/shared/tests/algorithms/recurringBoards.test.ts`                 | CREATE | Jest table-driven tests                                                                                 |
| `packages/shared/src/types/user.ts`                                        | MODIFY | 4 new fields on `UserPreferences`, default values, `mergeUserPreferences` validation                    |
| `packages/shared/src/index.ts`                                             | MODIFY | Export new symbols                                                                                      |
| `apps/web/src/hooks/usePendingRecurringBoards.ts`                          | CREATE | useLiveQuery wrapper around `findPendingRecurringBoards`                                                |
| `apps/web/src/hooks/useParentBoardTasks.ts`                                | CREATE | useLiveQuery wrapper around `getParentBoards` + task resolution                                         |
| `apps/web/src/components/RecurringBoardsBanner.tsx`                        | CREATE | Banner UI; per-row Create + Dismiss buttons; session-dismissal local state                              |
| `apps/web/src/pages/BoardsPage.tsx`                                        | MODIFY | Render `<RecurringBoardsBanner />` above the existing list when non-empty                               |
| `apps/web/src/pages/BoardWizardPage.tsx`                                   | MODIFY | Read `timeframe`, `start`, `end` URL params; pass into `useBoardWizard` initial state                   |
| `apps/web/src/components/wizard/BoardWizardSetupStep.tsx`                  | MODIFY | Render read-only timeframe chip when prefilled                                                          |
| `apps/web/src/components/wizard/BoardWizardTasksStep.tsx`                  | MODIFY | Add "From parent boards" filter chip; switch task source when active                                    |
| `apps/web/src/pages/BoardPreferencesPage.tsx`                              | MODIFY | New "Recurring boards" section with 4 toggle switches                                                   |
| `apps/web/src/firebase/userMappers.ts` (or equivalent)                     | MODIFY | Include 4 new fields in user-prefs push/pull mapping                                                    |
| `apps/ios/OYBC/Views/Components/RecurringBoardsBannerView.swift`           | CREATE | Mirror of web banner                                                                                    |
| `apps/ios/OYBC/Views/BoardsTab/PendingRecurringBoardsViewModel.swift`      | CREATE | Observed query equivalent to `usePendingRecurringBoards`                                                |
| `apps/ios/OYBC/Views/CreateTab/ViewModels/ParentBoardTasksViewModel.swift` | CREATE | Mirror of `useParentBoardTasks`                                                                         |
| `apps/ios/OYBC/Views/BoardsTab/BoardListView.swift`                        | MODIFY | Render banner above list                                                                                |
| `apps/ios/OYBC/Views/CreateTab/BoardWizardView.swift`                      | MODIFY | Accept `prefilledTimeframe`, `prefilledStart`, `prefilledEnd` init args                                 |
| `apps/ios/OYBC/Views/CreateTab/ViewModels/BoardWizardViewModel.swift`      | MODIFY | Accept matching init args; lock timeframe field when prefilled                                          |
| `apps/ios/OYBC/Views/CreateTab/Components/BoardWizardSetupStepView.swift`  | MODIFY | Render read-only timeframe chip when prefilled                                                          |
| `apps/ios/OYBC/Views/CreateTab/Components/BoardWizardTasksStepView.swift`  | MODIFY | Add filter chip mirroring web                                                                           |
| `apps/ios/OYBC/Views/ProfileTab/BoardPreferencesView.swift`                | MODIFY | New 4-toggle section                                                                                    |
| `apps/ios/OYBC/Database/Models/User.swift`                                 | MODIFY | 4 new boolean columns; GRDB migration; forward-compatible decoder                                       |
| `apps/ios/OYBC/Services/SyncService.swift`                                 | MODIFY | Include 4 new fields in user-prefs push/pull mapping                                                    |
| `apps/ios/OYBCSnapshotTests/RecurringBoardsBannerSnapshotTests.swift`      | CREATE | 0/1/3/4-entry baselines                                                                                 |
| `apps/ios/OYBCSnapshotTests/BoardWizardPrefillSnapshotTests.swift`         | CREATE | Setup-step + tasks-step prefilled variants                                                              |

After adding new Swift files, run `xcodegen generate` per CLAUDE.md.

#### Phase 2 sketch — Preset-pool recurring boards

A user-curated task pool that automatically creates a fresh board every window without user intervention. Example: "daily workout" with a pool of 25 exercises, randomized into a 5×5 each morning when the user opens the app.

**New entity**: `RecurringBoardTemplate`

```ts
interface RecurringBoardTemplate {
  id: string; // UUID
  userId: string;
  name: string;
  timeframe: Timeframe; // DAILY / WEEKLY / MONTHLY / YEARLY (no CUSTOM)
  boardSize: BoardSize;
  centerSquareType: CenterSquareType;
  isRandomized: boolean;
  seedTaskIds: string[]; // Pool to randomize/select from each window
  poolStrategy: "all" | "random_subset"; // How seedTaskIds map to grid cells
  lastSpawnedWindowKey: string | null; // ISO startDate of last-spawned window
  isActive: boolean; // User can pause/resume without deleting
  createdAt: string;
  updatedAt: string;
  version: number;
  isDeleted: boolean;
  deletedAt?: string;
}
```

**Lazy spawn**: extends Phase 1's detection hook. When `findPendingRecurringBoards` runs on Boards-tab open, also iterate active templates → for each, compute `getTimeframeBoundaries(template.timeframe, now, weekStartDay).startDate` → if it doesn't match `template.lastSpawnedWindowKey`, spawn a board from the template (creating `BoardTask` rows from `seedTaskIds`) and update `lastSpawnedWindowKey` in the same transaction. **No banner entry** for template spawns — they appear directly in the board list. Rationale: pool boards are pre-configured; surfacing a banner would defeat the "set it and forget it" value.

**UI**: new "Recurring templates" section on the Create tab (sibling to the manual board wizard). CRUD UI for templates: pick timeframe + name + size + pool strategy + seed tasks.

**Sync**: new Firestore subcollection `users/{uid}/recurringBoardTemplates` (camelCase, matching the existing convention used by `boardTasks` / `compoundChildren` — see `apps/web/src/firebase/syncService.ts`). The local SQLite table is `recurring_board_templates` (snake_case, matching `board_tasks` / `compound_children`). Versioning + LWW + soft-delete tombstones mirror `boards`. The new collection name is added to the sync service's known-collections list; no new conflict-resolution logic.

**Reuses** verbatim from Phase 1: detection hook scaffolding, `getTimeframeBoundaries()`, banner-tab orchestration, sync infrastructure.

#### Phase 3 sketch — Extend achievement squares for specific-board references

A square whose completion criterion is the **status of one named board**, not aggregate counts across a timeframe. Examples: "greenlog the _Daily Wellness_ board" as a square on a separate daily board; "complete the _Q2 Planning_ monthly board" as a square on a yearly board.

This is **not a new TaskType.** Achievement squares (the existing `BoardTask`-level mechanism with `isAchievementSquare + achievementType + achievementCount + achievementTimeframe + achievementProgress`) already cover the _aggregate_ form ("any N boards of timeframe T satisfy condition X"). The Phase 3 work extends the same mechanism with a **specific-board reference** mode by adding one optional field — no new task type, no parallel mechanism, same evaluation branch in the derivation pass.

**Schema delta**: one new optional field on `BoardTask`:

```ts
referencedBoardId?: string;  // FK boards. When set, the square switches from
                              // aggregate mode to specific-board mode:
                              //   - achievementType is interpreted vs the
                              //     referenced board's state
                              //   - achievementCount is ignored (defaults to 1)
                              //   - achievementTimeframe is ignored
```

**Evaluation rule** (extension to the existing achievement-square branch in `derivationPass.ts:118`):

```
if (bt.isAchievementSquare) {
  if (bt.referencedBoardId) {
    // specific-board mode (NEW)
    const ref = boardsById[bt.referencedBoardId];
    isComplete = ref && !ref.isDeleted &&
                 satisfiesAchievementType(ref, bt.achievementType);
  } else {
    // existing aggregate mode (unchanged from derivationPass.ts:119-128)
    const required = bt.achievementCount ?? 0;
    const progress = bt.achievementProgress ?? 0;
    isComplete = (required > 0 && progress >= required);
  }
}
```

`satisfiesAchievementType(board, type)` is `'full_completion' → board.status === COMPLETED`, `'bingo' → board.linesCompleted >= 1`. Same enum as existing aggregate mode.

**Cross-board cascade** (extension to the existing fan-out): when a board's status or `linesCompleted` changes (today: by `runBoardCascadeForTask` detecting greenlog or bingo), the orchestration layer additionally queries `board_tasks WHERE referencedBoardId = this.id AND isAchievementSquare = true AND !isDeleted` and reruns the board cascade for any boards holding those squares. Reuses the same fan-out pattern that already increments aggregate-mode `achievementProgress` — just a new event handler in the same orchestration step.

**Constraints**:

- **Cycle detection**: a board cannot place a specific-board achievement square that references itself, nor can a chain `A → B → A` (or longer) exist. Validated in shared code at placement time. Aggregate-mode squares (no `referencedBoardId`) don't participate in cycles. Starting algorithm sketch (refine during implementation):
  ```
  hasCycle(candidateBoardId, targetBoardId, allUserBoardTasks):
    // Question: would placing a specific-board square on `candidateBoardId`
    // that references `targetBoardId` create a cycle?
    if candidateBoardId == targetBoardId: return true   // self-reference
    visited = {candidateBoardId}
    queue = [targetBoardId]
    while queue not empty:
      currentBoardId = queue.shift()
      if currentBoardId in visited: return true   // cycle: came back to start
      visited.add(currentBoardId)
      // Walk outgoing referencedBoardId edges from currentBoardId
      for bt in allUserBoardTasks:
        if bt.boardId == currentBoardId
           and bt.isAchievementSquare
           and bt.referencedBoardId
           and not bt.isDeleted:
          queue.push(bt.referencedBoardId)
    return false
  ```
  Data source: load all non-deleted achievement-square `board_tasks` for the user once (typically dozens), not just the candidate board's. Diamond graphs (board A referenced by both B and C, where C is also placed on a square on A) are **not** cycles and are accepted — only direct/indirect cycles back to the candidate are rejected. Open question (decisions log): whether to ship this as a single shared algorithm in `packages/shared` or as paired per-platform validators.
- A square cannot be both specific-board and aggregate — `referencedBoardId` set ⇒ `achievementTimeframe` and `achievementCount` are ignored. Validation ensures the user-facing config form doesn't allow mixed input.
- A specific-board square referencing a soft-deleted board evaluates to `false` (and the cascade ignores it on the target side).

**UI**: square renders with a board-reference badge instead of a count progress bar (e.g., "📌 _Daily Wellness_" with a check or unchecked state). Aggregate-mode squares keep their existing "X / N" progress UI. The achievement-square config sheet gets a new toggle: _"Watch a specific board"_ vs _"Count across timeframe"_.

**Why this beats inventing a new TaskType**:

- Per-placement state is the right semantic — placing "greenlog Daily Wellness" on Monday's daily board and Tuesday's daily board should track _independently_ per placement, not share global state. Achievement squares are already per-`BoardTask`; a global `Task`-level mechanism would have required carving out a per-placement override.
- Reuses the existing `isAchievementSquare` branch in `derivationPass.ts:118` and the existing fan-out wiring; Phase 3 work is bounded to one new field, one new evaluation branch, one new event handler, and one new UI mode.
- Keeps the task-type taxonomy stable at three (Normal / Counting / Compound) — these correspond to _user-facing concepts_, not implementation mechanics.

#### Decisions log

| Date       | Decision                                                                                           | Why                                                                                                                                                                                                                                                                                                                                                                                                     | Status                                 |
| ---------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| 2026-05-01 | Derivation = shared task across boards (no clone path)                                             | Cheapest engineering path; user understands the implication that completing on daily auto-completes parent monthly                                                                                                                                                                                                                                                                                      | Locked                                 |
| 2026-05-01 | MVP = timeframe-prompted only; Phase 2 + 3 deferred                                                | Lowest-risk first ship; learn from real usage before committing to template entity or achievement-square specific-board mode                                                                                                                                                                                                                                                                            | Locked                                 |
| 2026-05-02 | Phase 3 = extend achievement squares (specific-board mode), **not** a new TaskType                 | Achievement squares already cover cross-board completion as a square criterion, with the right per-placement state semantics. Inventing TaskType.VIRTUAL would have created a parallel mechanism with global state semantics that don't fit (placing the same goal on Mon/Tue daily boards should track independently). Keeps TaskType taxonomy at user-facing concepts (Normal / Counting / Compound). | Locked                                 |
| 2026-05-01 | Multi-window UX = non-blocking banner on Boards tab                                                | Lowest friction; user can dismiss individually or disable in prefs for permanent suppression                                                                                                                                                                                                                                                                                                            | Locked                                 |
| 2026-05-01 | Pool trigger (Phase 2) = lazy on app-open                                                          | No background-task infrastructure; matches Phase 1 pattern                                                                                                                                                                                                                                                                                                                                              | Locked (Phase 2)                       |
| 2026-05-01 | Custom-timeframe recurrence excluded from Phase 1                                                  | `Timeframe.CUSTOM` requires user-specified dates per board — incompatible with "compute current window automatically" detection                                                                                                                                                                                                                                                                         | Locked (revisit if Phase 2 demands it) |
| TBD        | Permanent dismissal: should the banner offer "skip this window forever" alongside session-dismiss? | Risk of accidental clicks; current plan = session-only, prefs toggle for permanent                                                                                                                                                                                                                                                                                                                      | Open                                   |
| TBD        | Phase 3 cycle-detection placement: shared algorithm or per-platform validator?                     | Shared package preferred for parity (walks `referencedBoardId` edges across `board_tasks`); not yet sketched                                                                                                                                                                                                                                                                                            | Open (Phase 3)                         |
| TBD        | Phase 2 `poolStrategy` semantics: how does `random_subset` interact with `boardSize²`?             | Probably draw `boardSize² - centerCount` from `seedTaskIds` per spawn; not finalized                                                                                                                                                                                                                                                                                                                    | Open (Phase 2)                         |

---

This plan represents a complete rebuild of OYBC with offline-first architecture, designed to provide instant UX and work perfectly without internet connection.
