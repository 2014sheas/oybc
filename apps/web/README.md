# OYBC Web App

Progressive Web App for OYBC (On Your Bingo Card) built with React, TypeScript, and Vite.

## Architecture

- **React 18** with hooks and concurrent features
- **TypeScript** (strict mode) for type safety
- **Dexie.js** for IndexedDB (offline-first)
- **Vite** for fast development and optimized builds
- **dexie-react-hooks** for reactive database queries

## Database Layer

The app uses Dexie.js for offline-first data storage with IndexedDB:

- **Board** - Main game boards
- **Task** - Reusable task definitions
- **BoardTask** - Junction table linking boards and tasks
- **TaskStep** - Steps for progress tasks
- **ProgressCounter** - Cross-board cumulative counters
- **User** - User profile and preferences
- **SyncQueue** - Offline sync queue

See `/src/db/schema.ts` for full schema definition.

## Project Structure

```
src/
├── db/                 # Dexie database layer
│   ├── database.ts     # Main database instance
│   ├── schema.ts       # Schema and indexes
│   └── operations/     # CRUD operations
├── hooks/              # React hooks for database
├── components/         # React components
├── pages/              # Page components
└── utils/              # Utilities
```

## Getting Started

### Prerequisites

- Node.js 18+
- pnpm 8+

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

Dexie automatically creates indexes for optimal query performance:

**Boards:**
- `[userId+isDeleted]` - Primary user query
- `[userId+timeframe+status]` - Filter by timeframe and status
- `[userId+timeframe+linesCompleted]` - Achievement queries
- `updatedAt` - Delta sync

**Tasks:**
- `[userId+isDeleted]` - Primary user query
- `updatedAt` - Delta sync
- `parentStepId` - Find tasks linked to steps

**BoardTasks:**
- `[boardId+isCompleted]` - Board completion queries
- `boardId` - All tasks for a board
- `taskId` - All boards using a task
- `isAchievementSquare` - Find achievement squares

**TaskSteps:**
- `[taskId+stepIndex]` - Steps in order
- `linkedTaskId` - Find steps linked to tasks
- `[isDeleted+taskId]` - Non-deleted steps

**ProgressCounters:**
- `[userId+isDeleted]` - Primary user query
- `updatedAt` - Delta sync

## Sync Strategy

The app implements offline-first sync with the following strategies:

- **ProgressCounter**: Last-write-wins using version fields
- **Achievement Squares**: Recompute from source data
- **Task Step Linking**: Additive merge of completedStepIds
- **Bingo Lines**: Always recompute from task completion grid

See `/docs/SYNC_STRATEGY.md` in repo root for details.

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
