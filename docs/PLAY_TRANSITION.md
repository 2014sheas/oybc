# Play OYBC — Monorepo Transition Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the oybc monorepo so Play OYBC (the real-time party-bingo sibling product) can be built inside it with a compiler-enforced boundary between Play and OYBC (Do)'s domain model, and with the genuinely-shared layers (game math, board placement, Riso tokens) extracted into packages both products consume.

**Architecture:** Split `packages/shared` into a domain-free `@oybc/bingo-core` (bingo detection, shuffle, center-square math, board placement) that `@oybc/shared` re-exports (zero breaking changes for `apps/web` / iOS mirrors), extract Riso design tokens into `@oybc/riso-tokens`, scaffold `apps/play` that depends **only** on those two packages (never `@oybc/shared` — enforced by ESLint), and prove `bingo-core` runs server-side in `functions/` via an esbuild bundle. Governance changes (root + scoped CLAUDE.md) prevent Do's offline-first invariants from bleeding into Play.

**Tech Stack:** pnpm workspaces + turbo (existing), TypeScript 6 / Jest 30 (existing shared-package toolchain), Vite 8 + React 19 (matching `apps/web` versions), esbuild (new, functions bundling only), Swift mirrors on iOS (manual, as today).

## Global Constraints

- **Non-breaking first:** every import of `@oybc/shared` in `apps/web` must keep compiling unchanged through T1–T3. The re-export shim in `@oybc/shared` is mandatory, not optional.
- **Behavior-preserving placement refactor (T2):** `buildWizardPlacement` (web + iOS) and `buildSpawnPlacement` (shared + iOS) must produce byte-identical placements for the same inputs + RNG before/after. Golden tests with a seeded RNG are the gate.
- **Cross-platform rule 6 applies to T2 only:** it changes user-facing placement code paths on both platforms → web and iOS land in the same PR. T1/T3–T6 are TS-package/infra/docs work with no iOS behavioral counterpart (document that in each PR body).
- **iOS mirrors are manual:** nothing in this plan makes Swift import TS. Every module moved into `bingo-core` gets a row in `packages/bingo-core/MIRRORS.md` mapping it to its Swift twin.
- **Play never imports `@oybc/shared`:** enforced by ESLint `no-restricted-imports` in `apps/play` from the first commit, plus the absence of the dependency in its `package.json`.
- **No Play product code in this plan.** The scaffold's demo board page exists to prove the dependency chain, not to start Phase 1. The realtime backend choice, session model, and lobby are the architecture spike's job (`docs/play/PLAY_OYBC.md` §6) and are out of scope here.
- **Branch naming:** `feature/play-transition-t<N>-<slug>`. Merge to `dev` after CI + self-review (reviewer agent pass per repo convention).
- Repo build/test invocations used throughout: `pnpm build` / `pnpm test` at root (turbo), `pnpm --filter <pkg> test` for one package.

---

## Why this shape (decision record)

Recorded here so the reasoning survives; the one-line versions belong in the Play design doc's Decisions Log.

1. **Monorepo co-habit, not a separate repo.** The shared layer (bingo-core, tokens) will churn most during exactly the next few months of spike/demo work; in-repo that churn is one atomic PR, cross-repo it is a publish/bump/pray loop. The workspace is already multi-app (`apps/web`, `apps/coming-soon`, `functions`) with path-filtered CI, so `apps/play` costs ~zero infra. The escape hatch is cheap in this direction only: with clean package boundaries, extracting `apps/play` later is `git filter-repo` + publishing two small packages; merging separate repos back is much uglier.
2. **The boundary is a package graph, not a repo split.** `apps/play` depending only on `@oybc/bingo-core` + `@oybc/riso-tokens` means the build itself proves Do's domain model (global-per-Task completion, sync metadata, timeframes) hasn't leaked into Play. A repo split enforces the same boundary at far higher cost.
3. **Server authority falls out of purity.** `packages/shared` (and therefore `bingo-core`) is pure TS with no platform imports, so the exact `detectBingos` the clients run can run in Cloud Functions — client and server can never disagree on what a win is. T6 proves the deploy mechanics before the spike depends on them.
4. **The known risk is philosophy bleed, mitigated by scoped CLAUDE.md.** The root CLAUDE.md is saturated with invariants that are *anti-goals* for Play (offline-first, local DB as source of truth, LWW, no server push, parity rule 6 between web and iOS-of-the-same-product). `apps/play/CLAUDE.md` explicitly inverts them (T5) and the root gets a delimiting section (T4).

### Target state

```
oybc/
├── packages/
│   ├── bingo-core/        # NEW (T1/T2) — pure game math, zero Do-domain types
│   │   ├── src/           #   bingoDetection, shuffle, centerSquare, placement,
│   │   │                  #   BOARD_SIZES/BoardSize, CenterSquareType
│   │   └── MIRRORS.md     #   TS ↔ Swift mirror map
│   ├── riso-tokens/       # NEW (T3) — riso.css design tokens only
│   └── shared/            # Do-domain: types, sync, recurrence, streaks, compound…
│                          #   depends on + re-exports bingo-core (compat shim)
├── apps/
│   ├── web/               # Do web — unchanged imports (via @oybc/shared)
│   ├── play/              # NEW (T5) — depends ONLY on bingo-core + riso-tokens
│   ├── coming-soon/       # unchanged (token drift-check added in T3)
│   └── ios/               # Do iOS — Swift mirrors unchanged; placement refactor in T2
├── functions/             # + esbuild bundling; can import bingo-core (T6)
└── docs/play/             # Play design doc home (T4)
```

Dependency rules after transition:

