# Production Integration — Tab-Based App

## Context

All playground features are tested, Firebase auth + sync is working. The app currently shows "Hello OYBC" and everything lives in the playground. Time to build the real app: auth-gated, tab-based navigation with board list, board play, and board creation. Web and iOS built simultaneously.

## Navigation

Bottom tab bar with 3 tabs: **Boards** (default), **Create**, **Profile**.
- Boards: list → tap → play view
- Create: task pool + board creation
- Profile: user info, board defaults settings, sign out, theme toggle, sync status
- Playground stays accessible via Profile tab link (dev tool)

## Cross-Platform File Structure

```
Web                                          iOS
components/TabBar.tsx          ←→            Views/MainTabView.swift
components/BoardListItem.tsx   ←→            Views/Components/BoardListItemView.swift
components/BoardStatusBadge.tsx ←→           Views/Components/BoardStatusBadgeView.swift
pages/BoardsPage.tsx           ←→            Views/BoardsTab/BoardListView.swift
pages/BoardPlayPage.tsx        ←→            Views/BoardsTab/BoardPlayView.swift
pages/CreatePage.tsx           ←→            Views/CreateTab/CreateView.swift
pages/ProfilePage.tsx          ←→            Views/ProfileTab/ProfileView.swift
hooks/useSyncLoop.ts           ←→            (SyncService lifecycle in AuthGateView)
```

---

## Phase 0: Synced User Preferences

**Goal**: Expand the preferences system to include board creation defaults and sync them via Firestore.

### Preferences Schema

```typescript
interface UserPreferences {
  weekStartDay: WeekStartDay;        // 'monday' | 'sunday'
  defaultBoardSize: 3 | 4 | 5;      // default: 3
  defaultCenterType: CenterSquareType; // default: FREE
}
```

### Approach

Move preferences from localStorage to a Firestore document at `users/{userId}/preferences/settings`. This makes them sync across devices. On web, the `usePreferences` hook reads from Dexie (local-first) and syncs via the existing sync queue. On iOS, `@AppStorage` is replaced with GRDB-backed preferences that sync the same way.

### Web

**Modify:**
- `packages/shared/src/types/` — Add `UserPreferences` type (or add to existing types)
- `apps/web/src/db/database.ts` — Add `preferences` table to Dexie schema (v4 migration)
- `apps/web/src/hooks/usePreferences.ts` — Rewrite: read from Dexie instead of localStorage, write to Dexie + enqueue sync. Keep localStorage as fallback for unauthenticated state.
- `apps/web/src/components/BoardCreatorPanel.tsx` — Use `defaultBoardSize` and `defaultCenterType` from preferences as initial form values
- `apps/web/src/firebase/syncService.ts` — Add `preferences` to `SYNCABLE_COLLECTIONS`

### iOS

**Modify:**
- Add `UserPreferences` GRDB model
- `AppDatabase.swift` — Add preferences table (v5 migration)
- `BoardCreatorPanelView.swift` — Read defaults from preferences instead of hardcoded values
- Replace `@AppStorage("oybc-weekStartDay")` with DB-backed preference
- `SyncService.swift` — Add `preferences` to syncable collections

---

## Phase 1: Auth Shell + Tab Bar

**Goal**: Replace "Hello OYBC" with auth-gated tab bar routing to placeholder pages.

### Web

**Create:**
- `components/TabBar.tsx` + `.module.css` — Bottom tab bar, 3 tabs, uses `NavLink`, `position: fixed; bottom: 0`
- `pages/BoardsPage.tsx` — Placeholder
- `pages/CreatePage.tsx` — Placeholder
- `pages/ProfilePage.tsx` — User info + sign out + theme toggle
- `hooks/useSyncLoop.ts` — Starts `startSyncLoop(userId)` on auth, stops on sign out

**Modify:**
- `App.tsx` — Major restructure:
  - `/playground` outside auth gate (dev tool access)
  - `/*` routes inside `AuthGate` + `TabBar` wrapper
  - Routes: `/boards`, `/boards/:id`, `/create`, `/profile`
  - `/` redirects to `/boards`
  - `useSyncLoop()` in authenticated layout
- `AuthGate.tsx` — Remove inline user bar (sign out moves to Profile tab). Pure gate: render children or auth form.

### iOS

**Create:**
- `Views/MainTabView.swift` — SwiftUI `TabView` with 3 tabs, each wrapping a `NavigationStack`
- `Views/BoardsTab/BoardListView.swift` — Placeholder
- `Views/CreateTab/CreateView.swift` — Placeholder
- `Views/ProfileTab/ProfileView.swift` — User info + sign out

**Modify:**
- `ContentView.swift` — Replace body with `AuthGateView { MainTabView() }`

---

## Phase 2: Board List

**Goal**: Production board list with filtering, progress indicators, tap to navigate.

### Web

