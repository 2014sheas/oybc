# Shared Package

Single source of truth for types, algorithms, validation, and constants shared across web and iOS.

## Rules

- **Pure TypeScript only** — no platform-specific code (no GRDB, Dexie, Firebase, React, SwiftUI).
- **No side effects** — every export must be a pure function, type, constant, or Zod schema.
- iOS Swift models mirror these types manually — changes here require corresponding iOS updates.

## Structure

```
src/
├── types/        # Board, Task, CompoundChild, BoardTask, ProgressCounter, User,
│                 #   SyncQueueItem, RecurringBoardTemplate, DefaultPool
│                 #   (TaskStep / CompositeTask persist as legacy migration-read types only)
├── algorithms/   # bingo detection, shuffle, calendar boundaries, compound evaluation,
│                 #   derivation pass, recurring boards, streaks, task events (windowed
│                 #   completion), cross-board rollup, task expiry, cycle detection, migration helpers
├── validation/   # Zod schemas for all types
├── constants/    # Enums (BoardStatus, TaskType = NORMAL/COUNTING/COMPOUND/ACHIEVEMENT,
│                 #   Timeframe, CenterSquareType, AchievementTrigger, OperatorType) + sync-retry constants
└── index.ts      # Public API — all exports go through here
```

## Commands

```bash
pnpm build          # tsc — compile to dist/
pnpm test           # jest
pnpm test:coverage  # jest --coverage (target: 80%+)
```

## Gotchas

- Web imports from `@oybc/shared` (workspace link). Always `pnpm build` after changes or web will use stale types.
- `generateCounterTaskTitle()` is the canonical way to build counting task titles — don't duplicate this logic on either platform.
