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
progress_counters       -- Vestigial dead (superseded by the Task.sharedCounterId
                           model — see docs/SHARED_COUNTERS.md); no live reads/writes.
sync_queue              -- Pending Firestore operations.
```

There is no `bingo_lines` table on either platform. Bingo state is denormalized directly onto `boards` (`linesCompleted` count + `completedLineIds` JSON array of line ids) and is always recomputed from the task-completion grid via `detectBingos` (`packages/bingo-core/src/bingoDetection.ts`, re-exported through `@oybc/shared`; Swift twin `Services/BingoDetection.swift`) — never trusted as authoritative during a sync conflict. See `docs/TASK_SYSTEM.md` §Global completion semantics / derivation pass.

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

**Achievement squares** shipped subsequently in Phase 6.3 (PR #54) as the `TaskType.ACHIEVEMENT` first-class type. The `ProgressCounter` open question below was resolved by Decision 1 (§Shared Counters) — the entity was **not** surfaced; counter-sharing instead ships as the per-Task `sharedCounterId` FK model, with `ProgressCounter`/`TaskProgressCounter`/`calculateCountingRollup` left vestigial-dead (web dropped the Dexie store at v11; iOS still declares the inert `progress_counters` table — tracked in `docs/ROADMAP.md` Track C5).

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

**Non-goals (Phase 1)**: no automatic background creation, no shared boards across users, no recurring custom-timeframe boards. Each is in scope for a later phase if real usage demands it; speculating now buys nothing.

> **Superseded (Phase 7):** "no notifications, no reminders" was a Phase-1 non-goal but is no longer in force. Phase 7 added **local OS-scheduled notifications on iOS** (board-expiring / new-recurring-window / daily-play reminders). These reschedule on app-open and are delivered by the OS with **no background execution and no DB write**, so the still-binding invariants — no automatic background board creation, no server push — are intact. Web notifications remain deferred. See `docs/NOTIFICATIONS.md` and CLAUDE.md §Notifications.

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

**No `Board`, `Task`, or `BoardTask` schema changes.** The iOS `User` GRDB model needs a small migration to add 4 boolean columns; the four `boards` / `tasks` / `board_tasks` tables are untouched. (Shipped with an effective default of `true` for all four — `DEFAULT_USER_PREFERENCES` in `packages/shared/src/types/user.ts` — i.e. recurrence is on by default.) Four new fields appended to `UserPreferences` (in `packages/shared/src/types/user.ts`):

```ts
export interface UserPreferences {
  // ...existing 7 fields...
  recurringDailyEnabled: boolean; // default true (shipped all-true post-6.1d)
  recurringWeeklyEnabled: boolean; // default true
  recurringMonthlyEnabled: boolean; // default true
  recurringYearlyEnabled: boolean; // default true
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

#### Core Board window pager — shipped

The Boards-tab **Core boards** rows previously opened the per-timeframe browser (a vertical list of windows). They now open the **current window's board directly**, with prev/next paging between windows; the browser is demoted to a secondary view reached from a `≡ list` button in the pager header.

- **Routing**: web adds `/boards/core/:timeframe/:date` (`CoreBoardWindowPage`) alongside the existing browser route `/boards/core/:timeframe`; iOS adds a `CoreWindowRoute(timeframe, windowStart)` navigation value → `CoreBoardWindowView`. The Core board row seeds the route with the current window's start date.
- **Empty windows are lazy**: when no core board exists for a window, the pager shows a setup prompt ("No board for <label> yet" → "Set up"/"Backfill"), which launches the wizard prefilled for that window. **No board row is written until the user acts** — the same no-auto-spawn invariant that governs the rest of Phase 6 (navigating to a window never creates a board).
- **Prev/next is an in-place state change, not a navigation push**: the pager owns the current-window state and re-resolves the board for the stepped window (via the shared `stepWindow` / iOS `stepCoreBoardWindow`). This avoids the iOS NavigationStack destination-reuse trap (a pushed destination is reused when the path's only element swaps) and avoids polluting web history. Paging is unbounded in both directions (past = backfill/review, future = pre-build). iOS guards rapid stepping with a `reloadToken` stale-result check.
- **Timezone**: the web route's date-only `:date` param is parsed as **local noon** (`new Date(\`${date}T12:00:00\`)`), not `new Date(date)` — a date-only ISO string parses as UTC midnight, which lands the daily pager on *yesterday's* window for users west of UTC.
- **Platform divergence (intentional)**: web extracts a presentational `BoardPlaySurface` from `BoardPlayPage` and reuses it in both the `/boards/:id` page and the pager; iOS embeds the existing `BoardPlayView` whole behind a new `embedded` flag (it self-loads by `boardId`, so embedding is lower-risk than extraction). Same behavior on both platforms. (Post-B2: both play surfaces have since had their write logic extracted — web into `useBoardPlayData`/`useBoardPlay` hooks + `toggleTaskCompletionAndCascade` operation (`BoardPlaySurface.tsx` now ~1,088 lines), iOS into `BoardPlayViewModel` (DB-injected, unit-tested; `BoardPlayView.swift` now ~2,000 lines of rendering). The `embedded`-flag structure itself is unchanged.)

## Wizard "From a board" picker

> Design captured 2026-06-01; **shipped** via PR #82 and Riso-reskinned in PR #128. Section is the canonical record of the design.

The wizard's Step 2 (Tasks) currently lets the user pick from their library list, filter by type, and surface tasks from currently-active **parent** boards via the `From parent boards` chip ([Phase 6.1](#three-phase-vision)). There is no way to visually browse another board's grid and pull its tasks across — every cross-board task add happens as a flat-list selection. "From a board" adds a sibling chip `From a board…` that swaps the list region for a source-board picker, then for the chosen board's actual grid, so users can compose a new board against the spatial layout of an existing one.

### Motivation

The strongest cross-board task-reuse pattern in OYBC's data ("I want this week's board to be like last week's, plus a few changes") has no first-class affordance. Today the user remembers the task titles, then types into search or scrolls the library. The `From parent boards` filter only helps when the source is a currently-active parent (a daily wizard can see its active weekly/monthly/yearly — not last week's daily or an unrelated yearly). This feature generalizes that path to "any board you've been working in recently" and adds a graphical grid view so recognition replaces recall.

**Non-goals**: a board-builder copy/clone tool (the wizard itself remains the only board-creation path); a way to copy an entire board's geometry + tasks in one shot (users can `⧉ Add all subtasks to board` on a compound or tap individual squares — bulk-add of all squares is intentionally not offered, to keep curation explicit).

### Locked design

#### Entry

New filter chip `From a board…` in the wizard's Tasks step (`BoardWizardTasksStep` / `BoardWizardTasksStepView`), sibling to `From parent boards`. Unlike the parent-boards chip, this one is **not** timeframe-gated — any wizard timeframe is a valid context for browsing another board. Tapping the chip swaps the list region inline (no modal, no nav push), matching how the existing filter chips already drive list-region content.

#### Source-board picker

When the chip is active and no source is selected, the list region renders a vertical list of **mini-grid cards**, one per eligible source board. Each card shows a count-based mini-grid thumbnail (`RisoMiniGrid` — scatters filled cells by the board's completed-count) + the board name + timeframe + window label + completion ratio. (An earlier per-cell-exact renderer, `BoardThumbnailView`, was superseded by `RisoMiniGrid` and removed.)

**Eligibility**: `Board.status === ACTIVE` ∪ `(status === COMPLETED && completedAt within last 30 days)`. Drafts and archived boards are excluded — drafts have no real task set; archived are intentionally out-of-view. Sorted recently-active first (`updatedAt desc`). Empty state: "No boards to browse. Create another board first, or build this one from scratch."

#### Source-board grid

After the user picks a source, the list region renders the source board at its actual geometry (3×3, 4×4, 5×5, or chosen variants). Each square is a tappable button with the task title centered. A header line shows `Source: <name> ▾` — the chevron lets the user swap to a different source without losing the running selection (selection lives in wizard state, not in the picker).

#### Per-square interaction

| Gesture                 | Behavior                                                                                          |
| ----------------------- | ------------------------------------------------------------------------------------------------- |
| Single tap              | **Link** the underlying `Task` into the new board's selection. No new Task is created.            |
| Long-press / right-click | Floating context menu (reuses existing `RowContextMenu` / SwiftUI `.contextMenu`) — see below.    |

#### Context-menu vocabulary

Reuses the existing `RowContextMenu` items + glyphs verbatim where they apply (so the user's mental model of the wizard's quick actions extends to the grid for free). Items only render when applicable to the square's type:

- `+ Add to board (link)` / `− Remove from board` — toggle; `(link)` hint disambiguates from the copy item below
- `⎘ Add a copy of this task…` — opens the Copy modal (see below)
- `⇣ Derive smaller version…` — counting tasks only; reuses the existing `DeriveCounterModal`
- `⧉ Add all subtasks to board` — compound tasks only (flattens the compound's primitive leaves into the new board's selection). The grid is fixed-geometry per the source's layout, so the list view's inline `▼ Expand subtasks` affordance has no analogue here — compounds either link as one square or get flattened via this item.
- `↗ Open in library` — always

#### Square visual states

All state communicated via color / border, never overlay text (preserves title centering):

- **Linked**: blue tint background (`selectedTaskIds.has(task.id)`)
- **Copied this session**: amber tint background (id in local `copiedThisSession: Set<string>`)
- **Expired**: 35% opacity, non-tappable, small "expired" pill (matches the existing `isTaskExpired` filter convention in the wizard list)
- **Source's center**: orange border. Tap still Links the task; the ★ does *not* transfer — the user can mark the new board's center via the existing list-view `★ Set as center task` flow after linking
- **Compound parent**: existing `C` badge; tapping links the compound as one square (`+ Add to board (link)` semantics); `⧉ Add all subtasks` from the menu flattens it
- **Achievement**: full parity (no dimming, no special restriction) — see invariants below

#### Copy modal

Opened from `⎘ Add a copy of this task…`. Pre-fills every field from the source task; per-type editable surface:

| Source type | Editable fields                                                                                       |
| ----------- | ----------------------------------------------------------------------------------------------------- |
| Normal      | Title                                                                                                 |
| Counting    | Title, `action`, `maxCount`, `unit`                                                                   |
| Compound    | Title only — children references stay shared (shallow copy; new parent, same children)                |
| Achievement | Title, `achievementTrigger`, reference picker (`referencedBoardId` XOR `referencedTemplateId`), `requiredCount` (when template mode) |

On Save: calls `copyTask(userId, sourceTask, overrides)` or `copyCompound(userId, sourceTask, overrides)` in `db/operations/tasks.ts` (web) / new helper in `AppDatabase.swift` (iOS). For Achievement copies, cycle detection (`hasCycle` from `packages/shared/src/algorithms/cycleDetection.ts`) is **not** invoked at copy time — the copy creates a Task that has no placements yet, so `parentBoardIds` is empty and the algorithm trivially returns `{ ok: true }`. The real cycle check fires at the existing Phase 6.3 gate: when the wizard's "Create board" commit places the (possibly newly-copied) Task on the new board. Edge surfaced inline at that step, same as a brand-new ACHIEVEMENT task placed via `+ New task`.

### Data flow

- **Reads**: `useSourceBoards(userId)` mirrors `useParentBoardTasks` (Dexie `useLiveQuery` + `boardId` index). `useSourceBoardPlacements(boardId)` fetches `BoardTask[]` + the matching `Task[]`. iOS twins live on `SourceBoardsViewModel` and reload on `.onAppear` (no SwiftUI `useLiveQuery`).
- **Writes**: Link is a normal placement — same write path the existing wizard's "Next ›" already uses for the selection set; no new code. Copy is a normal `createTask` / `createCompound` call with field overrides; for Achievement copies, gated by the existing cycle-detection algorithm.

### Invariants

- **Link is a UI filter, never a clone path** — same invariant Phase 6.1 locked for `From parent boards`. The user selecting a linked square places the *same* `Task` on the new board; completion remains globally shared per Task.
- **Copy is a normal `createTask` / `createCompound`** — no special table, no special validation. The Zod refinements in `packages/shared/src/validation/schemas.ts` (`referencedFieldsOnTaskMutuallyExclusive`, `achievementRequiresReference`) already cover the Copy modal's commit path because it routes through the same helpers as the `+ New task` sheet.
- **Compound copies are shallow** by default — new parent, same children (which are themselves first-class `Task`s under the unified model). A deep-clone path is not provided; the user can always create independent primitives via `+ New task` if that's what they want.
- **Achievement copies are gated at wizard commit, not at copy commit** — Phase 6.3's cycle-detection (`hasCycle`) runs when the wizard *places* the (copied) Task on the new board, not when the Copy modal saves. A brand-new copy has no placements, so a pre-commit `hasCycle` call is trivially `{ ok: true }`. This matches how a fresh ACHIEVEMENT task created via `+ New task` flows: validation happens at placement time. Cycle errors surface inline on the wizard's commit step.
- **No bulk-add-all-squares affordance** — `⧉ Add all subtasks to board` on a compound is intentionally the only bulk-add path. "Add every square from this source" would defeat the curation step the wizard exists to enable.

### Status

| Step | State |
| --- | --- |
| Design (this section) | Locked 2026-06-01 |
| Branch | `feature/wizard-from-a-board` |
| PR | TBD — link added when opened |

## Shared counters (Issue #84 — Phase 0 design)

> Design captured 2026-06-04; investigation / Phase 0 only — no implementation yet. Section is the canonical record for the locked design decisions that unblock Phases 1–4 (playground spike → UI → increment integration → sync), kept in sync as those phases land. PR link added under **Status** when each phase opens.

The create-task interface lets a user pick an existing counting task as a "template" (`CountingTemplatePicker` / `CountingTemplatePickerView`), but the picker only prefills `action` + `unit` into a brand-new, fully independent task — there is no mechanism for two distinct counting tasks to share a running total. Dormant scaffolding exists: `ProgressCounter` + `TaskProgressCounter` types live on both platforms (no production callers, not in `SYNCABLE_COLLECTIONS`); `calculateCountingRollup()` lives in the shared TS algorithms only (no Swift twin, no production callers — only `packages/shared/tests/algorithms/crossBoardSharing.test.ts` exercises it). This section locks the seven design decisions called out in [Issue #84](https://github.com/2014sheas/oybc/issues/84) so the Phase 1 playground spike, Phase 2 UI, Phase 3 increment integration, and Phase 4 sync can proceed without re-litigating the model on each PR.

### Motivation

The example from the issue body: a user has **"Read 100 pages"** as a daily task and wants to create **"Read 5,000 pages"** as a yearly task that draws on the *same* page-count total. Every page logged on the daily should also advance the yearly. Two flavors of new-task semantics:

- **Inherit**: the yearly shows pages already logged historically.
- **Start from zero**: the yearly shows `0 / 5000` today, but each new page still increments the shared total (and the daily) going forward.

Today the user has no first-class way to do this. The shallow "template" affordance creates a duplicate, fully independent counter — completing one has no effect on the other. The feature closes that gap by introducing a **shared accumulator** that multiple counting tasks read from, each with its own **threshold** and **baseline offset**.

**Non-goals**: a separate user-managed "Counter" object surfaced in its own tab or library; cross-user shared counters; aggregating counts from non-counting task types into a counter. Phase 0 explicitly chooses to keep "existing counters" = "existing COUNTING tasks" (see decision #1).

### Locked design

#### Decision 1 — Model: per-Task `sharedCounterId` FK, NOT revive `ProgressCounter`

**Locked**: Add `sharedCounterId: string | null` to `Task`. A counter-sharing task is a `TaskType.COUNTING` task whose `sharedCounterId` points at another COUNTING task — the **source** — whose `currentCount` becomes the shared accumulator. The dormant `ProgressCounter` / `TaskProgressCounter` / `calculateCountingRollup` scaffolding stays dead and is removed in Phase 4 (see the cleanup note under [Phasing](#phasing)).

**Rationale**: "existing counters = existing COUNTING tasks" (per the issue's first open question) is the user's mental model — they pick a source counting task from `CountingTemplatePicker`, which already filters to `TaskType.COUNTING`. Promoting `ProgressCounter` to a first-class user-visible object would mean a second concept ("counter" vs "task") competing for library shelf space, plus a migration to convert existing counting tasks into counters. The FK model keeps the user-visible vocabulary at one noun (Task), reuses every existing counting-task UI surface (library row, detail sheet, type filter), and makes the source/derived relationship inspectable from either end. The trade-off is that "the accumulator lives on a Task" means deleting the source Task needs a defined behavior (see invariants below) — but `ProgressCounter` had the same problem in a different shape (orphaned counter rows).

**Implication for the other six decisions**:
- Decision 2 baseline lives on the *derived* Task (`baseline: number | null`), not on a link row.
- Decision 3 threshold = `Task.maxCount` (no schema change needed).
- Decision 4 hot path walks tasks by `sharedCounterId === sourceTaskId`, not a link table join.
- Decision 5 the syncable entity is `tasks` (already syncable) — we don't add `progress_counters` to `SYNCABLE_COLLECTIONS`. The additive-merge problem moves onto `Task.currentCount`.
- Decision 6 timeframe-scoped reset becomes a baseline-mutation operation on the derived Task, not a counter-reset operation.
- Decision 7 file pairs reduce to existing `tasks.ts` / `Task.swift` plus the picker + increment hot path; no new tables, no new sync collections.

**Schema delta**:

| Surface | Change |
| --- | --- |
| `packages/shared/src/types/task.ts` | Add `sharedCounterId?: string` and `baseline?: number` to `Task` interface. Both optional; absent ⇒ task is a standalone counter (today's behavior). |
| `packages/shared/src/validation/schemas.ts` | Add fields to `TaskSchema`. Add a refinement: `sharedCounterId` non-null ⇒ `type === COUNTING` AND `baseline` is a non-negative number. |
| `apps/web/src/db/database.ts` (Dexie) | New migration: add `sharedCounterId` to the `tasks` schema string (`'id, userId, type, sharedCounterId, ...'`) so Dexie can index it. No data backfill (existing rows get `undefined`). |
| `apps/ios/OYBC/Database/Schema.sql` | `ALTER TABLE tasks ADD COLUMN sharedCounterId TEXT;` + `ALTER TABLE tasks ADD COLUMN baseline REAL;`. New index `idx_tasks_shared_counter ON tasks(sharedCounterId) WHERE sharedCounterId IS NOT NULL`. |
| `apps/ios/OYBC/Database/Models/Task.swift` | Add `var sharedCounterId: String?` and `var baseline: Double?`. Update the `init(from:)` mirror in `UserPreferences`-style forward-compatible decode (decode-if-present, default nil). |
| Both platforms — migration version bump | iOS adds a numbered migration (`migrate_addSharedCounterColumns`). Web bumps the Dexie schema version and adds the index in the `.upgrade()` callback (no data transform). |

The retired `ProgressCounter` / `TaskProgressCounter` / `calculateCountingRollup` scaffolding is **not removed in Phase 1** — left in place during the spike so the diff is reviewable. Removed in Phase 4 alongside the sync work (so the cleanup commit and the sync commit ship in the same PR — one decision, one diff). Follows the Phase 8 cleanup precedent from the compound-tasks unification.

#### Decision 2 — Baseline semantics: per-Task `baseline` field, displayed = `sourceTask.currentCount - thisTask.baseline`

**Locked**: A derived task carries a `baseline: number` (default 0). Its displayed count = `sourceTask.currentCount - thisTask.baseline`, clamped at zero on the low end only (see [Counter-overshoot invariant](#counter-overshoot-invariant) for the high end). Completion latches when `displayed >= thisTask.maxCount` (same one-way latch as today's counting tasks). "Inherit existing count" sets `baseline = 0`; "Start from zero" sets `baseline = sourceTask.currentCount` at the moment the derived task is created.

**Rationale**: A per-Task offset is the minimum new state needed to express both inherit (offset 0) and start-from-zero (offset = current value at creation) without forking the accumulator. The alternative — duplicate the accumulator value per-task and add increments to all of them on every write — works but recreates the "n independent counters" problem the feature is trying to escape, and trades a single source-of-truth value (one `Task.currentCount` on the source) for n separate per-derived-task counters that must be kept in sync. Offset math has a single accumulator and n stateless derivations; LWW conflicts on the offset itself are inert (the offset is only set at creation; if it ever changes — see Decision 6 — that's a deliberate user action, so plain LWW on `baseline` is correct).

**Implication for the other six decisions**:
- Decision 4 the derivation pass reads `sourceTask.currentCount` and computes `displayed = max(0, sourceTask.currentCount - baseline)` for every derived Task that has `sharedCounterId === sourceTaskId`. No write to derived rows in the simple case (count + completion are pure functions of source + baseline + maxCount).
- Decision 5 since `displayed` is computed, conflicts on the *derived* Task only matter for `baseline` (set-once at creation, near-impossible conflict) and `maxCount` (the user editing the threshold — normal LWW is fine).
- Decision 6 "timeframe-scoped baseline reset" = `baseline := sourceTask.currentCount` re-applied at window boundaries. v1 scope: see Decision 6.

**Storage of derived `currentCount`**: open question whether to store `Task.currentCount` on derived tasks at all, or compute it lazily everywhere. Locked answer: **don't store it on derived tasks**. The derived Task's `currentCount` field becomes computed-only (`source.currentCount - baseline`). The cell renderer, the increment hot path, and the cascade pass all read it via a shared helper (`deriveDisplayedCount(task, sourceTask)`) from `packages/shared/src/algorithms/`. Reasons:
- Two values that must agree (stored derived count + source accumulator) is the silent-divergence bug class we already burn time on for board stats.
- Sync is simpler — only the source's `currentCount` ever changes from a user increment; the derived rows don't need write traffic on every tap.
- `isCompleted` is still stored on the derived Task (one-way latch, sync-relevant — see overshoot invariant).

#### Decision 3 — Threshold: reuse existing `Task.maxCount`

**Locked**: The derived task's "larger or smaller" target is its own `Task.maxCount`. No new field. The Phase 2 picker UI exposes a `Threshold` input that maps 1:1 to `maxCount` on the new Task being created.

**Rationale**: `maxCount` already exists on every counting Task and is the field every existing renderer (`InteractiveTaskSquare`, `TaskDetailPage`, the counting-row in the wizard) reads to compute progress percentage and decide cell completion. Inventing a new field would just create a parallel state. The `TaskProgressCounter.targetValue` field from the dead scaffolding is also a `targetValue: number` — same shape — but since `TaskProgressCounter` is being retired (Decision 1), `maxCount` is the surviving home.

**Implication for the other six decisions**: none — this decision is the smallest. Decision 1's `sharedCounterId` is the only schema addition driven by the threshold/source-of-truth concern; `maxCount` does not need to change.

#### Decision 4 — Increment hot-path rewrite: derivation pass extends `runBoardCascadeForTask`

**Locked**: The existing `runBoardCascadeForTask(changedTaskId)` (web `apps/web/src/db/operations/orchestration.ts`; iOS twin embedded in `BoardPlayView.swift`'s cascade block) becomes the single hook point. On any write to a counting Task's `currentCount`, after the existing parent-compound / affected-board derivation, a **new sub-pass** runs:

1. Query all Tasks where `sharedCounterId === changedTaskId AND isDeleted === false`. Call this set `derivedTasks`.
2. For each derived Task `dt`:
   a. Compute `displayed = max(0, changedTask.currentCount - dt.baseline)`.
   b. Compute `newCompleted = displayed >= dt.maxCount` (one-way latch — if `dt.isCompleted` was already true, leave it true even on `displayed` decrease; see overshoot invariant for the > maxCount case).
   c. If `newCompleted !== dt.isCompleted`, write the new `isCompleted` + `completedAt` + bumped `version` on `dt`. This is the only derived-Task write the pass performs.
   d. Recursively call `runBoardCascadeForTask(dt.id)` so the board stats / bingo detection / status transitions for every board `dt` is on get recomputed. The recursion is bounded — `dt` has `sharedCounterId !== null`, and a derived task cannot itself be a source (see invariants), so depth is exactly one extra hop.

The recursive call into `runBoardCascadeForTask(dt.id)` already exists as the right primitive — it's the same cascade that fires today when a compound child completes. The new sub-pass only adds the "find shared-counter consumers" lookup and the derived-Task completion write. The bingo / greenlog / board-status transitions are handled by the existing recursion.

**Rationale**: Extending `runBoardCascadeForTask` rather than introducing a parallel "counter cascade" function reuses the existing transactional boundary (the function is already required to be called inside the Dexie / GRDB transaction), reuses the existing sync-enqueue path, and means the new code is reviewable as a single addition to one already-well-tested function. The alternative — a separate `runSharedCounterCascade` that is called alongside — duplicates the find-affected-boards and enqueue-sync logic and creates two transactional boundaries that must agree. One function, one transaction, one mental model.

**Implication for the other six decisions**:
- Decision 5 the sub-pass is inside the existing transaction, so additive-merge work (Decision 5) operates on the *push/pull* layer, not on the local-write layer. The local hot path stays linear.
- Decision 7 only `orchestration.ts` and the iOS cascade block in `BoardPlayView.swift` need touching for the hot-path rewrite. The render layer (cell, detail) needs the new `deriveDisplayedCount` helper.

**Where the new hook attaches**: in `runBoardCascadeForTask`, immediately after the `for (const affectedBoardId of affectedBoardIds)` loop completes for the source Task's own boards, before the function returns. iOS twin: same position in the `await db.write { ... }` block inside the cascade closure.

#### Decision 5 — Sync / conflict: additive merge on `Task.currentCount` for shared-counter sources

**Locked**: A counting Task with at least one derived Task (i.e., another Task references it via `sharedCounterId`) becomes an **additive-merge source**. On sync conflict (local version + remote version both incremented since `lastSyncedAt`), instead of plain LWW on `currentCount`, the resolver computes:

```
mergedCount = remoteCount + (localCount - baseAtLastSync)
```

where `baseAtLastSync` is the locally-stored `lastSyncedCount` value (new field on `Task`, populated at every successful push of a counting Task). The semantics: "apply our local delta on top of whatever the remote agreed value is." Both devices' increments contribute; concurrent increments are summed, not lost.

Plain LWW silently loses counts in the multi-device case: if device A increments 100→105 and device B independently increments 100→103, the higher-version write wins and 2 (or 5) of the 8 total increments evaporate. Additive merge preserves both deltas: `103 + (105 - 100) = 108`.

**Rationale**: The semantically-correct merge for a monotonically-increasing accumulator on a deterministic-action ledger ("the user logged 5 more pages, then the user logged 3 more pages") is to sum the deltas — anything else throws away user-recorded data. Plain LWW is correct for the `maxCount` / `title` / `action` fields of a counting Task (those are user edits, not increments), so the rule is scoped: **additive merge applies to `currentCount` only, and only when the Task is a shared-counter source**. Standalone counters (no derived Tasks pointing at them) stay on plain LWW for v1 — the additive-merge complexity is paid only where it matters. (Whether to extend additive merge to *all* counting Tasks regardless of derived consumers is left to a future cleanup once the shared-counter codepath is proven; the issue's third open question raises this and v1 doesn't force a global answer.)

**Reference**: Phase 6.3 handled a comparable additive concern with the cycle-detection algorithm in `packages/shared/src/algorithms/cycleDetection.ts` and the achievement-trigger sync invariants in [§Phase 6.3](#phase-6-recurring-boards--shipped). The pattern there — put the merge logic in `packages/shared/src/algorithms/`, call it from both `syncService.ts` (web) and `SyncService.swift` (iOS), validate the inputs with shared Zod refinements — is the precedent. The new file: `packages/shared/src/algorithms/sharedCounterMerge.ts` exporting `mergeCounterValue(local: number, remote: number, base: number): number` plus a Jest spec covering: clean local-wins, clean remote-wins, both-incremented, both-incremented-with-decrement (a user editing `currentCount` down to correct a typo — the merge still sums the local delta, so a decrement local + increment remote produces a smaller-than-remote result, which is the correct interpretation of "the user said the local count is wrong by this much").

**Implication for the other six decisions**:
- Decision 1 the new `lastSyncedCount` field is per-Task (lives on `Task`, sets at push completion) — fits the FK model.
- Decision 4 the local hot path doesn't change — additive merge only fires on pull/push conflict resolution, never on local increment.
- Decision 7 sync changes touch `syncService.ts` (web) + `SyncService.swift` (iOS) + the new shared algorithm file.

#### Decision 6 — "…for the specified timeframe": static baseline only in v1; no timeframe-scoped resets

**Locked**: v1 ships with a **static baseline** set once at derived-Task creation. There is no automatic baseline reset on timeframe windows (daily / weekly / monthly / yearly rollover). The Phase 2 picker UI exposes only the binary "Inherit" / "Start from zero" choice.

**Rationale**: Timeframe-scoped baseline resets — e.g., "the derived weekly task starts from zero every Monday but the yearly accumulator keeps climbing" — are a real user need but introduce three new sub-problems that v1 does not need to solve: (a) when exactly the reset fires (lazy on app open vs. background scheduler — see the Recurring Boards lazy-detection invariant), (b) how the reset interacts with multi-device sync (two devices both detecting the rollover and both writing a new baseline), and (c) how it interacts with the `isCompleted` latch (does completion clear on rollover? for which timeframe?). All three are tractable but each is its own design discussion. Shipping static baselines first lets the feature land, get usage feedback, and lets timeframe resets be added in a v2 PR once we know which combinations users actually want.

**Implication for the other six decisions**:
- Decision 2 `baseline` is set on Task creation only. Edits to it are not exposed in v1 UI.
- Decision 4 the derivation pass never mutates `baseline` — it's pure read-side state in the cascade.
- Decision 5 since `baseline` doesn't change after creation in v1, sync conflicts on it are degenerate (two devices creating two different derived Tasks with two different baselines is fine — they're different Tasks).
- Decision 7 no calendar/window code touched in v1.

#### Decision 7 — Cross-platform parity: file pairs that must change in lockstep

**Locked**: Every PR across Phases 1–4 ships web + iOS together per the CLAUDE.md cross-platform rule. The representative file pairs (not exhaustive):

| Concern | Web | iOS |
| --- | --- | --- |
| Shared model + schema | `packages/shared/src/types/task.ts`, `validation/schemas.ts` | (consumed via Codable; mirror updates in `Database/Models/Task.swift`) |
| Local DB schema | `apps/web/src/db/database.ts` (Dexie migration) | `apps/ios/OYBC/Database/Schema.sql` + numbered migration in `AppDatabase.swift` |
| Picker UI (Phase 2) | `apps/web/src/components/wizard/CountingTemplatePicker.tsx` | `apps/ios/OYBC/Views/CreateTab/Components/CountingTemplatePickerView.swift` |
| Increment hot path (Phase 3) | `apps/web/src/db/operations/orchestration.ts` (`runBoardCascadeForTask`) | `apps/ios/OYBC/Views/BoardsTab/BoardPlayView.swift` cascade block + `apps/ios/OYBC/Database/AppDatabase.swift` |
| Derivation helper (Phase 1+) | `packages/shared/src/algorithms/sharedCounterDerivation.ts` (new) | (consumed via shared; iOS reads it through the TS-mirrored Swift port — by convention this file gets a Swift twin in `apps/ios/OYBC/Algorithms/` since cross-platform algorithms aren't bridged from `@oybc/shared` at runtime) |
| Sync conflict resolver (Phase 4) | `apps/web/src/firebase/syncService.ts` + new `packages/shared/src/algorithms/sharedCounterMerge.ts` | `apps/ios/OYBC/Services/SyncService.swift` + Swift port of the merge function |
| Cell renderer | `apps/web/src/components/InteractiveTaskSquare.tsx` (read displayed via helper) | `apps/ios/OYBC/Views/Components/InteractiveTaskSquareView.swift` |

**Rationale**: Matches the cross-platform file-structure rule in CLAUDE.md (`Cross-Platform File Structure` §) and the iOS-twin convention. The shared algorithm pattern is the same one Phase 6.3 used for cycle detection — TypeScript home in `packages/shared/src/algorithms/`, hand-mirrored Swift port for iOS consumers. Listed by concern (not by Phase) because Phases 1–4 each touch a subset; the playground spike (Phase 1) only touches the derivation helper, the UI phase only touches the picker, etc.

**Implication for the other six decisions**: none — this decision is purely the implementation map. It does constrain the Phasing order: nothing that touches the hot path or picker can land without its twin in the same commit.

### Data flow

End-to-end on a single shared-counter increment (post-Phase 3):

1. **User taps `+` on the source task's cell** (e.g., "Read 100 pages") on board X. `InteractiveTaskSquare` calls `handleTaskCompletion(boardX, btSourceOnX, { currentCount: source.currentCount + N })`.
2. **`handleTaskCompletion` writes the new `currentCount` on the source Task** (existing code — no change). Inside the same transaction it calls `runBoardCascadeForTask(sourceTaskId)`.
3. **`runBoardCascadeForTask`** runs its existing pass for board X (recomputes stats, status, sync queue for board X), then the **new sub-pass**:
   a. Look up `derivedTasks = tasks.where({ sharedCounterId: sourceTaskId, isDeleted: false })`.
   b. For each derived Task `dt`, recompute `displayed = max(0, source.currentCount - dt.baseline)` and `newCompleted = displayed >= dt.maxCount` (one-way latch).
   c. If `dt.isCompleted` changed, write the new latch state on `dt` (bumped version, syncQueue entry).
   d. Recursively call `runBoardCascadeForTask(dt.id)` — this handles every board `dt` is placed on, plus any compound parents `dt` belongs to (existing recursion does this).
4. **Sync (Phase 4)**: `pushSync` drains the `tasks` queue. The source Task push carries `currentCount + version`. On a conflict-detected push, the resolver invokes `mergeCounterValue(localCount, remoteCount, lastSyncedCount)` and writes the merged value back to local (bumping version again) before re-attempting the push.
5. **Pull (Phase 4)**: when a remote source-Task update arrives, `runBoardCascadeForTask(remoteTaskId)` fires the same sub-pass on the receiving device, so all derived Tasks re-derive without needing their own per-device push.

### Invariants

- **No cycles in `sharedCounterId`** — a Task `A` with `sharedCounterId = B` cannot itself be a source. The check needs DB context (must query the task table for any other Task with `sharedCounterId = thisTask.id`), so Zod's shape-only refinements can't enforce it. Implement as: (a) a pure predicate `isValidSharedCounterChain(candidate, allTasks)` in `packages/shared/src/algorithms/` (mirroring Phase 6.3's `hasCycle`), (b) called by the create / update helpers (`createTask` / `updateTask` web; `AppDatabase.shared.createTask` / `updateTask` iOS) before the write commits, with `allTasks` fetched from the live DB at call time. Zod stays responsible for shape (the field is a valid Task id or null); the chain check is the write-helper's job. (Two-level chains would force the derivation pass to recurse beyond depth 1 and make the additive-merge semantics ambiguous — what's the "source of truth" accumulator when there are three of them? Not a feature, just a footgun.)
- **Deleting the source Task soft-deletes its derived Tasks too** (cascade, mirrors `deleteTaskWithCascade` for compound children). The derived Tasks become useless without their accumulator; orphaning them produces "always 0 / N" zombie squares. The cascade preview modal (existing `computeTaskDeletionImpact`) gets a new branch for "this task is a shared counter source for N other tasks — they will be deleted too."
- **`baseline` is set once at creation and not user-editable in v1** (per Decision 6). The Task-detail-view edit sheet hides the field. Phase 5 v2 might expose it; v1 does not.
- **Additive merge applies only to shared-counter sources** (Decision 5). Standalone counters keep plain LWW. The conflict resolver checks `derivedTasks.length > 0` before invoking the additive path.
- **Derived Task `currentCount` is computed, never stored** (Decision 2). The Dexie / GRDB row keeps the field nullable; reads always go through `deriveDisplayedCount(task, sourceTask)` from the shared algorithm. Storing it would re-introduce the silent-divergence bug class.
- **Compound containment is orthogonal** — a shared-counter derived Task can itself be a child of a compound Task (it's still a normal `Task`). The compound-rollup math reads the derived Task's `isCompleted` latch, which is already maintained by the derivation pass. No special case needed in the compound cascade.

### Counter-overshoot invariant

Per agent memory `feedback_counter_overshoot_is_valid`: counter tasks may legitimately have `currentCount > maxCount`, and the cell stays completed forever — overshoot is a load-bearing UX affordance, never "fixed" by clamping. The new derivation MUST preserve this:

- **`displayed = max(0, source.currentCount - baseline)` clamps the *low* end only** (a baseline larger than the source value yields 0, not a negative). The high end is **not clamped** — if `source.currentCount = 5500` and `baseline = 0` and `dt.maxCount = 5000`, the displayed value is `5500`, the cell shows `5500 / 5000`, and `isCompleted = true` stays latched.
- **The one-way latch on `dt.isCompleted` stays the same as today**: once `displayed >= dt.maxCount` is reached, `isCompleted = true` and does not flip back even if a subsequent edit decreases the source or increases the threshold. The Phase 3 sub-pass only ever sets `isCompleted := true`; it never sets it back to `false`.
- **Editing `dt.maxCount` down below `displayed` does not block, does not auto-clamp** — same rule as today's standalone counters. The Phase 2 picker's threshold field validates only that `maxCount > 0`.

The `calculateCountingRollup()` function in `packages/shared/src/algorithms/rollup.ts` (no production callers — only exercised by `crossBoardSharing.test.ts`) uses `Math.min(parentCurrentCount + subtaskMaxCount, parentMaxCount)` — that's an artifact of the (now-retired) per-board cascade math for the legacy `progress` task type and is irrelevant here. The new `deriveDisplayedCount` helper must **not** copy that clamp pattern. Reviewer checklist for any PR touching the derivation: grep for `Math.min(` in any new line of the derivation helper and reject if found.

### Phasing

Re-stated from the issue body so the parallel-triage plan's Wave 2–5 stream names match. Each phase is its own PR (or group of paired PRs per cross-platform parity).

- **Phase 0 — design doc + decisions (this section).** No code. Locks decisions 1–7 + invariants. Status: this section.
- **Phase 1 — playground spike**: shared-counter math in a `SharedCounterPlayground.tsx` + `SharedCounterPlaygroundView.swift` pair. Increment a source, derive `displayed` + `isCompleted` for N linked tasks, render the results in real reusable components per the "Build real components, not demos" rule in `CLAUDE.md` → Feature Implementation Guidelines → Core Principles. No boards, no real DB writes — synthetic in-memory fixtures only. Verifies the math + the derivation helper + the no-overshoot-clamp invariant.
- **Phase 2 — create-interface UI**: extend `CountingTemplatePicker` / `CountingTemplatePickerView` with a `Link to existing counter` mode (sibling to the existing "use as template" mode), a `Threshold` input, and an `Inherit` / `Start from zero` radio. Wires to a stub increment that surfaces "linked but increment not yet wired" so the UI ships before the hot-path rewrite. Both platforms, same PR.
- **Phase 3 — increment integration**: the `runBoardCascadeForTask` sub-pass per Decision 4 above. Removes the Phase 2 stub. Includes the cascade-delete update for `deleteTaskWithCascade`, the cycle-detection refinement in Zod, and the new `deriveDisplayedCount` helper consumed by the cell renderer.
- **Phase 4 — sync**: `mergeCounterValue` shared algorithm, conflict resolver in `syncService.ts` + `SyncService.swift`, `lastSyncedCount` field added to Task, end-to-end multi-device test scenario in `docs/SYNC_STRATEGY.md`. **Also** the dead-scaffolding cleanup commit (delete `progress_counters` table + index, delete `ProgressCounter` types + model + CRUD, delete `TaskProgressCounter` + `calculateCountingRollup`). Cleanup ships with sync, not separately, so reviewer sees both halves of the model decision (locked-in + scaffolding-removed) in one diff.

### Resolved design decisions (Phase 0 — resolved 2026-06-05)

The three open questions below were unresolvable without user input and blocked Phase 1. They are now resolved; Phase 1 implementation has begun on branch `feature/shared-counter-spike`.

1. **Picker placement** — **Third mode inside `CountingTemplatePicker`** (sibling to the existing "Use as template" mode). Phase 2 will surface a tab/segmented control inside the picker with two options: "Use as template" (today's behaviour) and "Link to existing counter" (the new shared-counter path). Phase 1 does not touch `CountingTemplatePicker`.

2. **Derived task default title** — **Autofill via `generateCounterTaskTitle()`** from `@oybc/shared`, using the derived task's own `maxCount` with the source task's `action` and `unit`. This is the same convention as a brand-new standalone counting task today. The user can always override the autofilled title. The Phase 1 playground demonstrates this behaviour: the "Add derived task" form shows the live autofilled title as the user types `maxCount`.

3. **Visual indicator on linked/derived tasks** — **Detail-sheet only — no list/cell badge**. The linked-counter relationship is surfaced only when the user opens the task's detail sheet; derived tasks look identical to standalone counting tasks in the library list and on the bingo board cell. Phase 1 playground does not add any badge. Phase 3/Phase 2 will add detail-sheet text indicating the source task.

### Out of scope

- **Cross-user shared counters** — Phase 0 / v1 is single-user only. Shared counters across friends / family is a separate cross-cutting feature that requires the auth + sharing model OYBC doesn't have yet.
- **Counter math involving non-counting task types** — a `NORMAL` task completion does not increment a counter. Only `COUNTING` source Tasks can be sources, only `COUNTING` derived Tasks can consume.
- **A standalone "Counters" tab or library section** — derived counters are normal counting Tasks; they show up in the Tasks tab counter filter exactly like standalone ones do. No new top-level navigation.
- **Timeframe-scoped baseline resets** (per Decision 6) — explicit v2.
- **Performance benchmarks for the additive-merge pull path** — Phase 4 should validate correctness; performance benchmarking against multi-thousand-Task workspaces is a future tooling sweep.

### Phase 4 — Conflict resolution for shared counters (this section)

> Design locked 2026-06-06 before any Phase 4 code. Decisions below supplement Decision 5 from the Phase 0 doc above, adding the implementation specifics that are safe to resolve without user input.

#### Storage: `lastSyncedCount` on `Task` (option a)

**Chosen**: `lastSyncedCount?: number | null` added to `Task` (lives on the same row as `sharedCounterId`). Fits Decision 1's "everything on Task" FK model; no new tables, no new sync collections.

**Rejected alternative**: separate `sync_state` keyed by `(taskId, deviceId)` — heavier, requires a new sync collection, adds a join to the conflict-resolution path.

**When it is set**:
- After a **successful push** of a counting Task: `lastSyncedCount := currentCount` at the moment the push completes. This records "Firestore now knows about this count value."
- After a **remote-wins pull** of a counting Task: `lastSyncedCount := remote.currentCount`. This records "remote's state is now our common ancestor."
- `lastSyncedCount` is NOT updated on local increments — only on confirmed Firestore round-trips.

#### Merge trigger: source tasks only, on pull-path `applyRemoteSubdoc`

**Chosen**: The additive merge fires in `applyRemoteSubdoc` (web) / `applyRemoteSubdoc` (iOS) when ALL of:
1. `collectionName === 'tasks'`
2. The Task has `type === COUNTING`
3. At least one non-deleted Task in local DB has `sharedCounterId === remoteTask.id` (i.e. it is a source)
4. Both local and remote have incremented since `lastSyncedCount` (detected via: `local.currentCount !== lastSyncedCount AND remote.currentCount !== lastSyncedCount`)

If condition 4 fails (no concurrent edit), LWW resolves as today.
If `lastSyncedCount` is null (first sync, no common ancestor), fall back to LWW (no merge possible — Document "null baseline → LWW fallback" in the test suite).

**Formula** (from Decision 5):
```
mergedCount = remote.currentCount + (local.currentCount - lastSyncedCount)
```

After merge: write merged value to local DB, bump `version`, set `lastSyncedCount := remote.currentCount`, enqueue push so the merged value reaches Firestore.

#### Propagation after merge

After additive merge resolves the source `currentCount`, Phase 3's `runBoardCascadeForTask` / `runPullCascade` runs on the source task id. This re-derives all linked tasks' `isCompleted` and all affected board stats atomically inside the same transaction.

#### All writes stay atomic

The merge write (update local `currentCount` + `lastSyncedCount` + `version`) + the cascade (`runBoardCascadeForTask`) happen in the **same Dexie / GRDB transaction** as the upsert. A cascade failure rolls back the merge so the safety-net pull can retry cleanly — same invariant as the existing pull cascade.

#### `lastSyncedCount` update on push

In `pushSync`, after a **local-wins** push completes successfully:
- If `entityType === 'tasks'` AND `payload.type === 'counting'`: update local `lastSyncedCount := payload.currentCount` (the value just confirmed remote).
- This is a targeted `db.tasks.update(id, { lastSyncedCount })` (web) / `UPDATE tasks SET lastSyncedCount = ? WHERE id = ?` (iOS) — NOT a full Task rewrite, NOT a version bump (it's sync bookkeeping, not a user edit).

#### Migration versions

- **Web**: Dexie v11 — adds `lastSyncedCount` to tasks schema string. No data transform (existing rows get `undefined`; treated as null by merge logic).
- **iOS**: GRDB v16 — `ALTER TABLE tasks ADD COLUMN lastSyncedCount INTEGER;`. No index needed. No data backfill.

#### Dead-scaffolding cleanup (ships with Phase 4)

Per the Phase 0 Phasing section: `ProgressCounter` types, Dexie / GRDB table definitions, and `calculateCountingRollup` from `rollup.ts` are removed in this PR. The `progress_counters` Dexie table is dropped via a `v11.stores({ progressCounters: null })` declaration. The GRDB table is left in place (SQLite cannot drop tables cleanly across migrations without recreating — inert rows are the least-risk cleanup; marked with a GRDB comment).

### Status

| Step | State |
| --- | --- |
| Design (this section) | Locked 2026-06-04 |
| Phase 4 design | Locked 2026-06-06 |
| Branch | `feature/shared-counter-sync-additive` |
| PR | TBD — link added when opened |
| Issue | [#84](https://github.com/2014sheas/oybc/issues/84) (investigation only; Phase 0 doc resolves the 7 design decisions) |

---

This plan represents a complete rebuild of OYBC with offline-first architecture, designed to provide instant UX and work perfectly without internet connection.
