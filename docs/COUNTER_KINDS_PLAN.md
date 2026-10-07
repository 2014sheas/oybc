# Counter Kinds — PR 1 (Foundation) + PR 2 (Logic) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every counting value (goal, count, log delta, baseline, default log amount, member-rule target) a 2-decimal real number with a per-task `countKind`, end to end on web + iOS, with **no user-visible change** in PR 1 and kind-aware kernels / member rules / kind switching in PR 2.

**Architecture:** One shared value module (`countValue.ts` ↔ `CountValue.swift`) owns quantization, kind resolution, window-sum finalisation, formatting and the kind-switch plan; every kernel, write path and validator calls it instead of doing its own integer maths. Integers are exact doubles, so every existing (discrete) counter is bit-identical; only `continuous` tasks ever hold fractions. `duration` = integer minutes on the discrete branch.

**Tech Stack:** TypeScript + Zod + Jest (`packages/shared`), React + Dexie + Vitest (`apps/web`), Swift + GRDB + XCTest (`apps/ios`), cross-platform JSON vectors (`packages/shared/tests/fixtures` → `apps/ios/OYBCTests/Fixtures`).

**Spec:** [`docs/COUNTER_KINDS.md`](COUNTER_KINDS.md) — read §2 (D1–D7) before any task.

## Global Constraints

