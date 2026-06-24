# OYBC iOS App

Native iOS app for OYBC (On Your Bingo Card) built with Swift and SwiftUI.

## Architecture

- **SwiftUI** for the UI layer (the "Riso" design system lives in `OYBC/Views/Riso/`)
- **GRDB** for the local SQLite database (offline-first source of truth)
- **Swift Concurrency** (async/await) for async work — note OYBC has a `Task` data model, so always write `_Concurrency.Task { … }` for concurrency tasks
- **Firebase** (Auth + Firestore) for background multi-device sync

## Database Layer

GRDB-backed local storage. Live entities (`OYBC/Database/Models/`):

- **Board** — game boards
- **Task** — reusable task definitions (Normal / Counting / Compound / Achievement); global completion lives here
- **BoardTask** — pure placement record linking a board cell to a task
- **CompoundChild** — one row per compound parent→child link (replaced the retired `task_steps` / `composite_nodes`)
- **ProgressCounter** — cross-board cumulative counters
- **RecurringBoardTemplate** — preset-pool recurring board definitions
- **DefaultPool** — saved task pools
- **User** — profile and preferences
- **SyncQueue** — offline sync queue

`TaskStep` / `CompositeTask` persist only as legacy migration-read types (first-launch backfill into `CompoundChild`). See `OYBC/Database/Schema.sql` for the base schema and `AppDatabase.swift` for the GRDB migrations.

## Project Structure

```
OYBC/
├── Database/           # GRDB database layer
│   ├── AppDatabase.swift   # connection + migrations
│   ├── Schema.sql          # base schema (bundled resource)
│   └── Models/             # Swift record types (mirror @oybc/shared)
├── Services/           # AuthService, SyncService, NotificationService, etc.
├── Views/              # SwiftUI views (tabs, wizard, Riso kit); per-feature
│                       #   ViewModels/ live alongside their views
├── Helpers/            # small shared helpers
├── Utils/              # formatting / timeframe utilities
├── Resources/          # assets, Info.plist, entitlements
└── OYBCApp.swift       # app entry point
```

## Getting Started

### Prerequisites

- Xcode 26.3 (CI pins this; the simulator that ships with it is what `OS=latest` resolves to)
- iOS 17+ deployment target
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

### Setup

The Xcode project is **generated from `project.yml`** by XcodeGen — it is not hand-maintained. After cloning (or after adding/removing any `.swift` file):

```bash
cd apps/ios
xcodegen generate     # regenerate OYBC.xcodeproj from project.yml + the file tree
open OYBC.xcodeproj
```

Add your `GoogleService-Info.plist` (gitignored, from the Firebase console) under `OYBC/Resources/` before building. Then select a simulator and run (⌘R). The `-bypassAuth YES` launch argument skips Firebase sign-in for local UI work.

### Dependencies

Declared in `project.yml`, resolved via Swift Package Manager:

- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite toolkit
- Firebase iOS SDK — Auth + Firestore
- Google Sign-In
- [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) — snapshot tests

## Testing

- **Logic tests** (`OYBCTests`) and **snapshot tests** (`OYBCSnapshotTests`) run in Xcode (⌘U) or from the command line:

```bash
xcodegen generate   # if test files were added
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project OYBC.xcodeproj -scheme OYBCSnapshotTests \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
  -derivedDataPath ~/oybc-derived test
```

Use the `OYBC` scheme for the logic-test target. See the root `CLAUDE.md` (§iOS snapshot tests) for the snapshot workflow and re-recording baselines.

## Sync Strategy

Offline-first, last-write-wins on version fields; cross-board features (achievement squares, bingo lines) are always recomputed from source data. See `docs/SYNC_STRATEGY.md` in the repo root.
