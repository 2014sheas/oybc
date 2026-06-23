# OYBC - On Your Bingo Card

**Offline-first bingo app for iOS and web**

## What is OYBC?

OYBC (On Your Bingo Card) is a gamified task management app that turns your goals into interactive bingo boards. Complete tasks to get bingos and achieve your "greenlog" (full board completion).

## Key Features

- **Offline-first**: full functionality without an internet connection
- **Multi-device sync**: background Firestore sync across devices
- **Instant UX**: local-database reads/writes (< 10ms target), no loading spinners
- **Four task types**:
  - **Normal**: simple completion tasks
  - **Counting**: track progress toward a goal (e.g., "Read 100 pages")
  - **Compound**: combine sub-tasks with AND / OR / M-of-N logic, optionally ordered (subsumes the former Progress + Composite types)
  - **Achievement**: cross-board watcher that completes when a referenced board (or recurring template) hits a bingo or greenlog
- **Flexible boards**: 3×3, 4×4, or 5×5 grids
- **Timeframes**: daily, weekly, monthly, yearly, or custom date ranges
- **Recurring boards**: per-timeframe core boards + preset-pool templates, lazily detected on app open
- **iOS local reminders**: board-expiring / new-recurring-window / daily-play notifications (opt-in, scheduled on-device)

## Architecture

**Offline-first, local-first design**:
- **Local databases are the source of truth** (GRDB/SQLite on iOS, Dexie/IndexedDB on web)
- **Background sync**: Firestore syncs when online for multi-device support only
- **Optimistic writes**: update the local DB immediately, queue sync in the background
- **Conflict resolution**: last-write-wins via version fields; cross-board features recomputed from source data

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the detailed technical plan and [docs/OFFLINE_FIRST.md](docs/OFFLINE_FIRST.md) for the data-flow model.

## Project Structure

This is a pnpm + Turborepo monorepo:

- **apps/ios**: SwiftUI iOS app with GRDB (SQLite); project generated via XcodeGen
- **apps/web**: React + Vite web app with Dexie (IndexedDB) and React Router
- **packages/shared**: shared TypeScript types, algorithms, and Zod validation (single source of truth)
- **functions**: Firebase Cloud Functions (TypeScript) — the only server-side code (account-deletion data purge)

## Tech Stack

### iOS
- SwiftUI (UI)
- GRDB.swift (SQLite wrapper)
- Firebase iOS SDK (Auth, Firestore sync) + Google Sign-In
- XcodeGen (project generation), swift-snapshot-testing (snapshot tests)

### Web
- React 19 + Vite
- React Router
- Dexie.js (IndexedDB wrapper)
- Firebase JS SDK (Auth, Firestore sync)
- CSS Modules (styling)

### Shared
- TypeScript (types, algorithms, validation)
- Zod (schema validation)
- Jest (testing)

### Cloud Functions
- TypeScript on Node 22 (requires the Firebase Blaze plan to deploy)

## Development

### Prerequisites

- Node.js 18+ (Cloud Functions run on Node 22)
- pnpm 9.15.4 (pinned via `package.json#packageManager`)
- Xcode (CI pins 26.3) + XcodeGen for iOS development
- A Firebase project (config obtained per developer — see below)

### Setup

```bash
# Install dependencies
pnpm install

# Build the shared package (web + functions consume it)
cd packages/shared && pnpm build

# Run the web app in dev mode (http://localhost:5173)
cd apps/web && pnpm dev

# iOS: generate + open the Xcode project
cd apps/ios && xcodegen generate && open OYBC.xcodeproj
```

**Firebase config** is gitignored and obtained per developer: `.env.local` (web) and `GoogleService-Info.plist` (iOS).

### Available Scripts (root)

```bash
pnpm build    # Build all packages
pnpm test     # Run all tests
pnpm lint     # Lint all packages
pnpm clean    # Clean all build artifacts
```

## Status

**Phases 1–7 shipped** — local DB, app infrastructure, core game loop, auth + Firestore sync, the tab-based production app, polish, recurring boards, and iOS local notifications. The "Riso" UI overhaul (Design Handoff #3), per-timeframe streaks, and the in-app Account & security screen (with account deletion) have all shipped on iOS. Web has parity gaps that are tracked as follow-ups (see CLAUDE.md). Active work is directed feature-by-feature, not by a fixed roadmap.

## Documentation

- [CLAUDE.md](CLAUDE.md) — canonical contributor guide (conventions, workflows, current status, follow-ups)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — technical plan + development phases
- [docs/OFFLINE_FIRST.md](docs/OFFLINE_FIRST.md) — offline-first design and data flow
- [docs/SYNC_STRATEGY.md](docs/SYNC_STRATEGY.md) — conflict resolution patterns
- [docs/TASK_SYSTEM.md](docs/TASK_SYSTEM.md) — the unified task system
- [docs/NOTIFICATIONS.md](docs/NOTIFICATIONS.md) — Phase 7 iOS local-notification design

## License

MIT
