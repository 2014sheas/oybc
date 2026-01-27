# OYBC - On Your Bingo Card

**Offline-first bingo app for iOS and web**

## What is OYBC?

OYBC (On Your Bingo Card) is a gamified task management app that turns your goals into interactive bingo boards. Complete tasks to get bingos and achieve your "greenlog" (full board completion).

## Key Features

- **Offline-first**: Full functionality without internet connection
- **Multi-device sync**: Seamless synchronization across devices
- **Instant UX**: All operations < 10ms (local database reads)
- **Three task types**:
  - Normal: Simple completion tasks
  - Counting: Track progress (e.g., "Read 100 pages")
  - Progress: Multi-step tasks with sub-tasks
- **Flexible boards**: 3x3, 4x4, or 5x5 grids
- **Timeframes**: Daily, weekly, monthly, yearly, or custom date ranges

## Architecture

**Offline-first, local-first design**:
- **Local databases**: Source of truth (GRDB on iOS, Dexie on web)
- **Background sync**: Firestore syncs when online for multi-device support
- **Instant operations**: All reads from local DB (< 10ms target)
- **Optimistic writes**: Update local DB immediately, sync in background

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed technical documentation.

## Project Structure

This is a monorepo containing:

- **apps/ios**: SwiftUI iOS app with GRDB (SQLite)
- **apps/web**: Next.js web app with Dexie (IndexedDB)
- **packages/shared**: Shared TypeScript types, algorithms, validation
- **packages/design-tokens**: Shared design system (colors, spacing)

## Tech Stack

### iOS
- SwiftUI (UI framework)
- GRDB.swift (SQLite wrapper)
- Firebase iOS SDK (Auth, Firestore sync)
- Combine (reactive state)

### Web
- Next.js 14 (App Router)
- Dexie.js (IndexedDB wrapper)
- Firebase JS SDK v10 (Auth, Firestore sync)
- Zustand (state management)
- Tailwind CSS + shadcn/ui (styling)

### Shared
- TypeScript (types, algorithms, validation)
- Zod (schema validation)
- Jest (testing)

## Development

### Prerequisites

- Node.js 18+
- pnpm 8+
- Xcode 15+ (for iOS development)
- Firebase project

### Setup

```bash
# Install dependencies
pnpm install

# Build shared package
cd packages/shared
pnpm build

# Run web app in dev mode
cd apps/web
pnpm dev

# Open iOS app in Xcode
open apps/ios/OYBC.xcodeproj
```

### Available Scripts

```bash
# Build all packages
pnpm build

# Run all tests
pnpm test

# Lint all packages
pnpm lint

# Clean all build artifacts
pnpm clean
```

## Development Phases

### Phase 1: Local Database Setup ✅
- [x] Archive MVP codebase
- [x] Create monorepo structure
- [x] Design data models from scratch
- [ ] Set up GRDB on iOS
- [ ] Set up Dexie on web

### Phase 2: Core Game Loop (Offline-Only)
- [ ] Board creation UI (iOS & web)
- [ ] Board grid display & interaction
- [ ] Bingo detection & celebrations
- [ ] Full offline functionality

### Phase 3: Authentication & Sync Layer
- [ ] Firebase authentication
- [ ] Background sync service
- [ ] Conflict resolution
- [ ] Multi-device testing

### Phase 4: Polish & Testing
- [ ] Animations & haptics
- [ ] Accessibility
- [ ] E2E testing
- [ ] TestFlight beta

### Phase 5: Launch
- [ ] App Store submission
- [ ] Web deployment (Vercel)
- [ ] Marketing website

## Design Principles

1. **Offline-first**: App works perfectly without internet
2. **Instant UX**: No loading spinners, no waiting for network
3. **Local database is source of truth**: Firestore is sync layer only
4. **Fresh start**: No code copied from MVP, simplified architecture
5. **Future-proof**: Schema designed for recurring boards, templates

## Documentation

- [ARCHITECTURE.md](docs/ARCHITECTURE.md) - Comprehensive technical plan
- [CLAUDE_GUIDE.md](docs/CLAUDE_GUIDE.md) - Guide for working with Claude Code
- [OFFLINE_FIRST.md](docs/OFFLINE_FIRST.md) - Offline architecture explanation

## License

MIT

## Status

**In Development** - Phase 1 (Local Database Setup)

This is a complete rebuild of the OYBC MVP with offline-first architecture.
