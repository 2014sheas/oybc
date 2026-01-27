# Architecture Review - OYBC v2

An independent review of the OYBC v2 technical architecture, data models, implementation plans, and overall viability.

---

## Overall Assessment

The project concept is strong: gamifying goal-tracking through bingo boards is a differentiated approach in the productivity space. The core mechanics (board grids, bingo line detection, varied task types) provide natural engagement loops that most task apps lack. The offline-first architectural decision is well-suited for a productivity app where users expect instant interactions.

The planning and documentation quality is high - clear principles, phased delivery, and well-structured data models. Below is a detailed review organized by area, covering what works well, what needs attention, and suggestions for added value.

---

## 1. Offline-First Architecture

### What Works Well

- **Local DB as source of truth** is the correct architectural choice. Productivity apps must feel instant, and < 10ms local reads deliver that.
- **Sync queue pattern** is a proven approach for eventually-consistent offline systems.
- **UUID primary keys** correctly eliminate the need for server-generated IDs during offline creation.
- **Denormalized stats** on boards avoid expensive joins for the most common read path (board list / board detail).
- **Soft deletes** are essential for sync reliability - hard deletes in distributed systems cause ghost records.

### Concerns

**1.1 Last-Write-Wins Loses Data in Common Scenarios**

The conflict resolution strategy (LWW at the entity level) is simple but lossy. Consider this realistic scenario:

- Device A (offline): User completes 3 tasks on a board (updating `board.completedTasks`, `board.linesCompleted`, `board.updatedAt`, `board.version`)
- Device B (offline): User renames the same board (updating `board.name`, `board.updatedAt`, `board.version`)
- Both reconnect: LWW picks one. The loser's changes are silently discarded.

The user loses either their task completions or their board rename - both of which were valid, non-conflicting changes.

**Recommendation**: Consider **field-level merging** for non-conflicting changes. If Device A changed `completedTasks` and Device B changed `name`, both changes can be preserved. Reserve LWW only for true conflicts (both devices changed the same field). This adds complexity to the sync layer but dramatically reduces data loss. At minimum, if you keep document-level LWW, you should log conflicts so users can be notified.

**1.2 Clock Skew in Timestamp Fallback**

When both devices produce the same version number, the resolution falls back to timestamp comparison:

```typescript
if (remote.version === local.version) {
  return new Date(remote.updatedAt) > new Date(local.updatedAt)
    ? remote : local;
}
```

Device clocks can skew by minutes or even hours if a user hasn't enabled automatic time. A device with a clock set 5 minutes ahead will consistently "win" conflicts regardless of actual edit order.

**Recommendation**: Include a **logical timestamp** (like a Lamport clock or hybrid logical clock) alongside the wall-clock timestamp. This doesn't depend on device clock accuracy and provides a more reliable ordering for distributed writes.

**1.3 Multi-Device Sync Latency**

The plan calls for 5-minute polling intervals for pull sync. After completing a task on iPhone, the web app won't reflect the change for up to 5 minutes. This can feel broken to users who expect near-real-time sync.

**Recommendation**: Use Firestore's real-time listeners (`onSnapshot`) for **push-based sync** instead of polling. This gives sub-second multi-device sync when online, with the local DB still serving as the source of truth. This is one of Firestore's biggest strengths and it would be underutilized with polling-only sync.

---

## 2. Sync Queue Design

### Concerns

**2.1 Queue Operation Coalescing**

If a user rapidly increments a counting task 10 times, that creates 10 separate sync queue entries for the same `BoardTask`. Each one would trigger a separate Firestore write.

**Recommendation**: Coalesce pending operations on the same entity. Before enqueuing, check if a pending operation already exists for the same `entityId`. If so, update the existing payload rather than creating a new queue entry. This reduces Firestore writes (and cost) significantly.

**2.2 Operation Ordering and Dependencies**