**Create:**
- `components/BoardListItem.tsx` + `.module.css` — Extracted from `BoardLifecyclePlayground` board row. Props: `board`, `onClick`. Shows: name, status badge, progress bar, bingo count, timeframe label, expiry indicator.
- `components/BoardStatusBadge.tsx` + `.module.css` — Extracted status badge (DRAFT/ACTIVE/COMPLETED)

**Modify:**
- `pages/BoardsPage.tsx` — Full implementation:
  - `useAuth().user.id` for userId
  - `useBoards(userId)` for reactive data
  - `FilterTabs` for All/Active/Completed/Draft
  - `BoardListItem` for each board
  - `useNavigate()` to `/boards/${id}` on click
  - Empty state when no boards

### iOS

**Create:**
- `Views/Components/BoardListItemView.swift` — Mirror of web
- `Views/Components/BoardStatusBadgeView.swift` — Mirror of web

**Modify:**
- `Views/BoardsTab/BoardListView.swift` — Full implementation with `List` + `NavigationLink`

**Extraction source**: `BoardLifecyclePlayground.tsx` board row rendering + status/expiry helper functions

---

## Phase 3: Board Play

**Goal**: Full-screen bingo grid for a selected board.

### Web

**Create:**
- `pages/BoardPlayPage.tsx` + `.module.css` — Extracted from `BoardLifecyclePlayground` play section:
  - `useParams()` for boardId
  - `useBoard(boardId)` + `useBoardTasks(boardId)` + `useTasks(userId)`
  - Auto-activate DRAFT boards on mount
  - Grid with `InteractiveTaskSquare` (direct reuse)
  - FREE center square placeholder
  - Stats bar (progress, bingos, status)
  - Flash messages for bingos/greenlog/lost bingos/reactivation
  - `DetailModal` + `FloatingContextMenu` (direct reuse)
  - Back button → `/boards`
  - Expiry locking for timeboxed boards

### iOS

**Create:**
- `Views/BoardsTab/BoardPlayView.swift` — SwiftUI equivalent

**Reused without modification**: `InteractiveTaskSquare`, `DetailModal`, `FloatingContextMenu`, `taskToSquareData()`, `boardTaskToSquareState()`, `handleTaskCompletion()`

---

## Phase 4: Create Tab (parallel with Phase 3)

**Goal**: Task pool builder + board creation.

### Web

**Modify:**
- `pages/CreatePage.tsx` — Single scrollable page:
  1. **Task section**: `useTasks(userId)` list with `SelectableTaskItem` toggle to pool. Inline task creator (simplified: name + type + create button, calls `createTask()`).
  2. **Board section**: `BoardCreatorPanel` with pool, taskMap, allTaskSteps, userId. `onBoardCreated` → navigate to `/boards/${id}`

### iOS

**Modify:**
- `Views/CreateTab/CreateView.swift` — Mirror: task list + `BoardCreatorPanelView`

**Reused without modification**: `BoardCreatorPanel`, `SelectableTaskItem`, `FilterTabs`, `createTask()`, `createBoard()`

---

## Phase 5: Profile + Settings + Polish (parallel with Phase 3/4)

### Web

**Modify:**
- `pages/ProfilePage.tsx` — Sections:
  - **Account**: avatar, name, email
  - **Board Defaults**: week start (Mon/Sun), default board size (3/4/5), default center type (Free/Custom/Chosen/None) — all wired to `usePreferences()`
  - **App**: theme toggle, sync status (`lastSyncedAt`), "Sync Now" button
  - **Dev**: link to `/playground`
  - **Sign Out** button

**Delete:**
- `pages/Home.tsx` + `Home.module.css` — Replaced by `/boards`
- `components/Navbar.tsx` + `Navbar.module.css` — Replaced by TabBar (or keep for playground only)

### iOS

**Modify:**
- `Views/ProfileTab/ProfileView.swift` — Mirror

---

## Dependency Graph

```
Phase 0 (Synced Preferences) ─── Phase 1 (Auth Shell + Tab Bar) ─┐
                                     │                            │
                                     ├── Phase 2 (Board List) ── Phase 3 (Play)
                                     │
                                     ├── Phase 4 (Create Tab) ←── can parallel
                                     │
                                     └── Phase 5 (Profile + Settings + Polish)
```

---

## Verification

1. `pnpm build` — web builds clean after each phase
2. `pnpm test` — all tests pass
3. Playwright per phase:
   - Phase 1: auth form → sign in → tab bar visible with 3 tabs
   - Phase 2: boards tab shows board list → filter works
   - Phase 3: tap board → play view → complete task → bingo flash
   - Phase 4: create tab → add tasks → create board → navigates to play
   - Phase 5: profile shows user info → settings persist → sign out works
4. iOS: Xcode build + manual verification after each phase
5. Cross-platform: same boards visible on both platforms after sync
