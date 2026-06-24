# OYBC Web App

Progressive Web App for OYBC (On Your Bingo Card) built with React, TypeScript, and Vite.

## Architecture

- **React 19** with hooks
- **TypeScript** (strict mode) for type safety
- **Dexie.js** for IndexedDB (offline-first source of truth)
- **Vite** for fast development and optimized builds
- **React Router** for navigation; **dexie-react-hooks** (`useLiveQuery`) for reactive database queries
- **Firebase** (Auth + Firestore) for background multi-device sync

## Database Layer

Dexie.js / IndexedDB. Live entities:

- **Board** — game boards
- **Task** — reusable task definitions (Normal / Counting / Compound / Achievement); global completion lives here
- **BoardTask** — pure placement record linking a board cell to a task
- **CompoundChild** — one row per compound parent→child link (replaced the retired `task_steps` / `composite_nodes`)
- **ProgressCounter** — cross-board cumulative counters
- **RecurringBoardTemplate** — preset-pool recurring board definitions
- **User** — profile and preferences
- **SyncQueue** — offline sync queue

`TaskStep` / `CompositeTask` persist only as legacy migration-read types. The schema + indexes are defined in `src/db/database.ts`.

## Project Structure

```
src/
├── db/                 # Dexie database layer
│   ├── database.ts     # database instance + schema/indexes
│   ├── adapters.ts     # row <-> domain mapping
│   ├── utils.ts
│   └── operations/     # CRUD operations
├── firebase/           # auth + Firestore sync services
├── hooks/              # React hooks (live queries, wizard, etc.)
├── components/         # React components (CSS Modules)
├── pages/              # route page components
└── utils/              # utilities
```

## Getting Started

### Prerequisites

- Node.js 18+
- pnpm 9.15.4 (pinned at the repo root)

### Setup

```bash
# Install dependencies
pnpm install

# Start dev server
pnpm dev

# Build for production
pnpm build

# Preview production build
pnpm preview
```

### Development

The app runs at `http://localhost:5173` by default.

Hot Module Replacement (HMR) is enabled for instant updates.

## Database Indexes

The Dexie schema + compound indexes are declared in `src/db/database.ts` and mirror the GRDB indexes on iOS. Primary access patterns are `[userId+isDeleted]` (per-user lists) and `updatedAt` (delta sync); `board_tasks` is indexed by `boardId` and `taskId`, and `compound_children` by parent/child id.

## Sync Strategy

Offline-first, last-write-wins on version fields; cross-board features (achievement squares, bingo lines) are always recomputed from source data. See `docs/SYNC_STRATEGY.md` in the repo root for the full conflict-resolution model.

## Testing

```bash
# Run type checking
pnpm typecheck

# Run linter
pnpm lint
```

## Build Configuration

- **Development**: Fast refresh, source maps, verbose errors
- **Production**: Optimized bundle, code splitting, minification

## Browser Support

- Chrome/Edge 90+
- Firefox 89+
- Safari 15+

IndexedDB is required (all modern browsers support it).
