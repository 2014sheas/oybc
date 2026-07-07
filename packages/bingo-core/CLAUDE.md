# bingo-core Package

Pure bingo game math shared by OYBC (Do) and Play OYBC — detection, shuffle,
center-square, placement. No domain types, no platform code.

## Rules

- **Pure TypeScript only** — no platform-specific code (no GRDB, Dexie, Firebase, React, SwiftUI).
- **No side effects** — every export must be a pure function, type, constant, or enum.
- **No Do-domain types** — `Task` / `Board` / `BoardTask` (and any other domain entity from
  `@oybc/shared`) must never appear here. Inputs/outputs are primitives (booleans, numbers,
  strings, generic arrays) so the same code can run for OYBC (Do) and Play OYBC without either
  depending on the other's domain model. `@oybc/shared` depends on this package (compat
  re-exports), never the other way around — `packages/bingo-core` must never import
  `@oybc/shared`.
- iOS Swift files mirror these modules manually — changes here require a corresponding iOS
  update in the **same PR** (CLAUDE.md rule 6). See [`MIRRORS.md`](MIRRORS.md) for the module ↔
  Swift-file map.

## Structure

```
src/
├── bingoDetection.ts  # line/greenlog detection, message formatting, highlighted squares
├── shuffle.ts         # Fisher-Yates shuffle (optional seeded RNG)
├── centerSquare.ts     # center-square index/auto-complete/display-text helpers
├── constants.ts        # BOARD_SIZES / BoardSize, CenterSquareType
└── index.ts            # Public API — all exports go through here
```

## Commands

```bash
pnpm build          # tsc — compile to dist/
pnpm test           # jest
pnpm test:coverage  # jest --coverage (target: 80%+)
```

## Gotchas

- `@oybc/shared` re-exports this package's symbols for backward compatibility (its
  `constants/index.ts`, `constants/enums.ts`, and `algorithms/index.ts` barrels). Don't
  duplicate a symbol in both packages — add it here if it's pure game math, add it in
  `shared` if it touches a domain type.
- Always `pnpm build` after changes here or `@oybc/shared`/`apps/web` will use stale types.