The sync queue has no mechanism to ensure ordering across related entities. If a user creates a board and immediately adds tasks to it, the board-creation operation must sync before the board-task operations, or Firestore will receive orphaned board-tasks.

**Recommendation**: Add an `ordinal` or sequence number to sync queue items and process them in order. Alternatively, use the `priority` field that already exists in `SyncQueueItem` to ensure creates are processed before updates. Also consider grouping related operations (board + its board-tasks) into a single Firestore batch write.

**2.3 Permanent Failure Handling**

The retry logic uses exponential backoff, but there's no discussion of what happens when a sync item permanently fails (e.g., Firestore schema mismatch, permissions error, corrupted payload).

**Recommendation**: Define a `MAX_RETRY_COUNT` (e.g., 10). After exceeding it, move the item to a `DEAD_LETTER` status. Surface permanently-failed syncs to the user with an option to retry or discard. Without this, a single bad item could block the queue if it's processed FIFO.

---

## 3. Framework Choice: Next.js for Offline-First Web

### Concern

Next.js is fundamentally an SSR/SSG framework. Its core value propositions - Server Components, server-side data fetching, streaming SSR, route-level caching - all assume server availability. An offline-first app that reads everything from IndexedDB cannot leverage any of these features:

- All data-fetching components must be Client Components (`'use client'`), negating Server Components entirely
- The App Router's `fetch`-based caching is irrelevant when data comes from IndexedDB
- Service Worker registration for offline support requires additional tooling on top of Next.js
- The Next.js dev server adds complexity with no architectural benefit for this use case

The result is effectively a client-side SPA running inside Next.js, inheriting its build tooling weight and server-oriented mental model without the benefits.

### Recommendation

Consider **Vite + React** (or Vite + React Router) for the web app. Benefits:
- Simpler mental model: everything is client-side, matching the offline-first architecture
- Smaller bundle size and faster builds
- Native PWA support with `vite-plugin-pwa` (service workers, install prompts, offline caching)
- No server to deploy or maintain (static hosting on any CDN)

If SEO matters for a marketing/landing page, that can be a separate static site or even a Next.js site that links to the app. The app itself gains nothing from SSR.

If you prefer to stay with Next.js (team familiarity, future SSR needs), document the convention clearly: the entire `app/` tree will be Client Components, and Server Components / server actions should not be used for data operations.

---

## 4. Data Model Review

### What Works Well

- Clean entity separation (Board, Task, BoardTask junction)
- Reusable tasks across boards via the junction table
- Well-typed enums with meaningful string values (not magic numbers)
- Zod schemas with cross-field validation refinements (counting tasks require action/unit/maxCount)
- Separate input types for create/update operations

### Concerns

**4.1 BoardTask Missing Soft Delete**

`Board` and `Task` both have `isDeleted` / `deletedAt` fields, but `BoardTask` does not. If a task is removed from a board, how is that deletion synced? Without soft delete on `BoardTask`, removing a task from a board would require a hard delete locally, and the sync layer would need a separate mechanism to propagate deletions.

**Recommendation**: Add `isDeleted` and `deletedAt` to `BoardTask` for consistency with the sync pattern.

**4.2 completedLineIds as String Array in SQLite**

`Board.completedLineIds` is typed as `string[]`, which maps naturally to IndexedDB (stores arrays natively) but requires JSON serialization in SQLite. This means:
- GRDB queries can't filter or index on individual line IDs
- Every read/write of this field involves JSON parse/serialize overhead
- Risk of data corruption if JSON is malformed

