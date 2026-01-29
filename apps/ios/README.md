# OYBC iOS App

Native iOS app for OYBC (On Your Bingo Card) built with Swift and SwiftUI.

## Architecture

- **SwiftUI** for UI layer
- **GRDB** for local SQLite database (offline-first)
- **Swift Concurrency** (async/await) for async operations
- **Combine** for reactive data flow

## Database Layer

The app uses GRDB for local-first data storage with the following entities:

- **Board** - Main game boards
- **Task** - Reusable task definitions
- **BoardTask** - Junction table linking boards and tasks
- **TaskStep** - Steps for progress tasks
- **ProgressCounter** - Cross-board cumulative counters
- **User** - User profile and preferences
- **SyncQueue** - Offline sync queue

See `/Database/Schema.sql` for full schema definition.

## Project Structure

```
OYBC/
├── Database/           # GRDB database layer
│   ├── AppDatabase.swift
│   ├── Schema.sql
│   ├── Migrations.swift
│   └── Models/         # Database record types
├── Models/             # Swift models matching TypeScript types
├── Services/           # Business logic and sync
├── Views/              # SwiftUI views
└── Resources/          # Assets, strings, etc.
```

## Getting Started

### Prerequisites

- Xcode 15+
- iOS 17+ target
- Swift 5.9+

### Setup

1. Open `OYBC.xcodeproj` in Xcode
2. Build and run (⌘R)

### Dependencies

Dependencies are managed via Swift Package Manager:

- [GRDB.swift](https://github.com/groue/GRDB.swift) - SQLite database toolkit

## Database Indexes

The following indexes are created for optimal query performance:

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

Run tests in Xcode (⌘U) or via command line:

```bash
swift test
```

## Build Configuration

The app supports multiple build configurations:

- **Debug** - Development with verbose logging
- **Release** - Production build with optimizations
- **Test** - Test environment with mock data