| Package/app | May depend on | Must NOT depend on |
| --- | --- | --- |
| `@oybc/bingo-core` | (nothing internal) | `@oybc/shared`, any app |
| `@oybc/shared` | `@oybc/bingo-core` | any app |
| `@oybc/riso-tokens` | (nothing) | everything |
| `apps/web` | shared, bingo-core (transitively), riso-tokens | — |
| `apps/play` | bingo-core, riso-tokens | **`@oybc/shared`** (ESLint-enforced) |
| `functions/` | bingo-core (bundled) | `@oybc/shared` (nothing server-side needs Do's local-DB domain) |
| `apps/coming-soon` | (nothing — by design) | everything (drift-check only) |

### What moves into `bingo-core` (and what stays put)

Verified module-by-module (2026-07-06):

| Module | Moves? | Why |
| --- | --- | --- |
| `algorithms/bingoDetection.ts` | ✅ | Pure `boolean[]` + gridSize; imports only `BoardSize` |
| `algorithms/shuffle.ts` | ✅ | Generic `<T>`, injectable RNG, zero imports |
| `algorithms/centerSquare.ts` | ✅ | Imports only `CenterSquareType` |
| `BOARD_SIZES` / `BoardSize` (constants/index.ts) | ✅ | Consumed by bingoDetection + board types |
| `CenterSquareType` (constants/enums.ts) | ✅ | Consumed by centerSquare; not Do-specific |
| `fillableCellCount` + core of `buildSpawnPlacement` (recurringBoardTemplates.ts) | ✅ generalized as `placeBoard` (T2) | The only placement logic that's already pure; wizard variants re-implement it 3 more times |
| Everything else (types, validation, sync constants, streaks, compound/derivation, recurrence, counters, task title, expiry, cycle detection) | ❌ stays in `@oybc/shared` | Do-domain semantics Play must not inherit |

The four existing placement sites that T2 collapses onto one core:

1. Web wizard — `apps/web/src/components/wizard/wizardPersist.ts` `buildWizardPlacement` (fill loop, lines ~101–123)
2. iOS wizard — `apps/ios/OYBC/Views/CreateTab/BoardWizardPersist.swift` `buildWizardPlacement` (lines ~87–145)
3. Shared spawn — `packages/shared/src/algorithms/recurringBoardTemplates.ts` `buildSpawnPlacement` (line 256)
4. iOS spawn — `apps/ios/OYBC/Services/RecurringBoardTemplates.swift` `buildSpawnPlacement` (line 211)

This is the repo's own "extract at three" rule firing (4 sites), independent of Play — and Play's launch fan-out ("generate N boards per player, server-side") is the 5th consumer.

---

## Task T1: Create `@oybc/bingo-core` and move the pure game-math modules

**Branch:** `feature/play-transition-t1-bingo-core` · **One PR.**

**Files:**
- Create: `packages/bingo-core/package.json`, `packages/bingo-core/tsconfig.json`, `packages/bingo-core/tsconfig.test.json` (copy shared's), `packages/bingo-core/jest.config.js`, `packages/bingo-core/src/index.ts`, `packages/bingo-core/MIRRORS.md`, `packages/bingo-core/CLAUDE.md`
- Move (git mv, history-preserving):
  - `packages/shared/src/algorithms/bingoDetection.ts` → `packages/bingo-core/src/bingoDetection.ts`
  - `packages/shared/src/algorithms/shuffle.ts` → `packages/bingo-core/src/shuffle.ts`
  - `packages/shared/src/algorithms/centerSquare.ts` → `packages/bingo-core/src/centerSquare.ts`
  - `packages/shared/tests/algorithms/bingoDetection.test.ts` → `packages/bingo-core/tests/bingoDetection.test.ts`
  - `packages/shared/tests/algorithms/shuffle.test.ts` → `packages/bingo-core/tests/shuffle.test.ts`
  - `packages/shared/tests/algorithms/centerSquare.test.ts` → `packages/bingo-core/tests/centerSquare.test.ts`
- Modify: `packages/bingo-core/src/constants.ts` (new — receives `BOARD_SIZES`/`BoardSize` + `CenterSquareType`), `packages/shared/src/constants/index.ts`, `packages/shared/src/constants/enums.ts`, `packages/shared/src/algorithms/index.ts` (the root `packages/shared/src/index.ts` barrel is untouched — re-exports flow through the constants/algorithms barrels it already wraps), `packages/shared/package.json`, `packages/shared/src/algorithms/recurringBoardTemplates.ts` + `derivationPass.ts` (import-path fixes), `.github/workflows/web.yml`

**Interfaces:**
- Produces: package `@oybc/bingo-core` exporting — verbatim, unchanged signatures — `detectBingos(completionGrid: boolean[], gridSize: BoardSize): BingoDetectionResult`, `formatBingoMessage`, `getHighlightedSquares`, `fisherYatesShuffle<T>(array, rng?)`, `getCenterSquareIndex(gridSize: number): number`, `isCenterAutoCompleted(type: CenterSquareType): boolean`, `getCenterDisplayText(type, customName?)`, `BOARD_SIZES`, `type BoardSize`, `enum CenterSquareType`, `interface BingoDetectionResult`.
- Consumed by: `@oybc/shared` (dependency + re-export), later `apps/play` (T5) and `functions/` (T6).

**Steps:**

- [ ] **Step 1: Scaffold the package**

`packages/bingo-core/package.json`:

```json
{
  "name": "@oybc/bingo-core",
  "version": "1.0.0",
  "description": "Pure bingo game math shared by OYBC (Do) and Play OYBC — detection, shuffle, center-square, placement. No domain types, no platform code.",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "scripts": {
    "build": "tsc",
    "dev": "tsc --watch",
    "test": "jest",
    "test:coverage": "jest --coverage",
    "clean": "rm -rf dist",
    "lint": "tsc --noEmit"
  },
  "license": "MIT",
  "devDependencies": {
    "@types/jest": "^30.0.0",
    "@types/node": "^26.1.0",
    "jest": "^30.4.2",
    "ts-jest": "^29.4.11",
    "typescript": "^6.0.3"
  }
}
```

(No `zod` — validation stays in shared. No runtime deps at all.)

Copy `packages/shared/tsconfig.json`, `tsconfig.test.json`, and `jest.config.js` verbatim into `packages/bingo-core/` (jest `roots` already points at `<rootDir>/tests`; keep the 80% coverage threshold).

- [ ] **Step 2: Move the three modules + their tests with `git mv`** (paths in the Files list above). Fix intra-file imports: `bingoDetection.ts`'s `import { BoardSize } from '../constants'` → `from './constants'`; `centerSquare.ts`'s `import { CenterSquareType } from '../constants/enums'` → `from './constants'`. Test files' `../../src/algorithms/X` → `../src/X`.

- [ ] **Step 3: Create `packages/bingo-core/src/constants.ts`** — cut `BOARD_SIZES`/`BoardSize` out of `packages/shared/src/constants/index.ts` and the `CenterSquareType` enum (with its doc comment) out of `packages/shared/src/constants/enums.ts`, paste both here verbatim.

- [ ] **Step 4: Create `packages/bingo-core/src/index.ts`**

```ts
/**
 * @oybc/bingo-core
 *
 * Pure bingo game math shared by OYBC (Do) and Play OYBC.
 * ONLY primitives-in/primitives-out pure functions — no domain entities
 * (Task/Board/BoardTask), no platform code, no side effects. This purity
 * is what lets the same detection code run in browsers, and Node
 * (Cloud Functions) for server-authoritative win validation.
 */
export * from './bingoDetection';
export * from './shuffle';
export * from './centerSquare';
export * from './constants';
```

- [ ] **Step 5: Wire `@oybc/shared` as a compat shim.** In `packages/shared/package.json` add `"@oybc/bingo-core": "workspace:*"` to `dependencies`. Then:
  - `packages/shared/src/constants/index.ts`: replace the removed `BOARD_SIZES`/`BoardSize` block with `export { BOARD_SIZES, type BoardSize } from '@oybc/bingo-core';`
  - `packages/shared/src/constants/enums.ts`: replace the removed enum with `export { CenterSquareType } from '@oybc/bingo-core';`
  - `packages/shared/src/algorithms/index.ts`: replace the `./bingoDetection`, `./shuffle`, `./centerSquare` export lines with `export * from '@oybc/bingo-core';` (dedupe: constants/index.ts already re-exports the constants — TS tolerates the double re-export of identical symbols via `export *`, but if `tsc` reports ambiguity, switch the algorithms barrel to named re-exports of just the functions + `BingoDetectionResult`).
  - Fix remaining intra-shared imports of the moved modules — exactly two files: `algorithms/recurringBoardTemplates.ts` (imports `getCenterSquareIndex`, `isCenterAutoCompleted`, `fisherYatesShuffle`) and `algorithms/derivationPass.ts` (imports `detectBingos`, `BoardSize`) → import from `@oybc/bingo-core`. Sweep for stragglers: `grep -rn "'./bingoDetection'\|'./shuffle'\|'./centerSquare'" packages/shared/src` → expect zero hits.

- [ ] **Step 6: Run `pnpm install`** (registers the new workspace package + link), then verify the moved tests pass in their new home: `pnpm --filter @oybc/bingo-core build && pnpm --filter @oybc/bingo-core test` → 3 suites green.

- [ ] **Step 7: Prove non-breakage.** `pnpm build && pnpm test` at root (turbo orders bingo-core → shared → web), then `pnpm --filter @oybc/web typecheck`. Expected: everything green with **zero changes under `apps/web/src`** — that's the acceptance criterion for the shim. (`apps/web` has no deep `@oybc/shared/...` imports — verified — so the barrel re-export is sufficient.)

- [ ] **Step 8: CI paths.** In `.github/workflows/web.yml`, both `pull_request.paths` and `push.paths`: replace `- 'packages/shared/**'` with `- 'packages/**'` (covers bingo-core now and riso-tokens in T3 without another edit).

- [ ] **Step 9: Write `packages/bingo-core/MIRRORS.md`**

```markdown
# TS ↔ Swift mirror map

iOS does not consume this package at build time — Swift files are manual
mirrors (same algorithms, same semantics). When you change a TS module
here, update its Swift twin in the same PR (CLAUDE.md rule 6).

| bingo-core module | Swift mirror |
| --- | --- |
| src/bingoDetection.ts | apps/ios/OYBC/Services/BingoDetection.swift |
| src/shuffle.ts | apps/ios/OYBC/Services/Shuffle.swift (+ RNG-param variant in Services/RecurringBoardTemplates.swift) |
| src/centerSquare.ts | inline in placement call sites (no dedicated Swift file) |
| src/placement.ts (T2) | apps/ios/OYBC/Services/BoardPlacement.swift (T2) |
| src/constants.ts | Swift enums in Database/Models (CenterSquareType), Int literals for BoardSize |
```

Also add a short `packages/bingo-core/CLAUDE.md` (mirror `packages/shared/CLAUDE.md`'s shape): pure-functions-only rule, "no Do-domain types (Task/Board/BoardTask must never appear here)", pointer to MIRRORS.md, build/test commands.

- [ ] **Step 10: Commit + PR.** `git add -A && git commit -m "refactor(shared): extract @oybc/bingo-core (detection, shuffle, center-square) with compat re-exports"`. PR body notes the rule-6 justification: pure TS package move, no user-visible behavior on either platform, iOS mirrors untouched.

---

## Task T2: `placeBoard` — one placement core, five consumers

**Branch:** `feature/play-transition-t2-place-board` · **One PR, both platforms (rule 6).**

**Files:**
- Create: `packages/bingo-core/src/placement.ts`, `packages/bingo-core/tests/placement.test.ts`, `apps/ios/OYBC/Services/BoardPlacement.swift`
- Modify: `packages/bingo-core/src/index.ts` (add `export * from './placement'`), `packages/shared/src/algorithms/recurringBoardTemplates.ts` (`buildSpawnPlacement` becomes a wrapper; `fillableCellCount` moves out), `apps/web/src/components/wizard/wizardPersist.ts` (`buildWizardPlacement` fill-loop → `placeBoard` call), `apps/ios/OYBC/Views/CreateTab/BoardWizardPersist.swift` (same on iOS), `apps/ios/OYBC/Services/RecurringBoardTemplates.swift` (`buildSpawnPlacement` → wrapper), `packages/bingo-core/MIRRORS.md` (placement row goes live)
- Test: existing suites `packages/shared/tests/algorithms/recurringBoardTemplates.test.ts` (spawn parity, must stay green untouched) + new `placement.test.ts`; iOS `xcodebuild test` for the logic scheme; snapshot suite (`OYBCSnapshotTests`) guards the non-randomized wizard ordering.

**Interfaces:**
- Consumes: `fisherYatesShuffle`, `getCenterSquareIndex`, `isCenterAutoCompleted` (from T1).
- Produces (exact TS signature — the Swift mirror matches it 1:1 with `Task` in place of `T`):

```ts
export interface PlaceBoardArgs<T extends { id: string }> {
  /** Candidate items in the caller's preferred order (used verbatim when randomize=false). */
  items: readonly T[];
  gridSize: number;
  centerType: CenterSquareType;
  /** CHOSEN center: id of the item pinned to the center cell. Ignored for other center types / even grids. */
  chosenCenterId?: string;
  randomize: boolean;
  /** Uniform [0,1) RNG for the shuffle. Default Math.random. Seeded in tests / server fan-out. */
  rng?: () => number;
}

/** Length gridSize² array; null = empty cell (reserved FREE/CUSTOM_FREE center, or pool underfill). */
export function placeBoard<T extends { id: string }>(args: PlaceBoardArgs<T>): (T | null)[];

/** Number of cells a task pool must fill (total minus reserved center). Moved from recurringBoardTemplates. */
export function fillableCellCount(gridSize: number, centerType: CenterSquareType): number;
```

**Semantics of `placeBoard`** (superset of all four existing sites — each behavior traced to its origin):
1. `centerIdx = getCenterSquareIndex(gridSize)`; even grids have no center (all cells ordinary).
2. If odd grid + `centerType === CHOSEN` + `chosenCenterId` resolves to an item in `items`: pin that item at `centerIdx`, exclude it from the fill pool. If the id doesn't resolve, treat the center as ordinary (matches web wizard's `?? null` fallback).
3. If odd grid + `FREE`/`CUSTOM_FREE`: center stays `null` (reserved; the render layer draws the FREE label).
4. `NONE` (or even grid): center is filled like any other cell.
5. Fill pool = `items` minus any pinned center item; `randomize ? fisherYatesShuffle(pool, rng) : pool` (order-preserving when not randomizing — callers own their deterministic ordering, e.g. iOS's sort-by-id for snapshots).
6. Walk cells `0..gridSize²-1` row-major, skipping the pinned/reserved center; place next pool item; extra items are ignored (loose-fit pools — spawn path); exhausted pool leaves `null`s (wizard preview mid-selection).

**Steps:**

- [ ] **Step 1: Write `placement.test.ts` first** — the cases that pin every semantic above: 5×5 FREE center leaves index 12 null and places 24 of 25; 5×5 CHOSEN pins the id and never duplicates it elsewhere; CHOSEN with unresolvable id falls back to ordinary center; 5×5 NONE fills all 25; 4×4 ignores centerType entirely; underfilled pool leaves trailing nulls in the right cells; overfilled pool drops extras; `randomize:false` preserves input order exactly; `randomize:true` with the seeded rng below is deterministic and matches a hand-verified permutation; every input `items` array is never mutated. The seeded RNG used by every golden/parity test in this plan (TS and Swift port identically):

```ts
/** Deterministic uniform [0,1) LCG (Numerical Recipes constants). Same seeds ⇒ same boards, in Jest and XCTest. */
export function makeSeededRng(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 4294967296;
  };
}
```

(Swift twin: `state = state &* 1664525 &+ 1013904223` on `UInt32`, `Double(state) / 4294967296.0`.) Put it in `packages/bingo-core/tests/seededRng.ts` — test helper, not a src export. Run → all fail (module doesn't exist).

- [ ] **Step 2: Implement `placement.ts`** per the semantics block; move `fillableCellCount` here from `recurringBoardTemplates.ts` verbatim (generalize its `template.boardSize`/`centerSquareType` params to the plain args in the signature above). Run → green.

- [ ] **Step 3: Golden-parity harness for the spawn path.** In `recurringBoardTemplates.test.ts`, before refactoring, capture `buildSpawnPlacement` outputs for a fixed seeded RNG across the matrix {3×3, 4×4, 5×5} × {FREE, CUSTOM_FREE, CHOSEN, NONE} × {randomized, not} × {exact-fit, overfilled pool} as inline expected arrays (task ids only). Commit these as tests against the **old** implementation first and see them pass — that's the baseline.

- [ ] **Step 4: Refactor shared `buildSpawnPlacement`** into a wrapper: resolve `template.isRandomized` / `template.centerSquareType` / pool ordering exactly as today, then `return placeBoard({ items: poolTasks, gridSize: template.boardSize, centerType: template.centerSquareType, randomize: template.isRandomized, rng })`. Delete the now-duplicated loop. Run the golden tests + full shared suite → green, unchanged.

- [ ] **Step 5: Refactor web wizard.** In `wizardPersist.ts`, keep the selection-resolution preamble (pending-task merge, library ordering, `chosenCenter` lookup) — that's wizard UI policy, not placement math — and replace the `ordered`/`grid` fill loop (the ~25 lines from `const ordered = …` through `return grid`) with:

```ts
  return placeBoard({
    items: selected,
    gridSize: size,
    centerType: isOdd ? centerType : CenterSquareType.NONE,
    chosenCenterId: chosenCenter?.id,
    randomize: isRandomized,
  });
```

(Passing `NONE` for even grids preserves today's "even grid = no special center" behavior through the shared core; `placeBoard` also handles it internally via `getCenterSquareIndex`, so this is belt-and-suspenders — keep whichever reads cleaner after the golden tests agree.) Import `placeBoard` from `@oybc/shared` (re-exported) so web's import convention (barrel-only) is preserved. Verify: `pnpm --filter @oybc/web typecheck && pnpm build`, then load the wizard preview in the dev server and confirm placement still previews (Playwright pass per repo convention for web changes).

- [ ] **Step 6: iOS mirror.** Create `apps/ios/OYBC/Services/BoardPlacement.swift`:

```swift
import Foundation

/// Swift mirror of `@oybc/bingo-core` `placeBoard` — see packages/bingo-core/MIRRORS.md.
/// Superset placement core used by the wizard and template-spawn paths.
enum BoardPlacement {
    /// - Parameters:
    ///   - items: candidates in the caller's preferred order (used verbatim when randomize == false).
    ///   - chosenCenterId: CHOSEN center pin; ignored for other center types / even grids.
    ///   - rng: uniform [0,1) generator, injectable for deterministic tests.
    /// - Returns: gridSize² array; nil = empty cell (reserved FREE/CUSTOM_FREE center or pool underfill).
    static func placeBoard(
        items: [Task],
        gridSize: Int,
        centerType: CenterSquareType,
        chosenCenterId: String? = nil,
        randomize: Bool,
        rng: () -> Double = { Double.random(in: 0..<1) }
    ) -> [Task?] {
        let total = gridSize * gridSize
        let isOdd = gridSize % 2 != 0
        let centerIdx = isOdd ? (gridSize / 2) * gridSize + (gridSize / 2) : -1

        let chosenCenter: Task? = {
            guard isOdd, centerType == .chosen, let id = chosenCenterId else { return nil }
            return items.first(where: { $0.id == id })
        }()
        let pool = chosenCenter != nil ? items.filter { $0.id != chosenCenter!.id } : items
        let ordered = randomize ? fisherYatesShuffle(pool, rng: rng) : pool

        var grid: [Task?] = Array(repeating: nil, count: total)
        var next = 0
        for cell in 0..<total {
            if cell == centerIdx {
                if let center = chosenCenter { grid[cell] = center; continue }
                if centerType == .free || centerType == .customFree { continue }
            }
            if next < ordered.count { grid[cell] = ordered[next]; next += 1 }
        }
        return grid
    }
}
```

(Reuse the existing RNG-parameterized `fisherYatesShuffle` from `Services/RecurringBoardTemplates.swift:249` — hoist it into `Services/Shuffle.swift` as the canonical variant if visibility requires, keeping the no-arg convenience.) Refactor `BoardWizardPersist.buildWizardPlacement` (keep its pending-merge + sort-by-id-when-not-randomized preamble, pass the sorted array with `randomize: controller.isRandomized`… **note:** when not randomized, pre-sort and pass `randomize: false` so the core preserves the deterministic order) and `RecurringBoardTemplates.buildSpawnPlacement` (thin wrapper, same shape as TS) onto it. Port the golden-parity cases from Step 3 into `OYBCTests` as `BoardPlacementTests.swift` with the same seeded LCG so TS and Swift assert **identical expected arrays** — that's the cross-platform lockstep proof. `xcodegen generate` (new file), then run the logic tests.

- [ ] **Step 7: Snapshot guard.** Run the snapshot suite (`OYBCSnapshotTests`, per CLAUDE.md invocation) — wizard-preview baselines exercise the `isRandomized = false` path and will catch any ordering regression. Expect green except the two known date-drift reds on clean dev (see memory: they're pre-existing).

- [ ] **Step 8: Commit + PR** — `refactor(shared+ios): extract placeBoard placement core into bingo-core; wizard + spawn paths on both platforms consume it`. PR body: golden-parity evidence (TS + Swift), snapshot result, note that this closes a 4-site duplication and is the primitive Play's server-side board fan-out will consume.

---

## Task T3: Extract `@oybc/riso-tokens`

**Branch:** `feature/play-transition-t3-riso-tokens` · **One PR, web-only (rule-6 justification: token *file relocation*, zero visual change; iOS tokens live in `RisoTheme.swift` and are untouched).**

**Files:**
- Create: `packages/riso-tokens/package.json`, move `apps/web/src/styles/riso.css` → `packages/riso-tokens/riso.css` (git mv), `scripts/check-coming-soon-tokens.mjs`
- Modify: `apps/web/src/main.tsx:6`, `.github/workflows/web.yml` (add drift-check step), `docs/RISO_WEB.md` (token file's new home), `docs/COMING_SOON.md` (drift-check note)

**Interfaces:**
- Produces: CSS-only package; consumers import `@oybc/riso-tokens/riso.css`. No JS exports.

**Steps:**

- [ ] **Step 1: Scaffold.** `packages/riso-tokens/package.json`:

```json
{
  "name": "@oybc/riso-tokens",
  "version": "1.0.0",
  "description": "OYBC Riso design tokens (CSS custom properties) — single source of truth for web surfaces of both products. iOS twin: apps/ios/OYBC/Views/Riso/RisoTheme.swift.",
  "exports": { "./riso.css": "./riso.css" },
  "scripts": { "build": "true", "test": "true", "lint": "true", "clean": "true" }
}
```

(No build step — Vite consumes the CSS straight from the workspace link; the no-op scripts keep turbo's task graph happy.)

- [ ] **Step 2: Move + rewire.** `git mv apps/web/src/styles/riso.css packages/riso-tokens/riso.css`. Add `"@oybc/riso-tokens": "workspace:*"` to `apps/web/package.json` dependencies; change `apps/web/src/main.tsx:6` to `import '@oybc/riso-tokens/riso.css';` (keep the ordering comment — it must still load after `index.css`). `pnpm install`, then `pnpm --filter @oybc/web build` → green.

- [ ] **Step 3: Visual no-op check.** Dev-server + Playwright screenshot of `/boards` (day + night toggle) compared against pre-move screenshots — tokens are load-order-sensitive; this catches a cascade regression cheaply. (Per repo rule: Playwright validation is mandatory for web changes.)

- [ ] **Step 4: Coming-soon drift-check** (decision: keep `apps/coming-soon` self-contained by design — its stylesheet header documents "zero dependency on the app build" — so we *detect* divergence rather than share the file). `scripts/check-coming-soon-tokens.mjs`: parse `--`-prefixed custom-property declarations from the `:root` and night-scheme blocks of both `packages/riso-tokens/riso.css` (`--riso-*`) and `apps/coming-soon/src/*.css` (unprefixed twins per its header comment), strip the `riso-` prefix, and fail (exit 1, listing mismatches) if any token present in both files differs in value. Tokens present in only one file are ignored (the app has tokens the placeholder doesn't need). Wire into `web.yml` as a step after lint: `node scripts/check-coming-soon-tokens.mjs`. Run locally → passes today (values are byte-identical per COMING_SOON docs).

- [ ] **Step 5: Docs + commit.** Update the two docs' token-path references. Commit: `refactor(web): extract @oybc/riso-tokens package; coming-soon token drift-check in CI`.

**Deliberately deferred:** a `@oybc/riso-react` package for the 10 primitives in `apps/web/src/components/riso/`. Extract it in Play Phase 1 *when Play's first real screen needs a primitive* — moving CSS-module components is mechanical, and we don't yet know whether Play wants the full kit or only board cells (YAGNI). Record as a follow-up in CLAUDE.md when T5 lands.

---

## Task T4: Governance — docs home + CLAUDE.md delimitation

**Branch:** `feature/play-transition-t4-governance` · **One PR, docs-only.**

**Files:**
- Create: `docs/play/PLAY_OYBC.md` (the design doc, checked in verbatim from the canonical draft — **confirm with Stephen that `docs/play/` becomes the canonical home before this lands**; if the master lives elsewhere, this task instead adds a one-line pointer in `docs/play/README.md` to wherever it lives, because a diverging copy of a "living design doc" is worse than no copy)
- Modify: root `CLAUDE.md`

**Steps:**

- [ ] **Step 1: Land the design doc** (or the pointer — see decision above) under `docs/play/`. The spike brief (`play-oybc-architecture-spike.md`) gets checked in beside it whenever it's written; don't create a placeholder.

- [ ] **Step 2: Root `CLAUDE.md` — add a delimiting section** immediately after the Project Overview:

```markdown
## Two products, one repo — invariant scoping

This repo hosts two products: **OYBC (Do)** (the solo, offline-first tracker —
everything this file describes) and **Play OYBC** (`apps/play` — a real-time,
server-authoritative multiplayer party game; design doc: `docs/play/PLAY_OYBC.md`,
transition plan: `docs/PLAY_TRANSITION.md`).

**Every architecture invariant in this file is scoped to Do unless it says
otherwise** — in particular: local-DB-as-source-of-truth, offline-first, LWW
sync, no server push, lazy detection, and the web↔iOS parity rule 6 (which
pairs Do-web with Do-iOS; Play is a separate product, not a parity target).
`apps/play/CLAUDE.md` states Play's own (largely inverted) invariants and
takes precedence inside that directory.

Shared-boundary rule: Play consumes ONLY `@oybc/bingo-core` and
`@oybc/riso-tokens`. `@oybc/shared` is Do's domain layer — importing it from
`apps/play` is a defect (ESLint-enforced there). Conversely, never add a
Do-domain type (Task/Board/BoardTask) or a Play-domain type (session, lobby,
player) to `bingo-core`; it stays primitives-only.
```

- [ ] **Step 3: Update the root docs list** (`## Documentation` section): add `docs/PLAY_TRANSITION.md` and `docs/play/PLAY_OYBC.md` lines. Commit: `docs: scope root invariants to Do; add Play design-doc home + transition plan`.

---

## Task T5: Scaffold `apps/play` (+ scoped CLAUDE.md, CI, boundary lint)

**Branch:** `feature/play-transition-t5-play-scaffold` · **One PR.** Requires T1–T4 merged.

**Files:**
- Create: `apps/play/package.json`, `apps/play/vite.config.ts`, `apps/play/tsconfig.json`, `apps/play/index.html`, `apps/play/eslint.config.js`, `apps/play/src/main.tsx`, `apps/play/src/index.css`, `apps/play/src/DemoBoard.tsx`, `apps/play/CLAUDE.md`, `.github/workflows/play.yml`
- Modify: nothing outside `apps/play/` + the new workflow (pnpm-workspace globs already cover `apps/*`).

**Interfaces:**
- Consumes: `placeBoard`, `detectBingos`, `getHighlightedSquares`, `CenterSquareType` from `@oybc/bingo-core`; `@oybc/riso-tokens/riso.css`.
- Produces: the app shell + CI lane the architecture spike builds inside.

**Steps:**

- [ ] **Step 1: Package + config.** `apps/play/package.json` — name `@oybc/play`, `"private": true`, scripts identical to `@oybc/web`'s minus e2e (`dev`/`build`/`preview`/`typecheck`/`lint`), dependencies **only** `react ^19.2.7`, `react-dom ^19.2.7`, `@oybc/bingo-core workspace:*`, `@oybc/riso-tokens workspace:*`; devDependencies copied from `apps/web` (same Vite 8 / TS 6 / ESLint 10 pins, minus Playwright). `vite.config.ts`, `tsconfig.json`, `index.html` copied from `apps/web` and trimmed (no PWA/firebase config; title "Play OYBC").

- [ ] **Step 2: The boundary lint.** In `apps/play/eslint.config.js` (flat config, same base as web's) add:

```js
  {
    rules: {
      'no-restricted-imports': ['error', {
        paths: [{
          name: '@oybc/shared',
          message: "Play must not import Do's domain layer. Game math lives in @oybc/bingo-core; if you need something from shared, it either moves to bingo-core (if it's pure game math) or gets reimplemented against Play's own session model.",
        }],
        patterns: [{ group: ['@oybc/shared/*'], message: 'See @oybc/shared restriction.' }],
      }],
    },
  },
```

Verify it bites: add `import '@oybc/shared';` to `main.tsx`, run `pnpm --filter @oybc/play lint` → error with the message above; remove the import.

- [ ] **Step 3: Demo board page** — `src/DemoBoard.tsx`: a hardcoded ~30-string party-task pool, `placeBoard({ items, gridSize: 5, centerType: CenterSquareType.FREE, randomize: true })` on mount (items as `{id, title}`), a 5×5 CSS-grid of Riso-token-styled cells (`--riso-paper-2` fill, `--riso-ink` keyline — tokens only, no kit primitives yet), click-to-toggle marks held in a `Set<number>`, `detectBingos` on every toggle with `getHighlightedSquares` driving a highlight class, and a "BINGO!"/"GREENLOG!" banner from `formatBingoMessage`. A "New board" button re-runs `placeBoard`. ~120 lines; this is a dependency-chain proof and the spike's canvas, not product code — no router, no state library, no auth.

- [ ] **Step 4: `apps/play/CLAUDE.md`** — the invariant inversion (full text, lands exactly as written):

```markdown
# Play OYBC (`apps/play`)

Play OYBC is the real-time, multiplayer party-bingo sibling of OYBC (Do).
Design doc: `docs/play/PLAY_OYBC.md`. Transition plan: `docs/PLAY_TRANSITION.md`.

## ⚠️ Root-CLAUDE.md invariants DO NOT apply here

The root file describes OYBC (Do). Play **inverts** its core architecture:

| Root invariant (Do) | Play's rule |
| --- | --- |
| Local DB is the source of truth | **Session state is server-authoritative.** Clients render server state; they do not own it. |
| Offline-first; sync is background-only | **Online-required.** Offline play is an explicit non-goal. |
| LWW conflict resolution | Real-time competitive state; authority + ordering come from the backend (see spike). |
| No server push / lazy detection only | Live push (lobby presence, pool updates, launch fan-out, race state) is the whole point. |
| Global-per-Task completion | **Per-player, per-session completion.** Nothing completes globally. |
| Web↔iOS parity rule 6 | Pairs Do-web with Do-iOS. Play is a separate product — never "mirror" a Do surface here, and Play features don't owe Do a counterpart. |

## Rules that DO carry over

- Shared-boundary: import ONLY `@oybc/bingo-core` + `@oybc/riso-tokens`
  (`@oybc/shared` is ESLint-banned here — the ban is load-bearing, don't
  disable it). Pure game math belongs in bingo-core, session/domain logic here.
- Riso design system: tokens from `@oybc/riso-tokens`; follow
  `docs/RISO_WEB.md` conventions for any UI.
- Code quality + testing standards (types, small functions, Jest/deterministic
  tests) apply as written.

## Status

Scaffold only. Architecture (realtime backend, session model, authority) is
OPEN pending the Phase 0 spike — see design doc §6. Do not pick a backend or
add a persistence layer without that decision being recorded in the design
doc's Decisions Log.
```

- [ ] **Step 5: CI.** `.github/workflows/play.yml` — copy `web.yml`'s shape (same pnpm/action-setup@v6 + node setup, same concurrency pattern with a `play-` group key) with paths `apps/play/**`, `packages/bingo-core/**`, `packages/riso-tokens/**`, lockfile/turbo/workflow-self; job runs `pnpm install`, `pnpm --filter @oybc/play... build` (the `...` pulls workspace deps), `pnpm --filter @oybc/play lint`, `pnpm --filter @oybc/play typecheck`.

- [ ] **Step 6: Verify + commit.** `pnpm install && pnpm build`, `pnpm --filter @oybc/play dev` → demo board renders, marks toggle, bingo banner fires, tokens show Riso paper/ink. Commit: `feat(play): scaffold apps/play — bingo-core+riso-tokens only, boundary lint, CI lane, scoped CLAUDE.md`.

---

## Task T6: Prove `bingo-core` server-side (functions bundling PoC)

**Branch:** `feature/play-transition-t6-functions-poc` · **One PR.** This is the deploy-mechanics friction the spike must not hit blind: `functions/` is npm-managed (own `package-lock.json`, outside the pnpm workspace), and Firebase's cloud installer can't resolve `workspace:*`/`file:` deps — so the answer is **bundling**, and this task proves it end-to-end on the emulator.

**Files:**
- Create: `functions/src/validateWin.ts`
- Modify: `functions/package.json`, `functions/src/index.ts` (export the new callable), `functions/tsconfig.json` (only if needed for the symlink — see Step 1)

**Steps:**

- [ ] **Step 1: Give functions a local, type-checked handle on bingo-core.** In `functions/`: `npm install --save-dev esbuild` and add `"@oybc/bingo-core": "file:../packages/bingo-core"` to `devDependencies` (dev-only: it must NOT appear in `dependencies`, or the cloud installer would try to fetch it; the bundle inlines it instead). Run `pnpm --filter @oybc/bingo-core build` first so the symlinked package has `dist/`. `npm install` in `functions/` → symlink created.

- [ ] **Step 2: Switch the build to a bundle.** In `functions/package.json` scripts, replace `"build": "tsc"` with:

```json
    "build": "tsc --noEmit && esbuild src/index.ts --bundle --platform=node --target=node22 --format=cjs --outfile=lib/index.js --external:firebase-admin --external:firebase-functions",
```

(`tsc --noEmit` keeps full type-checking; esbuild inlines `@oybc/bingo-core` from the symlink; the two firebase packages stay external because they're real runtime `dependencies` the cloud installs.) `npm run build` → `lib/index.js` exists and `grep -c "detectBingos" lib/index.js` ≥ 1 once Step 3 lands.

- [ ] **Step 3: The PoC callable** — `functions/src/validateWin.ts`:

```ts
import { onCall, HttpsError } from 'firebase-functions/v2/https';
import { detectBingos, BOARD_SIZES, type BoardSize } from '@oybc/bingo-core';

/**
 * PoC: server-authoritative win validation running the SAME detection code
 * the clients run (see docs/PLAY_TRANSITION.md T6). Play's spike replaces
 * this with the real session-scoped endpoint; the point here is proving the
 * bundling path, not the API shape.
 */
export const validateWin = onCall((request) => {
  const { completionGrid, gridSize } = request.data as {
    completionGrid: unknown;
    gridSize: unknown;
  };
  if (
    !Array.isArray(completionGrid) ||
    !completionGrid.every((c) => typeof c === 'boolean') ||
    !BOARD_SIZES.includes(gridSize as BoardSize)
  ) {
    throw new HttpsError('invalid-argument', 'completionGrid: boolean[], gridSize: 3|4|5');
  }
  const result = detectBingos(completionGrid, gridSize as BoardSize);
  return { isWin: result.isGreenlog, completedLines: result.completedLines };
});
```

Export it from `functions/src/index.ts` alongside the existing deletion functions.

- [ ] **Step 4: Emulator verification (do NOT deploy).** `cd functions && npm run build && firebase emulators:start --only functions`, then from another shell call it (`curl` the emulator's callable endpoint with `{"data":{"completionGrid":[true,…25×true…],"gridSize":5}}`) → `{"result":{"isWin":true,"completedLines":[…12 lines…]}}`; a 24-true grid → `isWin:false`. Record the transcript in the PR body. Leave `validateWin` **undeployed** — it ships to the dev project only when the spike gives it a real consumer (note this in the PR body so nobody "helpfully" deploys it).

- [ ] **Step 5: Commit** — `chore(functions): esbuild bundling + validateWin PoC proving @oybc/bingo-core runs server-side (emulator-only)`.

---

## Sequencing, risks, rollback

**Order:** T1 → T2 → (T3, T4 in parallel) → T5 → T6. T2 needs T1's package; T5 needs T1+T3 (deps) and T4 (the root delimitation should exist before an agent ever works inside `apps/play`); T6 needs only T1 but is last because it's pure spike-enablement. T1+T2 are also the pieces worth doing *even if Play stalls* — they close a real 4-site duplication and make the wizard→persist placement seam pure and testable (the seam PR #202's bugs hid in).

| Risk | Mitigation |
| --- | --- |
| Barrel re-export ambiguity (`export *` collisions between constants and algorithms barrels re-exporting the same bingo-core symbols) | T1 Step 5 names the fallback: switch the algorithms barrel to named re-exports. Caught by `tsc` at build, not runtime. |
| Stale `dist/` confusion (`web` compiles against old shared build) | Known repo gotcha (shared CLAUDE.md). Turbo's `^build` ordering handles CI; locally always `pnpm build` from root after T1. |
| Placement refactor silently changes board layouts | Golden-parity tests (T2 Steps 3/6) with seeded RNG on both platforms + snapshot suite for the non-randomized wizard path. |
| iOS/TS mirror drift accelerates as bingo-core grows | `MIRRORS.md` + rule-6 discipline; T2's twin test vectors (identical expected arrays in Jest and XCTest) make drift loud. |
| Coming-soon token copy diverges | T3 drift-check in CI (fails the web workflow on value mismatch). |
| Do invariants bleed into Play (agents or humans) | T4 root delimitation + T5 scoped CLAUDE.md + the ESLint import ban — three independent tripwires. |
| Functions bundling breaks the existing deletion functions | T6 keeps `tsc --noEmit` type-checking and verifies **all** exports on the emulator before merge; `onUserDeleted`/`deleteUserData` behavior is untouched (same source, new bundler). |
| `xcodegen` / pbxproj churn (T2 adds Swift files) | Standard repo flow: `xcodegen generate`, never hand-edit pbxproj; on conflict take-either-side + regenerate. |

**Rollback:** T1/T3 are file moves + re-exports — revert the PR and everything is back (no consumer changed its imports outside the moved packages). T2 reverts to the four inline loops (golden tests continue to pass either way, by construction). T5/T6 are additive (new app dir, new callable) — deleting them touches nothing existing.

## Out of scope (recorded so nobody "helpfully" does them here)

- The architecture spike itself (realtime backend, session model, authority split) — Play design doc §6 owns it.
- `@oybc/riso-react` extraction — deferred to Play Phase 1 (see T3).
- A Swift `RisoKit`/`BingoCoreKit` package — deferred until a Play iOS client exists; Do-iOS keeps its in-target mirrors.
- `play.oybc.com` hosting/domain wiring — spike/Phase-1 concern (multi-site Firebase Hosting, like the coming-soon apex setup).
- Any Play monetization, moderation, or App Store work — design doc §7/§8.

## Decisions this plan takes as settled (flag now if wrong)

1. Monorepo co-habit (`apps/play`) — per the review discussion; revisit only if Play gains independent contributors/toolchain.
2. Package name `@oybc/bingo-core`; `CenterSquareType` + `BoardSize` move with it (they're game geometry, not Do domain).
3. Coming-soon keeps its self-contained token copy + CI drift-check (rather than importing the package) — preserves its documented zero-dependency intent.
4. Play demo scaffold is web-only (matches "web and/or TestFlight" with web-first maximizing actual reuse; a Play iOS client is a later, separate decision).
5. `functions/` stays npm-managed with esbuild bundling (rather than joining the pnpm workspace) — smallest change that makes workspace code deployable.
6. `docs/play/` becomes the canonical Play design-doc home — **the one decision needing explicit confirmation (T4), since the design doc is a living document that may be mastered elsewhere.**