- Kinds: `'discrete' | 'continuous' | 'duration'`; field `Task.countKind`, absent ⇒ `'discrete'` (D1).
- Precision: **2 decimal places**, quantize = round half away from zero at 0.01, applied once per write (D2/D3).
- Whole kinds (`discrete`, `duration`): window sums round **half-up** at read; stored goals/default amounts are integers (D4).
- Switching: `discrete ⇄ continuous` only; never into or out of `duration` (D4). Switching to a whole kind rounds `maxCount` (min 1) and `defaultLogAmount` (min 1). Events are NEVER rewritten.
- Family: linked / minted copies carry the ROOT's `countKind`; a root switch cascades to the family (D5). Frozen (ended-window) derived rows keep their kind — see Review Focus #3.
- `duration` stores integer minutes; every step is 1 minute (D6).
- PR 1 is inert: no UI string, control or behaviour changes. All UI work is PR 3/4 (blocked on the Claude Design handoff).
- Every task lands web + iOS together when it touches a twin (CLAUDE.md rule 6). Vector fixtures are regenerated with `pnpm --filter @oybc/shared run gen:sync-fixtures` and committed in the same task.
- File-size guardrail: no source file > 1000 lines (`node scripts/check-file-sizes.mjs`). `memberRules.ts` is 970 and `BoardSourceMemberRules.swift` 956 — new maths goes in `countValue.ts` / `CountValue.swift`, never inline. Never bump a cap.
- `packages/shared` coverage gate is 80% — new modules ship with full tests.
- iOS builds/tests always use `-derivedDataPath /Volumes/Stephen/oybc-derived` and `-destination 'platform=iOS Simulator,name=iPhone 17,OS=26.3.1'`. After adding a `.swift` file, run `xcodegen generate` in `apps/ios`.
- iOS async closures: `_Concurrency.Task { }` (OYBC `Task` shadows Swift's).
- Push with `git push origin HEAD:feature/counter-kinds` and verify the remote SHA (CLAUDE.md §Push & merge safety).

## Review Focus

1. **Float drift at the goal line** — 0.1 + 0.2 logged against a 0.3 goal must complete; 3 × 0.1 must display `0.3`, never `0.30000000000000004`. (Task 1 vectors, Task 7 kernel vectors.)
2. **Fractional history on a switched-to-discrete task** — three 0.4 logs on a task switched to `discrete` show 1 (sum-then-round), and switching back shows 1.2. (Task 7 vectors, Task 10 integration test.)
3. **Kind switch on a family with ended windows** — a root switched `continuous → discrete` must not change the target or kind of a frozen derived row (`isFrozenDerivedRow`), so a closed board's snapshot and its displayed target can't disagree. (Task 10 test.)
4. **Old payloads and iOS raw upsert** — a Firestore `Double` (3.1) for `delta` / `maxCount` must land in GRDB and decode into `Double?` on iOS, and pass the web pull validator; a pre-feature row with no `countKind` decodes as discrete. (Task 4 web test, Task 6 iOS test.)
5. **Member-rule seeded reproducibility** — a continuous member's dice roll must consume exactly one rng sample (or none on a degenerate range) on both platforms, so seeded vectors agree byte-for-byte. (Task 9 vectors.)

---

# PR 1 — Foundation (inert)

### Task 1: Shared count-value module

**Files:**
- Create: `packages/shared/src/algorithms/countValue.ts`
- Modify: `packages/shared/src/algorithms/index.ts` (export block)
- Create: `packages/shared/tests/fixtures/countValueVectors.json`
- Create: `packages/shared/tests/algorithms/countValue.test.ts`

**Interfaces:**
- Produces (used by every later task):
  - `type CountKind = 'discrete' | 'continuous' | 'duration'`
  - `COUNT_KINDS: readonly CountKind[]`
  - `resolveCountKind(task: { countKind?: CountKind | null }): CountKind`
  - `isWholeCountKind(kind: CountKind): boolean`
  - `quantizeCount(x: number): number`
  - `isQuantizedCount(x: number): boolean`
  - `finalizeWindowCount(sum: number, kind: CountKind): number`
  - `formatCount(value: number, kind: CountKind, locale?: string): string`
  - `canSwitchCountKind(from: CountKind, to: CountKind): boolean`
  - `planCountKindSwitch(fields: { maxCount?: number | null; defaultLogAmount?: number | null }, from: CountKind, to: CountKind): { maxCount?: number; defaultLogAmount?: number } | null`
  - `countTargetStep(kind: CountKind): number` (1 for whole kinds, 0.1 for continuous — used by Task 9)

- [ ] **Step 1: Write the vectors file**

`packages/shared/tests/fixtures/countValueVectors.json`:

```json
{
  "_note": "Cross-platform vectors for countValue.ts <-> CountValue.swift (docs/COUNTER_KINDS.md §3). quantize = round half away from zero at 0.01 via Math.round(|x|*100 + 1e-7) / 100 with the sign restored; -0 normalises to 0. finalize = clamp >= 0, quantize, then whole kinds (discrete, duration) round half-up. format uses the given locale with no grouping; duration values are minutes rendered 'Xh Ym' with zero parts dropped ('0m' for zero).",
  "quantize": [
    { "name": "integer unchanged", "x": 26, "expected": 26 },
    { "name": "two places unchanged", "x": 3.12, "expected": 3.12 },
    { "name": "drift sum", "x": 0.30000000000000004, "expected": 0.3 },
    { "name": "half rounds away from zero", "x": 1.005, "expected": 1.01 },
    { "name": "three places down", "x": 2.344, "expected": 2.34 },
    { "name": "negative half", "x": -1.005, "expected": -1.01 },
    { "name": "negative zero", "x": -0.001, "expected": 0 }
  ],
  "isQuantized": [
    { "name": "integer", "x": 5, "expected": true },
    { "name": "one place", "x": 3.1, "expected": true },
    { "name": "two places", "x": 26.25, "expected": true },
    { "name": "three places", "x": 3.125, "expected": false },
    { "name": "drift value", "x": 0.30000000000000004, "expected": false }
  ],
  "finalize": [
    { "name": "continuous drift", "sum": 0.30000000000000004, "kind": "continuous", "expected": 0.3 },
    { "name": "continuous negative clamps", "sum": -2.5, "kind": "continuous", "expected": 0 },
    { "name": "discrete integer", "sum": 7, "kind": "discrete", "expected": 7 },
    { "name": "discrete fractional history rounds half-up", "sum": 1.2000000000000002, "kind": "discrete", "expected": 1 },
    { "name": "discrete half rounds up", "sum": 2.5, "kind": "discrete", "expected": 3 },
    { "name": "duration minutes", "sum": 90, "kind": "duration", "expected": 90 }
  ],
  "format": [
    { "name": "continuous trims zeros", "value": 26.2, "kind": "continuous", "locale": "en-US", "expected": "26.2" },
    { "name": "continuous whole", "value": 5, "kind": "continuous", "locale": "en-US", "expected": "5" },
    { "name": "continuous two places", "value": 12.75, "kind": "continuous", "locale": "en-US", "expected": "12.75" },
    { "name": "continuous no grouping", "value": 1250.5, "kind": "continuous", "locale": "en-US", "expected": "1250.5" },
    { "name": "continuous comma locale", "value": 3.1, "kind": "continuous", "locale": "de-DE", "expected": "3,1" },
    { "name": "discrete whole", "value": 300, "kind": "discrete", "locale": "en-US", "expected": "300" },
    { "name": "discrete rounds stray fraction", "value": 2.5, "kind": "discrete", "locale": "en-US", "expected": "3" },
    { "name": "duration hours and minutes", "value": 270, "kind": "duration", "locale": "en-US", "expected": "4h 30m" },
    { "name": "duration whole hours", "value": 600, "kind": "duration", "locale": "en-US", "expected": "10h" },
    { "name": "duration minutes only", "value": 45, "kind": "duration", "locale": "en-US", "expected": "45m" },
    { "name": "duration zero", "value": 0, "kind": "duration", "locale": "en-US", "expected": "0m" }
  ],
  "switch": [
    { "name": "discrete to continuous keeps values", "from": "discrete", "to": "continuous", "fields": { "maxCount": 26, "defaultLogAmount": 3 }, "expected": { "maxCount": 26, "defaultLogAmount": 3 } },
    { "name": "continuous to discrete rounds", "from": "continuous", "to": "discrete", "fields": { "maxCount": 26.2, "defaultLogAmount": 3.5 }, "expected": { "maxCount": 26, "defaultLogAmount": 4 } },
    { "name": "continuous to discrete floors at one", "from": "continuous", "to": "discrete", "fields": { "maxCount": 0.3, "defaultLogAmount": 0.25 }, "expected": { "maxCount": 1, "defaultLogAmount": 1 } },
    { "name": "goal-less counter", "from": "continuous", "to": "discrete", "fields": { "maxCount": null, "defaultLogAmount": null }, "expected": {} },
    { "name": "into duration refused", "from": "discrete", "to": "duration", "fields": { "maxCount": 30 }, "expected": null },
    { "name": "out of duration refused", "from": "duration", "to": "continuous", "fields": { "maxCount": 30 }, "expected": null },
    { "name": "same kind refused", "from": "continuous", "to": "continuous", "fields": { "maxCount": 3 }, "expected": null }
  ]
}
```

- [ ] **Step 2: Write the failing test**

`packages/shared/tests/algorithms/countValue.test.ts`:

```ts
import vectors from '../fixtures/countValueVectors.json';
import {
  quantizeCount, isQuantizedCount, finalizeWindowCount, formatCount,
  planCountKindSwitch, canSwitchCountKind, resolveCountKind, isWholeCountKind,
  countTargetStep, type CountKind,
} from '../../src/algorithms/countValue';

describe('countValue vectors', () => {
  it.each(vectors.quantize)('quantize: $name', ({ x, expected }) => {
    expect(quantizeCount(x)).toBe(expected);
  });
  it.each(vectors.isQuantized)('isQuantized: $name', ({ x, expected }) => {
    expect(isQuantizedCount(x)).toBe(expected);
  });
  it.each(vectors.finalize)('finalize: $name', ({ sum, kind, expected }) => {
    expect(finalizeWindowCount(sum, kind as CountKind)).toBe(expected);
  });
  it.each(vectors.format)('format: $name', ({ value, kind, locale, expected }) => {
    expect(formatCount(value, kind as CountKind, locale)).toBe(expected);
  });
  it.each(vectors.switch)('switch: $name', ({ from, to, fields, expected }) => {
    expect(planCountKindSwitch(fields, from as CountKind, to as CountKind)).toEqual(expected);
  });
});

describe('countValue helpers', () => {
  it('absent or null kind resolves to discrete', () => {
    expect(resolveCountKind({})).toBe('discrete');
    expect(resolveCountKind({ countKind: null })).toBe('discrete');
    expect(resolveCountKind({ countKind: 'continuous' })).toBe('continuous');
  });
  it('whole kinds are discrete and duration', () => {
    expect(isWholeCountKind('discrete')).toBe(true);
    expect(isWholeCountKind('duration')).toBe(true);
    expect(isWholeCountKind('continuous')).toBe(false);
  });
  it('rejects non-finite values', () => {
    expect(isQuantizedCount(Number.NaN)).toBe(false);
    expect(isQuantizedCount(Number.POSITIVE_INFINITY)).toBe(false);
  });
  it('switch permission matrix', () => {
    expect(canSwitchCountKind('discrete', 'continuous')).toBe(true);
    expect(canSwitchCountKind('continuous', 'discrete')).toBe(true);
    expect(canSwitchCountKind('discrete', 'duration')).toBe(false);
    expect(canSwitchCountKind('duration', 'discrete')).toBe(false);
    expect(canSwitchCountKind('discrete', 'discrete')).toBe(false);
  });
  it('target step per kind', () => {
    expect(countTargetStep('discrete')).toBe(1);
    expect(countTargetStep('duration')).toBe(1);
    expect(countTargetStep('continuous')).toBe(0.1);
  });
});
```

- [ ] **Step 3: Run it — expect FAIL** (`Cannot find module '../../src/algorithms/countValue'`)

Run: `pnpm --filter @oybc/shared test -- countValue`

- [ ] **Step 4: Implement**

`packages/shared/src/algorithms/countValue.ts`:

```ts
/**
 * Counter kinds — the single owner of counting-value maths
 * (docs/COUNTER_KINDS.md §3). Every kernel, write path and validator that
 * touches a goal / count / delta / baseline / default log amount /
 * member-rule target goes through these helpers. Swift twin:
 * `apps/ios/OYBC/Helpers/CountValue.swift`, pinned by countValueVectors.json.
 */

/** A counting task's kind. Absent on a stored row ⇒ `'discrete'`. */
export type CountKind = 'discrete' | 'continuous' | 'duration';

/** Every kind, in picker order. */
export const COUNT_KINDS: readonly CountKind[] = ['discrete', 'continuous', 'duration'];

/**
 * A task's effective kind.
 *
 * @param task - Anything carrying an optional `countKind`.
 * @returns The kind, defaulting to `'discrete'` when absent or null.
 */
export function resolveCountKind(task: { countKind?: CountKind | null }): CountKind {
  return task.countKind ?? 'discrete';
}

/**
 * Whether a kind counts in whole units (discrete counts, duration minutes).
 *
 * @param kind - The kind.
 * @returns True for `'discrete'` and `'duration'`.
 */
export function isWholeCountKind(kind: CountKind): boolean {
  return kind !== 'continuous';
}

/**
 * Rounds to 2 decimal places, half away from zero. The `1e-7` nudge absorbs
 * binary representation error (1.005 is stored as 1.00499…), and dividing an
 * integer by 100 yields the same nearest double in JS and Swift.
 *
 * @param x - Any finite number.
 * @returns `x` at 0.01 precision; `-0` normalised to `0`.
 */
export function quantizeCount(x: number): number {
  const r = Math.round(Math.abs(x) * 100 + 1e-7) / 100;
  if (r === 0) return 0;
  return x < 0 ? -r : r;
}

/**
 * Whether `x` is a storable counting value: finite and already at 2dp.
 *
 * @param x - The candidate.
 * @returns True when `quantizeCount(x) === x`.
 */
export function isQuantizedCount(x: number): boolean {
  return Number.isFinite(x) && quantizeCount(x) === x;
}

/**
 * The displayed / compared count for a window: low-clamped at 0, quantized,
 * and rounded half-up for whole kinds (a task switched to discrete may hold
 * fractional history — D4 rounds the SUM, never each event).
 *
 * @param sum - Raw signed delta sum.
 * @param kind - The task's kind.
 * @returns The finalised count.
 */
export function finalizeWindowCount(sum: number, kind: CountKind): number {
  const q = quantizeCount(Math.max(0, sum));
  return isWholeCountKind(kind) ? Math.floor(q + 0.5) : q;
}

/**
 * Display text for a counting value. Whole kinds show whole numbers;
 * continuous trims trailing zeros; duration (minutes) renders `Xh Ym`.
 * No digit grouping (matches the pre-feature raw interpolation).
 *
 * @param value - The value (minutes for duration).
 * @param kind - The task's kind.
 * @param locale - BCP 47 locale; defaults to the runtime locale.
 * @returns The formatted string.
 */
export function formatCount(value: number, kind: CountKind, locale?: string): string {
  if (kind === 'duration') {
    const minutes = Math.max(0, Math.floor(value + 0.5));
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    if (h === 0) return `${m}m`;
    return m === 0 ? `${h}h` : `${h}h ${m}m`;
  }
  const digits = kind === 'continuous' ? 2 : 0;
  const v = kind === 'continuous' ? quantizeCount(value) : Math.floor(quantizeCount(value) + 0.5);
  return new Intl.NumberFormat(locale, {
    minimumFractionDigits: 0,
    maximumFractionDigits: digits,
    useGrouping: false,
  }).format(v);
}

/**
 * Whether a counter may change kind (D4): discrete ⇄ continuous only.
 *
 * @param from - Current kind.
 * @param to - Requested kind.
 * @returns True only for a real discrete ⇄ continuous change.
 */
export function canSwitchCountKind(from: CountKind, to: CountKind): boolean {
  return from !== to && from !== 'duration' && to !== 'duration';
}

/**
 * The field patch a kind switch writes, or `null` when the switch is refused.
 * Switching to a whole kind rounds the goal and default amount (min 1).
 * Absent / null inputs stay absent in the patch.
 *
 * @param fields - The task's current goal / default log amount.
 * @param from - Current kind.
 * @param to - Requested kind.
 * @returns The patch (may be `{}`), or `null`.
 */
export function planCountKindSwitch(
  fields: { maxCount?: number | null; defaultLogAmount?: number | null },
  from: CountKind,
  to: CountKind,
): { maxCount?: number; defaultLogAmount?: number } | null {
  if (!canSwitchCountKind(from, to)) return null;
  const conv = (v: number): number =>
    isWholeCountKind(to) ? Math.max(1, Math.floor(quantizeCount(v) + 0.5)) : quantizeCount(v);
  const patch: { maxCount?: number; defaultLogAmount?: number } = {};
  if (fields.maxCount != null) patch.maxCount = conv(fields.maxCount);
  if (fields.defaultLogAmount != null) patch.defaultLogAmount = conv(fields.defaultLogAmount);
  return patch;
}

/**
 * The granularity of a member-rule target / vary bound for a kind.
 *
 * @param kind - The kind.
 * @returns 1 for whole kinds, 0.1 for continuous.
 */
export function countTargetStep(kind: CountKind): number {
  return isWholeCountKind(kind) ? 1 : 0.1;
}
```

Add to `packages/shared/src/algorithms/index.ts` after the `taskTitle` exports:

```ts
// ===== Counter kinds (docs/COUNTER_KINDS.md) =====
export {
  COUNT_KINDS,
  resolveCountKind,
  isWholeCountKind,
  quantizeCount,
  isQuantizedCount,
  finalizeWindowCount,
  formatCount,
  canSwitchCountKind,
  planCountKindSwitch,
  countTargetStep,
} from './countValue';
export type { CountKind } from './countValue';
```

- [ ] **Step 5: Run — expect PASS.** `pnpm --filter @oybc/shared test -- countValue`. If `de-DE` fails, Node lacks full ICU — check `node -p "Intl.NumberFormat('de-DE').format(3.1)"`; Node ≥ 13 ships full ICU, so a failure means a mis-written formatter, not the env.

- [ ] **Step 6: Commit**

```bash
git add packages/shared/src/algorithms/countValue.ts packages/shared/src/algorithms/index.ts packages/shared/tests/fixtures/countValueVectors.json packages/shared/tests/algorithms/countValue.test.ts
git commit -m "feat(shared): countValue module — kinds, 2dp quantize, window finalise, format, kind-switch plan"
```

---

### Task 2: Swift twin of the count-value module

**Files:**
- Create: `apps/ios/OYBC/Helpers/CountValue.swift`
- Create: `apps/ios/OYBCTests/CountValueVectorTests.swift`
- Generate: `apps/ios/OYBCTests/Fixtures/countValueVectors.json` (via script)

**Interfaces:**
- Consumes: `countValueVectors.json` (Task 1).
- Produces: `typealias CountValue = Double`; `enum CountKind: String, Codable, CaseIterable, Equatable { case discrete, continuous, duration }`; free functions `resolveCountKind(_ raw: CountKind?) -> CountKind`, `isWholeCountKind(_:) -> Bool`, `quantizeCount(_:) -> CountValue`, `isQuantizedCount(_:) -> Bool`, `finalizeWindowCount(_ sum: CountValue, kind: CountKind) -> CountValue`, `formatCount(_ value: CountValue, kind: CountKind, locale: Locale = .current) -> String`, `canSwitchCountKind(from:to:) -> Bool`, `planCountKindSwitch(maxCount: CountValue?, defaultLogAmount: CountValue?, from: CountKind, to: CountKind) -> CountKindSwitchPatch?` with `struct CountKindSwitchPatch: Equatable { var maxCount: CountValue?; var defaultLogAmount: CountValue? }`, `countTargetStep(_:) -> CountValue`.

- [ ] **Step 1: Sync the fixture.** `pnpm --filter @oybc/shared run gen:sync-fixtures` → confirm `apps/ios/OYBCTests/Fixtures/countValueVectors.json` exists.

- [ ] **Step 2: Write the failing test** `apps/ios/OYBCTests/CountValueVectorTests.swift`:

```swift
import XCTest
@testable import OYBC

/// Cross-platform pins for `CountValue.swift`, driven by the same
/// `countValueVectors.json` as `packages/shared/tests/algorithms/countValue.test.ts`.
final class CountValueVectorTests: XCTestCase {
    private struct NumVector: Decodable { let name: String; let x: Double; let expected: Double }
    private struct BoolVector: Decodable { let name: String; let x: Double; let expected: Bool }
    private struct FinalizeVector: Decodable { let name: String; let sum: Double; let kind: CountKind; let expected: Double }
    private struct FormatVector: Decodable { let name: String; let value: Double; let kind: CountKind; let locale: String; let expected: String }
    private struct Fields: Decodable { let maxCount: Double?; let defaultLogAmount: Double? }
    private struct SwitchVector: Decodable { let name: String; let from: CountKind; let to: CountKind; let fields: Fields; let expected: Fields? }
    private struct Fixture: Decodable {
        let quantize: [NumVector]
        let isQuantized: [BoolVector]
        let finalize: [FinalizeVector]
        let format: [FormatVector]
        let `switch`: [SwitchVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: CountValueVectorTests.self).url(forResource: "countValueVectors", withExtension: "json") else {
            XCTFail("countValueVectors.json missing from the test bundle — re-run gen:sync-fixtures and xcodegen generate.")
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testQuantize() throws {
        for v in try loadFixture().quantize { XCTAssertEqual(quantizeCount(v.x), v.expected, v.name) }
    }
    func testIsQuantized() throws {
        for v in try loadFixture().isQuantized { XCTAssertEqual(isQuantizedCount(v.x), v.expected, v.name) }
    }
    func testFinalize() throws {
        for v in try loadFixture().finalize { XCTAssertEqual(finalizeWindowCount(v.sum, kind: v.kind), v.expected, v.name) }
    }
    func testFormat() throws {
        for v in try loadFixture().format {
            XCTAssertEqual(formatCount(v.value, kind: v.kind, locale: Locale(identifier: v.locale)), v.expected, v.name)
        }
    }
    func testSwitch() throws {
        for v in try loadFixture().switch {
            let got = planCountKindSwitch(maxCount: v.fields.maxCount, defaultLogAmount: v.fields.defaultLogAmount, from: v.from, to: v.to)
            if let exp = v.expected {
                XCTAssertEqual(got, CountKindSwitchPatch(maxCount: exp.maxCount, defaultLogAmount: exp.defaultLogAmount), v.name)
            } else {
                XCTAssertNil(got, v.name)
            }
        }
    }
    func testKindDecodesAndDefaults() throws {
        XCTAssertEqual(resolveCountKind(nil), .discrete)
        XCTAssertEqual(try JSONDecoder().decode(CountKind.self, from: Data("\"continuous\"".utf8)), .continuous)
        XCTAssertEqual(countTargetStep(.continuous), 0.1)
        XCTAssertEqual(countTargetStep(.duration), 1)
    }
}
```

Note: the switch vector `"expected": {}` decodes to `Fields(maxCount: nil, defaultLogAmount: nil)` (an empty patch) and `null` to `nil` (refused) — the two must stay distinct.

- [ ] **Step 3: Run — expect a compile FAIL** (`cannot find 'quantizeCount'`):

```bash
cd apps/ios && xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project OYBC.xcodeproj -scheme OYBC -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.3.1' -derivedDataPath /Volumes/Stephen/oybc-derived test -only-testing:OYBCTests/CountValueVectorTests
```

- [ ] **Step 4: Implement** `apps/ios/OYBC/Helpers/CountValue.swift`:

```swift
import Foundation

/// Counter kinds — Swift twin of `packages/shared/src/algorithms/countValue.ts`
/// (docs/COUNTER_KINDS.md §3), pinned by `countValueVectors.json`.

/// Every counting value (goal, count, delta, baseline, default log amount,
/// member-rule target). Integers are exact, so discrete counters are unchanged.
typealias CountValue = Double

/// A counting task's kind. A nil stored value resolves to `.discrete`.
enum CountKind: String, Codable, CaseIterable, Equatable {
    case discrete, continuous, duration
}

/// - Returns: `raw`, or `.discrete` when nil.
func resolveCountKind(_ raw: CountKind?) -> CountKind { raw ?? .discrete }

/// - Returns: True for `.discrete` and `.duration` (whole units).
func isWholeCountKind(_ kind: CountKind) -> Bool { kind != .continuous }

/// Rounds to 2 decimal places, half away from zero; `-0` → `0`.
/// Same arithmetic as the TS twin so both land on the identical double.
/// JS `Math.round` rounds half toward +∞; the argument is non-negative here,
/// so `.toNearestOrAwayFromZero` is the identical rule.
func quantizeCount(_ x: CountValue) -> CountValue {
    let q = (abs(x) * 100 + 1e-7).rounded(.toNearestOrAwayFromZero) / 100
    if q == 0 { return 0 }
    return x < 0 ? -q : q
}

/// - Returns: True when finite and already at 2dp.
func isQuantizedCount(_ x: CountValue) -> Bool { x.isFinite && quantizeCount(x) == x }

/// Low-clamp, quantize, then round half-up for whole kinds.
func finalizeWindowCount(_ sum: CountValue, kind: CountKind) -> CountValue {
    let q = quantizeCount(max(0, sum))
    return isWholeCountKind(kind) ? (q + 0.5).rounded(.down) : q
}

/// Display text: whole numbers for whole kinds, trimmed decimals for
/// continuous, `Xh Ym` for duration minutes. No grouping.
func formatCount(_ value: CountValue, kind: CountKind, locale: Locale = .current) -> String {
    if kind == .duration {
        let minutes = Int(max(0, (value + 0.5).rounded(.down)))
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
    let f = NumberFormatter()
    f.locale = locale
    f.numberStyle = .decimal
    f.usesGroupingSeparator = false
    f.minimumFractionDigits = 0
    f.maximumFractionDigits = kind == .continuous ? 2 : 0
    f.roundingMode = .halfUp
    let v = kind == .continuous ? quantizeCount(value) : (quantizeCount(value) + 0.5).rounded(.down)
    return f.string(from: NSNumber(value: v)) ?? "\(v)"
}

/// Discrete ⇄ continuous only (D4).
func canSwitchCountKind(from: CountKind, to: CountKind) -> Bool {
    from != to && from != .duration && to != .duration
}

/// The fields a kind switch writes.
struct CountKindSwitchPatch: Equatable {
    var maxCount: CountValue?
    var defaultLogAmount: CountValue?
}

/// - Returns: The patch, or nil when the switch is refused.
func planCountKindSwitch(
    maxCount: CountValue?,
    defaultLogAmount: CountValue?,
    from: CountKind,
    to: CountKind
) -> CountKindSwitchPatch? {
    guard canSwitchCountKind(from: from, to: to) else { return nil }
    func conv(_ v: CountValue) -> CountValue {
        isWholeCountKind(to) ? max(1, (quantizeCount(v) + 0.5).rounded(.down)) : quantizeCount(v)
    }
    return CountKindSwitchPatch(maxCount: maxCount.map(conv), defaultLogAmount: defaultLogAmount.map(conv))
}

/// - Returns: 1 for whole kinds, 0.1 for continuous.
func countTargetStep(_ kind: CountKind) -> CountValue { isWholeCountKind(kind) ? 1 : 0.1 }
```

- [ ] **Step 5: Run — expect PASS** (same command; trust per-test "passed" lines, not a trailing "TEST FAILED" — CLAUDE.md sharp edge).

- [ ] **Step 6: Commit**

```bash
git add apps/ios/OYBC/Helpers/CountValue.swift apps/ios/OYBCTests/CountValueVectorTests.swift apps/ios/OYBCTests/Fixtures/countValueVectors.json apps/ios/OYBC.xcodeproj/project.pbxproj
git commit -m "feat(ios): CountValue twin — CountKind, quantize, finalise, format, kind-switch plan"
```

---

### Task 3: Shared types + Zod — `countKind` and 2dp count fields

**Files:**
- Create: `packages/shared/src/validation/countValue.ts`
- Modify: `packages/shared/src/types/task.ts` (add `countKind`; fix "integer" doc comments on `maxCount`, `currentCount`, `baseline`, `defaultLogAmount`)
- Modify: `packages/shared/src/types/taskEvent.ts:34-37` (doc: "Signed, non-zero, 2dp-quantized delta")
- Modify: `packages/shared/src/validation/schemas.ts` (lines 188-190, 239, 255, 322, 368, 371, 431, 466, 486, 490, 504, 560, 573-580; add `countKind` to `CreateTaskInputSchema`, `UpdateTaskInputSchema` (line 298), `TaskSchema`)
- Modify: `packages/shared/src/validation/boardSource.ts:24`
- Test: `packages/shared/tests/validation/countKindSchemas.test.ts` (create)

**Interfaces:**
- Consumes: `isQuantizedCount`, `CountKind`, `resolveCountKind`, `isWholeCountKind` (Task 1).
- Produces: `CountKindSchema`, `positiveCount()`, `nonNegativeCount()`, `nonZeroCountDelta` predicate, `countFieldsMatchKind(task)` refine predicate; `Task.countKind?: CountKind`, `CreateTaskInput.countKind?`, `UpdateTaskInput.countKind?`.

- [ ] **Step 1: Write the failing test** `packages/shared/tests/validation/countKindSchemas.test.ts`. Copy the two fixture builders named in the comment below into the new file (test files don't export them).

```ts
import { TaskSchema, TaskEventSchema, CreateTaskInputSchema } from '../../src/validation/schemas';
import { BoardSourceMemberRuleSchema } from '../../src/validation/boardSource';

// Copy `baseRow` verbatim from tests/validation/defaultLogAmount.test.ts (a valid
// COUNTING TaskSchema row) and `validIncrement` from tests/validation/taskEventSchema.test.ts.
const baseCountingTask = () => ({ ...baseRow });
const baseIncrement = () => validIncrement();

describe('counter kinds — schemas', () => {
  it('accepts a continuous task with a fractional goal and count', () => {
    const r = TaskSchema.safeParse({ ...baseCountingTask(), countKind: 'continuous', maxCount: 26.2, currentCount: 3.1, defaultLogAmount: 3.1 });
    expect(r.success).toBe(true);
  });
  it('accepts a pre-feature task with no countKind', () => {
    expect(TaskSchema.safeParse({ ...baseCountingTask(), maxCount: 26 }).success).toBe(true);
  });
  it('rejects an unknown kind', () => {
    expect(TaskSchema.safeParse({ ...baseCountingTask(), countKind: 'weight' }).success).toBe(false);
  });
  it('rejects three decimal places', () => {
    expect(TaskSchema.safeParse({ ...baseCountingTask(), countKind: 'continuous', maxCount: 26.125 }).success).toBe(false);
  });
  it('rejects a fractional goal on a whole kind', () => {
    expect(TaskSchema.safeParse({ ...baseCountingTask(), maxCount: 26.2 }).success).toBe(false);
    expect(TaskSchema.safeParse({ ...baseCountingTask(), countKind: 'duration', maxCount: 90.5 }).success).toBe(false);
  });
  it('allows a fractional currentCount cache on a discrete task (switched history)', () => {
    expect(TaskSchema.safeParse({ ...baseCountingTask(), maxCount: 26, currentCount: 1.2 }).success).toBe(true);
  });
  it('accepts a fractional increment delta and rejects 3dp / zero', () => {
    expect(TaskEventSchema.safeParse({ ...baseIncrement(), delta: 3.1 }).success).toBe(true);
    expect(TaskEventSchema.safeParse({ ...baseIncrement(), delta: -0.25 }).success).toBe(true);
    expect(TaskEventSchema.safeParse({ ...baseIncrement(), delta: 3.125 }).success).toBe(false);
    expect(TaskEventSchema.safeParse({ ...baseIncrement(), delta: 0 }).success).toBe(false);
  });
  it('create input carries countKind', () => {
    const r = CreateTaskInputSchema.safeParse({ title: 'Run 26.2 miles', type: 'counting', action: 'Run', unit: 'miles', maxCount: 26.2, countKind: 'continuous' });
    expect(r.success).toBe(true);
    if (r.success) expect(r.data.countKind).toBe('continuous');
  });
  it('member-rule target accepts 2dp, rejects zero', () => {
    expect(BoardSourceMemberRuleSchema.safeParse({ target: 6.1 }).success).toBe(true);
    expect(BoardSourceMemberRuleSchema.safeParse({ target: 0 }).success).toBe(false);
  });
});
```

(Check the actual `TaskType.COUNTING` string value in `packages/shared/src/constants` and use it in the create-input test.)

- [ ] **Step 2: Run — expect FAIL.** `pnpm --filter @oybc/shared test -- countKindSchemas`

- [ ] **Step 3: Implement.** `packages/shared/src/validation/countValue.ts`:

```ts
import { z } from 'zod';
import { isQuantizedCount, isWholeCountKind, resolveCountKind, type CountKind } from '../algorithms/countValue';

/**
 * Zod pieces for counter kinds (docs/COUNTER_KINDS.md §3). Lives outside
 * schemas.ts (near its 1000-line cap) — the `boardSource.ts` precedent.
 */
export const CountKindSchema = z.enum(['discrete', 'continuous', 'duration']);

const QUANTIZED_MSG = 'must be a finite number with at most 2 decimal places';

/** A strictly positive 2dp counting value (goal, default log amount, target). */
export const positiveCount = () => z.number().positive().refine(isQuantizedCount, { message: QUANTIZED_MSG });

/** A non-negative 2dp counting value (count cache, baseline). */
export const nonNegativeCount = () => z.number().min(0).refine(isQuantizedCount, { message: QUANTIZED_MSG });

/** A valid increment delta: non-zero and 2dp. */
export const isValidCountDelta = (d: number): boolean => d !== 0 && isQuantizedCount(d);

/**
 * Whole kinds store whole goals / default amounts. `currentCount` is a cache
 * that may hold fractional history after a switch (D4), so it is not checked.
 */
export const countFieldsMatchKind = (t: {
  countKind?: CountKind | null;
  maxCount?: number | null;
  defaultLogAmount?: number | null;
}): boolean => {
  if (!isWholeCountKind(resolveCountKind(t))) return true;
  const whole = (v: number | null | undefined) => v == null || Number.isInteger(v);
  return whole(t.maxCount) && whole(t.defaultLogAmount);
};
```

In `schemas.ts`: import these; replace each `z.number().int().positive()` on `maxCount` (239, 368, 431) and `defaultLogAmount` (504) with `positiveCount()`; `baseline` `.int().min(0)` (255, 322, 371, 486) with `nonNegativeCount()`; `currentCount` (466) and `lastSyncedCount` (490) with `nonNegativeCount()`; `delta: z.number().int().optional()` (560) with `delta: z.number().optional()` and the refine at 573 with `return data.delta !== undefined && isValidCountDelta(data.delta);`; update its message to `"TaskEvent.delta must be a non-zero 2dp number when kind='increment', …"`. In `sharedCounterFieldsConsistent` (188-190) replace `!Number.isInteger(data.baseline)` with `!isQuantizedCount(data.baseline)`. Add `countKind: CountKindSchema.optional(),` beside `isCounter` in `CreateTaskInputSchema`, `UpdateTaskInputSchema` and `TaskSchema`, and append `.refine(countFieldsMatchKind, { message: 'Whole-number kinds need whole goals' })` to `CreateTaskInputSchema` and `TaskSchema`. **Leave `threshold`, `requiredCount`, `totalCompletions`, `totalInstances`, `version` integer** — they are not counting values.

In `types/task.ts`: `import type { CountKind } from '../algorithms/countValue';` and add to `Task`, `CreateTaskInput`, `UpdateTaskInput`:

```ts
  /**
   * Counter kinds (docs/COUNTER_KINDS.md). COUNTING only. Absent ⇒ 'discrete'
   * (every pre-feature row). 'continuous' holds 2dp values; 'duration' holds
   * whole minutes. Linked / minted copies carry the root's kind.
   */
  countKind?: CountKind;
```

In `boardSource.ts:24`: `const TargetSchema = positiveCount();` (import from `./countValue`).

- [ ] **Step 4: Run the full shared suite** — `pnpm --filter @oybc/shared test` — expect PASS, including every pre-existing schema test (integers are still valid). Then `pnpm --filter @oybc/shared build` (tsc) and `node scripts/check-file-sizes.mjs` (schemas.ts must stay ≤ 1000; if not, trim the replaced lines' now-stale comments, never bump).

- [ ] **Step 5: Commit**

```bash
git add packages/shared/src/validation packages/shared/src/types packages/shared/tests/validation/countKindSchemas.test.ts
git commit -m "feat(shared): Task.countKind + 2dp-quantized counting fields at the Zod boundary"
```

---

### Task 4: Title generation + web write-path guards

**Files:**
- Modify: `packages/shared/src/algorithms/taskTitle.ts:32` (drop `Math.floor`)
- Modify: `packages/shared/tests/fixtures/taskTitleVectors.json` (add fractional vectors; delete the `_note` sentence "iOS maxCount is Int, so no fractional-goal vectors")
- Modify: `packages/shared/tests/algorithms/taskTitle.test.ts` (any assertion pinning the floor)
- (iOS `TaskTitle.swift` + `TaskTitleVectorTests.swift` change in Task 6 — they can't compile against `Int?` model fields before then. Until Task 6 lands, the iOS `TaskTitleVectorTests` fails to decode the new fractional vectors; that is expected inside the PR and is closed by Task 6 Step 5.)
- Modify: `apps/web/src/db/operations/tasks.sharedCounter.ts:178,288,576`, `lateLog.ts:195,333`, `tasks.counter.ts:56`
- Test: `apps/web/src/db/operations/__tests__/countKindWritePaths.test.ts` (create), `__tests__/lateLog.test.ts` (extend)

**Interfaces:**
- Consumes: `quantizeCount`, `isQuantizedCount` (Task 1).
- Produces: `generateCounterTaskTitle(action, maxCount, unit, providedTitle?)` renders a 2dp goal trimmed, locale-independent ("Run 26.2 miles") — titles are stored data, so never the device locale.

- [ ] **Step 1: Add vectors** to `taskTitleVectors.json` → `generateCounterTaskTitle`: `{ "name": "fractional goal", "action": "Run", "maxCount": 26.2, "unit": "miles", "providedTitle": null, "expected": "Run 26.2 miles" }`, `{ "name": "whole goal stays whole", "action": "Read", "maxCount": 300, "unit": "pages", "providedTitle": null, "expected": "Read 300 pages" }`; → `isAutoCounterTitle`: `{ "name": "fractional auto title", "title": "Run 26.2 miles", "action": "Run", "maxCount": 26.2, "unit": "miles", "expected": true }`; → `counterCopyTitle`: `{ "name": "auto title regenerates fractional target", "member": { "title": "Run 26.2 miles", "action": "Run", "unit": "miles", "maxCount": 26.2 }, "newMaxCount": 6.1, "expected": "Run 6.1 miles" }`. Run `gen:sync-fixtures`.

- [ ] **Step 2: Write the failing web test** `countKindWritePaths.test.ts`. Copy the file preamble of `__tests__/lateLog.test.ts` (`fake-indexeddb/auto` import, `db` reset in `beforeEach`) and its `seedCountingTask(id, maxCount, over)` helper (line 84), then define `const seedCounter = (over: Partial<Task>) => seedCountingTask(crypto.randomUUID(), over.maxCount ?? 10, over);`:

```ts
it('incrementSharedCounter accepts a 2dp amount and writes a 2dp delta', async () => {
  const root = await seedCounter({ countKind: 'continuous', maxCount: 26.2 });
  await incrementSharedCounter(root.id, 3.1);
  const events = await db.taskEvents.where('taskId').equals(root.id).toArray();
  expect(events.map((e) => e.delta)).toEqual([3.1]);
});
it('incrementSharedCounter rejects a 3dp amount', async () => {
  const root = await seedCounter({ countKind: 'continuous', maxCount: 26.2 });
  await expect(incrementSharedCounter(root.id, 3.125)).rejects.toThrow(/2dp/);
});
it('setCounterDefaultLogAmount accepts 2dp', async () => {
  const root = await seedCounter({ countKind: 'continuous', maxCount: 26.2 });
  await setCounterDefaultLogAmount(root.id, 3.1);
  expect((await db.tasks.get(root.id))!.defaultLogAmount).toBe(3.1);
});
// The late-log case goes in the EXISTING __tests__/lateLog.test.ts (its seed helpers
// are file-local): duplicate the test that calls `lateLogIncrement(DAILY, TASK, 5, FRIDAY_NOW)`
// (~line 184), seed the task with `seedCountingTask(TASK, 26.2, { countKind: 'continuous' })`,
// call `lateLogIncrement(DAILY, TASK, 0.5, FRIDAY_NOW)`, and assert
// `(await eventsFor(TASK)).map((e) => e.delta)` contains `0.5`. Add a second duplicate
// asserting `lateLogIncrement(DAILY, TASK, 0.125, FRIDAY_NOW)` rejects.
```

- [ ] **Step 3: Run — expect FAIL.** `pnpm --filter @oybc/web exec vitest run src/db/operations/__tests__/countKindWritePaths.test.ts` and `pnpm --filter @oybc/shared test -- taskTitle`.

- [ ] **Step 4: Implement.**
  - `taskTitle.ts:32`: `return \`${action.trim()} ${String(quantizeCount(maxCount))} ${unit.trim()}\`;` (JS `String` is locale-free and trims zeros). Update the `@param maxCount` doc.
  - Web guards: replace `!Number.isInteger(x)` with `!isQuantizedCount(x)` and change messages from "positive integer" to "positive 2dp number" at `tasks.sharedCounter.ts:178,288,576`, `lateLog.ts:195,333`, `tasks.counter.ts:56`. Any `+`/`-` of counts in these files (`tasks.sharedCounter.ts:338,497-499`, `lateLog.ts:212,478`) wraps in `quantizeCount(...)`.
  - **Do not** change `parseCustomLogAmount` / any input parser — inputs stay integer until PR 3/4 (PR 1 is inert).

- [ ] **Step 5: Run — expect PASS**, then `pnpm --filter @oybc/web build` (Vitest doesn't typecheck) and `pnpm --filter @oybc/web lint`.

- [ ] **Step 6: Commit**

```bash
git add packages/shared apps/web/src/db/operations apps/ios/OYBCTests/Fixtures/taskTitleVectors.json
git commit -m "feat(counters): fractional goals in titles; web write paths accept 2dp amounts"
```

---

### Task 5: Web pull path — fractional rows + `countKind` round-trip

**Files:**
- Modify: `apps/web/src/db/operations/__tests__/pullApply.test.ts`, `__tests__/taskEventPull.test.ts` (add cases)
- Modify (only if a test fails): `apps/web/src/db/operations/pullApply.ts`, `taskEventPull.ts`, any web Firestore→local field mapper in `apps/web/src/firebase/syncService.ts` that lists Task fields explicitly (grep `defaultLogAmount` there — if Task fields are enumerated anywhere, add `countKind` beside it).

**Interfaces:**
- Consumes: Task 3 schemas.
- Produces: guarantee that a remote Task `{countKind:'continuous', maxCount: 26.2, currentCount: 3.1}` and a remote event `{delta: 3.1}` are applied, not skipped.

- [ ] **Step 1: Write failing/pinning tests.** In `pullApply.test.ts`, copy the nearest "applies a remote task" case and add one with `countKind: 'continuous', maxCount: 26.2, currentCount: 3.1` asserting the local row equals those values; add one with no `countKind` asserting the local row has `countKind === undefined`. In `taskEventPull.test.ts`, copy the "applies a remote increment" case with `delta: 3.1`.
- [ ] **Step 2: Run** `pnpm --filter @oybc/web exec vitest run src/db/operations/__tests__/pullApply.test.ts src/db/operations/__tests__/taskEventPull.test.ts`. Expected: PASS already if Task 3 is complete (the schemas are the only gate); a FAIL means an explicit field list exists — add `countKind` there and re-run.
- [ ] **Step 3: Grep the push side.** `grep -rn "defaultLogAmount" apps/web/src/firebase` — if a push serializer enumerates Task fields, add `countKind`; add a test beside its existing test.
- [ ] **Step 4: Commit** `git commit -m "test(web): pull path applies fractional counts and countKind"`

---

### Task 6: iOS model, migration v39, and the `Int` → `CountValue` ripple

This is the largest mechanical change. It cannot be split — the type change breaks compilation until every caller is converted.

**Files:**
- Modify: `apps/ios/OYBC/Database/Models/Task.swift` (`maxCount`, `currentCount`, `baseline`, `lastSyncedCount`, `defaultLogAmount` → `CountValue?`; add `var countKind: CountKind?`; CodingKeys, `init(from:)` `decodeIfPresent(CountValue.self, …)` and `decodeIfPresent(CountKind.self, forKey: .countKind)`, `encode(to:)` `encodeIfPresent(countKind, …)`, memberwise init param `countKind: CountKind? = nil`)
- Modify: `apps/ios/OYBC/Database/Models/TaskEvent.swift:38` (`delta: CountValue?`)
- Modify: `apps/ios/OYBC/Database/Models/BoardSource.swift:26,51` (`target: CountValue?`)
- Modify: `apps/ios/OYBC/Database/AppDatabase+Migrations.swift` (add v39)
- Modify: `apps/ios/OYBC/Helpers/TaskEvents.swift:21-24` (`TaskWindowState.count: CountValue`) and every helper the compiler flags — inventory below
- Modify: `apps/ios/OYBC/Helpers/TaskTitle.swift:25-27,74,100` (`maxCount: CountValue?`, `newMaxCount: CountValue`; render the goal with `formatCount(maxCount, kind: .continuous, locale: Locale(identifier: "en_US_POSIX"))` — 2dp, trimmed, `.` separator, never the device locale since titles are stored) and `apps/ios/OYBCTests/TaskTitleVectorTests.swift` (`Int?`/`Int` → `Double?`/`Double` in the three vector structs) — this turns Task 4's fractional title vectors green on iOS
- Test: `apps/ios/OYBCTests/CountKindModelTests.swift` (create)

**Interfaces:**
- Consumes: `CountValue`, `CountKind` (Task 2).
- Produces: every iOS counting value typed `CountValue`; `Task.countKind: CountKind?`; GRDB column `tasks.countKind TEXT`.

**Conversion rules (apply at every compiler error):**
1. A variable/parameter/property that holds a goal, count, delta, baseline, amount or member target becomes `CountValue` (`Int?` → `CountValue?`). Name stays the same.
2. Things that are NOT counting values stay `Int`: `threshold`, `requiredCount`, `totalCompletions`, `totalInstances`, `version`, row/col, slot indices, board sizes, source `min`/`max`, child counts, vary level.
3. Sums: `sum += e.delta ?? 0` stays; the final count goes through `finalizeWindowCount` only in PR 2 — **in PR 1 keep `max(0, sum)`** so behaviour is identical (all values are still integers).
4. Display: replace `"\(count)"` / `String(count)` / `.formatted()` of a counting value with `formatCount(count, kind: resolveCountKind(task.countKind))` when the task is in scope, else `formatCount(count, kind: .discrete)`. For integer inputs this prints exactly what it printed before — verify with the snapshot run in Step 6.
5. Input parsing (`Int(text)`) at UI boundaries stays integer-only (PR 1 is inert): wrap as `Int(text).map(CountValue.init)`.
6. A `[1, 10, 25]` preset array becomes `[CountValue]`; `ForEach` identity becomes `id: \.self` (Double is Hashable).
7. `Int(x)` casts of a counting value for maths (e.g. `Int(goal * ratio .rounded(.up))`) keep their rounding but return `CountValue` (`(goal * ratio).rounded(.up)`). Member-rule maths must stay integer-valued in PR 1 — vectors in `MemberRuleVectorTests` prove it.

**Ripple inventory** (from the 2026-10-06 scan; the compiler is the source of truth, this is the checklist):
- Helpers: `TaskEvents.swift` (`:23`, `:122-154`, `:277-285` `windowSum`, `:339`, `:391`), `SharedCounter.swift` (`:16,38-41,64-85,111-112`), `SharedCounterGroups.swift` (`:41-47,68,76,261-298`), `CounterMilestone.swift` (`:18-57`), `CounterDailyTotals.swift` (`:34,43,118`), `CounterArrivals.swift` (`:39,72,120-121`), `DeriveCounterLink.swift:17`, `LinkableCounter.swift:43,141`, `LinkedCounterWindowHeal.swift:272-275`, `BoardSourceMemberRules.swift` (`:150-156,188-192,211-215,379-381,469-487,758-776`), `BoardSourceMemberRulesDisplay.swift` (`:59-87,114-121,152,186,244-251,786`), `TaskCountDisplay.swift:35,61-65`, `CounterLogAmount.swift:14-32`, `TaskTitle.swift`.
- Database: `AppDatabase+TaskEvents.swift:45,73,389,419`, `AppDatabase+SharedCounters.swift:31,245,416,584,815`, `AppDatabase+BoardCompletion.swift:25,103`, `AppDatabase+LateLog.swift:219,385`, `AppDatabase+Counters.swift:42`, `AppDatabase+DerivedCounters.swift:239`, `AppDatabase+CompoundStructureEdit.swift:18,43`, `AppDatabase+TaskEditing.swift:238`.
- ViewModels/Views: `BoardPlayViewModel.swift:513,540,565,673,831,858,1068-1076`, `BoardPlayViewModel+LateLog.swift:67,130`, `BoardPlayView.swift:1244-1248,1376,1405-1415,1559,1656-1702`, `BoardPlayView+CountingStepper.swift:38-56`, `BoardPlayView+LateLog.swift:179`, `RisoCountingStepperSheet.swift:51,62-63,80,180,207-240,302,316-355`, `RisoBoardPlayCell.swift:37-38,158,251,338-370`, `LateLogSheetView.swift:42,54,159,165,177-185`, `CounterDetailView.swift`, `CountersHubView.swift:143-150`, `SharedCounterLedgerCard.swift:51,81,108,118,136,236`, `ProfileHomeViewModel.swift:120,150`, `NewCounterSheetView.swift:68-69,135,245,283`, `CounterLogToastView.swift:36`, `LinkedCounterCaptionView.swift:80,104`, `RisoCounterLinkHintView.swift:28,46`, `RisoSpecialTaskPanel.swift:225-226,653-657,833-920`, `RisoCompoundFieldsView.swift:216-217`, `RisoCompoundEditFieldsView.swift:108-109`, `RisoMemberRuleRowView.swift:38-72`, `BoardWizardViewModel+MemberRules.swift:148,174,266`, `RisoSourceRowView.swift:54,58`, `BoardWizardTasksStepView.swift:175,179`, `CreateFormViewModel.swift:132,282-283,322,492,783`, `TaskEditPatch.swift:105,151`, `SquareEditTaskSheet.swift:85,277,436-438,556`, `SquaresDraft.swift:76`, `BoardWizardPreviewDerived.swift`.

- [ ] **Step 1: Write the failing test** `apps/ios/OYBCTests/CountKindModelTests.swift`:

```swift
import XCTest
import GRDB
@testable import OYBC

final class CountKindModelTests: XCTestCase {
    /// Copy of `AppDatabaseCounterLogOpsTests.makeSourceTask` (it is private there),
    /// with its count params retyped to `CountValue` and `countKind: nil` appended.
    private func countingTask(id: String = UUID().uuidString) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: "u1", title: "Test Counter \(id)", description: nil, type: .counting,
            action: "Run", unit: "miles", maxCount: 20, operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil, requiredCount: nil,
            totalCompletions: 0, totalInstances: 0, isCompleted: false, completedAt: nil, currentCount: 0,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil, sharedCounterId: nil, baseline: nil,
            lastSyncedCount: nil, createdInWizard: false, isCounter: false, defaultLogAmount: nil,
            countKind: nil
        )
    }

    func testContinuousTaskRoundTripsThroughGRDB() throws {
        let db = try AppDatabase.makeTestInstance()
        var t = countingTask()
        t.countKind = .continuous
        t.maxCount = 26.2
        t.currentCount = 3.1
        t.defaultLogAmount = 3.1
        try db.write { try t.save($0) }
        let back = try db.read { try Task.fetchOne($0, key: t.id) }!
        XCTAssertEqual(back.countKind, .continuous)
        XCTAssertEqual(back.maxCount, 26.2)
        XCTAssertEqual(back.currentCount, 3.1)
    }

    func testPreFeatureRowDecodesAsDiscrete() throws {
        let db = try AppDatabase.makeTestInstance()
        let t = countingTask()
        try db.write { try t.save($0) }
        try db.write { try $0.execute(sql: "UPDATE tasks SET countKind = NULL WHERE id = ?", arguments: [t.id]) }
        let back = try db.read { try Task.fetchOne($0, key: t.id) }!
        XCTAssertNil(back.countKind)
        XCTAssertEqual(resolveCountKind(back.countKind), .discrete)
    }

    func testIntegerColumnStoresFractionalDelta() throws {
        // INTEGER affinity keeps 3.1 as REAL; decoding into CountValue? must succeed.
        let db = try AppDatabase.makeTestInstance()
        let t = countingTask()
        try db.write { try t.save($0) }
        try db.write {
            try $0.execute(sql: "UPDATE tasks SET maxCount = 26.2, currentCount = 3.1 WHERE id = ?", arguments: [t.id])
        }
        let back = try db.read { try Task.fetchOne($0, key: t.id) }!
        XCTAssertEqual(back.maxCount, 26.2)
        XCTAssertEqual(back.currentCount, 3.1)
    }

    func testPulledFirestoreDoubleDecodes() throws {
        // A Firestore number arrives as NSNumber(26.2). SyncService's raw upsert
        // skips the `as? Int` branch (Swift refuses a lossy NSNumber→Int bridge)
        // and binds it as a Double; the decode below is the same Codable path
        // `SyncService.applyPulledDocument` ends in (SyncWirePayloadTests precedent).
        var row = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(countingTask())) as! [String: Any]
        row["maxCount"] = NSNumber(value: 26.2)
        row["currentCount"] = NSNumber(value: 3.1)
        row["countKind"] = "continuous"
        let pulled = try JSONDecoder().decode(Task.self, from: JSONSerialization.data(withJSONObject: row))
        XCTAssertEqual(pulled.maxCount, 26.2)
        XCTAssertEqual(pulled.currentCount, 3.1)
        XCTAssertEqual(pulled.countKind, .continuous)
        XCTAssertNil(NSNumber(value: 3.1) as? Int, "the upsert's Int branch must not swallow a fractional value")
    }
}
```

Adjust the `Task(...)` argument list to the memberwise init's actual order if it differs (the compiler names the mismatch).

- [ ] **Step 2: Run — expect a compile FAIL** (`value of type 'Task' has no member 'countKind'`).

- [ ] **Step 3: Implement the model + migration.** Add to `AppDatabase+Migrations.swift` after v38:

```swift
        // Counter kinds (docs/COUNTER_KINDS.md §3). Nullable TEXT: every
        // pre-v39 row stays NULL and `Task.init(from:)` decodes it to nil
        // (resolved as `.discrete`). Count columns stay INTEGER — SQLite's
        // INTEGER affinity stores a non-integral REAL losslessly, so no rebuild.
        // Web: no Dexie bump (unindexed).
        migrator.registerMigration("v39") { db in
            try db.execute(sql: "ALTER TABLE tasks ADD COLUMN countKind TEXT")
        }
```

Then change the five `Task` fields, `TaskEvent.delta`, `BoardSource` `target` to `CountValue?` and add `countKind` (CodingKeys `case countKind`, decode, encode, memberwise init).

- [ ] **Step 4: Ripple.** Build (`xcodebuild … build-for-testing`) and convert every error per the conversion rules, working through the inventory. Repeat until it compiles. Then `grep -rn "maxCount: Int\|currentCount: Int\|delta: Int\|amount: Int\|baseline: Int\|target: Int" apps/ios/OYBC` must return nothing that is a counting value.

- [ ] **Step 5: Run the logic suite** — `xcodebuild … test -only-testing:OYBCTests` — expect all green, including every `*VectorTests` (vectors are integer, so decoding them into `Double` must not change a single result). Fix vector-test decoding structs (`Int?` → `Double?`) where the compiler or a decode error demands.

- [ ] **Step 6: Run snapshots** on the pinned runtime and diff the **set** of failures against `dev`:

```bash
xcodebuild … -scheme OYBCSnapshotTests test > /tmp/ck-snap.log 2>&1
grep "' failed (" /tmp/ck-snap.log | sed -E "s/.*\.([A-Za-z]+ test[A-Za-z0-9_]+)\]' failed.*/\1/" | sort -u
```

Expected: exactly the standing reds listed in CLAUDE.md (CountersHub ×4, RisoDeleteConfirm ×2, RisoTasksTab ×2, calendar-dependent RisoEditBoard pair). Any new red means a display site changed output — fix it, don't re-record.

- [ ] **Step 7: Commit** — `git status` first; revert `project.pbxproj` churn if `xcodegen` ran without new files.

```bash
git add apps/ios
git commit -m "feat(ios): CountValue counting fields, Task.countKind, GRDB v39 (inert)"
```

**PR 1 checkpoint:** push, open PR "Counter kinds PR 1 — foundation (inert)", run the self-review (reviewer agent) per `feedback_self_review_prs`, then merge per the standing authorization. Before opening: `pnpm -w test`, `pnpm --filter @oybc/web build`, `pnpm --filter @oybc/web lint`, `node scripts/check-file-sizes.mjs`, `node scripts/check-knip.mjs`.

---

# PR 2 — Logic

### Task 7: Window kernels finalise by kind (TS + Swift)

**Files:**
- Modify: `packages/shared/src/algorithms/taskEvents.ts` (`resolveTaskWindowState` ~141-151, `resolveWindowStampedDerivedState` 243-256, `resolveDerivedCounterWindowState` ~306, `resolveLinkedCounterDisplay` ~359)
- Modify: `packages/shared/src/algorithms/sharedCounter.ts:52-67` (`deriveDisplayedCount`), `:147` (`propagateIncrement`)
- Modify: `apps/ios/OYBC/Helpers/TaskEvents.swift` (twins), `apps/ios/OYBC/Helpers/SharedCounter.swift`, `apps/ios/OYBC/Database/AppDatabase+TaskEvents.swift:45,73` (completion checks)
- Modify: `packages/shared/tests/fixtures/taskWindowStateVectors.json`, `sharedCounterVectors.json`; their TS tests + `TaskEventVectorTests.swift`, `SharedCounterVectorTests.swift` (decode a new optional `countKind` on the task shape)
- Modify (added after PR 1's final review, ruling R12): `apps/ios/OYBC/Database/AppDatabase+SharedCounters.swift` (increment / decrement / undo cache sums ~:294, :488, :688; `setCounterDefaultLogAmount` guard) and `apps/ios/OYBC/Database/AppDatabase+LateLog.swift` (~:219 guard, ~:385 sum) — the iOS twins of web's PR 1 write-path changes: every guard becomes `isQuantizedCount(x) && x > 0` (throw/return exactly as the existing guard does), every cache sum/difference is wrapped in `quantizeCount`
- Test (R12): an iOS test against `AppDatabase.makeTestInstance()` beside `AppDatabaseCounterLogOpsTests.swift` — incrementing a continuous counter by 0.1 then 0.2 stores `currentCount == 0.3` exactly, and an increment of 0.125 is rejected
- Modify: `scripts/audit/file-size-allowlist.json` — lower `BoardPlayView.swift`'s cap to its current line count (it shrank in PR 1; the guardrail prints the stale note)

**Interfaces:**
- Consumes: `finalizeWindowCount`, `resolveCountKind` (Tasks 1/2).
- Produces: `resolveWindowStampedDerivedState(task: { startDate?, endDate?, maxCount?, countKind? }, rootEvents)`; `deriveDisplayedCount(derivedTask: { baseline?, maxCount?, countKind? }, source)` — every count these return is finalised; completion is `count >= maxCount` on finalised values.

- [ ] **Step 1: Add vectors.** In `taskWindowStateVectors.json` add (task shape gains optional `countKind`; mirror the existing case structure exactly):
  - `continuous-drift-completes`: task `{type:"counting", maxCount:0.3, countKind:"continuous"}`, increments 0.1 and 0.2 in window → `{isCompleted:true, count:0.3}`.
  - `continuous-fractional-sum`: maxCount 26.2, increments 3.1, 5, 0.25 → `{isCompleted:false, count:8.35}`.
  - `discrete-fractional-history-rounds`: maxCount 1, no countKind, increments 0.4 ×3 → `{isCompleted:true, count:1}`.
  - `continuous-same-history-exact`: same events, countKind continuous, maxCount 1 → `{isCompleted:true, count:1.2}`.
  - `continuous-overshoot-preserved`: maxCount 26.2, increment 28.4 → `{isCompleted:true, count:28.4}`.
  In `sharedCounterVectors.json` add a derived-display case: derived `{baseline:1.5, maxCount:6.1, countKind:"continuous"}`, source `{currentCount:7.6}` → `{displayed:6.1, isCompleted:true}`.
  Run `gen:sync-fixtures`.
- [ ] **Step 2: Run both suites — expect FAIL** on the new cases (`count` 0.30000000000000004 / 1.2).
- [ ] **Step 3: Implement (TS).** In `resolveTaskWindowState` replace `const count = Math.max(0, sum);` with `const count = finalizeWindowCount(sum, resolveCountKind(task));`. In `resolveWindowStampedDerivedState` widen the param to `{ startDate?: string | null; endDate?: string | null; maxCount?: number | null; countKind?: CountKind | null }` and finalise the same way; in `resolveDerivedCounterWindowState` and `resolveLinkedCounterDisplay` pass `countKind: task.countKind` in the synthesized object literals. In `deriveDisplayedCount`: `const displayed = finalizeWindowCount(sourceCount - baseline, resolveCountKind(derivedTask));`. In `propagateIncrement` wrap the new count in `quantizeCount`.
- [ ] **Step 4: Implement (Swift)** identically: `let count = finalizeWindowCount(sum, kind: resolveCountKind(task.countKind))`; `windowStampedDerivedState` gains `countKind: CountKind?`; every caller passes `task.countKind`; `isCompleted = task.maxCount.map { count >= $0 } ?? false` (removes the force-unwrap). Same for `AppDatabase+TaskEvents.swift:45,73`.
- [ ] **Step 5: Run** `pnpm --filter @oybc/shared test` and `xcodebuild … test -only-testing:OYBCTests` — expect PASS everywhere (integer cases unchanged).
- [ ] **Step 6: Commit** `git commit -m "feat(counters): window kernels finalise counts by kind (2dp, whole kinds round the sum)"`

---

### Task 8: Counter aggregators — groups, totals, milestones, arrivals, baselines, heal (TS + Swift)

**Files:**
- Modify: `packages/shared/src/algorithms/sharedCounterGroups.ts`, `counterDailyTotals.ts`, `counterMilestone.ts:39`, `counterArrivals.ts`, `memberRules.ts:728-743` (`computeWindowBaseline`), `linkedCounterWindowHeal.ts:368,377`
- Modify Swift twins: `SharedCounterGroups.swift`, `CounterDailyTotals.swift`, `CounterMilestone.swift`, `CounterArrivals.swift`, `BoardSourceMemberRules.swift:758-776`, `LinkedCounterWindowHeal.swift:272-275`
- Modify vectors: `sharedCounterGroupsVectors.json`, `counterArrivalsVectors.json`, `linkedCounterWindowHealVectors.json` (+ tests that decode them)
- Modify: `memberRules.ts` (`PlanTask` 270-273, `DerivedTaskDraft` 276-294, `mint` ~495) + Swift twin — the `countKind` field only
- Modify: every `DerivedTaskDraft` → Task persist site: `apps/web/src/db/operations/derivedCounters.ts`, `linkedCounterPlacement.ts`, `linkedCounterWindowHeal.ts`; `apps/ios/OYBC/Database/AppDatabase+DerivedCounters.swift`, `+LinkedCounterWindowHeal.swift`, `+SharedCounters.swift`, `+Tasks.swift`, `+LateLog.swift`, `Views/CreateTab/BoardWizardPreviewDerived.swift` (grep `rootTaskId` — one `countKind: d.countKind` line each)

**Interfaces:**
- Consumes: `quantizeCount`, `finalizeWindowCount`, `resolveCountKind`.
- Produces: every aggregate is `quantizeCount`-ed after summing (logged / lifetime / over / daily total / baseline); **`DerivedTaskDraft` gains `countKind: CountKind`** (`memberRules.ts` + Swift twin) — set by `windowStampedCopyDraft` from `resolveCountKind(sourceTask)` and, in this task, by `planDerivedTasks`' `mint` as `countKind: resolveCountKind(t)` (`PlanTask` gains `'countKind'`); every draft → Task persist site writes it. `windowStampedCopyDraft` keeps a continuous goal verbatim (`quantizeCount`) and floors only for whole kinds; `baseline = Math.max(0, quantizeCount(baseline))`; `sourceTask` Pick gains `'countKind'`.

- [ ] **Step 1: Add vectors**: `sharedCounterGroups` — a continuous family whose events are 0.1 + 0.2 → `logged: 0.3`; `linkedCounterWindowHeal` — `windowStampedCopyDraft` of a continuous source with `maxCount: 26.2`, baseline `3.1` → draft `maxCount: 26.2, baseline: 3.1, countKind: "continuous", title: "Run 26.2 miles"`; a discrete source keeps today's floor. `counterArrivals` — a fractional total crossing a milestone. Run `gen:sync-fixtures`.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** in both languages: wrap every sum/difference result in `quantizeCount`; replace the two `Math.floor`s in `windowStampedCopyDraft` with `isWholeCountKind(kind) ? Math.floor(x) : quantizeCount(x)` where `kind = resolveCountKind(sourceTask)`; `counterMilestone` steps stay integer (milestones are whole numbers of the unit) but compare against a quantized lifetime.
- [ ] **Step 4: Persist test.** One web test in the existing `derivedCounters` test file and one iOS test beside `AppDatabase+DerivedCounters` tests: a minted copy of a continuous member stores `countKind == 'continuous'`; a heal copy of a continuous hub-linked row stores it too.
- [ ] **Step 5: Run** shared, web (`vitest run`, `build`, `lint`), iOS logic suite — expect PASS.
- [ ] **Step 6: Commit** `git commit -m "feat(counters): aggregates quantize; derived drafts carry countKind; continuous copies keep fractional goals"`

---

### Task 9: Member rules — continuous branch (TS + Swift)

**Files:**
- Modify: `packages/shared/src/algorithms/memberRules.ts` (`autoTarget` 147-152, `varyRange` 172-179, `rollTarget` 193-197, `goalOf` 394-396, `resolveTarget` 485-492, `mint` ~495)
- Modify: `packages/shared/src/algorithms/memberRulesDisplay.ts` (`effectiveMemberTarget` ~80, `varyRangeLabel` 108-112, `remainingTarget` 321-322, `prefilledOneOffTarget` ~358, `countingSummary` 415-423, seeded targets ~505)
- Modify Swift twins: `BoardSourceMemberRules.swift`, `BoardSourceMemberRulesDisplay.swift`
- Modify: `apps/web/src/pages/createHub/wizardMemberRulesLogic.ts:364-370`, `apps/ios/OYBC/Views/CreateTab/ViewModels/BoardWizardViewModel+MemberRules.swift:148` (`goal >= 1` gates → `goal > 0`)
- Modify vectors: `memberRuleVectors.json` (+ `MemberRuleVectorTests.swift` decode `countKind`)

**Interfaces:**
- Consumes: `countTargetStep`, `quantizeCount`, `resolveCountKind`, `isWholeCountKind`.
- Produces (signatures — every new param is LAST and defaults to `'discrete'` so existing callers/vectors are untouched):
  - `autoTarget(goal, sourceDays, targetDays, kind: CountKind = 'discrete'): number`
  - `varyRange(t, level, goal, kind: CountKind = 'discrete'): [number, number]`
  - `rollTarget(t, level, goal, rng, kind: CountKind = 'discrete'): number`
  - Consumes `PlanTask.countKind` / `DerivedTaskDraft.countKind` from Task 8.
  - Swift: same, `kind: CountKind = .discrete` last.

**Maths (put the step helpers in `countValue.ts` / `CountValue.swift` to protect the 1000-line cap):**

```ts
// countValue.ts additions. Whole kinds take the EXACT pre-feature integer ops
// (no quantize first — 1/366 must still ceil to 1); only continuous steps in
// tenths, quantizing the tenths count so 6.1/0.1 = 60.999… reads as 61.
// Inputs are non-negative (targets, goals).
/** Ceil to the kind's step. */
export function ceilToCountStep(x: number, kind: CountKind): number {
  if (isWholeCountKind(kind)) return Math.ceil(x);
  return quantizeCount(Math.ceil(quantizeCount(x * 10) - 1e-9) / 10);
}
/** Round half-up to the kind's step. */
export function roundToCountStep(x: number, kind: CountKind): number {
  if (isWholeCountKind(kind)) return Math.round(x);
  return quantizeCount(Math.round(quantizeCount(x * 10) + 1e-9) / 10);
}
/** Floor to the kind's step. */
export function floorToCountStep(x: number, kind: CountKind): number {
  if (isWholeCountKind(kind)) return Math.floor(x);
  return quantizeCount(Math.floor(quantizeCount(x * 10) + 1e-9) / 10);
}
```

(Whole kinds call `Math.ceil` / `Math.round` / `Math.floor` directly — the existing discrete vectors must not move. Add vectors for each helper to `countValueVectors.json`: `ceil(6.04, continuous) = 6.1`, `ceil(6.1, continuous) = 6.1`, `round(4.25, continuous) = 4.3`, `floor(26.29, continuous) = 26.2`, and the integer equivalents.)

In `memberRules.ts`:
- `autoTarget`: last line → `return Math.min(goal, ceilToCountStep((goal * targetDays) / sourceDays, kind));`
- `varyRange`: `const step = countTargetStep(kind); const tc = Math.min(Math.max(step, t), goal); … const lo = Math.max(step, roundToCountStep(tc * (1 - p), kind)); return [lo, Math.max(lo, roundToCountStep(tc * (1 + p), kind))];`
- `rollTarget`: `const step = countTargetStep(kind); const n = Math.round((hi - lo) / step); return quantizeCount(lo + Math.floor(rng() * (n + 1)) * step);` — still one rng sample, none when degenerate.
- `goalOf`: `typeof t.maxCount === 'number' && t.maxCount > 0 ? (isWholeCountKind(resolveCountKind(t)) ? Math.floor(t.maxCount) : t.maxCount) : null` — **keep `>= 1` for whole kinds** (`isWhole ? t.maxCount >= 1 : t.maxCount > 0`) so discrete behaviour is identical.
- `resolveTarget`: `return Math.min(Math.max(countTargetStep(kind), floorToCountStep(base, kind)), goal);` with `kind = resolveCountKind(t)` threaded from the member.
- `mint`: `rollTarget(target, vary, goal, rng, kind)` with `kind = resolveCountKind(t)` (the draft's `countKind` is already set by Task 8); title via `counterCopyTitle` (fractional-safe after Task 4).
- `computeWindowBaseline` (from Task 8) unchanged here.

In `memberRulesDisplay.ts`: thread the kind the same way; `remainingTarget(goal, windowCount)` → `Math.max(1, goal - windowCount)` stays (window counts are integers — it counts windows, not amounts) but the result for a continuous goal is `quantizeCount`-ed; `varyRangeLabel` renders bounds with `formatCount(lo, kind)` / `formatCount(hi, kind)`; `countingSummary` likewise.

- [ ] **Step 1: Add vectors** to `memberRuleVectors.json`, reusing the shape of the nearest existing case for each function and adding `"countKind": "continuous"` on the member: `autoTarget` goal 26.2 monthly→weekly-ish (sourceDays 30, targetDays 7) → `6.2` (26.2·7/30 = 6.113… → ceil to 0.1 = 6.2); `varyRange` t 10.0 level 1 goal 26.2 → `[8, 12]`; t 6.1 level 1 → `[4.9, 7.3]`; `rollTarget` seeded with the existing seed fixture, t 6.1 level 1 → record the TS output, then assert Swift equals it; `planDerivedTasks` with one continuous member pulled from a monthly board onto a weekly → one draft `maxCount 6.2, countKind "continuous", title "Run 6.2 miles"`. Also one **duration** member (goal 600 minutes, 30→7 days) → `140` (600·7/30 = 140) to pin that duration rides the discrete branch. Run `gen:sync-fixtures`.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement TS**, then **Swift** (`ceilToCountStep` etc. in `CountValue.swift`, same arithmetic; `rollTarget` must compute `n` and the index exactly as TS — `Int((rng() * Double(n + 1)).rounded(.down))`).
- [ ] **Step 4: Persist check.** Extend Task 8's persist tests: the minted copy of the continuous member also stores `maxCount == 6.2`.
- [ ] **Step 5: Run** shared, web (`vitest run` + `build` + `lint`), iOS logic suite — expect PASS; `node scripts/check-file-sizes.mjs` — `memberRules.ts` / `BoardSourceMemberRules.swift` ≤ 1000 (move doc text into `countValue` docs if tight).
- [ ] **Step 6: Commit** `git commit -m "feat(member-rules): continuous counters pro-rate, vary and roll in 0.1 steps; copies carry countKind"`

---

### Task 10: Kind switch — task edit + family cascade (web + iOS)

**Files:**
- Create: `apps/web/src/db/operations/countKindSwitch.ts`
- Create: `apps/web/src/db/operations/__tests__/countKindSwitch.test.ts`
- Create: `apps/ios/OYBC/Database/AppDatabase+CountKindSwitch.swift`
- Create: `apps/ios/OYBCTests/AppDatabaseCountKindSwitchTests.swift`
- Modify: every non-draft placement / derive mint path that copies counting fields from a source to a new linked Task so it also copies `countKind`: web `components/wizard/deriveCounterLink.ts:47` + its persist op, `addBoardTaskToBoard` / `updateBoardTaskAndCascade` linked-copy branches; iOS `DeriveCounterLink.swift`, `LinkableCounter.swift`, `AppDatabase+SharedCounters.swift` link creation (grep `sharedCounterId:` assignments in both apps' `db`/`Database` dirs for every place a linked Task is constructed)

**Interfaces:**
- Consumes: `planCountKindSwitch`, `canSwitchCountKind`, `resolveCountKind`, `isFrozenDerivedRow(t, now)` (`memberRules.ts:795` / Swift twin), `updateTaskAndCascade` (`tasks.crud.ts:485`), iOS `applyTaskEditPatch` neighbourhood (`AppDatabase+TaskEditing.swift:98`) for the write+cascade pattern.
- Produces:
  - web `switchCounterKind(rootTaskId: string, to: CountKind, now?: Date): Promise<void>` — throws `CountKindSwitchError` (`'not-a-root' | 'refused' | 'not-counting'`).
  - iOS `func switchCounterKind(rootTaskId: String, to: CountKind, now: Date = Date()) throws` on `AppDatabase`, throwing `CountKindSwitchError`.
  - PR 3 wires the UI to these; nothing calls them in PR 2 except tests.

**Behaviour (both platforms, ONE transaction):**
1. Load the root; reject if not COUNTING (`not-counting`), or `sharedCounterId != null` (`not-a-root` — linked rows never switch on their own, brief constraint 6).
2. `plan = planCountKindSwitch(root, from, to)`; `null` ⇒ `refused`.
3. Write the root: `countKind = to`, plus `plan` fields; version bump + sync enqueue (the `updateTask` path).
4. For every non-deleted task with `sharedCounterId == root.id`: skip if `isFrozenDerivedRow(row, now)` (Review Focus #3 — ended windows are permanent records); else write `countKind = to` plus `planCountKindSwitch(row, from, to)` fields, version bump + enqueue.
5. Run the board cascade for the root and every written row (`runBoardCascadeForTask` per id on web inside the same `db.transaction('rw', [boards, boardTasks, tasks, compoundChildren, taskEvents, syncQueue])`; iOS the cascade helper `applyTaskEditPatch` calls, threaded with the same `db`).
6. Never touch `task_events`.

- [ ] **Step 1: Write failing tests (web)** in `countKindSwitch.test.ts` (setup copied from `sharedCounterPropagationFreeze.test.ts`, which already seeds a root, a live derived row and an ended derived row):

```ts
it('continuous → discrete rounds root and live family, events untouched', async () => {
  const { root, liveRow, endedRow } = await seedFamily({ countKind: 'continuous', rootGoal: 26.2, liveTarget: 6.1, endedTarget: 6.4, deltas: [0.4, 0.4, 0.4] });
  const before = await db.taskEvents.toArray();
  await switchCounterKind(root.id, 'discrete', NOW);
  expect(await db.tasks.get(root.id)).toMatchObject({ countKind: 'discrete', maxCount: 26 });
  expect(await db.tasks.get(liveRow.id)).toMatchObject({ countKind: 'discrete', maxCount: 6 });
  expect(await db.tasks.get(endedRow.id)).toMatchObject({ countKind: 'continuous', maxCount: 6.4 });
  expect(await db.taskEvents.toArray()).toEqual(before);
});
it('round trip restores the exact window count', async () => {
  const { root, liveRow } = await seedFamily({ countKind: 'continuous', rootGoal: 26.2, liveTarget: 6.1, deltas: [0.4, 0.4, 0.4] });
  await switchCounterKind(root.id, 'discrete', NOW);
  expect(await displayedCountFor(liveRow.id)).toBe(1);
  await switchCounterKind(root.id, 'continuous', NOW);
  expect(await displayedCountFor(liveRow.id)).toBe(1.2);
});
it('refuses duration in either direction and linked rows', async () => {
  const { root, liveRow } = await seedFamily({ countKind: 'discrete', rootGoal: 30 });
  await expect(switchCounterKind(root.id, 'duration', NOW)).rejects.toMatchObject({ code: 'refused' });
  await expect(switchCounterKind(liveRow.id, 'continuous', NOW)).rejects.toMatchObject({ code: 'not-a-root' });
});
it('enqueues one sync item per written task', async () => { /* assert syncQueue rows for root + liveRow only */ });
```

`seedFamily` and `displayedCountFor` are local helpers built from the copied setup (`displayedCountFor` = `resolveLinkedCounterDisplay(row, eventsByTaskId, null, boardWindow).displayed` using the row's placing board).

- [ ] **Step 2: Mirror the four tests in Swift** (`AppDatabaseCountKindSwitchTests.swift`, against `AppDatabase.makeTestInstance()`, setup copied from `SharedCounterWindowRegressionTests.swift`).
- [ ] **Step 3: Run — expect FAIL** (missing function).
- [ ] **Step 4: Implement** both per the behaviour list.
- [ ] **Step 5: Copy `countKind` on every linked-Task construction site** found by the grep in Files; add one assertion per platform that linking a new square to a continuous root yields a continuous linked row.
- [ ] **Step 6: Run** web (`vitest run`, `build`, `lint`), shared, iOS logic suite — expect PASS.
- [ ] **Step 7: Commit** `git commit -m "feat(counters): switchCounterKind — Discrete ⇄ Continuous with family cascade; frozen windows keep their kind"`

**PR 2 checkpoint:** push, open PR "Counter kinds PR 2 — logic", self-review, run the full verification list from the PR 1 checkpoint, merge. Update `docs/COUNTER_KINDS.md` §Status ("PR 1 #…, PR 2 #… shipped; UI pending design") and `docs/TASK_SYSTEM.md`'s counting section with one paragraph + link, in the PR 2 branch.

---

## After PR 2

PR 1 #551 and PR 2 #552 shipped (data + logic).

PRs 3 (authoring UI) and 4 (logging + display UI) are planned separately once the Claude Design handoff for `docs/design/counter-kinds/BRIEF.md` is approved. They consume: `formatCount`, `switchCounterKind`, `canSwitchCountKind`, `COUNT_KINDS`, and replace the integer-only parsers (`parseCustomLogAmount`, `CounterLogAmount.parseCustom`, `RisoNumberField` `.numberPad`, `parsePositiveGoal`, the `parseInt` Goal parsers) with kind-aware ones.
