# OYBC Native Migration Plan - Offline-First Architecture

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

**Tables** (identical structure on iOS SQLite and web IndexedDB):

```
users                   -- Cached user profiles
boards                  -- Board documents
tasks                   -- Task definitions (reusable across boards)
task_steps              -- Progress task steps (structure only, data in tasks table)
board_tasks             -- Junction: board ↔ task (completion state per board)
composite_tasks         -- Composite task definitions (tree roots)
composite_nodes         -- Tree structure (operators + leaf references)
board_composite_tasks   -- Junction: board ↔ composite task (completion state)
bingo_lines             -- Completed lines (denormalized for performance)
sync_queue              -- Pending Firestore operations
```

**Key Design Decisions**:
- **UUID primary keys** (enable offline creation, no server-generated IDs)
- **ISO8601 timestamps** (Firestore compatibility)
- **Version fields** (optimistic locking for conflict resolution)
- **Soft deletes** (`isDeleted` flag, not hard delete - prevents data loss)
- **Denormalized stats** (board.completedTasks stored directly for instant reads)
- **All progress steps are tasks** (task_steps only stores structure/order, all data in tasks table)
- **Cross-board task reusability** (same task can appear on multiple boards with independent completion)

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

### Phase 3: Authentication & Sync Layer (Weeks 8-10)

**Goal**: Add Firebase auth and background sync for multi-device support

**Week 8: Authentication**

**iOS**:
- [ ] Install Firebase iOS SDK (Auth only for now)
- [ ] Create new Firebase project
- [ ] `AuthService.swift` (sign up, sign in, sign out)
- [ ] `LoginView.swift`, `RegisterView.swift`
- [ ] Store userId in local DB (associate boards/tasks with user)

**Web**:
- [ ] Install Firebase JS SDK
- [ ] Auth service (sign up, sign in, sign out)
- [ ] Login/register pages
- [ ] Auth context provider
- [ ] Store userId in Dexie

**Testing**:
- [ ] Sign up on iOS → account exists in Firebase console
- [ ] Sign in on web with same credentials
- [ ] User's boards isolated by userId (can't see other users' data)

**Week 9: Sync Queue & Background Sync**

**iOS**:
- [ ] Add Firebase Firestore SDK
- [ ] Implement `SyncService.swift`:
  - Read from `sync_queue` table
  - Batch operations (up to 50)
  - Send to Firestore (create, update, delete)
  - Remove from queue on success, retry on failure
- [ ] Trigger sync: on app launch, on reconnect, every 5 min

**Web**:
- [ ] Implement `SyncService.ts` (mirrors iOS)
- [ ] Same queue pattern
- [ ] Trigger sync: on load, on reconnect, periodic

**Testing**:
- [ ] Create board on iOS (offline) → goes to sync_queue
- [ ] Connect to internet → sync processes → board appears in Firestore console
- [ ] Disconnect again → operations queue locally
- [ ] Reconnect → all operations sync

**Week 10: Pull Sync & Conflict Resolution**

**iOS & Web**:
- [ ] Implement pull sync (fetch changes from Firestore since last sync)
- [ ] Query Firestore: `where('userId', '==', uid).where('updatedAt', '>', lastSyncAt)`
- [ ] For each remote change:
  - Get local version
  - Compare version fields
  - If remote.version > local.version → update local DB
  - If local.version > remote.version → keep local (will push next sync)
- [ ] Update `lastSyncedAt` timestamp

**Testing**:
- [ ] Create board on iOS → syncs to Firestore
- [ ] Pull on web → board appears
- [ ] Complete task on web → syncs to Firestore
- [ ] Pull on iOS → task shows completed
- [ ] **Conflict test**: Edit same board on both devices offline → reconnect → higher version wins

**Success Criteria**:
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
- [ ] Create Xcode project (SwiftUI)
- [ ] Add GRDB.swift via SPM
- [ ] Define SQLite schema
- [ ] Implement GRDB models
- [ ] Test offline CRUD operations

### Following Session (Web Database)
- [ ] Create Next.js project
- [ ] Set up Dexie.js
- [ ] Mirror iOS schema in IndexedDB
- [ ] Implement database service
- [ ] Test offline CRUD operations

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

### Phase 4: Polish & Launch (Weeks 11-15)
- ✅ UI polish and animations
- ✅ Achievement squares and progress counters
- ✅ TestFlight beta (5-10 users)
- ✅ No sync bugs (1 week testing)
- ✅ Performance targets met (< 10ms reads, < 50ms composite evaluation)
- ✅ Security verified (can't access other users' data)

---

This plan represents a complete rebuild of OYBC with offline-first architecture, designed to provide instant UX and work perfectly without internet connection.