**Recommendation**: Consider a separate `bingo_lines` table (which is already mentioned in the schema design section of ARCHITECTURE.md but doesn't have a corresponding TypeScript type). Use a normalized table for bingo lines and keep `linesCompleted` as the only denormalized count on `Board`. Remove `completedLineIds` from the Board interface and model bingo lines as their own entity with proper sync support.

**4.3 Achievement Squares Add Significant Complexity**

The `BoardTask` entity carries 5 optional achievement-related fields (`isAchievementSquare`, `achievementType`, `achievementCount`, `achievementTimeframe`, `achievementProgress`). This adds cross-board query requirements and real-time progress tracking across multiple boards.

Computing achievement progress requires querying bingo/completion counts across other boards filtered by timeframe, which cuts against the "no joins, instant reads" principle unless the progress is denormalized and updated on every board completion.

**Recommendation**: Defer achievement squares to v1.1. The core bingo experience (create board, complete tasks, get bingos, get greenlogs) is compelling without cross-board achievements. Adding them later with a dedicated `Achievement` entity will be cleaner than embedding them in `BoardTask`. This aligns with the plan's own guidance: "No complex features prematurely."

**4.4 Task Denormalized Counters Are Hard to Sync**

`Task.totalCompletions` and `Task.totalInstances` are denormalized counters that aggregate across all boards. In a multi-device sync scenario:

- Device A completes a task on Board 1 → increments `totalCompletions` to 5
- Device B adds the task to Board 2 → increments `totalInstances` to 3
- LWW sync picks one version, losing the other counter update

**Recommendation**: Either (a) compute these counters on-read from BoardTask data (a COUNT query), trading read performance for sync correctness, or (b) use Firestore `FieldValue.increment()` for these counters in the sync layer rather than overwriting the whole document. Option (a) is simpler and the query cost is minimal since a user is unlikely to have more than a few hundred board-tasks.

**4.5 TaskStep Identity and Lifecycle**

`TaskStep` has full sync metadata (version, isDeleted, lastSyncedAt) and its own UUID, suggesting it's a first-class synced entity. But the architecture doc says steps are "embedded" in progress tasks. The current design sits between two approaches:

1. **Embedded**: Steps are just an array on Task (simpler, synced as part of the task document)
2. **Separate entity**: Steps have their own table, IDs, sync lifecycle (more flexible, more complex)

The current code defines `TaskStep` as a separate interface with full sync fields, which implies approach 2, but there's no `taskSteps` schema in the Dexie setup or sync queue entity type list.

**Recommendation**: Pick one approach explicitly. For v1.0, embedding steps as a JSON array on the Task document is simpler and avoids an entire entity's worth of sync complexity. Steps don't need independent sync since they only make sense in the context of their parent task. If you keep them as a separate entity, document the Firestore collection structure and add the entity type to the sync queue.

---

## 5. Validation Schemas

### What Works Well

- Cross-field refinements for task type-specific requirements
- Separate schemas for create input, update input, and full entity
- Proper use of `z.nativeEnum` for TypeScript enum integration
- Good field-level constraints (min/max lengths, positive numbers)

### Suggestions

**5.1 Add Board Size / Center Square Validation**

A 4x4 board has no center square, but the current schema allows `CenterSquareType.FREE` on a 4x4 board. Similarly, `CenterSquareType.NONE` could be set on a 3x3 or 5x5 board, which might be intentional (user doesn't want a free space) or a bug.

**Recommendation**: Add a refinement:

```typescript
.refine(
  (data) => {
    if (data.boardSize % 2 === 0) {
      return data.centerSquareType === CenterSquareType.NONE;
    }
    return true;
  },
  { message: 'Even-sized boards cannot have a center square' }
)
```

**5.2 Row/Col Bounds Validation on BoardTask**

`CreateBoardTaskInputSchema` validates `row >= 0` and `col >= 0` but doesn't validate upper bounds against the board size. A row of 5 on a 3x3 board would pass validation.

**Recommendation**: This requires cross-entity validation (knowing the board size when validating a board-task). Add a factory function that takes `boardSize` and returns a schema with proper bounds, or validate at the service layer rather than the schema layer.

---

## 6. Project Structure and Build

### What Works Well

- pnpm + Turborepo is a solid monorepo choice with good caching
- Clean workspace separation (apps/*, packages/*)
- Strict TypeScript configuration
- 80% test coverage threshold enforced from the start
- Jest configured correctly for the shared package

### Suggestions

**6.1 Vitest Over Jest for Web**

The shared package uses Jest, which works. When the web app is created, consider Vitest instead - it's faster, uses the same Vite config, and has near-identical API to Jest. The shared package could also switch since ts-jest adds build overhead that Vitest avoids.

**6.2 Missing Design Tokens Package**

The planned `packages/design-tokens/` for colors and spacing is referenced but doesn't exist. For cross-platform consistency (web CSS and iOS SwiftUI colors), define these early. Even a simple JSON file mapping color names to hex values prevents drift between platforms.

---

## 7. Missing Architectural Considerations

**7.1 Local Database Migrations**

The architecture doesn't address what happens when the schema changes in an app update. Both GRDB and Dexie support migrations, but the strategy needs to be defined:
- How will version numbers be tracked?
- What happens to sync queue items created with old schema?
- Will migrations run synchronously on app launch (blocking) or asynchronously?

**Recommendation**: Define a migration strategy early. Both GRDB and Dexie handle this well when planned for. For Dexie, version-based schema changes are straightforward. For GRDB, use `DatabaseMigrator` with incremental steps.

**7.2 Initial Sync (New Device Setup)**

When a user signs in on a new device, the local database is empty. The architecture needs a "full pull" mechanism to populate the local DB from Firestore. This is distinct from the incremental sync described in Phase 3.

**Recommendation**: Add a "bootstrap sync" step after authentication that fetches all user data from Firestore and populates the local DB before allowing app interaction. Show a one-time loading state for this (the only acceptable loading spinner in the app).

**7.3 Storage Limits**

IndexedDB quotas vary by browser:
- Chrome: ~60% of disk space (usually generous)
- Safari: 1GB, then prompts user; may evict after 7 days without interaction
- Firefox: ~50% of disk space

Safari's eviction policy is particularly concerning for an offline-first app. If the user doesn't open the web app for a week, Safari may delete the IndexedDB data.

**Recommendation**: Document the storage limitation for Safari. Consider using the Storage API (`navigator.storage.persist()`) to request persistent storage. Also implement the "bootstrap sync" from 7.2 as a recovery mechanism if local data is lost.

**7.4 Account Management**

No mention of:
- Account deletion (required by App Store and GDPR/CCPA)
- Data export (nice to have, may be legally required depending on jurisdiction)
- Password reset flow
- Anonymous/guest usage before signup

**Recommendation**: Plan for account deletion from the start. It needs to cascade through Firestore (delete all user documents) and clear the local database. This is an App Store review requirement.

**7.5 Soft Delete Accumulation**

Soft-deleted records accumulate forever. Over months of use, a significant portion of the database could be deleted records that are retained only for sync purposes.

**Recommendation**: Define a purge strategy. After a soft-deleted record has been synced to Firestore and confirmed on all devices (or after a time threshold like 30 days), hard-delete it from the local database. Keep the Firestore copy as the archive.

---

## 8. Timeline Assessment

The 12-14 week timeline to production is ambitious for two polished, production-quality apps with sync. Some observations:

- **Weeks 1-2 (Database setup)**: Reasonable for both platforms.
- **Weeks 3-5 (Core game loop)**: Building complete board creation, grid interaction, and bingo detection UI on both iOS and web in 3 weeks is tight. Each platform has its own UI paradigms, component libraries, and testing approaches. Budget closer to 4-5 weeks.
- **Weeks 6-8 (Auth & Sync)**: Sync is where unexpected complexity lives. Conflict resolution edge cases, retry logic, initial sync, and multi-device testing will consume time. Budget 4 weeks.
- **Weeks 9-11 (Polish)**: Animations, haptics, accessibility, and E2E testing across two platforms in 3 weeks is very tight. Accessibility alone can take 2 weeks if done properly.
- **Week 12 (Launch)**: App Store review can take 1-3 days, and first submissions often get rejected for minor issues.

**Recommendation**: Adjust to 16-20 weeks, or scope down to a single platform (iOS) first with web following 4-6 weeks later. Shipping one polished app is better than two rough ones. The offline-first architecture means the web app can be added without any backend changes since the sync layer is already built.

---

## 9. Feature Suggestions

These are features that could add meaningful value, ordered by estimated impact:

**9.1 Board Templates** (High Impact)
Let users save a board layout as a reusable template. Users creating weekly boards likely reuse the same tasks - recreating them each week would be tedious. Templates could also be the foundation for a community feature later.

**9.2 Recurring Boards** (High Impact)
Auto-create boards on a schedule (every Monday, first of each month). This turns OYBC from a one-time board game into an ongoing habit tracker. This is the feature most likely to drive daily active usage and retention.

**9.3 Undo/Redo** (Medium Impact)
Task completions should be easily reversible. Accidental taps (especially with the planned double-tap-to-complete gesture) need a fast undo mechanism. Store a short undo stack locally.

**9.4 Streaks** (Medium Impact)
Track consecutive timeframes with bingos or greenlogs. "3-week bingo streak" is a natural gamification extension that drives engagement.

**9.5 Statistics Dashboard** (Medium Impact)
Completion rates, most-used tasks, bingo frequency, time-to-greenlog, and trends over time. This gives users a reason to look back at archived boards and provides a sense of progress.

**9.6 iOS Widget** (Medium Impact)
A home screen widget showing current board progress. This is extremely effective for engagement in productivity apps - users see their board every time they look at their phone. WidgetKit + the local GRDB database makes this straightforward.

**9.7 Haptic Feedback Patterns** (Low Effort, High Polish)
Different haptic patterns for task completion, bingo, and greenlog on iOS. This is cheap to implement and makes the physical interaction feel rewarding. Already mentioned in the plan, but worth calling out as a polish item that punches above its weight.

**9.8 Board Sharing** (Lower Priority)
Share a board template (not completion data) with friends via a link. This creates organic growth. Defer to post-launch unless you want a viral loop in v1.

---

## 10. Summary of Critical Action Items

Listed by priority:

| # | Item | Priority | Effort |
|---|------|----------|--------|
| 1 | Decide on field-level merge vs document-level LWW | High | Medium |
| 2 | Add `isDeleted`/`deletedAt` to BoardTask | High | Low |
| 3 | Define Firestore collection structure and security rules | High | Medium |
| 4 | Re-evaluate Next.js vs Vite for web | High | Low (decision) |
| 5 | Design initial/bootstrap sync for new devices | High | Medium |
| 6 | Add account deletion flow to plan | High | Low (planning) |
| 7 | Defer achievement squares to v1.1 | Medium | Low (removal) |
| 8 | Add sync queue coalescing | Medium | Medium |
| 9 | Plan local DB migration strategy | Medium | Low (planning) |
| 10 | Normalize bingo_lines as its own entity | Medium | Medium |
| 11 | Consider Firestore real-time listeners over polling | Medium | Medium |
| 12 | Add center-square / board-size cross-validation | Low | Low |
| 13 | Define soft delete purge strategy | Low | Low (planning) |
| 14 | Adjust timeline to 16-20 weeks or single-platform-first | Low | Low (planning) |

---

## Conclusion

OYBC has a solid foundation: clear product vision, well-documented architecture, and sensible technology choices. The offline-first approach is the right one for this type of app. The data models are well-structured and the phased implementation plan is logical.

The areas that need the most attention before implementation are sync conflict resolution strategy (the biggest source of subtle bugs in offline-first systems), the web framework choice (Next.js adds complexity without clear benefit for this use case), and a few data model gaps (BoardTask soft deletes, bingo lines normalization, achievement square scoping).

Addressing the critical items in section 10 before starting Phase 2 will prevent significant rework later. The optional feature suggestions in section 9 (especially templates and recurring boards) are natural extensions of the core mechanic that would meaningfully differentiate OYBC from standard task apps.
