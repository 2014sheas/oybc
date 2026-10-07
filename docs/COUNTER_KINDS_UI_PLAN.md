# Counter Kinds — PR 3 (Authoring UI) + PR 4 (Logging + Display UI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a person choose a counter's kind (Discrete / Continuous / Duration), enter decimal and h:m goals, switch Discrete ⇄ Continuous, and log / read Continuous and Duration counts on every surface, on web and iOS together.

**Architecture:** Two shared pure modules carry every rule a surface needs — `countEntry.ts` ↔ `CountEntry.swift` (PR 3: input parsing, duration fields, picker lock state, unit suffix, family-kind resolution) and `logAmounts.ts` ↔ `CounterLogAmount.swift` (PR 4: chip sets, initial selection, pill / menu / toast labels) — pinned by JSON vectors. Two reusable components per platform (`KindPicker`, `GoalEntry`) are dropped into the six Goal surfaces and the four logging surfaces; no surface carries its own parser, chip set or formatter. Kind switches always go through the shipped `switchCounterKind` (now also callable inside a caller's transaction) so staged surfaces apply them atomically at Save.

**Tech Stack:** TypeScript + Zod + Jest (`packages/shared`), React 18 + Dexie + Vitest (`environment: 'node'`, `renderToStaticMarkup`) + Playwright (`apps/web`), SwiftUI + GRDB + XCTest + swift-snapshot-testing (`apps/ios`), XcodeGen.

**Spec:** [`docs/COUNTER_KINDS.md`](COUNTER_KINDS.md) — §2 (D1–D7) and §5 (the decided interface) are binding. Design source: `design_handoff_counter_kinds/` (gitignored; `Counter Kinds.dc.html` + the component files). The handoff is design data; where it disagrees with §5's owner overrides, §5 wins.

## Global Constraints

Binding values (verbatim from the spec / owner rulings — every task's requirements include these):

- On-screen kind labels: **Discrete / Continuous / Duration**, in that order. Never "Amount" as a kind label (it stays the custom-amount field placeholder).
- Kinds in code: `'discrete' | 'continuous' | 'duration'` (`CountKind`); absent `countKind` ⇒ `'discrete'`.
- Precision: counts quantize to **2 decimal places**; display trims trailing zeros; locale decimal separator; **Latin digits only** (R10) — parsers accept ASCII digits and `.` or `,` as the decimal separator, nothing else.
- Duration is **integer minutes**; display `Xh Ym` with zero parts dropped (`4h 30m`, `10h`, `45m`, `0m`). **Duration steps are 1 minute everywhere** — goals, wizard target steppers, ¼ / ½ chip amounts, vary ranges (owner override; the handoff's 15m / 5m steps and 5-minute quarters are rejected).
- Continuous steps: **0.1** for member-rule targets, vary ranges and ¼ / ½ chip amounts; goals and custom amounts accept up to 2 dp.
- Chips **with a goal** (board sheet, late log, Continuous / Duration only): **¼ · ½ · goal · #** — Continuous ¼ / ½ round to 0.1, Duration to 1 minute, each floored at one step; the goal chip is the goal itself (never re-stepped).
- Chips **without a goal** (Counters hub, Counter Detail): **Discrete 1 · 10 · 25 · #**, **Continuous 0.5 · 1 · 5 · #**, **Duration 15m · 30m · 1h · #**.
- Discrete keeps today's presets verbatim: board sheet `+1 · +10 · #` (shared squares only; standalone discrete squares keep the plain −/+ stepper), late log `+1 · +2 · +5 · Custom…`.
- Last-used amount (`defaultLogAmount`) pre-selects when it matches a chip, else `#` shows it (Continuous / Duration). Discrete keeps `initialChipAmount` (preset match, else 1). Only an explicitly entered custom amount persists as the new default.
- Square tap opens the stepper sheet **on both platforms** for every counting square; **web Discrete loses its +1 tap** (the right-click menu keeps "+ Add 1").
- Continuous / Duration sheet: amount field pinned open, chips set it, the pad / wheel edits it, − and + apply it, **no OK button**.
- "+ Log" pills: Continuous / Duration read `+ Log {amount}` ("+ Log 3.1", "+ Log 30m"); with no default yet, `+ Log` and it opens Counter Detail. Discrete unchanged (`+ Log`, logs `defaultLogAmount ?? 1`).
- Long-press / right-click (Continuous / Duration): `+ Add {last} {unit}`, `# Custom amount…` (opens the sheet), `− Remove {last} {unit}`; `{last}` = `defaultLogAmount ?? first chip`. Discrete menus unchanged.
- Kind switch: only **Continuous → Discrete** confirms. Title `Switch to Discrete?`; rows `{title} → {rounded title}` and `{logged} logged → {rounded} logged`; body `Switching back restores the exact values.` + (`Follows on {n} linked squares.` / `Follows on 1 linked square.` only when n > 0); buttons `Cancel` / `Switch`. Discrete → Continuous switches silently. Duration never switches (D4).
- Kind picker states: create = none locked; existing Discrete/Continuous = Duration locked; existing Duration = all locked, lock glyph on the selected segment; locked segments 45% opacity, not hit-testable. Linked rows (and auto-linking creates) show a kind tag, never a picker.
- Duration hides the Unit field; a Duration title is `{Action} {Xh Ym}` ("Practice 10h 30m").
- Board cells: bar text tiers **`cur/max` → `cur` → fill only**; the `×goal` tag always shows the goal; overshoot shows the real value with a **gold** bar fill; never clamp.
- Vary range: both ends at the more precise end's precision for Continuous ("21.0–31.4 miles"); Duration ranges are whole minutes ("8h 24m–12h 36m").
- Lifetime totals keep thousands grouping (`formatCountTotal`, R7): "1,240", "148.6", "112h 15m".
- **No explanatory copy** (CLAUDE.md, owner rule 2026-09-30/10-06): no helper lines, tips, provenance captions. Every task that touches a surface carrying a #548 caption removes it on both platforms (rows listed per task) and updates the snapshot / e2e that pinned it. Kept on purpose: validation errors, loading/error states, the switch-confirm consequence body, empty-state one-liners.
- Rule 6: every task that touches a twin lands web + iOS in the same commit.
- Reuse the Riso kit (`RisoSegmented`, `RisoNumberField`, `RisoChip`, `RisoButton`, `RisoSectionLabel`) — extend, never fork. Tokens only; no new colours (gold = `--riso-gold` / `Color.risoGold`, on gold use `--riso-ink-static` / `Color.risoInkStatic`).
- File-size guardrail (`node scripts/check-file-sizes.mjs`): no source file > 1000 lines; allowlisted files may not grow (`BoardPlayView.swift` 1996, `BoardPlayViewModel.swift` 1518, `BoardPlaySurface.tsx` 1241, `CounterDetailView.swift` 1009). Never bump a cap; extract helpers instead. Shrink an allowlist entry when a task shrinks the file.
- iOS: `_Concurrency.Task { }` for async closures; run `xcodegen generate` in `apps/ios` after adding a `.swift` file; never drive the simulator.
- Vector fixtures: edit under `packages/shared/tests/fixtures/`, then `pnpm --filter @oybc/shared run gen:sync-fixtures` and commit the iOS copy in the same task.

### Commands used below

- `SHARED_TEST` = `pnpm --filter @oybc/shared test --`
- `WEB_TEST` = `pnpm --filter @oybc/web test --`
- `WEB_CHECK` = `pnpm --filter @oybc/web build && pnpm --filter @oybc/web lint` (Vitest does not typecheck; `build` runs both `tsc` passes)
- `WEB_E2E` = `pnpm --filter @oybc/web exec playwright test` (webServer auto-boots vite; e2e is advisory in CI but must pass locally)
- `IOS_TEST` = `cd apps/ios && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project OYBC.xcodeproj -scheme OYBC -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.3.1' -derivedDataPath /Volumes/Stephen/oybc-derived test`
- `IOS_SNAP` = `cd apps/ios && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project OYBC.xcodeproj -scheme OYBCSnapshotTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.3.1' -derivedDataPath /Volumes/Stephen/oybc-derived test`
- Snapshot re-record = delete the named `apps/ios/OYBCSnapshotTests/__Snapshots__/<Class>/<test>.1.png`, run `IOS_SNAP -only-testing:OYBCSnapshotTests/<Class>` (records via `record: .missing`), run again to confirm green, then **Read the PNG** and compare against the handoff frame before committing. Compare red SETS, never counts (CLAUDE.md); the standing reds (`CountersHub` ×4, `RisoDeleteConfirm` ×2, `RisoTasksTab` ×2, `RisoEditBoard` weekly pair) are not regressions.
- Playwright validation = `pnpm --filter @oybc/web dev`, open the stated URL with `?__oybc_test_bypass=1` in the Playwright MCP browser, perform the stated interaction, screenshot to `.playwright-mcp/<task>-<surface>-{light,dark}.png`, compare to the handoff frame.

## Review Focus

1. **Typing a partial or locale-formatted decimal** — "3," / "3." / ",5" / "26,2" in a Continuous field must parse (3, 3, 0.5, 26.2) and never silently drop to an integer; "3.125" must be refused, not rounded. Pinned by Task 1's `parseCountInput` vectors (`partial separator`, `comma decimal`, `three places refused`) and Task 4's GoalEntry tests.
2. **A Duration goal typed as minutes vs hours** — "90", "1:30", "1h 30m" and "1h30m" all mean 90 minutes; "1.5h" is refused (not 1 minute or 90 hours). Pinned by Task 1 vectors (`duration bare minutes`, `duration colon`, `duration compact`, `duration fractional hours refused`).
3. **Switching an auto-linked create** — a create whose (verb, noun) pair auto-links to a Continuous counter must save Continuous even if the picker last showed Discrete, and the preview must render the root's kind (R19). Pinned by Task 5's `useCreateFormState` test (`linked create takes the root kind`) and the iOS `CreateFormViewModelCountKindTests.testLinkedCreateTakesRootKind`.
4. **Board Edit Save with a staged Continuous → Discrete switch plus a goal edit** — one transaction: the switch rounds, then the typed goal wins; a failing step rolls both back. Pinned by Task 9's `boardEditCommit` test (`kind switch then goal edit, atomic`) and iOS `BoardEditKindSwitchTests.testSwitchThenGoalEditAtomic`.
5. **Overshoot in a 5×5 cell at the widest Duration value** — `112h 15m/500h` drops to `112h 15m`; an overshoot `28.4/26.2` keeps its real value and a gold full bar. Pinned by Task 20's `cellCountFit` vectors and the `RisoBoardCellKinds` snapshots.

---

## File map

**Shared (PR 3)** — `packages/shared/src/algorithms/countEntry.ts` (create), `countValue.ts` (+`formatCountTotal`, `formatCountRange`), `taskTitle.ts` (kind-aware), `memberRulesDisplay.ts` (`varyRangeLabel` via `formatCountRange`), `validation/schemas.ts` (Duration needs no unit), `types/task.ts` (`AutoCreateCompoundChildTask.countKind`), fixtures `countEntryVectors.json` (create), `countValueVectors.json`, `taskTitleVectors.json`, `memberRuleVectors.json`.
**Shared (PR 4)** — `packages/shared/src/algorithms/logAmounts.ts` (create), `sharedCounterGroups.ts` (+`countKind`), fixture `logAmountVectors.json` (create), `sharedCounterGroupsVectors.json`.
**iOS helpers** — `Helpers/CountEntry.swift` (create), `Helpers/CountValue.swift`, `Helpers/TaskTitle.swift`, `Helpers/BoardSourceMemberRulesDisplay.swift`, `Helpers/CounterLogAmount.swift`, `Helpers/SharedCounterGroups.swift`.
**Components** — web `components/counters/KindPicker.tsx`, `KindTag.tsx`, `GoalEntry.tsx`, `KindSwitchConfirmDialog.tsx` (create, each with `.module.css`), `components/riso/RisoSegmented.tsx` (+`lockedValues`); iOS `Views/Riso/KindPickerView.swift`, `Views/Riso/GoalEntryView.swift`, `Views/Components/KindSwitchConfirmView.swift`, `Views/Riso/RisoCountStepperView.swift` (create), `Views/Riso/RisoControls.swift` (`RisoSegmented.lockedValues`, `RisoNumberField.keyboard`).
**PR 4 extractions** — web `components/boardPlay/useCountingLogModal.ts` (create; shrinks `BoardPlaySurface.tsx`), iOS `Views/ProfileTab/Components/CounterDetailLogCard.swift` (create; shrinks `CounterDetailView.swift`).

---

# PR 3 — Authoring UI

Branch: `feature/counter-kinds-authoring` (this worktree). Push with `git push origin HEAD:feature/counter-kinds-authoring` and verify the remote SHA.

### Task 1: Shared count-entry module + kind-aware titles, ranges, totals, schema

**Files:**
- Create: `packages/shared/src/algorithms/countEntry.ts`
- Create: `packages/shared/tests/fixtures/countEntryVectors.json`
- Create: `packages/shared/tests/algorithms/countEntry.test.ts`
- Modify: `packages/shared/src/algorithms/countValue.ts` (append `formatCountTotal`, `formatCountRange` after `formatCountForInput`, ~line 113)
- Modify: `packages/shared/src/algorithms/taskTitle.ts:16-34` (`generateCounterTaskTitle`), `:69-78` (`isAutoCounterTitle`), `:42-47` (`CounterTitleFields.countKind`), `counterCopyTitle`
- Modify: `packages/shared/src/algorithms/memberRulesDisplay.ts:116-129` (`varyRangeLabel` → `formatCountRange`)
- Modify: `packages/shared/src/algorithms/index.ts` (export `countEntry`)
- Modify: `packages/shared/src/validation/schemas.ts:262-271` (create refine), `:369-386` (`AutoCreateCompoundChildTaskSchema` + `countKind`)
- Modify: `packages/shared/src/types/task.ts:348-371` (`AutoCreateCompoundChildTask.countKind?: CountKind`)
- Modify: `packages/shared/tests/fixtures/countValueVectors.json` (+`formatTotal`, `formatRange`), `taskTitleVectors.json` (+duration cases), `memberRuleVectors.json` (`display.varyRangeLabel` +2 cases)
- Test: `packages/shared/tests/algorithms/countValue.test.ts`, `taskTitleVectors.test.ts`, `memberRulesDisplay.test.ts`, `packages/shared/tests/validation/schemas.test.ts` (or the existing schema test file — `grep -l CreateTaskInputSchema packages/shared/tests`)

**Interfaces:**
- Consumes: `CountKind`, `quantizeCount`, `formatCount`, `formatCountForInput`, `resolveCountKind` (`countValue.ts`, PR 1).
- Produces:
  - `type KindPickerLock = 'none' | 'duration' | 'all'`
  - `kindPickerLock(mode: 'create' | 'edit', kind: CountKind): KindPickerLock`
  - `isKindSegmentLocked(lock: KindPickerLock, segment: CountKind): boolean`
  - `kindSegmentShowsLock(lock: KindPickerLock, segment: CountKind, selected: CountKind): boolean`
  - `COUNT_KIND_LABELS: Readonly<Record<CountKind, string>>` = `{ discrete: 'Discrete', continuous: 'Continuous', duration: 'Duration' }`
  - `parseCountInput(raw: string, kind: CountKind, options?: { allowZero?: boolean }): number | null`
  - `durationToFields(minutes: number | null | undefined): { hours: string; minutes: string }`
  - `durationFromFields(hours: string, minutes: string): string` (returns a `parseCountInput`-parsable string, `''` when both blank)
  - `countUnitSuffix(kind: CountKind, unit: string | null | undefined): string` (`''` or `' unit'`)
  - `formatCountWithUnit(value: number, kind: CountKind, unit: string | null | undefined, locale?: string): string`
  - `resolveFamilyCountKind(task: { countKind?: CountKind | null; sharedCounterId?: string | null }, lookup: (id: string) => { countKind?: CountKind | null } | undefined): CountKind`
  - `countKindNeedsUnit(kind: CountKind): boolean` (false only for duration)
  - `formatCountTotal(value: number, kind: CountKind, locale?: string): string` (grouping on; duration = `formatCount`)
  - `formatCountRange(lo: number, hi: number, kind: CountKind, locale?: string): string`
  - `generateCounterTaskTitle(action, maxCount, unit, providedTitle?, countKind?: CountKind)`; `isAutoCounterTitle(title, action, maxCount, unit, countKind?)`; `CounterTitleFields.countKind?: CountKind | null`

- [ ] **Step 1: Write the vectors file** `packages/shared/tests/fixtures/countEntryVectors.json`:

```json
{
  "_note": "Cross-platform vectors for countEntry.ts <-> CountEntry.swift (docs/COUNTER_KINDS.md §5). parse: discrete = ASCII digits only, > 0; continuous = digits with an optional '.' or ',' separator and at most 2 fraction digits (a trailing separator is allowed: '3.' = 3), quantized, > 0; duration = minutes from 'N' (bare = minutes), 'H:MM', 'Xh Ym' / 'Xh' / 'Ym' (spaces optional, case-insensitive), > 0. allowZero admits 0. Anything else (signs, exponents, non-ASCII digits, 3+ decimals, fractional hours) is null.",
  "parse": [
    { "name": "discrete whole", "raw": "300", "kind": "discrete", "expected": 300 },
    { "name": "discrete trims", "raw": "  12 ", "kind": "discrete", "expected": 12 },
    { "name": "discrete decimal refused", "raw": "2.5", "kind": "discrete", "expected": null },
    { "name": "discrete zero refused", "raw": "0", "kind": "discrete", "expected": null },
    { "name": "discrete zero allowed", "raw": "0", "kind": "discrete", "allowZero": true, "expected": 0 },
    { "name": "discrete sign refused", "raw": "-3", "kind": "discrete", "expected": null },
    { "name": "discrete exponent refused", "raw": "1e3", "kind": "discrete", "expected": null },
    { "name": "discrete arabic-indic digits refused", "raw": "٣", "kind": "discrete", "expected": null },
    { "name": "continuous one place", "raw": "26.2", "kind": "continuous", "expected": 26.2 },
    { "name": "continuous two places", "raw": "12.75", "kind": "continuous", "expected": 12.75 },
    { "name": "continuous comma decimal", "raw": "26,2", "kind": "continuous", "expected": 26.2 },
    { "name": "continuous partial separator", "raw": "3.", "kind": "continuous", "expected": 3 },
    { "name": "continuous partial comma", "raw": "3,", "kind": "continuous", "expected": 3 },
    { "name": "continuous leading separator", "raw": ",5", "kind": "continuous", "expected": 0.5 },
    { "name": "continuous whole", "raw": "5", "kind": "continuous", "expected": 5 },
    { "name": "continuous three places refused", "raw": "3.125", "kind": "continuous", "expected": null },
    { "name": "continuous lone separator refused", "raw": ".", "kind": "continuous", "expected": null },
    { "name": "continuous zero refused", "raw": "0.0", "kind": "continuous", "expected": null },
    { "name": "continuous zero allowed", "raw": "0", "kind": "continuous", "allowZero": true, "expected": 0 },
    { "name": "continuous grouping refused", "raw": "1,250.5", "kind": "continuous", "expected": null },
    { "name": "duration bare minutes", "raw": "90", "kind": "duration", "expected": 90 },
    { "name": "duration colon", "raw": "1:30", "kind": "duration", "expected": 90 },
    { "name": "duration h and m", "raw": "10h 30m", "kind": "duration", "expected": 630 },
    { "name": "duration compact", "raw": "1h30m", "kind": "duration", "expected": 90 },
    { "name": "duration hours only", "raw": "10h", "kind": "duration", "expected": 600 },
    { "name": "duration minutes only", "raw": "45m", "kind": "duration", "expected": 45 },
    { "name": "duration upper case", "raw": "2H 5M", "kind": "duration", "expected": 125 },
    { "name": "duration minutes over 59 normalise", "raw": "1h 75m", "kind": "duration", "expected": 135 },
    { "name": "duration fractional hours refused", "raw": "1.5h", "kind": "duration", "expected": null },
    { "name": "duration zero refused", "raw": "0h 0m", "kind": "duration", "expected": null },
    { "name": "duration zero allowed", "raw": "0m", "kind": "duration", "allowZero": true, "expected": 0 },
    { "name": "duration junk refused", "raw": "abc", "kind": "duration", "expected": null },
    { "name": "empty refused", "raw": "   ", "kind": "continuous", "expected": null }
  ],
  "durationToFields": [
    { "name": "hours and minutes", "minutes": 630, "expected": { "hours": "10", "minutes": "30" } },
    { "name": "minutes pad", "minutes": 65, "expected": { "hours": "1", "minutes": "05" } },
    { "name": "under an hour", "minutes": 45, "expected": { "hours": "0", "minutes": "45" } },
    { "name": "absent", "minutes": null, "expected": { "hours": "", "minutes": "" } }
  ],
  "durationFromFields": [
    { "name": "both", "hours": "10", "minutes": "30", "expected": "10h 30m" },
    { "name": "hours only", "hours": "2", "minutes": "", "expected": "2h 0m" },
    { "name": "minutes only", "hours": "", "minutes": "45", "expected": "0h 45m" },
    { "name": "both blank", "hours": " ", "minutes": "", "expected": "" }
  ],
  "unitSuffix": [
    { "name": "discrete unit", "kind": "discrete", "unit": "pages", "expected": " pages" },
    { "name": "continuous unit trims", "kind": "continuous", "unit": " mi ", "expected": " mi" },
    { "name": "duration never shows a unit", "kind": "duration", "unit": "guitar", "expected": "" },
    { "name": "blank unit", "kind": "continuous", "unit": "", "expected": "" }
  ],
  "pickerLock": [
    { "name": "create", "mode": "create", "kind": "discrete", "expected": "none" },
    { "name": "create duration", "mode": "create", "kind": "duration", "expected": "none" },
    { "name": "edit discrete", "mode": "edit", "kind": "discrete", "expected": "duration" },
    { "name": "edit continuous", "mode": "edit", "kind": "continuous", "expected": "duration" },
    { "name": "edit duration", "mode": "edit", "kind": "duration", "expected": "all" }
  ],
  "segmentState": [
    { "name": "none lock: nothing locked", "lock": "none", "segment": "duration", "selected": "discrete", "locked": false, "glyph": false },
    { "name": "duration lock: duration locked + glyph", "lock": "duration", "segment": "duration", "selected": "continuous", "locked": true, "glyph": true },
    { "name": "duration lock: discrete live", "lock": "duration", "segment": "discrete", "selected": "continuous", "locked": false, "glyph": false },
    { "name": "all lock: selected glyph", "lock": "all", "segment": "duration", "selected": "duration", "locked": true, "glyph": true },
    { "name": "all lock: unselected no glyph", "lock": "all", "segment": "discrete", "selected": "duration", "locked": true, "glyph": false }
  ]
}
```

- [ ] **Step 2: Write the failing test** `packages/shared/tests/algorithms/countEntry.test.ts`:

```ts
import vectors from '../fixtures/countEntryVectors.json';
import {
  COUNT_KIND_LABELS,
  countKindNeedsUnit,
  countUnitSuffix,
  durationFromFields,
  durationToFields,
  formatCountWithUnit,
  isKindSegmentLocked,
  kindPickerLock,
  kindSegmentShowsLock,
  parseCountInput,
  resolveFamilyCountKind,
  type KindPickerLock,
} from '../../src/algorithms/countEntry';
import type { CountKind } from '../../src/algorithms/countValue';

describe('countEntry vectors', () => {
  it.each(vectors.parse)('parse: $name', ({ raw, kind, allowZero, expected }) => {
    expect(parseCountInput(raw, kind as CountKind, { allowZero: allowZero === true })).toBe(expected);
  });
  it.each(vectors.durationToFields)('durationToFields: $name', ({ minutes, expected }) => {
    expect(durationToFields(minutes)).toEqual(expected);
  });
  it.each(vectors.durationFromFields)('durationFromFields: $name', ({ hours, minutes, expected }) => {
    expect(durationFromFields(hours, minutes)).toBe(expected);
  });
  it.each(vectors.unitSuffix)('unitSuffix: $name', ({ kind, unit, expected }) => {
    expect(countUnitSuffix(kind as CountKind, unit)).toBe(expected);
  });
  it.each(vectors.pickerLock)('pickerLock: $name', ({ mode, kind, expected }) => {
    expect(kindPickerLock(mode as 'create' | 'edit', kind as CountKind)).toBe(expected);
  });
  it.each(vectors.segmentState)('segmentState: $name', ({ lock, segment, selected, locked, glyph }) => {
    expect(isKindSegmentLocked(lock as KindPickerLock, segment as CountKind)).toBe(locked);
    expect(kindSegmentShowsLock(lock as KindPickerLock, segment as CountKind, selected as CountKind)).toBe(glyph);
  });
});

describe('countEntry helpers', () => {
  it('labels in picker order', () => {
    expect(Object.values(COUNT_KIND_LABELS)).toEqual(['Discrete', 'Continuous', 'Duration']);
  });
  it('only duration drops the unit', () => {
    expect(countKindNeedsUnit('discrete')).toBe(true);
    expect(countKindNeedsUnit('continuous')).toBe(true);
    expect(countKindNeedsUnit('duration')).toBe(false);
  });
  it('formats with the unit suffix', () => {
    expect(formatCountWithUnit(3.1, 'continuous', 'mi', 'en-US')).toBe('3.1 mi');
    expect(formatCountWithUnit(90, 'duration', 'guitar', 'en-US')).toBe('1h 30m');
  });
  it('a linked row takes its root kind; a lost root falls back to its own', () => {
    const root = { countKind: 'continuous' as CountKind };
    const lookup = (id: string) => (id === 'root' ? root : undefined);
    expect(resolveFamilyCountKind({ sharedCounterId: 'root' }, lookup)).toBe('continuous');
    expect(resolveFamilyCountKind({ sharedCounterId: 'gone', countKind: 'discrete' }, lookup)).toBe('discrete');
    expect(resolveFamilyCountKind({ countKind: 'duration' }, lookup)).toBe('duration');
  });
});
```

- [ ] **Step 3: Run it — expect FAIL** (`Cannot find module '../../src/algorithms/countEntry'`). Run: `SHARED_TEST countEntry`

- [ ] **Step 4: Implement** `packages/shared/src/algorithms/countEntry.ts`:

```ts
/**
 * Counter kinds — the single owner of counting INPUT rules and the authoring
 * picker's state (docs/COUNTER_KINDS.md §5). Every Goal / custom-amount field
 * on every surface parses through {@link parseCountInput}; every kind picker
 * derives its locks from {@link kindPickerLock}. Swift twin:
 * `apps/ios/OYBC/Helpers/CountEntry.swift`, pinned by countEntryVectors.json.
 */
import { formatCount, quantizeCount, resolveCountKind, type CountKind } from './countValue';

/** On-screen kind labels, in picker order (D1 / §5). */
export const COUNT_KIND_LABELS: Readonly<Record<CountKind, string>> = {
  discrete: 'Discrete',
  continuous: 'Continuous',
  duration: 'Duration',
};

/** Which picker segments are locked: none, Duration only, or every segment. */
export type KindPickerLock = 'none' | 'duration' | 'all';

/**
 * The picker's lock state for a surface (D4: Duration never switches either way).
 *
 * @param mode - `'create'` for a task that does not exist yet, else `'edit'`.
 * @param kind - The task's current kind.
 * @returns `'none'` on create; `'all'` for an existing Duration; else `'duration'`.
 */
export function kindPickerLock(mode: 'create' | 'edit', kind: CountKind): KindPickerLock {
  if (mode === 'create') return 'none';
  return kind === 'duration' ? 'all' : 'duration';
}

/**
 * @param lock - The picker's lock state.
 * @param segment - The segment being rendered.
 * @returns Whether the segment ignores taps.
 */
export function isKindSegmentLocked(lock: KindPickerLock, segment: CountKind): boolean {
  return lock === 'all' || (lock === 'duration' && segment === 'duration');
}

/**
 * Whether a segment carries the lock glyph: with every segment locked only the
 * selected one does; otherwise each locked, unselected segment does.
 *
 * @param lock - The picker's lock state.
 * @param segment - The segment being rendered.
 * @param selected - The picker's value.
 * @returns True when the glyph renders on `segment`.
 */
export function kindSegmentShowsLock(lock: KindPickerLock, segment: CountKind, selected: CountKind): boolean {
  if (lock === 'all') return segment === selected;
  return isKindSegmentLocked(lock, segment) && segment !== selected;
}

const DIGITS = /^[0-9]+$/;
const CONTINUOUS = /^([0-9]+)?(?:[.,]([0-9]{0,2}))?$/;
const DURATION_COLON = /^([0-9]+):([0-9]{1,2})$/;
const DURATION_HM = /^(?:([0-9]+)\s*h)?\s*(?:([0-9]+)\s*m)?$/i;

function parseDurationMinutes(s: string): number | null {
  if (DIGITS.test(s)) return Number(s);
  const colon = DURATION_COLON.exec(s);
  if (colon) return Number(colon[1]) * 60 + Number(colon[2]);
  const hm = DURATION_HM.exec(s);
  if (hm && (hm[1] !== undefined || hm[2] !== undefined)) {
    return Number(hm[1] ?? '0') * 60 + Number(hm[2] ?? '0');
  }
  return null;
}

/**
 * Parses a Goal / custom-amount field for a kind. ASCII digits only (R10).
 *
 * @param raw - The field text.
 * @param kind - The counter's kind.
 * @param options - `allowZero` admits 0 (the hub's optional "Start from").
 * @returns The value (minutes for duration), or null when not a valid entry.
 */
export function parseCountInput(
  raw: string,
  kind: CountKind,
  options: { allowZero?: boolean } = {},
): number | null {
  const s = raw.trim();
  if (s === '') return null;
  let value: number | null = null;
  if (kind === 'discrete') {
    value = DIGITS.test(s) ? Number(s) : null;
  } else if (kind === 'continuous') {
    const m = CONTINUOUS.exec(s);
    if (m && `${m[1] ?? ''}${m[2] ?? ''}` !== '') {
      value = quantizeCount(Number(`${m[1] ?? '0'}.${m[2] || '0'}`));
    }
  } else {
    value = parseDurationMinutes(s);
  }
  if (value === null || !Number.isFinite(value) || value < 0) return null;
  if (value === 0 && options.allowZero !== true) return null;
  return value;
}

/**
 * Splits stored minutes into the web Duration entry's two fields.
 *
 * @param minutes - Stored minutes, or absent.
 * @returns `{ hours, minutes }` strings; minutes zero-padded; both `''` when absent.
 */
export function durationToFields(minutes: number | null | undefined): { hours: string; minutes: string } {
  if (minutes == null) return { hours: '', minutes: '' };
  const total = Math.max(0, Math.floor(minutes + 0.5));
  return { hours: String(Math.floor(total / 60)), minutes: String(total % 60).padStart(2, '0') };
}

/**
 * Joins the two Duration fields into a {@link parseCountInput}-parsable string.
 *
 * @param hours - The hours field text.
 * @param minutes - The minutes field text.
 * @returns `'Xh Ym'` (a blank side reads 0), or `''` when both are blank.
 */
export function durationFromFields(hours: string, minutes: string): string {
  const h = hours.trim();
  const m = minutes.trim();
  if (h === '' && m === '') return '';
  return `${h === '' ? '0' : h}h ${m === '' ? '0' : m}m`;
}

/**
 * @param kind - The counter's kind.
 * @returns False only for duration (its unit is time; the Unit field hides).
 */
export function countKindNeedsUnit(kind: CountKind): boolean {
  return kind !== 'duration';
}

/**
 * The unit text that follows a count on screen.
 *
 * @param kind - The counter's kind.
 * @param unit - The stored unit.
 * @returns `' unit'`, or `''` for duration or a blank unit.
 */
export function countUnitSuffix(kind: CountKind, unit: string | null | undefined): string {
  const u = (unit ?? '').trim();
  return kind === 'duration' || u === '' ? '' : ` ${u}`;
}

/**
 * `formatCount` + {@link countUnitSuffix} — "3.1 mi", "1h 30m".
 *
 * @param value - The value (minutes for duration).
 * @param kind - The counter's kind.
 * @param unit - The stored unit.
 * @param locale - Optional BCP 47 locale.
 * @returns The display string.
 */
export function formatCountWithUnit(
  value: number,
  kind: CountKind,
  unit: string | null | undefined,
  locale?: string,
): string {
  return `${formatCount(value, kind, locale)}${countUnitSuffix(kind, unit)}`;
}

/**
 * A row's effective kind: a linked row (`sharedCounterId`) follows its root
 * (D5), even when the row itself was written before the root's kind landed
 * (a wizard-pending link — R19). A root that cannot be found falls back to
 * the row's own kind.
 *
 * @param task - The row.
 * @param lookup - Resolves a task id (the caller's task map).
 * @returns The family kind.
 */
export function resolveFamilyCountKind(
  task: { countKind?: CountKind | null; sharedCounterId?: string | null },
  lookup: (id: string) => { countKind?: CountKind | null } | undefined,
): CountKind {
  if (task.sharedCounterId) {
    const root = lookup(task.sharedCounterId);
    if (root) return resolveCountKind(root);
  }
  return resolveCountKind(task);
}
```

Append to `packages/shared/src/algorithms/countValue.ts` (after `formatCountForInput`):

```ts
/**
 * A LIFETIME total (hub, Profile, Counter Detail hero, link hints): like
 * {@link formatCount} but with thousands grouping (R7 — the pre-feature
 * `toLocaleString()` / `.formatted()` sites grouped). Duration is unchanged.
 *
 * @param value - The total (minutes for duration).
 * @param kind - The counter's kind.
 * @param locale - Optional BCP 47 locale.
 * @returns "1,240", "148.6", "112h 15m".
 */
export function formatCountTotal(value: number, kind: CountKind, locale?: string): string {
  if (kind === 'duration') return formatCount(value, kind, locale);
  const v = kind === 'continuous' ? quantizeCount(value) : Math.floor(quantizeCount(value) + 0.5);
  return new Intl.NumberFormat(locale, {
    minimumFractionDigits: 0,
    maximumFractionDigits: kind === 'continuous' ? 2 : 0,
    useGrouping: true,
    numberingSystem: 'latn',
  }).format(v);
}

function fractionDigits(value: number): number {
  const s = formatCountForInput(value, 'continuous');
  const dot = s.indexOf('.');
  return dot < 0 ? 0 : s.length - dot - 1;
}

/**
 * An inclusive range "lo–hi" (en dash). Continuous renders both ends at the
 * more precise end's precision ("21.0–31.4"); other kinds format each end.
 *
 * @param lo - Lower bound.
 * @param hi - Upper bound.
 * @param kind - The counter's kind.
 * @param locale - Optional BCP 47 locale.
 * @returns The range text.
 */
export function formatCountRange(lo: number, hi: number, kind: CountKind, locale?: string): string {
  if (kind !== 'continuous') return `${formatCount(lo, kind, locale)}–${formatCount(hi, kind, locale)}`;
  const digits = Math.max(fractionDigits(lo), fractionDigits(hi));
  const fmt = new Intl.NumberFormat(locale, {
    minimumFractionDigits: digits,
    maximumFractionDigits: 2,
    useGrouping: false,
    numberingSystem: 'latn',
  });
  return `${fmt.format(quantizeCount(lo))}–${fmt.format(quantizeCount(hi))}`;
}
```

In `memberRulesDisplay.ts:116-129` replace the final return of `varyRangeLabel`:

```ts
  return lo === hi ? `${a}${suffix}` : `${formatCountRange(lo, hi, kind)}${suffix}`;
```

(import `formatCountRange` from `./countValue`; `a` stays `formatCount(lo, kind)` for the collapsed case).

In `taskTitle.ts` change `generateCounterTaskTitle` (lines 16-34):

```ts
export function generateCounterTaskTitle(
  action: string,
  maxCount: number | null | undefined,
  unit: string,
  providedTitle?: string,
  countKind: CountKind = 'discrete'
): string {
  if (providedTitle && providedTitle.trim().length > 0) {
    return providedTitle.trim();
  }
  if (maxCount == null) {
    return formatCounterName(action, unit);
  }
  if (countKind === 'duration') {
    // Duration's unit IS time: "Practice 10h 30m" (minutes are stored; the
    // `Xh Ym` rendering is locale-independent, so stored titles stay stable).
    return `${action.trim()} ${formatCount(maxCount, 'duration')}`;
  }
  return `${action.trim()} ${String(quantizeCount(maxCount))} ${unit.trim()}`;
}
```

`isAutoCounterTitle(title, action, maxCount, unit, countKind: CountKind = 'discrete')` passes `countKind` as the 5th argument (`providedTitle` `undefined`). `CounterTitleFields` gains `countKind?: CountKind | null`; `counterCopyTitle` passes `member.countKind ?? 'discrete'` to both calls. Import `formatCount`, `type CountKind` from `./countValue`.

In `schemas.ts:262-271` the create refine becomes:

```ts
    if (data.type === TaskType.COUNTING) {
      const hasUnit = Boolean(data.unit) || data.countKind === 'duration';
      return Boolean(data.action) && hasUnit && Boolean(data.maxCount || data.isCounter === true);
    }
```

and its message `'Counting tasks must have action, unit (unless duration), and maxCount (unless isCounter)'`. `AutoCreateCompoundChildTaskSchema` gains `countKind: CountKindSchema.optional(),` and its refine `data.action !== undefined && (data.unit !== undefined || data.countKind === 'duration') && data.maxCount !== undefined`; add `.refine(countFieldsMatchKind, { message: 'Whole-number kinds need whole goals' })`. `types/task.ts` `AutoCreateCompoundChildTask` gains:

```ts
  /** Counter kinds (docs/COUNTER_KINDS.md D1) — counting only; absent = discrete. A linked child still takes its root's kind at write time (`withRootCountKind`). */
  countKind?: CountKind;
```

Export from `algorithms/index.ts`: `export * from './countEntry';`.

- [ ] **Step 5: Add the vectors for the countValue / title / range changes.** Append to `countValueVectors.json`:

```json
  "formatTotal": [
    { "name": "discrete grouped", "value": 1240, "kind": "discrete", "locale": "en-US", "expected": "1,240" },
    { "name": "continuous grouped", "value": 1250.5, "kind": "continuous", "locale": "en-US", "expected": "1,250.5" },
    { "name": "continuous small", "value": 148.6, "kind": "continuous", "locale": "en-US", "expected": "148.6" },
    { "name": "continuous de-DE", "value": 1250.5, "kind": "continuous", "locale": "de-DE", "expected": "1.250,5" },
    { "name": "duration ungrouped", "value": 6735, "kind": "duration", "locale": "en-US", "expected": "112h 15m" }
  ],
  "formatRange": [
    { "name": "continuous pads the coarser end", "lo": 21, "hi": 31.4, "kind": "continuous", "locale": "en-US", "expected": "21.0–31.4" },
    { "name": "continuous two places wins", "lo": 4.9, "hi": 7.35, "kind": "continuous", "locale": "en-US", "expected": "4.90–7.35" },
    { "name": "continuous whole ends", "lo": 8, "hi": 12, "kind": "continuous", "locale": "en-US", "expected": "8–12" },
    { "name": "continuous comma locale", "lo": 21, "hi": 31.4, "kind": "continuous", "locale": "de-DE", "expected": "21,0–31,4" },
    { "name": "duration whole minutes", "lo": 504, "hi": 756, "kind": "duration", "locale": "en-US", "expected": "8h 24m–12h 36m" },
    { "name": "discrete", "lo": 24, "hi": 36, "kind": "discrete", "locale": "en-US", "expected": "24–36" }
  ]
```

and the tests in `countValue.test.ts`:

```ts
  it.each(vectors.formatTotal)('formatTotal: $name', ({ value, kind, locale, expected }) => {
    expect(formatCountTotal(value, kind as CountKind, locale)).toBe(expected);
  });
  it.each(vectors.formatRange)('formatRange: $name', ({ lo, hi, kind, locale, expected }) => {
    expect(formatCountRange(lo, hi, kind as CountKind, locale)).toBe(expected);
  });
```

Append to `taskTitleVectors.json` `generateCounterTaskTitle` (the test reads `countKind` when present — extend its `it.each` call to pass `v.providedTitle, v.countKind`):

```json
    { "name": "duration renders Xh Ym and drops the unit", "action": "Practice", "maxCount": 630, "unit": "", "countKind": "duration", "expected": "Practice 10h 30m" },
    { "name": "duration minutes only", "action": "Meditate", "maxCount": 20, "unit": "", "countKind": "duration", "expected": "Meditate 20m" },
    { "name": "continuous keeps decimals", "action": "Save", "maxCount": 1250.5, "unit": "dollars", "countKind": "continuous", "expected": "Save 1250.5 dollars" }
```

and to `isAutoCounterTitle`:

```json
    { "name": "duration auto title is auto", "title": "Practice 10h 30m", "action": "Practice", "maxCount": 630, "unit": "", "countKind": "duration", "expected": true }
```

Append to `memberRuleVectors.json` `display.varyRangeLabel`:

```json
      { "name": "continuous ends share precision: t 26.2 a little then 21.0–31.4 miles", "t": 26.2, "level": 1, "goal": 26.2, "unit": "miles", "countKind": "continuous", "expected": "21.0–31.4 miles" },
      { "name": "duration 1-minute range: t 630 a little then 8h 24m–12h 36m", "t": 630, "level": 1, "goal": 630, "unit": "", "countKind": "duration", "expected": "8h 24m–12h 36m" }
```

Add a schema test:

```ts
it('a duration counting task needs no unit; discrete still does', () => {
  const base = { title: 'Practice 10h', type: TaskType.COUNTING, action: 'Practice', maxCount: 600 };
  expect(CreateTaskInputSchema.safeParse({ ...base, countKind: 'duration' }).success).toBe(true);
  expect(CreateTaskInputSchema.safeParse({ ...base }).success).toBe(false);
  expect(AutoCreateCompoundChildTaskSchema.safeParse({ ...base, countKind: 'duration' }).success).toBe(true);
  expect(AutoCreateCompoundChildTaskSchema.safeParse({ ...base, countKind: 'discrete', maxCount: 2.5, unit: 'x' }).success).toBe(false);
});
```

- [ ] **Step 6: Run** `SHARED_TEST countEntry countValue taskTitle memberRulesDisplay schemas` — expect PASS. Then `pnpm --filter @oybc/shared test:coverage` — the 80% gate must hold. Then `pnpm --filter @oybc/shared run gen:sync-fixtures`.

- [ ] **Step 7: Commit**

```bash
git add packages/shared apps/ios/OYBCTests/Fixtures
git commit -m "feat(counters): shared count-entry module, kind-aware titles/ranges/totals, duration needs no unit (PR 3 Task 1)"
```

(The iOS fixture copies land here; their Swift tests arrive in Task 2 — the iOS `TaskTitleVectorTests` / `MemberRuleVectorTests` are red between Task 1 and Task 2 inside the PR, as PR 1 did.)

---

### Task 2: Swift twin — CountEntry.swift, totals/ranges, kind-aware titles

**Files:**
- Create: `apps/ios/OYBC/Helpers/CountEntry.swift`
- Create: `apps/ios/OYBCTests/CountEntryVectorTests.swift`
- Create: `apps/ios/OYBCTests/TestTaskBuilders.swift` (`Task.counting(id:maxCount:)`, reused by Tasks 6, 8)
- Modify: `apps/ios/OYBC/Helpers/CountValue.swift` (append `formatCountTotal`, `formatCountRange` after `formatCountForInput`, line ~66)
- Modify: `apps/ios/OYBC/Helpers/TaskTitle.swift:25-50` (+`countKind:`), `isAutoCounterTitle`, `counterCopyTitle`
- Modify: `apps/ios/OYBC/Helpers/BoardSourceMemberRulesDisplay.swift:120-129` (`varyRangeLabel` → `formatCountRange`)
- Modify: `apps/ios/OYBCTests/CountValueVectorTests.swift` (Fixture + 2 tests), `TaskTitleVectorTests.swift` (decode `countKind`), `MemberRuleVectorTests.swift` (nothing if it already decodes `countKind` for `varyRangeLabel`; verify)

**Interfaces:**
- Consumes: Task 1 vectors (synced copies).
- Produces (Swift, free functions unless noted, same semantics as Task 1):
  - `enum KindPickerLock: String, Decodable { case none, duration, all }`
  - `func kindPickerLock(mode: KindPickerMode, kind: CountKind) -> KindPickerLock` with `enum KindPickerMode: String, Decodable { case create, edit }`
  - `func isKindSegmentLocked(_ lock: KindPickerLock, segment: CountKind) -> Bool`
  - `func kindSegmentShowsLock(_ lock: KindPickerLock, segment: CountKind, selected: CountKind) -> Bool`
  - `extension CountKind { var label: String }` ("Discrete" / "Continuous" / "Duration")
  - `func parseCountInput(_ raw: String, kind: CountKind, allowZero: Bool = false) -> CountValue?`
  - `func durationToFields(_ minutes: CountValue?) -> (hours: String, minutes: String)`
  - `func durationFromFields(hours: String, minutes: String) -> String`
  - `func countKindNeedsUnit(_ kind: CountKind) -> Bool`
  - `func countUnitSuffix(_ kind: CountKind, unit: String?) -> String`
  - `func formatCountWithUnit(_ value: CountValue, kind: CountKind, unit: String?, locale: Locale = .current) -> String`
  - `func resolveFamilyCountKind(_ task: Task, lookup: (String) -> Task?) -> CountKind`
  - `func formatCountTotal(_ value: CountValue, kind: CountKind, locale: Locale = .current) -> String`
  - `func formatCountRange(_ lo: CountValue, _ hi: CountValue, kind: CountKind, locale: Locale = .current) -> String`
  - `TaskTitle.generateCounterTaskTitle(action:maxCount:unit:providedTitle:countKind: CountKind = .discrete)`

- [ ] **Step 1: Write the failing test** `apps/ios/OYBCTests/CountEntryVectorTests.swift`:

```swift
import XCTest
@testable import OYBC

/// Cross-platform pins for `CountEntry.swift`, driven by the same
/// `countEntryVectors.json` as `packages/shared/tests/algorithms/countEntry.test.ts`.
final class CountEntryVectorTests: XCTestCase {
    private struct ParseVector: Decodable { let name: String; let raw: String; let kind: CountKind; let allowZero: Bool?; let expected: Double? }
    private struct Fields: Decodable, Equatable { let hours: String; let minutes: String }
    private struct ToFieldsVector: Decodable { let name: String; let minutes: Double?; let expected: Fields }
    private struct FromFieldsVector: Decodable { let name: String; let hours: String; let minutes: String; let expected: String }
    private struct SuffixVector: Decodable { let name: String; let kind: CountKind; let unit: String; let expected: String }
    private struct LockVector: Decodable { let name: String; let mode: KindPickerMode; let kind: CountKind; let expected: KindPickerLock }
    private struct SegmentVector: Decodable { let name: String; let lock: KindPickerLock; let segment: CountKind; let selected: CountKind; let locked: Bool; let glyph: Bool }
    private struct Fixture: Decodable {
        let parse: [ParseVector]
        let durationToFields: [ToFieldsVector]
        let durationFromFields: [FromFieldsVector]
        let unitSuffix: [SuffixVector]
        let pickerLock: [LockVector]
        let segmentState: [SegmentVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: CountEntryVectorTests.self).url(forResource: "countEntryVectors", withExtension: "json") else {
            XCTFail("countEntryVectors.json missing from the test bundle — re-run gen:sync-fixtures and xcodegen generate.")
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testParse() throws {
        for v in try loadFixture().parse {
            XCTAssertEqual(parseCountInput(v.raw, kind: v.kind, allowZero: v.allowZero ?? false), v.expected, v.name)
        }
    }
    func testDurationToFields() throws {
        for v in try loadFixture().durationToFields {
            let f = durationToFields(v.minutes)
            XCTAssertEqual(Fields(hours: f.hours, minutes: f.minutes), v.expected, v.name)
        }
    }
    func testDurationFromFields() throws {
        for v in try loadFixture().durationFromFields {
            XCTAssertEqual(durationFromFields(hours: v.hours, minutes: v.minutes), v.expected, v.name)
        }
    }
    func testUnitSuffix() throws {
        for v in try loadFixture().unitSuffix { XCTAssertEqual(countUnitSuffix(v.kind, unit: v.unit), v.expected, v.name) }
    }
    func testPickerLock() throws {
        for v in try loadFixture().pickerLock { XCTAssertEqual(kindPickerLock(mode: v.mode, kind: v.kind), v.expected, v.name) }
    }
    func testSegmentState() throws {
        for v in try loadFixture().segmentState {
            XCTAssertEqual(isKindSegmentLocked(v.lock, segment: v.segment), v.locked, v.name)
            XCTAssertEqual(kindSegmentShowsLock(v.lock, segment: v.segment, selected: v.selected), v.glyph, v.name)
        }
    }
    func testLabels() {
        XCTAssertEqual(CountKind.allCases.map(\.label), ["Discrete", "Continuous", "Duration"])
    }
    func testFamilyKind() {
        var root = Task.counting(id: "root", maxCount: 26.2)
        root.countKind = .continuous
        var linked = Task.counting(id: "row", maxCount: 6.2)
        linked.sharedCounterId = "root"
        XCTAssertEqual(resolveFamilyCountKind(linked, lookup: { $0 == "root" ? root : nil }), .continuous)
        XCTAssertEqual(resolveFamilyCountKind(linked, lookup: { _ in nil }), .discrete)
    }
}
```

`Task.counting(id:maxCount:)` — there is no shared counting builder in `OYBCTests` (each file has a private `makeTask`), so add it to `apps/ios/OYBCTests/TestTaskBuilders.swift` (create; later tasks reuse it) as:

```swift
@testable import OYBC

extension Task {
    /// Minimal live COUNTING task for logic tests.
    static func counting(id: String, maxCount: CountValue, userId: String = "u1") -> Task {
        Task(
            id: id, userId: userId, title: "T \(id)", type: .counting,
            action: "Run", unit: "mi", maxCount: maxCount,
            totalCompletions: 0, totalInstances: 0,
            createdAt: "2026-10-01T00:00:00Z", updatedAt: "2026-10-01T00:00:00Z",
            version: 1, isDeleted: false
        )
    }
}
```

Extend `CountValueVectorTests.Fixture` with `let formatTotal: [FormatVector]` and `let formatRange: [RangeVector]` (`private struct RangeVector: Decodable { let name: String; let lo: Double; let hi: Double; let kind: CountKind; let locale: String; let expected: String }`) and add:

```swift
    func testFormatTotal() throws {
        for v in try loadFixture().formatTotal {
            XCTAssertEqual(formatCountTotal(v.value, kind: v.kind, locale: Locale(identifier: v.locale)), v.expected, v.name)
        }
    }
    func testFormatRange() throws {
        for v in try loadFixture().formatRange {
            XCTAssertEqual(formatCountRange(v.lo, v.hi, kind: v.kind, locale: Locale(identifier: v.locale)), v.expected, v.name)
        }
    }
```

In `TaskTitleVectorTests.swift` add `let countKind: CountKind?` to the generate / isAuto vector structs and pass `countKind: v.countKind ?? .discrete`.

- [ ] **Step 2: Run — expect build FAIL** (`cannot find 'parseCountInput' in scope`). Run: `cd apps/ios && xcodegen generate && cd - && IOS_TEST -only-testing:OYBCTests/CountEntryVectorTests -only-testing:OYBCTests/CountValueVectorTests -only-testing:OYBCTests/TaskTitleVectorTests -only-testing:OYBCTests/MemberRuleVectorTests`

- [ ] **Step 3: Implement** `apps/ios/OYBC/Helpers/CountEntry.swift`:

```swift
import Foundation

/// Counter kinds — Swift twin of `packages/shared/src/algorithms/countEntry.ts`
/// (docs/COUNTER_KINDS.md §5), pinned by `countEntryVectors.json`. Every Goal /
/// custom-amount field parses through `parseCountInput`; every kind picker
/// derives its locks from `kindPickerLock`.

extension CountKind {
    /// On-screen label (D1 / §5), in picker order via `allCases`.
    var label: String {
        switch self {
        case .discrete: return "Discrete"
        case .continuous: return "Continuous"
        case .duration: return "Duration"
        }
    }
}

/// Whether the picker is on a task that does not exist yet.
enum KindPickerMode: String, Decodable { case create, edit }

/// Which picker segments are locked.
enum KindPickerLock: String, Decodable { case none, duration, all }

/// - Returns: `.none` on create; `.all` for an existing Duration; else `.duration` (D4).
func kindPickerLock(mode: KindPickerMode, kind: CountKind) -> KindPickerLock {
    guard mode == .edit else { return .none }
    return kind == .duration ? .all : .duration
}

/// - Returns: Whether `segment` ignores taps under `lock`.
func isKindSegmentLocked(_ lock: KindPickerLock, segment: CountKind) -> Bool {
    lock == .all || (lock == .duration && segment == .duration)
}

/// - Returns: Whether `segment` carries the lock glyph (only the selected one under `.all`).
func kindSegmentShowsLock(_ lock: KindPickerLock, segment: CountKind, selected: CountKind) -> Bool {
    if lock == .all { return segment == selected }
    return isKindSegmentLocked(lock, segment: segment) && segment != selected
}

private func isASCIIDigits(_ s: Substring) -> Bool {
    !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
}

private func parseDurationMinutes(_ s: String) -> CountValue? {
    if isASCIIDigits(Substring(s)) { return CountValue(s) }
    if let colon = s.firstIndex(of: ":") {
        let h = s[..<colon], m = s[s.index(after: colon)...]
        guard isASCIIDigits(h), isASCIIDigits(m), m.count <= 2, let hv = Int(h), let mv = Int(m) else { return nil }
        return CountValue(hv * 60 + mv)
    }
    // "Xh Ym" / "Xh" / "Ym", spaces optional, case-insensitive — the same
    // grammar as the TS DURATION_HM regex.
    let pattern = #"^(?:([0-9]+)\s*h)?\s*(?:([0-9]+)\s*m)?$"#
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    func group(_ i: Int) -> Int? {
        guard let r = Range(match.range(at: i), in: s) else { return nil }
        return Int(s[r])
    }
    let h = group(1), m = group(2)
    guard h != nil || m != nil else { return nil }
    return CountValue((h ?? 0) * 60 + (m ?? 0))
}

/// Parses a Goal / custom-amount field for a kind. ASCII digits only (R10).
///
/// - Parameters:
///   - raw: The field text.
///   - kind: The counter's kind.
///   - allowZero: Admits 0 (the hub's optional "Start from").
/// - Returns: The value (minutes for duration), or nil when not a valid entry.
func parseCountInput(_ raw: String, kind: CountKind, allowZero: Bool = false) -> CountValue? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    var value: CountValue?
    switch kind {
    case .discrete:
        value = isASCIIDigits(Substring(s)) ? CountValue(s) : nil
    case .continuous:
        let sepIndex = s.firstIndex(where: { $0 == "." || $0 == "," })
        let whole = sepIndex.map { s[..<$0] } ?? Substring(s)
        let frac = sepIndex.map { s[s.index(after: $0)...] } ?? Substring("")
        let wholeOK = whole.isEmpty || isASCIIDigits(whole)
        let fracOK = frac.isEmpty || (isASCIIDigits(frac) && frac.count <= 2)
        if wholeOK, fracOK, !(whole.isEmpty && frac.isEmpty) {
            value = CountValue("\(whole.isEmpty ? "0" : String(whole)).\(frac.isEmpty ? "0" : String(frac))").map(quantizeCount)
        }
    case .duration:
        value = parseDurationMinutes(s)
    }
    guard let v = value, v.isFinite, v >= 0 else { return nil }
    if v == 0 && !allowZero { return nil }
    return v
}

/// Splits stored minutes into hours / zero-padded minutes strings (both "" when nil).
func durationToFields(_ minutes: CountValue?) -> (hours: String, minutes: String) {
    guard let minutes else { return ("", "") }
    let total = Int(max(0, (minutes + 0.5).rounded(.down)))
    return (String(total / 60), String(format: "%02d", total % 60))
}

/// Joins the two Duration fields into a `parseCountInput`-parsable string ("" when both blank).
func durationFromFields(hours: String, minutes: String) -> String {
    let h = hours.trimmingCharacters(in: .whitespaces), m = minutes.trimmingCharacters(in: .whitespaces)
    if h.isEmpty && m.isEmpty { return "" }
    return "\(h.isEmpty ? "0" : h)h \(m.isEmpty ? "0" : m)m"
}

/// - Returns: False only for duration (its unit is time).
func countKindNeedsUnit(_ kind: CountKind) -> Bool { kind != .duration }

/// - Returns: " unit", or "" for duration or a blank unit.
func countUnitSuffix(_ kind: CountKind, unit: String?) -> String {
    let u = (unit ?? "").trimmingCharacters(in: .whitespaces)
    return kind == .duration || u.isEmpty ? "" : " \(u)"
}

/// `formatCount` + `countUnitSuffix` — "3.1 mi", "1h 30m".
func formatCountWithUnit(_ value: CountValue, kind: CountKind, unit: String?, locale: Locale = .current) -> String {
    formatCount(value, kind: kind, locale: locale) + countUnitSuffix(kind, unit: unit)
}

/// A row's effective kind: a linked row follows its root (D5 / R19); a lost
/// root falls back to the row's own kind.
func resolveFamilyCountKind(_ task: Task, lookup: (String) -> Task?) -> CountKind {
    if let rootId = task.sharedCounterId, let root = lookup(rootId) { return resolveCountKind(root.countKind) }
    return resolveCountKind(task.countKind)
}
```

Append to `CountValue.swift`:

```swift
/// A LIFETIME total — `formatCount` with thousands grouping (R7); duration unchanged.
func formatCountTotal(_ value: CountValue, kind: CountKind, locale: Locale = .current) -> String {
    if kind == .duration { return formatCount(value, kind: kind, locale: locale) }
    let f = NumberFormatter()
    f.locale = Locale(identifier: locale.identifier.components(separatedBy: "@").first! + "@numbers=latn")
    f.numberStyle = .decimal
    f.usesGroupingSeparator = true
    f.minimumFractionDigits = 0
    f.maximumFractionDigits = kind == .continuous ? 2 : 0
    f.roundingMode = .halfUp
    let v = kind == .continuous ? quantizeCount(value) : (quantizeCount(value) + 0.5).rounded(.down)
    return f.string(from: NSNumber(value: v)) ?? "\(v)"
}

/// "lo–hi"; continuous renders both ends at the more precise end's precision.
func formatCountRange(_ lo: CountValue, _ hi: CountValue, kind: CountKind, locale: Locale = .current) -> String {
    guard kind == .continuous else {
        return "\(formatCount(lo, kind: kind, locale: locale))\u{2013}\(formatCount(hi, kind: kind, locale: locale))"
    }
    func digits(_ v: CountValue) -> Int {
        let s = formatCountForInput(v, kind: .continuous)
        guard let dot = s.firstIndex(of: ".") else { return 0 }
        return s.distance(from: dot, to: s.endIndex) - 1
    }
    let f = NumberFormatter()
    f.locale = Locale(identifier: locale.identifier.components(separatedBy: "@").first! + "@numbers=latn")
    f.numberStyle = .decimal
    f.usesGroupingSeparator = false
    f.minimumFractionDigits = max(digits(lo), digits(hi))
    f.maximumFractionDigits = 2
    f.roundingMode = .halfUp
    let a = f.string(from: NSNumber(value: quantizeCount(lo))) ?? "\(lo)"
    let b = f.string(from: NSNumber(value: quantizeCount(hi))) ?? "\(hi)"
    return "\(a)\u{2013}\(b)"
}
```

`TaskTitle.generateCounterTaskTitle` gains `countKind: CountKind = .discrete` (last parameter) and, after the goal-less guard:

```swift
        if countKind == .duration {
            return "\(trimmedAction) \(formatCount(maxCount, kind: .duration))"
        }
```

`isAutoCounterTitle` / `counterCopyTitle` thread `countKind` exactly as Task 1. `BoardSources.varyRangeLabel` (`BoardSourceMemberRulesDisplay.swift:127-128`) returns `"\(formatCountRange(range.lowerBound, range.upperBound, kind: kind))\(suffix)"` for the non-collapsed case.

- [ ] **Step 4: Run** the Step 2 command — expect PASS. Then the whole logic suite `IOS_TEST -only-testing:OYBCTests` — expect no new reds.

- [ ] **Step 5: Commit**

```bash
git add apps/ios/OYBC/Helpers apps/ios/OYBCTests apps/ios/OYBC.xcodeproj/project.pbxproj
git commit -m "feat(counters): CountEntry.swift twin + kind-aware titles, grouped totals, precision-matched ranges (PR 3 Task 2)"
```

---

### Task 3: KindPicker + KindTag (both platforms)

**Files:**
- Modify: `apps/web/src/components/riso/RisoSegmented.tsx:9-88` (+`lockedValues`, `lockGlyphValues`), `RisoSegmented.module.css` (+`.locked`, `.lockGlyph`)
- Create: `apps/web/src/components/counters/KindPicker.tsx`, `KindTag.tsx`, `KindPicker.module.css`
- Test: `apps/web/src/components/riso/__tests__/RisoSegmented.test.ts` (+2 cases), `apps/web/src/components/counters/__tests__/KindPicker.test.ts` (create)
- Modify: `apps/ios/OYBC/Views/Riso/RisoControls.swift:200-245` (`RisoSegmented` +`lockedValues`, `lockGlyphValues`; card body only)
- Create: `apps/ios/OYBC/Views/Riso/KindPickerView.swift` (`KindPickerView`, `KindTagView`)
- Modify: `apps/ios/OYBC/Views/Riso/RisoKitGallery.swift` (add a "Kind picker" section — part of `testKit*`)
- Test: `apps/ios/OYBCSnapshotTests/RisoKitSnapshotTests.swift` (+`testKindPickerStates{Light,Dark}`); re-record `RisoKitSnapshotTests/testKitLight.1.png`, `testKitDark.1.png` (the gallery gains a section — intentional)

**Interfaces:**
- Consumes: `kindPickerLock`, `isKindSegmentLocked`, `kindSegmentShowsLock`, `COUNT_KIND_LABELS` / `CountKind.label` (Tasks 1–2).
- Produces:
  - web `RisoSegmentedProps.lockedValues?: ReadonlyArray<T>`, `lockGlyphValues?: ReadonlyArray<T>` (`card` only; locked = `aria-disabled="true"`, no `onChange`, class `locked`)
  - web `<KindPicker value: CountKind; lock: KindPickerLock; onChange(kind: CountKind): void; size?: 'default' | 'compact'; id?: string />` — `aria-label="Kind"`
  - web `<KindTag kind: CountKind; counterName?: string; lifetime?: number />` — renders `Continuous ●● · Miles · 148.6 all-time` (name/total only when both given)
  - iOS `RisoSegmented(options:selection:…, lockedValues: Set<T> = [], lockGlyphValues: Set<T> = [])`
  - iOS `KindPickerView(selection: Binding<CountKind>, lock: KindPickerLock, size: RisoSegmentedSize = .regular, onRequest: ((CountKind) -> Void)? = nil)` — when `onRequest` is set, a tap calls it INSTEAD of writing the binding (the caller confirms then writes; Task 7)
  - iOS `KindTagView(kind: CountKind, counterName: String? = nil, lifetime: CountValue? = nil)`

- [ ] **Step 1: Write the failing web tests.** Append to `RisoSegmented.test.ts`:

```ts
  it('locks a segment: aria-disabled, no click handler, lock glyph only where asked', () => {
    const html = stripHash(
      render({
        options: [
          { value: 'discrete', label: 'Discrete' },
          { value: 'duration', label: 'Duration' },
        ],
        value: 'discrete',
        onChange: () => {},
        lockedValues: ['duration'],
        lockGlyphValues: ['duration'],
        'aria-label': 'Kind',
      }),
    );
    expect(html).toContain('<button type="button" class="seg locked" aria-pressed="false" aria-disabled="true">Duration');
    expect(html).toContain('class="lockGlyph"');
    expect(html.match(/lockGlyph/g)).toHaveLength(1);
  });

  it('renders unchanged when no lock props are passed', () => {
    const html = stripHash(render({ options: OPTIONS, value: 'one', onChange: () => {}, 'aria-label': 'Squares' }));
    expect(html).not.toContain('locked');
    expect(html).not.toContain('aria-disabled');
  });
```

Create `apps/web/src/components/counters/__tests__/KindPicker.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { KindPicker } from '../KindPicker';
import { KindTag } from '../KindTag';

const strip = (h: string) => h.replace(/_([A-Za-z][A-Za-z0-9]*)_[0-9a-f]{6}/g, '$1');
const pick = (props: Parameters<typeof KindPicker>[0]) => strip(renderToStaticMarkup(React.createElement(KindPicker, props)));

describe('KindPicker', () => {
  it('create: three live segments in order, labelled Kind', () => {
    const html = pick({ value: 'continuous', lock: 'none', onChange: () => {} });
    expect(html).toContain('aria-label="Kind"');
    expect(html.indexOf('Discrete')).toBeLessThan(html.indexOf('Continuous'));
    expect(html.indexOf('Continuous')).toBeLessThan(html.indexOf('Duration'));
    expect(html).not.toContain('aria-disabled');
  });
  it('existing continuous: duration locked out with a glyph', () => {
    const html = pick({ value: 'continuous', lock: 'duration', onChange: () => {} });
    expect(html.match(/aria-disabled="true"/g)).toHaveLength(1);
    expect(html.match(/lockGlyph/g)).toHaveLength(1);
  });
  it('existing duration: every segment locked, glyph on the selected one only', () => {
    const html = pick({ value: 'duration', lock: 'all', onChange: () => {} });
    expect(html.match(/aria-disabled="true"/g)).toHaveLength(3);
    expect(html.match(/lockGlyph/g)).toHaveLength(1);
  });
  it('never says Amount', () => {
    expect(pick({ value: 'discrete', lock: 'none', onChange: () => {} })).not.toContain('Amount');
  });
});

describe('KindTag', () => {
  it('kind + counter name + all-time total', () => {
    const html = strip(renderToStaticMarkup(React.createElement(KindTag, { kind: 'continuous', counterName: 'Miles', lifetime: 148.6 })));
    expect(html).toContain('Continuous');
    expect(html).toContain('Miles · 148.6 all-time');
  });
  it('kind only', () => {
    const html = strip(renderToStaticMarkup(React.createElement(KindTag, { kind: 'duration' })));
    expect(html).toContain('Duration');
    expect(html).not.toContain('all-time');
  });
});
```

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST RisoSegmented KindPicker`

- [ ] **Step 3: Implement web.** In `RisoSegmented.tsx` add to the props interface:

```ts
  /**
   * `card` only: values whose segment ignores taps — 45% opacity, not
   * hit-testable, `aria-disabled`. The counter-kind picker's locked states
   * (docs/COUNTER_KINDS.md §5). Omitted ⇒ unchanged markup.
   */
  lockedValues?: ReadonlyArray<T>;
  /** `card` only: values whose segment carries the lock glyph. */
  lockGlyphValues?: ReadonlyArray<T>;
```

and the button render:

```tsx
      {options.map((opt) => {
        const selected = opt.value === value;
        const locked = lockedValues?.includes(opt.value) ?? false;
        const glyph = lockGlyphValues?.includes(opt.value) ?? false;
        return (
          <button
            key={String(opt.value)}
            type="button"
            className={[styles.seg, selected ? styles.on : '', locked ? styles.locked : ''].filter(Boolean).join(' ')}
            aria-pressed={selected}
            aria-disabled={locked ? true : undefined}
            onClick={locked ? undefined : () => onChange(opt.value)}
          >
            {opt.label}
            {glyph && (
              <span className={styles.lockGlyph} aria-hidden="true">
                <RisoIcon name="lock" size={11} />
              </span>
            )}
          </button>
        );
      })}
```

(import `RisoIcon` from `./RisoIcon`). CSS:

```css
/* ---- card, locked segment (counter-kind picker) ---- */
.card .seg.locked { cursor: default; }
.card .seg.locked:not(.on) { opacity: 0.45; }
.card .seg.locked:hover:not(.on) { background: var(--riso-paper-2); }
.card .seg { display: inline-flex; align-items: center; justify-content: center; gap: 5px; }
.lockGlyph { display: inline-grid; place-items: center; margin-top: -1px; }
```

Create `KindPicker.tsx`:

```tsx
import {
  COUNT_KINDS,
  COUNT_KIND_LABELS,
  isKindSegmentLocked,
  kindSegmentShowsLock,
  type CountKind,
  type KindPickerLock,
} from '@oybc/shared';
import { RisoSegmented } from '../riso';

export interface KindPickerProps {
  /** The selected kind. */
  value: CountKind;
  /** Lock state — `kindPickerLock(mode, kind)`. */
  lock: KindPickerLock;
  /** Called with a live (unlocked) segment's kind. The caller confirms Continuous → Discrete (Task 7). */
  onChange: (kind: CountKind) => void;
  /** `compact` for dense rows (compound sub-task, pool row). */
  size?: 'default' | 'compact';
}

/**
 * The one counter-kind picker (docs/COUNTER_KINDS.md §5) — a full-width
 * three-segment card `RisoSegmented` with the D4 lock states. iOS twin:
 * `KindPickerView`.
 *
 * @returns The picker.
 */
export function KindPicker({ value, lock, onChange, size = 'default' }: KindPickerProps): React.ReactElement {
  return (
    <RisoSegmented<CountKind>
      aria-label="Kind"
      variant="card"
      fullWidth
      size={size}
      options={COUNT_KINDS.map((k) => ({ value: k, label: COUNT_KIND_LABELS[k] }))}
      value={value}
      onChange={onChange}
      lockedValues={COUNT_KINDS.filter((k) => isKindSegmentLocked(lock, k))}
      lockGlyphValues={COUNT_KINDS.filter((k) => kindSegmentShowsLock(lock, k, value))}
    />
  );
}
```

Create `KindTag.tsx`:

```tsx
import { COUNT_KIND_LABELS, formatCountTotal, type CountKind } from '@oybc/shared';
import styles from './KindPicker.module.css';

export interface KindTagProps {
  kind: CountKind;
  /** The family's counter name (linked rows / auto-linking creates). */
  counterName?: string;
  /** The family's all-time total. */
  lifetime?: number;
}

/**
 * A linked row's kind: no picker, the family's kind (D5) — kind chip with the
 * shared-counter dots, then "{counter} · {all-time} all-time".
 *
 * @returns The tag row.
 */
export function KindTag({ kind, counterName, lifetime }: KindTagProps): React.ReactElement {
  return (
    <div className={styles.tagRow}>
      <span className={styles.tag}>
        {COUNT_KIND_LABELS[kind]}
        <span className={styles.dots} aria-hidden="true"><i /><i /></span>
      </span>
      {counterName && lifetime !== undefined && (
        <span className={styles.tagMeta}>{`${counterName} · ${formatCountTotal(lifetime, kind)} all-time`}</span>
      )}
    </div>
  );
}
```

`KindPicker.module.css`:

```css
.tagRow { display: flex; align-items: center; gap: 8px; min-height: 38px; }
.tag {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 6px 10px; border: 2px solid var(--riso-ink); border-radius: var(--riso-r-card);
  background: var(--riso-blue); color: var(--riso-on-color);
  font-family: var(--riso-font-head); font-size: 12px; font-weight: 700;
}
.dots { display: inline-flex; gap: 2px; }
.dots i { width: 5px; height: 5px; border-radius: 50%; background: var(--riso-on-color); }
.tagMeta { font-family: var(--riso-font-body); font-size: 12px; font-weight: 600; color: var(--riso-muted); }
```

- [ ] **Step 4: Run** `WEB_TEST RisoSegmented KindPicker` — expect PASS; `WEB_CHECK`.

- [ ] **Step 5: iOS — write the snapshot test first.** Append to `RisoKitSnapshotTests.swift`:

```swift
    // MARK: - Counter kinds (PR 3) — the four picker states of handoff §1

    private func kindPickerStates() -> some View {
        KindPickerStatesPreview()
            .padding(16)
            .background(Color.risoPaper)
            .frame(width: 353, height: 230)
    }

    func testKindPickerStatesLight() {
        assertSnapshot(of: kindPickerStates(), as: .image(layout: .fixed(width: 353, height: 230)), record: recordMode)
    }

    func testKindPickerStatesDark() {
        assertSnapshot(
            of: kindPickerStates(),
            as: .image(layout: .fixed(width: 353, height: 230), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }
```

and at the bottom of the file:

```swift
/// New (all live) · existing Continuous (Duration locked out) · existing
/// Duration (locked in) · linked tag — handoff `Counter Kinds.dc.html` §1.
private struct KindPickerStatesPreview: View {
    @State private var a: CountKind = .continuous
    @State private var b: CountKind = .continuous
    @State private var c: CountKind = .duration
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KindPickerView(selection: $a, lock: .none)
            KindPickerView(selection: $b, lock: .duration)
            KindPickerView(selection: $c, lock: .all)
            KindTagView(kind: .continuous, counterName: "Miles", lifetime: 148.6)
        }
    }
}
```

- [ ] **Step 6: Run — expect build FAIL** (`cannot find 'KindPickerView'`). `IOS_SNAP -only-testing:OYBCSnapshotTests/RisoKitSnapshotTests`

- [ ] **Step 7: Implement iOS.** In `RisoControls.swift` `RisoSegmented` add stored properties (defaulted, so every existing call compiles unchanged):

```swift
    /// `.card` only: values that ignore taps — 45% opacity, lock glyph per
    /// `lockGlyphValues` (counter-kind picker, docs/COUNTER_KINDS.md §5).
    var lockedValues: Set<T> = []
    var lockGlyphValues: Set<T> = []
```

and in `cardBody` replace the `Button { selection = opt.value } label: { Text(opt.label) …` with:

```swift
            ForEach(options, id: \.value) { opt in
                let locked = lockedValues.contains(opt.value)
                Button { if !locked { selection = opt.value } } label: {
                    HStack(spacing: 5) {
                        Text(opt.label)
                            .font(.risoHead(13, .bold))
                            .lineLimit(equalWidth ? nil : 1)
                        if lockGlyphValues.contains(opt.value) {
                            Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold))
                        }
                    }
                    .foregroundStyle(selection == opt.value ? Color.risoPaper : Color.risoInk)
                    .frame(maxWidth: equalWidth ? .infinity : nil)
                    .padding(.vertical, 10)
                    .padding(.horizontal, equalWidth ? 0 : 14)
                    .background(
                        RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .fill(selection == opt.value ? selectedFill(opt.value) : Color.risoPaper2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                    )
                    .opacity(locked && selection != opt.value ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!locked)
                .accessibilityAddTraits(locked ? [.isStaticText] : [])
            }
```

(An `HStack` around a single `Text` lays out identically, so existing `.card` snapshots stay green — the gallery re-record below is only for the new section.)

Create `apps/ios/OYBC/Views/Riso/KindPickerView.swift`:

```swift
import SwiftUI

/// The one counter-kind picker (docs/COUNTER_KINDS.md §5): a three-segment
/// card `RisoSegmented` with the D4 lock states. Web twin: `KindPicker.tsx`.
///
/// When `onRequest` is set a tap on a live segment calls it instead of
/// writing `selection`, so the caller can confirm Continuous → Discrete
/// (`KindSwitchConfirmView`, Task 7) and write the binding itself.
struct KindPickerView: View {
    @Binding var selection: CountKind
    let lock: KindPickerLock
    var onRequest: ((CountKind) -> Void)? = nil

    var body: some View {
        RisoSegmented(
            options: CountKind.allCases.map { (value: $0, label: $0.label) },
            selection: Binding(
                get: { selection },
                set: { next in
                    guard next != selection else { return }
                    if let onRequest { onRequest(next) } else { selection = next }
                }
            ),
            lockedValues: Set(CountKind.allCases.filter { isKindSegmentLocked(lock, segment: $0) }),
            lockGlyphValues: Set(CountKind.allCases.filter { kindSegmentShowsLock(lock, segment: $0, selected: selection) })
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kind")
    }
}

/// A linked row's kind (D5): kind chip + shared dots, then
/// "{counter} · {all-time} all-time". Never a picker.
struct KindTagView: View {
    let kind: CountKind
    var counterName: String? = nil
    var lifetime: CountValue? = nil

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(kind.label).font(.risoHead(12, .bold))
                HStack(spacing: 2) {
                    Circle().frame(width: 5, height: 5)
                    Circle().frame(width: 5, height: 5)
                }
                .accessibilityHidden(true)
            }
            .foregroundStyle(Color.risoPaper)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoBlue))
            .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
            if let counterName, let lifetime {
                Text("\(counterName) · \(formatCountTotal(lifetime, kind: kind)) all-time")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 38, alignment: .leading)
    }
}
```

(`Color.risoPaper` on blue follows the iOS on-colour divergence — CLAUDE.md C8.) Add to `RisoKitGallery.swift` a `section("Kind picker") { KindPickerView(selection: $sampleKind, lock: .duration) }` with `@State private var sampleKind: CountKind = .continuous` — follow the gallery's existing `section` helper.

- [ ] **Step 8: Record + verify.** `cd apps/ios && xcodegen generate`; delete `__Snapshots__/RisoKitSnapshotTests/testKitLight.1.png` and `testKitDark.1.png`; run `IOS_SNAP -only-testing:OYBCSnapshotTests/RisoKitSnapshotTests` twice (record, then green). Read the four new / re-recorded PNGs: the existing gallery sections must be pixel-identical above the new section; the states preview must match handoff §1 (45% Duration, lock glyph placement). Every other `RisoKitSnapshotTests` test must stay green unmodified (it proves the `.card` change is invisible).

- [ ] **Step 9: Commit**

```bash
git add apps/web/src/components/riso apps/web/src/components/counters apps/ios/OYBC/Views/Riso apps/ios/OYBCSnapshotTests apps/ios/OYBC.xcodeproj/project.pbxproj
git commit -m "feat(counters): KindPicker + KindTag on RisoSegmented locked segments, both platforms (PR 3 Task 3)"
```

---

### Task 4: GoalEntry — the one amount field (both platforms)

**Files:**
- Create: `apps/web/src/components/counters/GoalEntry.tsx`, `GoalEntry.module.css`
- Test: `apps/web/src/components/counters/__tests__/GoalEntry.test.ts` (create)
- Modify: `apps/ios/OYBC/Views/Riso/RisoControls.swift:367-378` (`RisoNumberField` +`keyboard: UIKeyboardType = .numberPad`)
- Create: `apps/ios/OYBC/Views/Riso/GoalEntryView.swift`
- Test: `apps/ios/OYBCSnapshotTests/RisoKitSnapshotTests.swift` (+`testGoalEntryKinds{Light,Dark}`), `apps/ios/OYBCTests/GoalEntryModelTests.swift` (create)

**Interfaces:**
- Consumes: `parseCountInput`, `durationToFields`, `durationFromFields`, `formatCountForInput` (Tasks 1–2).
- Produces:
  - web `<GoalEntry kind: CountKind; value: string; onChange(next: string): void; id?: string; 'aria-label'?: string; placeholder?: string; suffix?: string; dense?: boolean; invalid?: boolean; autoFocus?: boolean; onEnter?: () => void />` — `value` is the field string in `parseCountInput` grammar (Duration: `'Xh Ym'` or `''`).
  - web `goalEntryInputMode(kind): 'numeric' | 'decimal'` (exported from `GoalEntry.tsx`'s sibling `goalEntryModel.ts` to keep the component file component-only)
  - iOS `RisoNumberField(placeholder:text:keyboard:)`
  - iOS `GoalEntryView(kind: CountKind, text: Binding<String>, placeholder: String? = nil, suffix: String? = nil, startsOpen: Bool = false)` — Duration shows the formatted value + chevron; tapping toggles an inline wheel (hours 0…999, minutes 0…59, 1-minute steps) that writes `formatCountForInput(h*60+m, kind: .duration)` (or `""` at 0h 0m).
  - iOS `enum GoalEntryModel { static func keyboard(for: CountKind) -> UIKeyboardType; static func wheelFields(_ text: String) -> (hours: Int, minutes: Int); static func text(hours: Int, minutes: Int) -> String }`

- [ ] **Step 1: Write the failing web test** `GoalEntry.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { GoalEntry } from '../GoalEntry';
import { goalEntryInputMode } from '../goalEntryModel';

const html = (p: Parameters<typeof GoalEntry>[0]) => renderToStaticMarkup(React.createElement(GoalEntry, p));

describe('GoalEntry', () => {
  it('discrete: one numeric text field', () => {
    const h = html({ kind: 'discrete', value: '300', onChange: () => {}, 'aria-label': 'Goal' });
    expect(h).toContain('inputMode="numeric"');
    expect(h).toContain('type="text"');
    expect(h).toContain('value="300"');
  });
  it('continuous: decimal keypad, unit suffix', () => {
    const h = html({ kind: 'continuous', value: '26.2', onChange: () => {}, suffix: 'mi', 'aria-label': 'Goal' });
    expect(h).toContain('inputMode="decimal"');
    expect(h).toContain('>mi<');
  });
  it('duration: two fields seeded from the value, labelled h and m', () => {
    const h = html({ kind: 'duration', value: '10h 30m', onChange: () => {}, 'aria-label': 'Goal' });
    expect(h).toContain('aria-label="Goal hours"');
    expect(h).toContain('aria-label="Goal minutes"');
    expect(h).toContain('value="10"');
    expect(h).toContain('value="30"');
    expect(h).not.toContain('>mi<');
  });
  it('input modes per kind', () => {
    expect(goalEntryInputMode('discrete')).toBe('numeric');
    expect(goalEntryInputMode('continuous')).toBe('decimal');
    expect(goalEntryInputMode('duration')).toBe('numeric');
  });
});
```

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST GoalEntry`

- [ ] **Step 3: Implement web.** `apps/web/src/components/counters/goalEntryModel.ts`:

```ts
import type { CountKind } from '@oybc/shared';

/**
 * The soft keyboard a kind's field asks for: decimal only for continuous
 * (iOS Safari then shows the locale's separator key).
 *
 * @param kind - The counter's kind.
 * @returns The `inputMode` attribute value.
 */
export function goalEntryInputMode(kind: CountKind): 'numeric' | 'decimal' {
  return kind === 'continuous' ? 'decimal' : 'numeric';
}
```

`GoalEntry.tsx`:

```tsx
import { useState } from 'react';
import { durationFromFields, durationToFields, parseCountInput, type CountKind } from '@oybc/shared';
import { goalEntryInputMode } from './goalEntryModel';
import styles from './GoalEntry.module.css';

export interface GoalEntryProps {
  kind: CountKind;
  /** Field text in `parseCountInput` grammar (Duration: `'Xh Ym'` or `''`). */
  value: string;
  onChange: (next: string) => void;
  id?: string;
  'aria-label'?: string;
  placeholder?: string;
  /** Unit text inside the field's right edge (Discrete / Continuous only). */
  suffix?: string;
  dense?: boolean;
  invalid?: boolean;
  autoFocus?: boolean;
  /** Enter key — the custom-amount rows commit on it. */
  onEnter?: () => void;
}

/**
 * The one amount-entry field (docs/COUNTER_KINDS.md §5): numeric for
 * Discrete, decimal for Continuous, two `[h] h [m] m` fields for Duration.
 * Text-typed (never `type="number"`) so `,` decimals and partial entries
 * survive typing; callers validate with `parseCountInput`. iOS twin:
 * `GoalEntryView`.
 *
 * @returns The field.
 */
export function GoalEntry(props: GoalEntryProps): React.ReactElement {
  const { kind, value, onChange, id, placeholder, suffix, dense, invalid, autoFocus, onEnter } = props;
  const label = props['aria-label'];
  const fieldClass = [styles.field, dense ? styles.dense : '', invalid ? styles.invalid : ''].filter(Boolean).join(' ');
  const onKeyDown = (e: React.KeyboardEvent<HTMLInputElement>): void => {
    if (e.key === 'Enter' && onEnter) { e.preventDefault(); onEnter(); }
  };
  if (kind === 'duration') {
    return <DurationFields {...{ value, onChange, id, label, fieldClass, autoFocus, onKeyDown }} />;
  }
  return (
    <span className={fieldClass}>
      <input
        id={id}
        type="text"
        inputMode={goalEntryInputMode(kind)}
        className={styles.input}
        value={value}
        placeholder={placeholder ?? '100'}
        aria-label={label}
        aria-invalid={invalid || undefined}
        autoFocus={autoFocus}
        onChange={(e) => onChange(e.target.value)}
        onKeyDown={onKeyDown}
      />
      {suffix && <span className={styles.suffix}>{suffix}</span>}
    </span>
  );
}

function DurationFields(p: {
  value: string; onChange: (v: string) => void; id?: string; label?: string;
  fieldClass: string; autoFocus?: boolean; onKeyDown: (e: React.KeyboardEvent<HTMLInputElement>) => void;
}): React.ReactElement {
  // Local field text so "1" then "15" in minutes doesn't re-normalise mid-typing;
  // re-seeded only when the parent's value stops matching what we emitted.
  const [fields, setFields] = useState(() => durationToFields(parseCountInput(p.value, 'duration', { allowZero: true })));
  const emitted = durationFromFields(fields.hours, fields.minutes);
  const external = parseCountInput(p.value, 'duration', { allowZero: true });
  if (external !== parseCountInput(emitted, 'duration', { allowZero: true }) && !(p.value === '' && emitted === '')) {
    setFields(durationToFields(external));
  }
  const set = (next: { hours: string; minutes: string }): void => {
    setFields(next);
    p.onChange(durationFromFields(next.hours, next.minutes));
  };
  return (
    <span className={styles.duration}>
      <span className={p.fieldClass}>
        <input id={p.id} type="text" inputMode="numeric" className={styles.input} value={fields.hours} placeholder="0"
          aria-label={p.label ? `${p.label} hours` : 'Hours'} autoFocus={p.autoFocus}
          onChange={(e) => set({ ...fields, hours: e.target.value })} onKeyDown={p.onKeyDown} />
      </span>
      <span className={styles.unit} aria-hidden="true">h</span>
      <span className={p.fieldClass}>
        <input type="text" inputMode="numeric" className={styles.input} value={fields.minutes} placeholder="00"
          aria-label={p.label ? `${p.label} minutes` : 'Minutes'}
          onChange={(e) => set({ ...fields, minutes: e.target.value })} onKeyDown={p.onKeyDown} />
      </span>
      <span className={styles.unit} aria-hidden="true">m</span>
    </span>
  );
}
```

(The render-phase `setFields` is React's documented "adjust state on prop change" pattern; it runs before paint, so no post-paint mutation — `reference_late_mutation_bug_class`.) CSS — reuse the form input look of `CreateNewTaskForm.module.css .input`:

```css
.field {
  display: flex; align-items: center; gap: 8px; flex: 1 1 0; min-width: 0;
  padding: 12px 14px; box-sizing: border-box;
  background: var(--riso-paper); border: 2px solid var(--riso-ink); border-radius: var(--riso-r-card);
}
.field:focus-within { outline: 3px solid var(--riso-blue); outline-offset: 1px; }
.dense { padding: 11px 12px; }
.invalid { border-color: var(--riso-red); }
.input {
  flex: 1; min-width: 0; border: 0; padding: 0; background: transparent; outline: none;
  font-family: var(--riso-font-body); font-size: 15px; font-weight: 500; color: var(--riso-ink);
}
.suffix { font-size: 12px; font-weight: 600; color: var(--riso-muted); }
.duration { display: flex; align-items: center; gap: 8px; width: 100%; }
.unit { font-family: var(--riso-font-head); font-size: 13px; font-weight: 700; color: var(--riso-muted); }
```

- [ ] **Step 4: Run** `WEB_TEST GoalEntry` — PASS; `WEB_CHECK`.

- [ ] **Step 5: iOS — failing tests first.** `apps/ios/OYBCTests/GoalEntryModelTests.swift`:

```swift
import XCTest
@testable import OYBC

final class GoalEntryModelTests: XCTestCase {
    func testKeyboards() {
        XCTAssertEqual(GoalEntryModel.keyboard(for: .discrete), .numberPad)
        XCTAssertEqual(GoalEntryModel.keyboard(for: .continuous), .decimalPad)
        XCTAssertEqual(GoalEntryModel.keyboard(for: .duration), .numberPad)
    }
    func testWheelRoundTrip() {
        XCTAssertEqual(GoalEntryModel.wheelFields("10h 30m").hours, 10)
        XCTAssertEqual(GoalEntryModel.wheelFields("10h 30m").minutes, 30)
        XCTAssertEqual(GoalEntryModel.wheelFields("").hours, 0)
        XCTAssertEqual(GoalEntryModel.text(hours: 2, minutes: 40), "2h 40m")
        XCTAssertEqual(GoalEntryModel.text(hours: 0, minutes: 0), "", "0h 0m is no entry, never a 0 goal")
        XCTAssertEqual(parseCountInput(GoalEntryModel.text(hours: 1, minutes: 5), kind: .duration), 65)
    }
}
```

Snapshot (append to `RisoKitSnapshotTests.swift`):

```swift
    private func goalEntryKinds() -> some View {
        GoalEntryKindsPreview().padding(16).background(Color.risoPaper).frame(width: 353, height: 300)
    }
    func testGoalEntryKindsLight() {
        assertSnapshot(of: goalEntryKinds(), as: .image(layout: .fixed(width: 353, height: 300)), record: recordMode)
    }
    func testGoalEntryKindsDark() {
        assertSnapshot(of: goalEntryKinds(), as: .image(layout: .fixed(width: 353, height: 300), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }
```

```swift
/// Discrete 300 · Continuous 26.2 · Duration 10h 30m with the wheel open — handoff §1 "Amount entry".
private struct GoalEntryKindsPreview: View {
    @State private var d = "300"
    @State private var c = "26.2"
    @State private var t = "10h 30m"
    var body: some View {
        VStack(spacing: 8) {
            GoalEntryView(kind: .discrete, text: $d)
            GoalEntryView(kind: .continuous, text: $c, suffix: "mi")
            GoalEntryView(kind: .duration, text: $t, startsOpen: true)
        }
    }
}
```

- [ ] **Step 6: Run — expect build FAIL.** `IOS_TEST -only-testing:OYBCTests/GoalEntryModelTests`

- [ ] **Step 7: Implement iOS.** `RisoNumberField`:

```swift
struct RisoNumberField: View {
    let placeholder: String
    @Binding var text: String
    /// `.numberPad` (default — every pre-kind caller) or `.decimalPad` for
    /// Continuous (`GoalEntryModel.keyboard(for:)`).
    var keyboard: UIKeyboardType = .numberPad

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(keyboard)
            .fieldStyle()
    }
}
```

`GoalEntryView.swift`:

```swift
import SwiftUI

/// Pure helpers behind `GoalEntryView` (unit-tested without a view).
enum GoalEntryModel {
    /// Decimal pad only for Continuous.
    static func keyboard(for kind: CountKind) -> UIKeyboardType { kind == .continuous ? .decimalPad : .numberPad }

    /// Field text → wheel columns (0/0 when blank or invalid).
    static func wheelFields(_ text: String) -> (hours: Int, minutes: Int) {
        let total = Int(parseCountInput(text, kind: .duration, allowZero: true) ?? 0)
        return (total / 60, total % 60)
    }

    /// Wheel columns → field text; 0h 0m is "" (no entry), never a 0 goal.
    static func text(hours: Int, minutes: Int) -> String {
        let total = hours * 60 + minutes
        return total == 0 ? "" : formatCountForInput(CountValue(total), kind: .duration)
    }
}

/// The one amount-entry field (docs/COUNTER_KINDS.md §5). Discrete / Continuous
/// wrap `RisoNumberField` with the kind's keypad and an optional unit suffix;
/// Duration shows the value with a chevron and an inline h / min wheel
/// (1-minute steps — owner rule). `text` is in `parseCountInput` grammar.
/// Web twin: `GoalEntry.tsx`.
struct GoalEntryView: View {
    let kind: CountKind
    @Binding var text: String
    var placeholder: String? = nil
    var suffix: String? = nil
    var startsOpen: Bool = false

    @State private var wheelOpen = false

    var body: some View {
        if kind == .duration { durationBody } else { numericBody }
    }

    private var numericBody: some View {
        ZStack(alignment: .trailing) {
            RisoNumberField(placeholder: placeholder ?? "100", text: $text, keyboard: GoalEntryModel.keyboard(for: kind))
            if let suffix, !suffix.isEmpty {
                Text(suffix)
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .padding(.trailing, 11)
                    .allowsHitTesting(false)
            }
        }
    }

    private var durationBody: some View {
        VStack(spacing: 8) {
            Button { wheelOpen.toggle() } label: {
                HStack {
                    Text(text.isEmpty ? (placeholder ?? "0h 0m") : formatCount(parseCountInput(text, kind: .duration, allowZero: true) ?? 0, kind: .duration))
                        .font(.risoHead(14, .bold))
                        .foregroundStyle(text.isEmpty ? Color.risoMuted : Color.risoInk)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.risoMuted)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.horizontal, 11)
                .frame(minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.risoPaper))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Duration, \(text.isEmpty ? "not set" : text)")
            if isOpen { wheel }
        }
    }

    private var isOpen: Bool { wheelOpen || startsOpen }

    private var wheel: some View {
        let fields = GoalEntryModel.wheelFields(text)
        return HStack(spacing: 0) {
            Picker("Hours", selection: Binding(
                get: { fields.hours },
                set: { text = GoalEntryModel.text(hours: $0, minutes: GoalEntryModel.wheelFields(text).minutes) }
            )) {
                ForEach(0...999, id: \.self) { Text("\($0) hours").tag($0) }
            }
            Picker("Minutes", selection: Binding(
                get: { fields.minutes },
                set: { text = GoalEntryModel.text(hours: GoalEntryModel.wheelFields(text).hours, minutes: $0) }
            )) {
                ForEach(0..<60, id: \.self) { Text("\($0) min").tag($0) }
            }
        }
        .pickerStyle(.wheel)
        .frame(height: 132)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.risoPaper2))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.risoInk.opacity(0.35), lineWidth: 1.5))
    }
}
```

(There is no `risoHair` token on iOS; `risoInk.opacity(0.35)` is the kit's existing hairline — the idle chip border in `RisoCountingStepperSheet`. Never add a colour.)

- [ ] **Step 8: Run + record.** `cd apps/ios && xcodegen generate`; `IOS_TEST -only-testing:OYBCTests/GoalEntryModelTests` PASS; `IOS_SNAP -only-testing:OYBCSnapshotTests/RisoKitSnapshotTests` twice; read the two new PNGs against handoff §1 (wheel 132pt, `hours`/`min` captions). `RisoNumberField`'s new defaulted parameter must not change any other baseline — run the full `IOS_SNAP` once and diff the red SET against the standing reds.

- [ ] **Step 9: Commit**

```bash
git add apps/web/src/components/counters apps/ios/OYBC/Views/Riso apps/ios/OYBCTests apps/ios/OYBCSnapshotTests apps/ios/OYBC.xcodeproj/project.pbxproj
git commit -m "feat(counters): GoalEntry — numeric / decimal / h:m amount field, both platforms (PR 3 Task 4)"
```

---
### Task 5: A1 — special panel / Create New Task form (kind row, linked tag, Duration without unit)

**Files:**
- Modify: `packages/shared/src/algorithms/linkableCounter.ts:28-41,109-114` (`LinkableCounter.countKind`) + `apps/ios/OYBC/Helpers/LinkableCounter.swift:34-46,114-119` (`LinkableCounterSuggestion.countKind`); tests `packages/shared/tests/algorithms/linkableCounter.test.ts`, `apps/ios/OYBCTests/LinkableCounterTests.swift` (whichever exists — `ls apps/ios/OYBCTests | grep -i linkable`)
- Modify: `apps/web/src/pages/createPage/useCreateFormState.ts` (`countKind` state + setter; `validateForm` at `:75-123` kind-aware; the two COUNTING create branches at `:511-540` and `:606-625` pass `countKind`; `resetCountingFields` clears it)
- Modify: `apps/web/src/pages/createPage/CreateNewTaskForm.tsx:129-130` (`goalValid` via `parseCountInput`), `:398-468` (Verb → Kind → Goal · Unit; Unit hidden for Duration; title preview kind-aware), `:152-200` (linked submit passes the root kind); remove the #548 captions at `:269` (Achievement explainer paragraph) and `:374` (`helpText` "Greenlog — …") — rows 67/68
- Modify: `apps/web/src/components/counters/CounterLinkHint.tsx` — drop both sentences (#548 rows 77/78): render the pill only, `aria-label` "Link to {counter}" / "Don't link to {counter}"
- Modify: `apps/ios/OYBC/Views/CreateTab/ViewModels/CreateFormViewModel.swift:109-131` (+`var countingKind: CountKind = .discrete`), `:254-284` (validation), `:319-326` (title), `:780-792` (`buildCreateTask` sets `countKind`), `:429-466` (resets)
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/RisoSpecialTaskPanel.swift:199-356` (kind state, row, goal field, unit hidden, linked tag, submit)
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/RisoCounterLinkHintView.swift:40-50` — drop both sentences (rows 77/78), keep the pill
- Test: `apps/web/src/pages/createPage/__tests__/useCreateFormState.countKind.test.ts` (create), `apps/web/src/pages/createPage/__tests__/CreateNewTaskForm.countKind.test.ts` (create), `apps/ios/OYBCTests/CreateFormViewModelCountKindTests.swift` (create), `apps/ios/OYBCSnapshotTests/RisoSpecialPanelCountingSnapshotTests.swift` (create), e2e `apps/web/e2e/counter-kinds-authoring.spec.ts` (create)
- Re-record (intentional — #548 caption removal in compound panels using the link hint): `RisoCompoundPanelSnapshotTests/testCompoundNewSubCountingLinked{Light,Dark}`, `testCompoundNewSubCountingOptedOut{Light,Dark}`

**Interfaces:**
- Consumes: `KindPicker`, `KindTag`, `GoalEntry` (Tasks 3–4); `parseCountInput`, `countKindNeedsUnit`, `generateCounterTaskTitle(…, countKind)` (Task 1).
- Produces:
  - `LinkableCounter.countKind: CountKind` / `LinkableCounterSuggestion.countKind: CountKind` (= `resolveCountKind(best)`)
  - web `UseCreateFormState.countKind: CountKind`, `setCountKind(kind: CountKind): void`; `validateForm(type, title, description, action, unit, maxCountStr, achievementMode?, achievementReferenceId?, achievementRequiredCountStr?, countKind: CountKind = 'discrete')`
  - iOS `CreateFormViewModel.countingKind: CountKind`
  - Rule: an auto-linking create saves the ROOT's kind and shows `KindTag` in place of the picker; tapping "Don't link" restores the picker at the user's last chosen kind.

- [ ] **Step 1: Failing web tests.** `useCreateFormState.countKind.test.ts` (the hook's `validateForm` is exported — test it directly, plus a create through Dexie with `fake-indexeddb` the way `apps/web/src/pages/createPage/__tests__` already does; copy that folder's setup/teardown verbatim):

```ts
import { describe, expect, it } from 'vitest';
import { TaskType } from '@oybc/shared';
import { validateForm } from '../useCreateFormState';

const counting = (overrides: Partial<{ action: string; unit: string; goal: string; kind: 'discrete' | 'continuous' | 'duration' }>) => {
  const o = { action: 'Run', unit: 'miles', goal: '26.2', kind: 'continuous' as const, ...overrides };
  // validateForm(type, title, description, action, unit, maxCountStr, achievementMode?, achievementReferenceId?,
  // achievementRequiredCountStr?, countKind?) — countKind is the new trailing parameter.
  return validateForm(TaskType.COUNTING, '', '', o.action, o.unit, o.goal, undefined, undefined, undefined, o.kind);
};

describe('validateForm — counter kinds', () => {
  it('continuous accepts a 1- and 2-place goal, refuses 3', () => {
    expect(counting({ goal: '26.2' }).maxCount).toBeUndefined();
    expect(counting({ goal: '12.75' }).maxCount).toBeUndefined();
    expect(counting({ goal: '3.125' }).maxCount).toBe('Goal must be a number above zero with up to 2 decimals');
  });
  it('discrete keeps the whole-number message', () => {
    expect(counting({ kind: 'discrete', goal: '2.5' }).maxCount).toBe('Goal must be a positive integer');
  });
  it('duration needs no unit and takes h:m', () => {
    const e = counting({ kind: 'duration', unit: '', goal: '10h 30m' });
    expect(e.unit).toBeUndefined();
    expect(e.maxCount).toBeUndefined();
    expect(counting({ kind: 'duration', unit: '', goal: '1.5h' }).maxCount).toBe('Goal must be a duration above zero');
  });
});
```

(`validateForm`'s real signature is `useCreateFormState.ts:75-85`; the call above matches it. The hook's own call site passes `countKind` as the new 10th argument.)

`CreateNewTaskForm.countKind.test.ts` — render with `renderToStaticMarkup` and a stub `form` object (the component is presentational, `CreateNewTaskFormProps.form` is the hook's return type; build it with `{ ...defaultFormStub, taskType: TaskType.COUNTING, countKind: 'duration' }` where `defaultFormStub` is constructed in the test file from the `UseCreateFormState` keys):

```ts
it('duration hides the Counting (unit) field and shows h / m fields', () => {
  const html = render({ taskType: TaskType.COUNTING, countKind: 'duration', action: 'Practice', maxCountStr: '10h 30m' });
  expect(html).toContain('aria-label="Kind"');
  expect(html).not.toContain('id="create-task-unit"');
  expect(html).toContain('aria-label="Goal hours"');
  expect(html).toContain('Practice 10h 30m');
});
it('continuous shows the decimal goal field and the unit', () => {
  const html = render({ taskType: TaskType.COUNTING, countKind: 'continuous', action: 'Run', unit: 'miles', maxCountStr: '26.2' });
  expect(html).toContain('inputMode="decimal"');
  expect(html).toContain('id="create-task-unit"');
  expect(html).toContain('Run 26.2 miles');
});
it('no Greenlog/Bingo explainer sentence (#548 row 68)', () => {
  const html = render({ taskType: TaskType.ACHIEVEMENT });
  expect(html).not.toContain('the whole board is completed');
});
```

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST useCreateFormState.countKind CreateNewTaskForm.countKind`

- [ ] **Step 3: Implement web.**
  - `linkableCounter.ts`: add `/** The counter's kind (D5) — a linked create takes it. */ countKind: CountKind;` to `LinkableCounter` and `countKind: resolveCountKind(best),` in the return (`:109-114`).
  - `useCreateFormState.ts`: `const [countKind, setCountKind] = useState<CountKind>('discrete');` beside `maxCountStr` (`:286`); expose both on the returned object and in `UseCreateFormState`; reset to `'discrete'` wherever `setMaxCountStr('')` runs in the reset helpers (`:405`, `:413`). `validateForm` counting branch:

```ts
    if (countKindNeedsUnit(countKind)) {
      if (unit.trim().length === 0) {
        errors.unit = 'Counting is required';
      } else if (unit.trim().length > UNIT_MAX_LENGTH) {
        errors.unit = `Counting must be ${UNIT_MAX_LENGTH} characters or less`;
      }
    }

    if (maxCountStr.trim().length === 0) {
      errors.maxCount = 'Goal is required';
    } else if (parseCountInput(maxCountStr, countKind) === null) {
      errors.maxCount =
        countKind === 'discrete'
          ? 'Goal must be a positive integer'
          : countKind === 'continuous'
            ? 'Goal must be a number above zero with up to 2 decimals'
            : 'Goal must be a duration above zero';
    }
```

    Both COUNTING create branches replace `parseInt(maxCountStr, 10)` with `parseCountInput(maxCountStr, countKind) as number` (validation already passed), pass `countKind` as `generateCounterTaskTitle`'s 5th argument, write `unit: countKindNeedsUnit(countKind) ? unit.trim() : ''`, and add `...(countKind !== 'discrete' ? { countKind } : {})` (the pending payload literal at `:519-540` and the `createTask` input at `:613-625`). Add `countKind` to the `useCallback` dependency list at `:667`.
  - `CreateNewTaskForm.tsx`: `const parsedMaxCount = parseCountInput(form.maxCountStr, form.countKind); const goalValid = parsedMaxCount !== null;` (`:129-130`). The counter match ignores Duration: `form.taskType === TaskType.COUNTING && form.countKind !== 'duration' && trimmedAction && trimmedUnit`. Effective kind: `const effectiveKind = linkHint?.linked ? linkHint.match.countKind : form.countKind;`. Between the Verb `fieldGroup` and the Goal `fieldGroup` insert:

```tsx
              <div className={styles.fieldGroup}>
                <span className={styles.label}>Kind</span>
                {linkHint?.linked ? (
                  <KindTag kind={linkHint.match.countKind} counterName={linkHint.match.name} lifetime={linkHint.match.lifetime} />
                ) : (
                  <KindPicker value={form.countKind} lock="none" onChange={form.setCountKind} />
                )}
              </div>
```

    Replace the Goal `<input type="number" …>` with:

```tsx
                <GoalEntry
                  id="create-task-maxcount"
                  aria-label="Goal"
                  kind={effectiveKind}
                  value={form.maxCountStr}
                  onChange={form.setMaxCountStr}
                  placeholder={effectiveKind === 'duration' ? '0h 0m' : '100'}
                  invalid={Boolean(form.errors.maxCount)}
                />
```

    Wrap the Counting (unit) `fieldGroup` in `{countKindNeedsUnit(effectiveKind) && ( … )}`. Title preview: `{goalValid && trimmedAction && (trimmedUnit || effectiveKind === 'duration') && ( … generateCounterTaskTitle(trimmedAction, parsedMaxCount, trimmedUnit, undefined, effectiveKind) … )}`. In `handleFormSubmit` the linked branch's `finalTitle` passes `sourceTask.countKind ?? 'discrete'` as the 5th argument and `maxCount: parsedMaxCount as number`. Delete the Achievement explainer `<p>` at `:269` and the `<span className={styles.helpText}>Greenlog — … </span>` at `:374` (delete the nodes, not just the text; drop any now-unused `helpText` CSS class).
  - `CounterLinkHint.tsx`: replace the `hintText` block with nothing and give the pill `aria-label={linked ? `Don't link to ${counterName}` : `Link to ${counterName}`}`; delete the `lifetime` / `goal` props (no longer rendered) and update every call site (`grep -rn "<CounterLinkHint" apps/web/src`) — TypeScript flags each. The Kind row's `KindTag` now carries the counter name and total.

- [ ] **Step 4: Run** `WEB_TEST useCreateFormState CreateNewTaskForm linkableCounter` and `SHARED_TEST linkableCounter` — PASS; `WEB_CHECK`.

- [ ] **Step 5: iOS failing tests.** `CreateFormViewModelCountKindTests.swift`:

```swift
import XCTest
@testable import OYBC

@MainActor
final class CreateFormViewModelCountKindTests: XCTestCase {
    private func makeForm(kind: CountKind, goal: String, unit: String, database: AppDatabase = .shared) -> CreateFormViewModel {
        let form = CreateFormViewModel(database: database)
        form.taskType = .counting
        form.countingAction = "Practice"
        form.countingUnit = unit
        form.countingMaxCount = goal
        form.countingKind = kind
        return form
    }

    func testDurationCreateHasNoUnitAndStoresMinutes() throws {
        let db = try AppDatabase.makeTestInstance()
        let form = makeForm(kind: .duration, goal: "10h 30m", unit: "", database: db)
        let created = expectation(description: "created")
        var createdId: String?
        form.handleCreateAndAddToPool(
            userId: "u1",
            onTaskCreated: { id, _, _ in createdId = id; created.fulfill() },
            onLibraryReloadRequested: {}
        )
        wait(for: [created], timeout: 2)
        let task = try XCTUnwrap(try db.fetchTask(id: XCTUnwrap(createdId)))
        XCTAssertEqual(task.countKind, .duration)
        XCTAssertEqual(task.maxCount, 630)
        XCTAssertEqual(task.title, "Practice 10h 30m")
    }

    func testContinuousRejectsThreePlaces() {
        let form = makeForm(kind: .continuous, goal: "3.125", unit: "mi")
        form.handleCreateAndAddToPool(userId: "u1", onTaskCreated: { _, _, _ in XCTFail("must not create") }, onLibraryReloadRequested: {})
        XCTAssertEqual(form.errorMessage, "Goal must be a number above zero with up to 2 decimals")
    }

    func testLinkedCreateTakesRootKind() {
        let form = makeForm(kind: .discrete, goal: "6.2", unit: "miles")
        form.countingSharedCounterId = "root"
        form.countingBaseline = 0
        form.applyLinkedRootKind(.continuous)
        XCTAssertEqual(form.countingKind, .continuous)
    }
}
```

(`CreateFormViewModel` already takes `init(database:)` (`CreateFormViewModel.swift:176`) and writes through it; `AppDatabase.fetchTask(id:)` is at `AppDatabase+Tasks.swift:16`.)

Snapshot `RisoSpecialPanelCountingSnapshotTests.swift` — render `RisoSpecialTaskPanel` expanded on Counting. The panel has no init today (memberwise only), so add a snapshot seam mirroring `RisoCompoundFieldsView.Seed`: `struct CountingSeed { var action = ""; var goal = ""; var unit = ""; var kind: CountKind = .discrete }` plus a stored `var countingSeed: CountingSeed? = nil` applied in `.onAppear` (sets `isExpanded = true`, `selectedType = .counting` and the counting `@State`s) — a stored defaulted property keeps every existing memberwise call compiling:

```swift
final class RisoSpecialPanelCountingSnapshotTests: XCTestCase {
    private let recordMode: SnapshotTestingConfiguration.Record? = .missing
    private func panel(_ seed: RisoSpecialTaskPanel.CountingSeed) -> some View {
        RisoSpecialTaskPanel(countingSeed: seed).padding(16).background(Color.risoPaper)
    }
    func testContinuousLight() {
        assertSnapshot(of: panel(.init(action: "Run", goal: "26.2", unit: "miles", kind: .continuous)), as: .image(layout: .fixed(width: 393, height: 420)), record: recordMode)
    }
    func testContinuousDark() {
        assertSnapshot(of: panel(.init(action: "Run", goal: "26.2", unit: "miles", kind: .continuous)), as: .image(layout: .fixed(width: 393, height: 420), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }
    func testDurationLight() {
        assertSnapshot(of: panel(.init(action: "Practice", goal: "10h 30m", unit: "", kind: .duration)), as: .image(layout: .fixed(width: 393, height: 420)), record: recordMode)
    }
    func testDiscreteLight() {
        assertSnapshot(of: panel(.init(action: "Read", goal: "300", unit: "pages", kind: .discrete)), as: .image(layout: .fixed(width: 393, height: 420)), record: recordMode)
    }
}
```

(The panel's other init parameters take the defaults the existing snapshot tests use — copy them from `RisoNewTaskSheetSnapshotTests.swift`.)

- [ ] **Step 6: Run — expect FAIL.** `cd apps/ios && xcodegen generate && cd - && IOS_TEST -only-testing:OYBCTests/CreateFormViewModelCountKindTests`

- [ ] **Step 7: Implement iOS.**
  - `LinkableCounter.swift`: `let countKind: CountKind` on the struct and `countKind: resolveCountKind(best.countKind)` in the initializer at `:114-119`.
  - `CreateFormViewModel.swift`: `var countingKind: CountKind = .discrete` beside `countingMaxCount`; `func applyLinkedRootKind(_ kind: CountKind) { countingKind = kind }`; validation `:269-284` becomes:

```swift
            if countKindNeedsUnit(countingKind) {
                guard !u.isEmpty else {
                    errorMessage = "Counting is required"
                    return
                }
                guard u.count <= CreateFormLimits.unit else {
                    errorMessage = "Counting must be \(CreateFormLimits.unit) characters or less"
                    return
                }
            }
            guard !m.isEmpty else {
                errorMessage = "Goal is required"
                return
            }
            guard parseCountInput(m, kind: countingKind) != nil else {
                switch countingKind {
                case .discrete: errorMessage = "Goal must be a positive integer"
                case .continuous: errorMessage = "Goal must be a number above zero with up to 2 decimals"
                case .duration: errorMessage = "Goal must be a duration above zero"
                }
                return
            }
```

    `:322` and `:783` use `parseCountInput(countingMaxCount, kind: countingKind) ?? 0`; `:323` passes `countKind: countingKind` to `TaskTitle.generateCounterTaskTitle`; `buildCreateTask` `.counting` case adds `unit: countKindNeedsUnit(countingKind) ? u : ""` and sets `t.countKind = countingKind == .discrete ? nil : countingKind` after construction (`var t = Task(…); t.countKind = …; return t`). Every reset that clears `countingMaxCount` sets `countingKind = .discrete`.
  - `RisoSpecialTaskPanel.swift`: `@State private var countingKind: CountKind = .discrete`; `countingGoal` (`:225-228`) = `parseCountInput(countingGoalText, kind: effectiveKind)`; `countingTitle` uses it and passes `countKind: effectiveKind`; `canSubmitCounting` requires the unit only when `countKindNeedsUnit(effectiveKind)`; `private var effectiveKind: CountKind { (linkSuggestion != nil && !linkDisabled) ? linkSuggestion!.countKind : countingKind }`; `updateLinkSuggestion` returns nil for Duration (`guard countingKind != .duration else { linkSuggestion = nil; return }`) and re-runs `.onChange(of: countingKind)`. `countingFields` body:

```swift
            fieldRow(label: "Verb", required: true) {
                RisoTextField(placeholder: "Do", text: $countingActionText)
            }
            fieldRow(label: "Kind") {
                if let suggestion = linkSuggestion, !linkDisabled {
                    KindTagView(kind: suggestion.countKind, counterName: suggestion.name, lifetime: suggestion.lifetime)
                } else {
                    KindPickerView(selection: $countingKind, lock: .none)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Goal", required: true)
                    GoalEntryView(kind: effectiveKind, text: $countingGoalText, placeholder: effectiveKind == .duration ? "0h 0m" : "100")
                }
                if countKindNeedsUnit(effectiveKind) {
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Counting", required: true)
                        RisoTextField(placeholder: "push-ups", text: $countingUnitText)
                    }
                }
            }
```

    `submitCounting` sets `form.countingKind = effectiveKind` (R19 — the pending payload carries the root's kind before the drain's `withRootCountKind`), `form.countingUnit = countKindNeedsUnit(effectiveKind) ? … : ""`; resets clear `countingKind`. Add the `CountingSeed` init from Step 5. Net line change must keep the file < 1000 (it is 921; Task 11 later removes ~290 lines of stepper code from this file — if this task alone would cross 1000, do Task 11's extraction of `RisoInlineStepperView`'s compact style first).
  - `RisoCounterLinkHintView.swift`: delete the two `Text` sentences (`:44-48`), keep the pill with `.accessibilityLabel(linked ? "Don't link to \(counterName)" : "Link to \(counterName)")`; drop the now-unused `lifetime` / `goal` parameters and fix the call sites the compiler flags (`RisoSpecialTaskPanel`, `RisoCompoundFieldsView`, `RisoCompoundEditFieldsView`).

- [ ] **Step 8: Run iOS.** `IOS_TEST -only-testing:OYBCTests/CreateFormViewModelCountKindTests -only-testing:OYBCTests/LinkableCounterTests` PASS. Record `RisoSpecialPanelCountingSnapshotTests` (new) and re-record the four `RisoCompoundPanelSnapshotTests` link-hint baselines listed above (delete → record → green). Read each PNG against handoff A1 (picker between Verb and Goal; Duration: no Counting field, wheel field "10h 30m").

- [ ] **Step 9: e2e + Playwright validation.** Create `apps/web/e2e/counter-kinds-authoring.spec.ts`:

```ts
import { test, expect, readTask } from './_fixtures/bypass';

test.describe('Counter kinds — authoring (A1)', () => {
  test('Tasks tab: create a Continuous and a Duration counter', async ({ page }) => {
    await page.goto('/tasks?__oybc_test_bypass=1');
    await page.getByRole('button', { name: 'Add a counting, compound or achievement task' }).click();
    await page.getByRole('button', { name: 'Counting', exact: true }).click();
    await page.getByLabel('Verb').fill('Run');
    await page.getByRole('group', { name: 'Kind' }).getByRole('button', { name: 'Continuous' }).click();
    await page.getByLabel('Goal', { exact: true }).fill('26,2');
    await page.getByLabel('Counting').fill('miles');
    await expect(page.getByText('Run 26.2 miles')).toBeVisible();
    await page.getByRole('button', { name: /^Add/ }).click();
    await expect(page.getByText('Run 26.2 miles')).toBeVisible();

    await page.getByRole('button', { name: 'Add a counting, compound or achievement task' }).click();
    await page.getByRole('button', { name: 'Counting', exact: true }).click();
    await page.getByLabel('Verb').fill('Practice');
    await page.getByRole('group', { name: 'Kind' }).getByRole('button', { name: 'Duration' }).click();
    await expect(page.getByLabel('Counting')).toHaveCount(0);
    await page.getByLabel('Goal hours').fill('10');
    await page.getByLabel('Goal minutes').fill('30');
    await page.getByRole('button', { name: /^Add/ }).click();
    await expect(page.getByText('Practice 10h 30m')).toBeVisible();
  });
});
```

(Use the fixture helpers `_fixtures/bypass.ts` exports; if there is no `readTask`, drop that import. Match the submit button's real label from `CreateNewTaskForm`'s `submitLabel` on the Tasks tab.) Run `WEB_E2E e2e/counter-kinds-authoring.spec.ts` — PASS. Then the Playwright MCP validation: `/tasks`, open the counting panel, screenshot light + dark with Continuous selected and with Duration selected → `.playwright-mcp/task5-a1-{continuous,duration}-{light,dark}.png`; compare to handoff A1 web frame.

- [ ] **Step 10: Commit**

```bash
git add packages/shared apps/web apps/ios
git commit -m "feat(counters): A1 kind picker + goal entry in the special panel / create form; linked creates take the root kind (R19); drop link-hint + achievement captions (#548 67/68, 77/78) (PR 3 Task 5)"
```

---

### Task 6: A2 — compound sub-tasks (create + edit) carry a kind

**Files:**
- Modify: `apps/web/src/components/wizard/CountingSubConfigRow.tsx` (+`kind`, `onKindChange`; Goal → `GoalEntry`; unit hidden for Duration)
- Modify: `apps/web/src/components/CountingStepFields.tsx:14-95` (+`countKind`, `onKindChange`; title via `parseCountInput`)
- Modify: `apps/web/src/components/compoundWizard/compoundSubtaskDraft.ts:22-43` (`InlineSubtaskDraft.countKind?: CountKind`), `:75-90` (readiness via `parseCountInput`)
- Modify: `apps/web/src/components/compoundWizard/SubtaskCard.tsx:312-330` (pass kind); delete the #548 row 65 caption at `:292` ("(auto-generated from action + count + unit if blank)")
- Modify: `apps/web/src/components/compoundWizard/CompoundTaskWizard.tsx:255-283` (`autoCreate.countKind`, `parseCountInput`)
- Modify: `apps/web/src/db/taskEditPatch.ts:21-62` (`ChildPatch.countKind: CountKind`; `newChildPatch`, `childPatchFromTask` seed it), `:218-240` (`parsePositiveGoal(goal, kind)`, `canAppendCounting(text, goal, unit, kind)`)
- Modify: `apps/web/src/components/wizard/CompoundFields.tsx:150-190` (new-sub kind row), `:229-237` (existing child goal → `GoalEntry` at the child's kind, unit hidden for Duration); delete the #548 row 61 caption at `:188`
- Modify: `apps/web/src/db/operations/tasks.crud.ts:243-260` (`autoCreate.countKind` written), `apps/web/src/db/operations/compoundStructureEdit.ts` (`applyStagedCompoundChildEdits` writes `countKind` for a new counting child — `:69`)
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/RisoCountingSubConfigRow.swift` (+`kind: Binding<CountKind>`; Goal → `GoalEntryView`)
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/RisoCompoundFieldsView.swift:25-33,97-98,154-155,207-231,370,586-604` (sub kind state, parse, seed)
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/RisoCompoundEditFieldsView.swift:108-111` (`parsePositiveGoal(_:kind:)`), `:263-268` (existing child goal), `:355` (new sub kind); delete the #548 row 62 caption at `:225`
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/TaskEditPatch.swift:15-62` (`ChildPatch.countKind`), `:105` (`parsedGoal` kind-aware), `:151` (child goal parse)
- Modify: `apps/ios/OYBC/Views/CreateTab/ViewModels/CreateFormViewModel.swift:474-500` (`CompoundSubItem.newCounting(… countKind:)`), `:640-670` (child Task gets `countKind`)
- Modify: `apps/ios/OYBC/Database/AppDatabase+CompoundStructureEdit.swift:38,107` (new counting child gets `countKind`)
- Test: `apps/web/src/db/__tests__/taskEditPatch.countKind.test.ts` (create), `apps/web/src/db/operations/__tests__/compoundCreate.countKind.test.ts` (create), `apps/ios/OYBCTests/CompoundSubKindTests.swift` (create)
- Re-record (intentional — kind row in the sub config + caption removal): `RisoCompoundPanelSnapshotTests/testCompoundNewSubCounting{Light,Dark}`, `testCompoundNewSubCountingLinked{Light,Dark}`, `testCompoundNewSubCountingOptedOut{Light,Dark}` (Task 5 re-recorded the last four for the hint; record again here), `RisoCompoundPanelSnapshotTests/testCompoundWithSubs{Light,Dark}` only if red, `PoolRowEditorSnapshotTests/testCompoundEditorNewSubCountingLight`, `RisoEditTaskSheetSnapshotTests/testCompound{Light,Dark}` (row 62 caption)

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces:
  - web `CountingSubConfigRowProps.kind: CountKind`, `onKindChange: (kind: CountKind) => void`, `kindLock?: KindPickerLock` (default `'none'`)
  - web `ChildPatch.countKind: CountKind`; `canAppendCounting(text, goal, unit, kind: CountKind = 'discrete')`
  - iOS `RisoCountingSubConfigRow(goal:unit:kind:)`; `ChildPatch.countKind: CountKind`; `CompoundSubItem.newCounting(action:goal:unit:sharedCounterId:baseline:countKind:)`
  - Rule (ruling): only a NEW sub-task picks a kind; an existing sub-task's goal edits at its own kind, no picker (its kind is changed from its own Task Detail).

- [ ] **Step 1: Failing web tests.** `taskEditPatch.countKind.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { canAppendCounting, childPatchFromTask, newChildPatch } from '../taskEditPatch';

describe('ChildPatch countKind', () => {
  it('a new counting child starts discrete', () => {
    expect(newChildPatch(true).countKind).toBe('discrete');
  });
  it('an existing child seeds its kind and goal text', () => {
    const child = { id: 'c', title: 'Run 26.2 mi', type: TaskType.COUNTING, action: 'Run', unit: 'mi', maxCount: 26.2, countKind: 'continuous' } as Task;
    const patch = childPatchFromTask(child);
    expect(patch.countKind).toBe('continuous');
    expect(patch.goal).toBe('26.2');
  });
  it('canAppendCounting is kind-aware', () => {
    expect(canAppendCounting('Run', '3.1', 'mi', 'continuous')).toBe(true);
    expect(canAppendCounting('Run', '3.1', 'mi', 'discrete')).toBe(false);
    expect(canAppendCounting('Practice', '1h 30m', '', 'duration')).toBe(true);
    expect(canAppendCounting('Practice', '90', '', 'discrete')).toBe(false);
  });
});
```

`compoundCreate.countKind.test.ts` (Dexie via `fake-indexeddb`, copy the setup of `apps/web/src/db/operations/__tests__/countKindWritePaths.test.ts`):

```ts
it('createCompound writes an inline Duration child with countKind and no unit', async () => {
  const compound = await createCompound('u1', {
    title: 'Music week',
    operator: OperatorType.AND,
    children: [{ autoCreate: { type: TaskType.COUNTING, title: '', action: 'Practice', maxCount: 630, countKind: 'duration' } }],
  });
  const links = await db.compoundChildren.where('parentTaskId').equals(compound.id).toArray();
  const child = await db.tasks.get(links[0].childTaskId);
  expect(child?.countKind).toBe('duration');
  expect(child?.title).toBe('Practice 10h 30m');
  expect(child?.maxCount).toBe(630);
});
```

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST taskEditPatch.countKind compoundCreate.countKind`

- [ ] **Step 3: Implement web.**
  - `ChildPatch` gains `countKind: CountKind;` — `newChildPatch` sets `'discrete'`, `childPatchFromTask` sets `resolveCountKind(child)` and `goal: child.maxCount !== undefined ? formatCountForInput(child.maxCount, resolveCountKind(child)) : ''`.
  - `parsePositiveGoal(goal: string, kind: CountKind = 'discrete'): number | undefined` → `parseCountInput(goal, kind) ?? undefined`; `canAppendCounting(text, goal, unit, kind = 'discrete')` = `text.trim().length > 0 && parsePositiveGoal(goal, kind) !== undefined && (!countKindNeedsUnit(kind) || unit.trim().length > 0)`. Update every `parsePositiveGoal(` call in the file to pass the child's / draft's kind.
  - `CountingSubConfigRow.tsx` — props gain `kind`, `onKindChange`, `kindLock?: KindPickerLock`; render `<KindPicker value={kind} lock={kindLock ?? 'none'} onChange={onKindChange} size="compact" />` as the first row, Goal as `<GoalEntry kind={kind} value={goal} onChange={onGoalChange} id={`${idPrefix}-goal`} aria-label="Goal" dense invalid={Boolean(goalError)} placeholder={kind === 'duration' ? '0h 0m' : '100'} />`, and the Counting field only `{countKindNeedsUnit(kind) && …}`.
  - `CountingStepFields.tsx` — props gain `countKind: CountKind; onKindChange(kind)`; `const parsed = parseCountInput(maxCount, countKind); const goalValid = parsed !== null;` and the title `generateCounterTaskTitle(trimmedAction, parsed, trimmedUnit, undefined, countKind)` gated on `(trimmedUnit || countKind === 'duration')`.
  - `compoundSubtaskDraft.ts` — `InlineSubtaskDraft.countKind?: CountKind` (absent = discrete); readiness `parseCountInput(draft.maxCountStr, draft.countKind ?? 'discrete') !== null` and the unit check skipped for Duration.
  - `SubtaskCard.tsx` passes `countKind={draft.countKind ?? 'discrete'}` and `onKindChange={(k) => onUpdate({ countKind: k, linkDisabled: false } as Partial<InlineSubtaskDraft>)}`; `InlineCounterLinkHint` is not rendered for Duration. Delete the `:292` caption node.
  - `CompoundTaskWizard.tsx:257-281`: `const kind = subtask.countKind ?? 'discrete'; const maxCount = parseCountInput(subtask.maxCountStr, kind);` and `autoCreate: { …, unit: countKindNeedsUnit(kind) ? trimmedUnit || undefined : undefined, maxCount: maxCount ?? undefined, ...(kind !== 'discrete' ? { countKind: kind } : {}) }`; the match is skipped for Duration.
  - `CompoundFields.tsx` — new-sub state `const [newSubKind, setNewSubKind] = useState<CountKind>('discrete');` passed to `CountingSubConfigRow`, to `canAppendCounting(…, newSubKind)` (`:157`) and to the appended `ChildPatch` (`countKind: newSubKind`). Existing child row `:229-237`: replace the `type="number"` input with `<GoalEntry kind={child.countKind} value={child.goal} onChange={(v) => onUpdate({ goal: v })} aria-label={`Sub-task ${index} goal`} dense />` and render the unit input only for `countKindNeedsUnit(child.countKind)`. Delete the `:188` `subtaskNote` span (row 61).
  - `tasks.crud.ts:243-260` add `...(entry.autoCreate.countKind ? { countKind: entry.autoCreate.countKind } : {})` and the title via `generateCounterTaskTitle(…, entry.autoCreate.countKind ?? 'discrete')` where the child title is generated (`withRootCountKind` still overrides for a linked child).
  - `compoundStructureEdit.ts` `applyStagedCompoundChildEdits`: when it creates a new counting child from a `ChildPatch`, set `countKind: step.countKind` (omit for discrete), `maxCount: parseCountInput(step.goal, step.countKind)`, unit `''` for Duration, title with the kind.

- [ ] **Step 4: Run** `WEB_TEST taskEditPatch compoundCreate CompoundFields SubtaskCard CountingStepFields` — PASS (existing tests of these files must stay green); `WEB_CHECK`.

- [ ] **Step 5: iOS failing tests** `CompoundSubKindTests.swift`:

```swift
import XCTest
@testable import OYBC

final class CompoundSubKindTests: XCTestCase {
    func testNewCountingSubCarriesKindIntoTheChildTask() throws {
        let db = try AppDatabase.makeTestInstance()
        let form = CreateFormViewModel(database: db)
        let done = expectation(description: "created")
        form.handleCreateCompoundAndAddToPool(
            userId: "u1",
            title: "Music week",
            rule: .allOf,
            subs: [.newCounting(action: "Practice", goal: 630, unit: "", sharedCounterId: nil, baseline: nil, countKind: .duration)],
            onTaskCreated: { _, _, _ in done.fulfill() },
            onLibraryReloadRequested: {}
        )
        wait(for: [done], timeout: 2)
        let child = try XCTUnwrap(try db.read { try Task.filter(Column("action") == "Practice").fetchOne($0) })
        XCTAssertEqual(child.countKind, .duration)
        XCTAssertEqual(child.title, "Practice 10h 30m")
    }

    func testChildPatchSeedsKindAndParsesPerKind() {
        var t = Task.counting(id: "c", maxCount: 26.2)
        t.countKind = .continuous
        let patch = ChildPatch(from: t)
        XCTAssertEqual(patch.countKind, .continuous)
        XCTAssertEqual(patch.goal, "26.2")
        XCTAssertTrue(RisoCompoundEditFieldsView.canAppendCounting(text: "Run", goal: "3.1", unit: "mi", kind: .continuous))
        XCTAssertFalse(RisoCompoundEditFieldsView.canAppendCounting(text: "Run", goal: "3.1", unit: "mi", kind: .discrete))
        XCTAssertTrue(RisoCompoundEditFieldsView.canAppendCounting(text: "Practice", goal: "90", unit: "", kind: .duration))
    }
}
```

(`CompoundRule` is the enum at `CreateFormViewModel.swift:516` — `.allOf` / `.anyOf` / `.atLeastN(threshold:)`.)

- [ ] **Step 6: Run — expect build FAIL.** `IOS_TEST -only-testing:OYBCTests/CompoundSubKindTests`

- [ ] **Step 7: Implement iOS.**
  - `RisoCountingSubConfigRow`: add `@Binding var kind: CountKind` and `var kindLock: KindPickerLock = .none`; body = `KindPickerView(selection: $kind, lock: kindLock)` row, then the `HStack` with `GoalEntryView(kind: kind, text: $goal, placeholder: kind == .duration ? "0h 0m" : "100")` and the Counting field only when `countKindNeedsUnit(kind)`.
  - `RisoCompoundFieldsView`: `@State private var subKind: CountKind` (seeded from `Seed.subKind`, default `.discrete`), goal parse `parseCountInput(subGoalText, kind: subKind)` at `:217`, unit requirement gated at `:231`, `RisoCountingSubConfigRow(goal: $subGoalText, unit: $subUnitText, kind: $subKind)` at `:370`, `.newCounting(…, countKind: subKind)` where the sub is appended (`:586-600`), reset `subKind = .discrete` at `:603`/`:656`. Link suggestion skipped for Duration.
  - `CompoundSubItem.newCounting` gains `countKind: CountKind` (last associated value); `displayTitle` passes it; the create loop (`CreateFormViewModel.swift` ~`:648-668`) passes `countKind:` to `TaskTitle.generateCounterTaskTitle`, writes `unit: countKindNeedsUnit(countKind) ? … : ""` and sets `child.countKind = countKind == .discrete ? nil : countKind`.
  - `TaskEditPatch.swift`: `ChildPatch.countKind: CountKind = .discrete`, seeded in `init(from:)` (`:62` already formats with the kind — also assign `countKind = resolveCountKind(child.countKind)`); `parsedGoal` → `parseCountInput(goal, kind: countKind)` where `TaskEditPatch` gains `var countKind: CountKind = .discrete` seeded at `:98` (used by Tasks 8/12); child goal `:151` → `parseCountInput(child.goal, kind: child.countKind) ?? 0`.
  - `RisoCompoundEditFieldsView`: `parsePositiveGoal(_ goal: String, kind: CountKind) -> CountValue?` = `parseCountInput(goal, kind: kind)`; `canAppendCounting(text:goal:unit:kind:)` (static, so the test can call it); new-sub `@State private var newSubKind: CountKind = .discrete` passed to `RisoCountingSubConfigRow` at `:355` and to the appended `ChildPatch`; existing child row `:266` → `GoalEntryView(kind: child.wrappedValue.countKind, text: child.goal).frame(width: 84)`, unit field only for `countKindNeedsUnit`. Delete the `:225` caption `Text` (row 62).
  - `AppDatabase+CompoundStructureEdit.swift` — the new-child builder (`applyStagedStepToChild` / the new-child branch of `applyStagedCompoundChildEdits`) sets `countKind` from the step and parses `goal` with it.

- [ ] **Step 8: Run iOS** `IOS_TEST -only-testing:OYBCTests/CompoundSubKindTests -only-testing:OYBCTests/BoardEditCompoundTests -only-testing:OYBCTests/AppDatabaseTaskEditTests` PASS. Re-record the baselines listed under **Files** (delete → record → green), read each against handoff A2 (Duration sub-task: no Counting field).

- [ ] **Step 9: Playwright validation.** `/tasks` → Compound → add a Counting sub, pick Duration, set 1h 30m; screenshot light/dark → `.playwright-mcp/task6-a2-{light,dark}.png`; then open an existing compound's Task Detail → Edit, add a Continuous sub "Run 3.1 mi", save; reload and confirm the sub reads "Run 3.1 mi".

- [ ] **Step 10: Commit**

```bash
git add apps/web apps/ios packages/shared
git commit -m "feat(counters): A2 compound sub-tasks pick a kind (create + edit); inline children carry countKind; drop sub-task captions (#548 61/62, 65) (PR 3 Task 6)"
```

---

### Task 7: Kind-switch infrastructure — in-transaction switch, impact preview, confirm dialog

**Files:**
- Modify: `apps/web/src/db/operations/countKindSwitch.ts:73-140` (extract `switchCounterKindInTransaction`; add `previewCounterKindSwitch`)
- Modify: `apps/ios/OYBC/Database/AppDatabase+CountKindSwitch.swift:45-106` (extract `static func switchCounterKind(db:rootTaskId:to:now:)`; batch the family fetch — R-perf; add `previewCounterKindSwitch(rootTaskId:to:)`)
- Create: `apps/web/src/components/counters/KindSwitchConfirmDialog.tsx`, `KindSwitchConfirmDialog.module.css`, `apps/web/src/components/counters/kindSwitchModel.ts`
- Create: `apps/ios/OYBC/Views/Components/KindSwitchConfirmView.swift`
- Test: `apps/web/src/db/operations/__tests__/countKindSwitch.test.ts` (+preview + in-transaction cases), `apps/web/src/components/counters/__tests__/kindSwitchModel.test.ts` (create), `apps/ios/OYBCTests/AppDatabaseCountKindSwitchTests.swift` (+cases), `apps/ios/OYBCSnapshotTests/KindSwitchConfirmSnapshotTests.swift` (create)

**Interfaces:**
- Consumes: `switchCounterKind` (PR 2), `planCountKindSwitch`, `generateCounterTaskTitle(…, countKind)`, `formatCount`.
- Produces:
  - web `switchCounterKindInTransaction(rootTaskId: string, to: CountKind, nowIso: string): Promise<string[]>` (written ids; must run inside an `rw` transaction over `boards, boardTasks, tasks, compoundChildren, taskEvents, syncQueue`; `switchCounterKind` wraps it unchanged)
  - web `previewCounterKindSwitch(rootTaskId: string, to: CountKind, now?: Date): Promise<KindSwitchPreview | null>` with `interface KindSwitchPreview { from: CountKind; to: CountKind; titleBefore: string; titleAfter: string; loggedBefore: number; loggedAfter: number; linkedCount: number }`
  - web `needsKindSwitchConfirm(from: CountKind, to: CountKind): boolean` (true only continuous → discrete) and `kindSwitchConfirmLines(p: KindSwitchPreview): { title: string; rows: [string, string][]; body: string }` in `kindSwitchModel.ts`
  - web `<KindSwitchConfirmDialog preview: KindSwitchPreview; onCancel(): void; onConfirm(): void />`
  - iOS `static func switchCounterKind(db: Database, rootTaskId: String, to: CountKind, now: Date) throws -> [String]`; `func previewCounterKindSwitch(rootTaskId: String, to: CountKind, now: Date = Date()) throws -> KindSwitchPreview?`; `struct KindSwitchPreview: Equatable { from, to: CountKind; titleBefore, titleAfter: String; loggedBefore, loggedAfter: CountValue; linkedCount: Int }`; `enum KindSwitchCopy { static func needsConfirm(from:to:) -> Bool; static func lines(_:) -> (title: String, rows: [(String, String)], body: String) }`; `KindSwitchConfirmView(preview:onCancel:onConfirm:)`
  - Rule for the preview: `titleAfter` regenerates the auto title only when the title is auto (`isAutoCounterTitle`), else keeps it; `loggedBefore` = the root's lifetime `currentCount`; `loggedAfter` = `finalizeWindowCount(loggedBefore, to)`; `linkedCount` = live family rows that the switch would write (non-frozen, `isFrozenDerivedRow` false at `now`).

- [ ] **Step 1: Failing web tests.** Append to `countKindSwitch.test.ts` (it already seeds a root + family with fractional events — reuse its `seedFamily()` helper):

```ts
describe('previewCounterKindSwitch', () => {
  it('continuous → discrete: rounded title, rounded logged, live linked count', async () => {
    const { rootId } = await seedFamily({ rootMaxCount: 26.2, rootTitle: 'Run 26.2 miles', lifetime: 12.75, liveLinked: 2, frozenLinked: 1 });
    const p = await previewCounterKindSwitch(rootId, 'discrete', NOW);
    expect(p).toEqual({
      from: 'continuous', to: 'discrete',
      titleBefore: 'Run 26.2 miles', titleAfter: 'Run 26 miles',
      loggedBefore: 12.75, loggedAfter: 13, linkedCount: 2,
    });
  });
  it('a custom title is kept', async () => {
    const { rootId } = await seedFamily({ rootMaxCount: 26.2, rootTitle: 'Marathon', lifetime: 1, liveLinked: 0 });
    expect((await previewCounterKindSwitch(rootId, 'discrete', NOW))?.titleAfter).toBe('Marathon');
  });
  it('refused switches preview null', async () => {
    const { rootId } = await seedFamily({ rootMaxCount: 26.2, rootTitle: 'Run 26.2 miles', lifetime: 0, liveLinked: 0 });
    expect(await previewCounterKindSwitch(rootId, 'duration', NOW)).toBeNull();
  });
});

describe('switchCounterKindInTransaction', () => {
  it('runs inside a caller transaction and rolls back with it', async () => {
    const { rootId } = await seedFamily({ rootMaxCount: 26.2, rootTitle: 'Run 26.2 miles', lifetime: 3, liveLinked: 1 });
    await expect(
      db.transaction('rw', [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue], async () => {
        await switchCounterKindInTransaction(rootId, 'discrete', NOW.toISOString());
        throw new Error('caller failed');
      }),
    ).rejects.toThrow('caller failed');
    expect((await db.tasks.get(rootId))?.countKind).toBe('continuous');
  });
});
```

(If `seedFamily` does not take these options, extend it in the test file — it is test-local.) `kindSwitchModel.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { kindSwitchConfirmLines, needsKindSwitchConfirm } from '../kindSwitchModel';

describe('kindSwitchModel', () => {
  it('only continuous → discrete confirms', () => {
    expect(needsKindSwitchConfirm('continuous', 'discrete')).toBe(true);
    expect(needsKindSwitchConfirm('discrete', 'continuous')).toBe(false);
  });
  it('copy matches the handoff', () => {
    const lines = kindSwitchConfirmLines({
      from: 'continuous', to: 'discrete', titleBefore: 'Run 26.2 miles', titleAfter: 'Run 26 miles',
      loggedBefore: 12.75, loggedAfter: 13, linkedCount: 2,
    });
    expect(lines.title).toBe('Switch to Discrete?');
    expect(lines.rows).toEqual([['Run 26.2 miles', 'Run 26 miles'], ['12.75 logged', '13 logged']]);
    expect(lines.body).toBe('Switching back restores the exact values. Follows on 2 linked squares.');
  });
  it('no family line without a family; singular for one', () => {
    const base = { from: 'continuous' as const, to: 'discrete' as const, titleBefore: 'a', titleAfter: 'a', loggedBefore: 0, loggedAfter: 0 };
    expect(kindSwitchConfirmLines({ ...base, linkedCount: 0 }).body).toBe('Switching back restores the exact values.');
    expect(kindSwitchConfirmLines({ ...base, linkedCount: 1 }).body).toBe('Switching back restores the exact values. Follows on 1 linked square.');
  });
});
```

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST countKindSwitch kindSwitchModel`

- [ ] **Step 3: Implement web.** In `countKindSwitch.ts` move the body of the transaction callback into:

```ts
/**
 * The body of {@link switchCounterKind}, for a caller that already holds the
 * `rw` transaction (Board Edit Save, staged pool / wizard edits, Task Detail
 * save) so the switch and the caller's other writes commit or roll back
 * together. Same rules and errors as `switchCounterKind`.
 *
 * @param rootTaskId - The counter root.
 * @param to - The requested kind.
 * @param nowIso - The switch instant (also the freeze clock).
 * @returns The ids written (root first).
 * @throws {CountKindSwitchError} as `switchCounterKind`.
 */
export async function switchCounterKindInTransaction(rootTaskId: string, to: CountKind, nowIso: string): Promise<string[]> {
  // … the existing callback body verbatim, ending with:
  await runBoardCascadeForTasks(writtenIds);
  return writtenIds;
}
```

and `switchCounterKind` becomes `await db.transaction('rw', [...same tables], () => switchCounterKindInTransaction(rootTaskId, to, now.toISOString()));`. Add:

```ts
/** What a kind switch would change — feeds the Continuous → Discrete confirm. */
export interface KindSwitchPreview {
  from: CountKind;
  to: CountKind;
  titleBefore: string;
  titleAfter: string;
  loggedBefore: number;
  loggedAfter: number;
  linkedCount: number;
}

/**
 * Read-only preview of {@link switchCounterKind} for the confirm dialog.
 *
 * @param rootTaskId - The counter root.
 * @param to - The requested kind.
 * @param now - The freeze clock for counting live linked rows.
 * @returns The preview, or null when the switch would be refused / the task is not a live counting root.
 */
export async function previewCounterKindSwitch(rootTaskId: string, to: CountKind, now: Date = new Date()): Promise<KindSwitchPreview | null> {
  const root = await db.tasks.get(rootTaskId);
  if (!root || root.isDeleted || root.type !== TaskType.COUNTING || root.sharedCounterId != null) return null;
  const from = resolveCountKind(root);
  const patch = planCountKindSwitch(root, from, to);
  if (!patch) return null;
  const nowIso = now.toISOString();
  const family = await db.tasks.where('sharedCounterId').equals(root.id).filter((t) => !t.isDeleted).toArray();
  const action = root.action ?? '';
  const unit = root.unit ?? '';
  const auto = isAutoCounterTitle(root.title, action, root.maxCount, unit, from);
  return {
    from,
    to,
    titleBefore: root.title,
    titleAfter: auto ? generateCounterTaskTitle(action, patch.maxCount ?? root.maxCount, unit, undefined, to) : root.title,
    loggedBefore: root.currentCount ?? 0,
    loggedAfter: finalizeWindowCount(root.currentCount ?? 0, to),
    linkedCount: family.filter((row) => !isFrozenDerivedRow(row, nowIso)).length,
  };
}
```

`kindSwitchModel.ts`:

```ts
import { COUNT_KIND_LABELS, formatCount, type CountKind } from '@oybc/shared';
import type { KindSwitchPreview } from '../../db/operations/countKindSwitch';

/** D4 / §5: only the rounding direction confirms. */
export function needsKindSwitchConfirm(from: CountKind, to: CountKind): boolean {
  return from === 'continuous' && to === 'discrete';
}

/**
 * The confirm's copy — the one place a consequence sentence is allowed.
 *
 * @param p - The switch preview.
 * @returns Title, before → after rows, consequence body.
 */
export function kindSwitchConfirmLines(p: KindSwitchPreview): { title: string; rows: [string, string][]; body: string } {
  const family =
    p.linkedCount === 0 ? '' : ` Follows on ${p.linkedCount} linked square${p.linkedCount === 1 ? '' : 's'}.`;
  return {
    title: `Switch to ${COUNT_KIND_LABELS[p.to]}?`,
    rows: [
      [p.titleBefore, p.titleAfter],
      [`${formatCount(p.loggedBefore, p.from)} logged`, `${formatCount(p.loggedAfter, p.to)} logged`],
    ],
    body: `Switching back restores the exact values.${family}`,
  };
}
```

`KindSwitchConfirmDialog.tsx` — follow the existing confirm-dialog chrome (`CounterDeleteConfirmDialog.tsx` + `useModalA11y`):

```tsx
import { useModalA11y } from '../../hooks/useModalA11y';
import type { KindSwitchPreview } from '../../db/operations/countKindSwitch';
import { RisoButton } from '../riso';
import { kindSwitchConfirmLines } from './kindSwitchModel';
import styles from './KindSwitchConfirmDialog.module.css';

export interface KindSwitchConfirmDialogProps {
  preview: KindSwitchPreview;
  onCancel: () => void;
  onConfirm: () => void;
}

/**
 * Continuous → Discrete confirm (docs/COUNTER_KINDS.md §5): before → after
 * rows for the title and the logged total, the consequence body, Cancel /
 * Switch. iOS twin: `KindSwitchConfirmView`.
 *
 * @returns The modal dialog.
 */
export function KindSwitchConfirmDialog({ preview, onCancel, onConfirm }: KindSwitchConfirmDialogProps): React.ReactElement {
  const { ref, props } = useModalA11y<HTMLDivElement>({ open: true, onCancel });
  const lines = kindSwitchConfirmLines(preview);
  return (
    <div className={styles.backdrop} onClick={onCancel}>
      <div ref={ref} {...props} role="dialog" aria-modal="true" aria-labelledby="kind-switch-title" className={styles.dialog} onClick={(e) => e.stopPropagation()}>
        <h2 id="kind-switch-title" className={styles.title}>{lines.title}</h2>
        <div className={styles.rows}>
          {lines.rows.map(([before, after]) => (
            <div key={before} className={styles.row}>
              <span className={styles.before}>{before}</span>
              <span aria-hidden="true">→</span>
              <span>{after}</span>
            </div>
          ))}
        </div>
        <p className={styles.body}>{lines.body}</p>
        <div className={styles.actions}>
          <RisoButton kind="ghost" onClick={onCancel}>Cancel</RisoButton>
          <RisoButton kind="blue" onClick={onConfirm}>Switch</RisoButton>
        </div>
      </div>
    </div>
  );
}
```

(Copy `backdrop` / `dialog` / `actions` CSS from `CreateCounterSheet.module.css`'s dialog chrome — the handoff's stated source; `.before { color: var(--riso-muted); text-decoration: line-through; }`. Verify the real `useModalA11y` import path with `grep -rn "export function useModalA11y" apps/web/src`.)

- [ ] **Step 4: Run** `WEB_TEST countKindSwitch kindSwitchModel` — PASS (existing `countKindSwitch` tests stay green: the wrapper is behaviour-identical); `WEB_CHECK`.

- [ ] **Step 5: iOS failing tests.** Append to `AppDatabaseCountKindSwitchTests.swift` (reuse its seeding helpers):

```swift
    func testPreviewRoundsTitleAndLoggedAndCountsLiveFamily() throws {
        let (db, rootId) = try seedFamily(rootMaxCount: 26.2, rootTitle: "Run 26.2 miles", lifetime: 12.75, liveLinked: 2, frozenLinked: 1)
        let p = try XCTUnwrap(db.previewCounterKindSwitch(rootTaskId: rootId, to: .discrete, now: Self.now))
        XCTAssertEqual(p, KindSwitchPreview(from: .continuous, to: .discrete, titleBefore: "Run 26.2 miles", titleAfter: "Run 26 miles",
                                           loggedBefore: 12.75, loggedAfter: 13, linkedCount: 2))
    }

    func testSwitchInsideCallerTransactionRollsBackWithIt() throws {
        let (db, rootId) = try seedFamily(rootMaxCount: 26.2, rootTitle: "Run 26.2 miles", lifetime: 3, liveLinked: 1, frozenLinked: 0)
        struct CallerFailed: Error {}
        XCTAssertThrowsError(try db.write { conn in
            _ = try AppDatabase.switchCounterKind(db: conn, rootTaskId: rootId, to: .discrete, now: Self.now)
            throw CallerFailed()
        })
        XCTAssertEqual(try db.fetchTask(id: rootId)?.countKind, .continuous)
    }

    func testConfirmCopy() {
        let p = KindSwitchPreview(from: .continuous, to: .discrete, titleBefore: "Run 26.2 miles", titleAfter: "Run 26 miles",
                                  loggedBefore: 12.75, loggedAfter: 13, linkedCount: 2)
        let lines = KindSwitchCopy.lines(p)
        XCTAssertEqual(lines.title, "Switch to Discrete?")
        XCTAssertEqual(lines.rows.map { "\($0.0)→\($0.1)" }, ["Run 26.2 miles→Run 26 miles", "12.75 logged→13 logged"])
        XCTAssertEqual(lines.body, "Switching back restores the exact values. Follows on 2 linked squares.")
        XCTAssertTrue(KindSwitchCopy.needsConfirm(from: .continuous, to: .discrete))
        XCTAssertFalse(KindSwitchCopy.needsConfirm(from: .discrete, to: .continuous))
    }
```

Snapshot `KindSwitchConfirmSnapshotTests.swift`: `testConfirmLight` / `testConfirmDark` rendering `KindSwitchConfirmView(preview: p, onCancel: {}, onConfirm: {})` at `.fixed(width: 393, height: 320)`.

- [ ] **Step 6: Run — expect build FAIL.** `IOS_TEST -only-testing:OYBCTests/AppDatabaseCountKindSwitchTests`

- [ ] **Step 7: Implement iOS.** Extract the `write { db in … }` body of `switchCounterKind(rootTaskId:to:now:)` into `static func switchCounterKind(db: Database, rootTaskId: String, to: CountKind, now: Date) throws -> [String]` (returns written ids); the instance method becomes `try write { db in _ = try Self.switchCounterKind(db: db, rootTaskId: rootTaskId, to: to, now: now) }`. Perf (carried item): fetch the family once with `Task.filter(Column("sharedCounterId") == rootTaskId && Column("isDeleted") == false).fetchAll(db)`, compute every patch first, then write each row (version bump + `.update` enqueue) and run ONE board cascade over all written ids at the end — the existing per-row cascade calls are removed. Add `KindSwitchPreview` + `previewCounterKindSwitch` mirroring the web function (`read { … }`; `isAutoCounterTitle`, `TaskTitle.generateCounterTaskTitle(…, countKind: to)`, `finalizeWindowCount`, `isFrozenDerivedRow`). `KindSwitchCopy` mirrors `kindSwitchModel.ts`. `KindSwitchConfirmView`:

```swift
import SwiftUI

/// Continuous → Discrete confirm (docs/COUNTER_KINDS.md §5). Web twin:
/// `KindSwitchConfirmDialog.tsx`. Presented as a `.sheet` with a fitted detent.
struct KindSwitchConfirmView: View {
    let preview: KindSwitchPreview
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        let lines = KindSwitchCopy.lines(preview)
        VStack(alignment: .leading, spacing: 14) {
            Text(lines.title).font(.risoHead(18, .extraBold)).foregroundStyle(Color.risoInk)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        Text(row.0).strikethrough().foregroundStyle(Color.risoMuted)
                        Text("→").foregroundStyle(Color.risoMuted).accessibilityHidden(true)
                        Text(row.1).foregroundStyle(Color.risoInk)
                    }
                    .font(.risoBody(13, .semibold))
                }
            }
            Text(lines.body).font(.risoBody(12, .regular)).foregroundStyle(Color.risoInk)
            HStack(spacing: 10) {
                RisoButton(title: "Cancel", kind: .neutral, fullWidth: true, action: onCancel)
                RisoButton(title: "Switch", kind: .blue, fullWidth: true, action: onConfirm)
            }
        }
        .padding(Riso.gutter)
        .background(Color.risoPaper)
        .presentationDetents([.height(300)])
        .presentationBackground(Color.risoPaper)
    }
}
```

- [ ] **Step 8: Run iOS** `IOS_TEST -only-testing:OYBCTests/AppDatabaseCountKindSwitchTests` — PASS (existing switch tests unchanged). `xcodegen generate`, record `KindSwitchConfirmSnapshotTests`, read vs handoff "Switch confirm".

- [ ] **Step 9: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): switchCounterKind in a caller transaction + impact preview + Continuous→Discrete confirm; iOS family switch batched (PR 3 Task 7)"
```

---

### Task 8: A4 — Task Detail edit picks / switches the kind

**Files:**
- Modify: `apps/web/src/pages/tasks/TaskEditSheet.tsx:77-80` (kind state), `:200-220` (submit), `:320-352` (Action / Kind / Goal / Unit)
- Modify: `apps/web/src/db/operations/compoundStructureEdit.ts:345-371` (`TaskEditSubmit.countKind`; `saveTaskEdit` switches first, in one transaction)
- Modify: `apps/ios/OYBC/Views/TasksTab/EditTaskSheet.swift:44-60` (`Patch.countKind: CountKind?`), `:75,116` (state), `:219-240` (fields), `:470-490` (submit), confirm sheet
- Modify: `apps/ios/OYBC/Database/AppDatabase+TaskEditing.swift:98-130` (`applyTaskEditPatch` switches first inside its `write`; goal parsed at the new kind)
- Test: `apps/web/src/db/operations/__tests__/saveTaskEdit.countKind.test.ts` (create), `apps/web/src/pages/tasks/__tests__/TaskEditSheet.countKind.test.ts` (create), `apps/ios/OYBCTests/AppDatabaseTaskEditTests.swift` (+cases)
- Re-record (intentional — Kind row): `RisoEditTaskSheetSnapshotTests/testCounting{Light,Dark}`; add `testCountingDurationLockedLight`, `testCountingContinuousLight`

**Interfaces:**
- Consumes: `KindPicker`, `GoalEntry`, `KindTag`, `KindSwitchConfirmDialog` / `KindSwitchConfirmView`, `previewCounterKindSwitch`, `switchCounterKindInTransaction` / `AppDatabase.switchCounterKind(db:…)`, `needsKindSwitchConfirm`, `kindPickerLock('edit', kind)`.
- Produces: `TaskEditSubmit.countKind?: CountKind`; iOS `EditTaskSheet.Patch.countKind: CountKind?` (nil = unchanged). Rule: Save = switch (when the kind changed) → field patch, one transaction; the typed goal is parsed at the NEW kind and written after the switch's rounding.

- [ ] **Step 1: Failing web test** `saveTaskEdit.countKind.test.ts`:

```ts
it('switches continuous → discrete then applies the typed goal, atomically', async () => {
  const root = await seedCounting({ maxCount: 26.2, countKind: 'continuous', title: 'Run 26.2 miles', action: 'Run', unit: 'miles' });
  await saveTaskEdit(root.id, { countKind: 'discrete', maxCount: 30, action: 'Run', unit: 'miles', title: '' });
  const saved = await db.tasks.get(root.id);
  expect(saved?.countKind).toBe('discrete');
  expect(saved?.maxCount).toBe(30);
});
it('a failing field patch rolls back the switch', async () => {
  const root = await seedCounting({ maxCount: 26.2, countKind: 'continuous', title: 'Run 26.2 miles', action: 'Run', unit: 'miles' });
  await expect(saveTaskEdit(root.id, { countKind: 'discrete', maxCount: 2.5 })).rejects.toThrow();
  expect((await db.tasks.get(root.id))?.countKind).toBe('continuous');
});
it('an unchanged kind does not call the switch (no extra version bump)', async () => {
  const root = await seedCounting({ maxCount: 5, title: 'Read 5 pages', action: 'Read', unit: 'pages' });
  await saveTaskEdit(root.id, { countKind: 'discrete', maxCount: 6 });
  expect((await db.tasks.get(root.id))?.version).toBe(root.version + 1);
});
```

(`seedCounting` — reuse `countKindWritePaths.test.ts`'s seed helper or add it locally.) `TaskEditSheet.countKind.test.ts` renders the sheet for a Continuous task, a Duration task and a linked row and asserts: Continuous → `aria-disabled="true"` once (Duration); Duration → three, no `id="…unit"` field; linked → no `aria-label="Kind"` group, a `KindTag`.

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST saveTaskEdit.countKind TaskEditSheet.countKind`

- [ ] **Step 3: Implement web.** `compoundStructureEdit.ts`:

```ts
export type TaskEditSubmit = UpdateTaskPatch & { compound?: TaskEditPatch; countKind?: CountKind };

export async function saveTaskEdit(taskId: string, submit: TaskEditSubmit): Promise<void> {
  const { compound, countKind, ...basicPatch } = submit;
  if (compound) {
    const description = 'description' in basicPatch ? (basicPatch.description ?? '') : undefined;
    await editCompoundStructure(taskId, compound, { description });
    return;
  }
  const existing = await db.tasks.get(taskId);
  const switching = countKind !== undefined && existing != null && resolveCountKind(existing) !== countKind;
  if (!switching) {
    await updateTaskAndCascade(taskId, basicPatch);
    return;
  }
  if (basicPatch.maxCount != null && isWholeCountKind(countKind) && !Number.isInteger(basicPatch.maxCount)) {
    throw new Error('Whole-number kinds need whole goals'); // nothing written yet
  }
  await db.transaction('rw', [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue], async () => {
    await switchCounterKindInTransaction(taskId, countKind, new Date().toISOString());
    await updateTaskAndCascade(taskId, basicPatch);
  });
}
```

(Confirm `updateTaskAndCascade` opens its transaction over a subset of these tables so Dexie nests it; if it uses a table outside the list, add that table to the outer list.) `TaskEditSheet.tsx`: `const [countKind, setCountKind] = useState<CountKind>(resolveCountKind(task)); const [pendingSwitch, setPendingSwitch] = useState<KindSwitchPreview | null>(null);` seed `maxCountStr` with `formatCountForInput(task.maxCount, resolveCountKind(task))`. Kind row (between Action and Goal, matching handoff A4's "Action / Kind / Goal · Unit / Reads as"):

```tsx
{task.sharedCounterId ? (
  <KindTag kind={resolveCountKind(task)} />
) : (
  <KindPicker
    value={countKind}
    lock={kindPickerLock('edit', resolveCountKind(task))}
    onChange={async (next) => {
      if (needsKindSwitchConfirm(countKind, next)) {
        setPendingSwitch(await previewCounterKindSwitch(task.id, next));
        return;
      }
      setCountKind(next);
    }}
  />
)}
{pendingSwitch && (
  <KindSwitchConfirmDialog
    preview={pendingSwitch}
    onCancel={() => setPendingSwitch(null)}
    onConfirm={() => {
      setCountKind(pendingSwitch.to);
      const rounded = parseCountInput(maxCountStr, 'continuous');
      if (rounded !== null) setMaxCountStr(formatCountForInput(Math.max(1, Math.floor(rounded + 0.5)), 'discrete'));
      setPendingSwitch(null);
    }}
  />
)}
```

Goal input → `GoalEntry kind={countKind}`; unit field only `countKindNeedsUnit(countKind)`; submit (`:209-217`) uses `parseCountInput(maxCountStr, countKind)` with the kind-specific messages from Task 5 and sets `patch.countKind = countKind`. The "Reads as" preview passes the kind.

- [ ] **Step 4: Run** `WEB_TEST saveTaskEdit TaskEditSheet compoundStructureEdit` PASS; `WEB_CHECK`.

- [ ] **Step 5: iOS failing tests** (append to `AppDatabaseTaskEditTests.swift`):

```swift
    func testEditSwitchesThenAppliesTypedGoal() throws {
        let db = try AppDatabase.makeTestInstance()
        var root = Task.counting(id: "r", maxCount: 26.2); root.countKind = .continuous; root.title = "Run 26.2 mi"
        try db.saveTaskForTest(root)
        _ = try db.applyTaskEditPatch(taskId: "r", patch: .countingPatch(action: "Run", unit: "mi", maxCountStr: "30", countKind: .discrete))
        let saved = try XCTUnwrap(db.fetchTask(id: "r"))
        XCTAssertEqual(saved.countKind, .discrete)
        XCTAssertEqual(saved.maxCount, 30)
    }

    func testEditRefusesThreePlaceGoalAndKeepsKind() throws {
        let db = try AppDatabase.makeTestInstance()
        var root = Task.counting(id: "r", maxCount: 26.2); root.countKind = .continuous
        try db.saveTaskForTest(root)
        XCTAssertThrowsError(try db.applyTaskEditPatch(taskId: "r", patch: .countingPatch(action: "Run", unit: "mi", maxCountStr: "2.5", countKind: .discrete)))
        XCTAssertEqual(try db.fetchTask(id: "r")?.countKind, .continuous)
    }
```

(Add `static func countingPatch(action:unit:maxCountStr:countKind:)` to a test-only `extension EditTaskSheet.Patch` in the test file, filling the achievement fields with neutral values; `saveTaskForTest` = whatever insert helper the existing tests in this file use.)

- [ ] **Step 6: Run — expect FAIL.** `IOS_TEST -only-testing:OYBCTests/AppDatabaseTaskEditTests`

- [ ] **Step 7: Implement iOS.** `Patch` gains `var countKind: CountKind? = nil`. In `applyTaskEditPatch` before `applyBasicFields`:

```swift
            if let to = patch.countKind, task.type == .counting, resolveCountKind(task.countKind) != to {
                _ = try Self.switchCounterKind(db: db, rootTaskId: taskId, to: to, now: Date())
                guard let refreshed = try Task.fetchOne(db, key: taskId) else { throw TaskEditError.taskNotFound }
                task = refreshed
            }
```

`applyBasicFields` parses `maxCountStr` with `parseCountInput(patch.maxCountStr, kind: resolveCountKind(task.countKind))` and throws the existing validation error when nil. `EditTaskSheet`: `@State private var countKind: CountKind` (seeded `resolveCountKind(task.countKind)`), `@State private var pendingSwitch: KindSwitchPreview?`; the Counting fields (`:219-240`) become Action → `fieldLabel("Kind")` + (`task.sharedCounterId != nil` ? `KindTagView(kind: resolveCountKind(task.countKind))` : `KindPickerView(selection: $countKind, lock: kindPickerLock(mode: .edit, kind: resolveCountKind(task.countKind)), onRequest: requestKind)`) → `GoalEntryView(kind: countKind, text: $maxCountStr)` → Unit only when `countKindNeedsUnit(countKind)`. `requestKind(_:)`: if `KindSwitchCopy.needsConfirm(from: countKind, to: next)` set `pendingSwitch = try? database.previewCounterKindSwitch(rootTaskId: task.id, to: next)`, else `countKind = next`; `.sheet(item: $pendingSwitch)` (make `KindSwitchPreview: Identifiable` with `var id: String { "\(from)-\(to)" }`) presenting `KindSwitchConfirmView` whose confirm sets `countKind = .discrete`, rounds `maxCountStr` (as web) and clears. The submit (`:479`) passes `countKind: countKind`.

- [ ] **Step 8: Run + snapshots.** `IOS_TEST -only-testing:OYBCTests/AppDatabaseTaskEditTests -only-testing:OYBCTests/EditTaskSheetCompoundGateTests` PASS. Re-record `RisoEditTaskSheetSnapshotTests/testCounting{Light,Dark}`, add + record `testCountingDurationLockedLight` (handoff A4: Duration locked in) and `testCountingContinuousLight`; read them.

- [ ] **Step 9: Playwright validation.** `/tasks/:id` of a seeded Continuous task → Edit → tap Discrete → the confirm shows "Run 26.2 miles → Run 26 miles", "12.75 logged → 13 logged" → Switch → Save; reload: the row reads "Run 26 miles"; screenshot the confirm light/dark → `.playwright-mcp/task8-a4-confirm-{light,dark}.png`. Add this flow to `counter-kinds-authoring.spec.ts` as `test('Task Detail: Continuous → Discrete confirms and rounds')` seeding the task with `seedTask(page, { …, countKind: 'continuous', maxCount: 26.2 })`.

- [ ] **Step 10: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): A4 Task Detail edit — kind picker, Continuous→Discrete confirm, switch+patch in one transaction (PR 3 Task 8)"
```

---

### Task 9: A3 — Board Edit square sheet (staged; applied at Save)

**Files:**
- Modify: `apps/web/src/components/boardEdit/boardEditTaskSheetModel.ts:88-115` (`SheetInput.countKind`), `:124-127` (`parseGoal(goalStr, kind)`), `:138-160` (`sheetValidationProblem`), `:169-210` (`buildSheetOverride` carries `countKind`)
- Modify: `apps/web/src/components/boardEdit/BoardEditTaskSheet.tsx:119-125` (state), `:255-330` (Kind row, GoalEntry, unit); delete the #548 row 23 caption at `:242` ("Editing this task changes it everywhere it's used.")
- Modify: `apps/web/src/db/operations/compoundStructureEdit.ts:410-470` (`applyBoardEditTaskOverrideInTransaction`: switch first when `override.countKind` differs, then fields)
- Modify: `apps/ios/OYBC/Views/BoardsTab/SquareEditTaskSheet.swift:80-100` (`EditResult.countKind`), `:99,153` (state), `:268-280` (validation), `:430-445` (fields), `:550-560` (result); delete the #548 row 24 caption at `:511`
- Modify: `apps/ios/OYBC/Views/BoardsTab/ViewModels/BoardPlayViewModel+EditCommit.swift:113-125` (`StagedTaskOverride.countKind`), `:439-470` (`applyStagedOverrides` switches first)
- Test: `apps/web/src/components/boardEdit/__tests__/boardEditTaskSheetModel.countKind.test.ts` (create), `apps/web/src/db/operations/__tests__/boardEditCommit.countKind.test.ts` (create), `apps/ios/OYBCTests/BoardEditKindSwitchTests.swift` (create)
- Re-record (intentional — Kind row + row-24 caption removal): `SquareEditTaskSheetSnapshotTests/testCounting{Light,Dark}`, `testLinkedCounterFixedTypeLight` (kind tag), `testNormal{Light,Dark}`, `testNormalThreeSegmentPickerLight`, `testCompoundLight`, `testConvertedCompoundEditorLight`, `testExistingCompoundFixedTypeEditorLight`, `testAchievementLight` (the row-24 caption sits on every type's sheet — re-record each that goes red, list the ones that did in the commit body)

**Interfaces:**
- Consumes: Tasks 3, 4, 7.
- Produces: web `SheetInput.countKind: CountKind` (the sheet's model input), `parseGoal(goalStr: string, kind: CountKind = 'discrete'): number | null`; override = `TaskEditSubmit` (now carrying `countKind`); iOS `SquareEditTaskSheet.EditResult.countKind: CountKind?`, `StagedTaskOverride.countKind: CountKind?`.
- Rules: Simple → Counting in the sheet starts the picker in `create` mode (the task becomes counting now); an existing counting task uses `edit` mode; a linked / window-stamped row shows `KindTag`. The switch applies at Save inside the squares-editor transaction, to the staged id's ROOT only when the staged task is itself a root (`sharedCounterId == null`); a remapped override never switches a placed copy.

- [ ] **Step 1: Failing web tests.** `boardEditTaskSheetModel.countKind.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { buildSheetOverride, parseGoal, sheetValidationProblem } from '../boardEditTaskSheetModel';

const original = { id: 't', type: TaskType.COUNTING, title: 'Run 26.2 mi', action: 'Run', unit: 'mi', maxCount: 26.2, countKind: 'continuous' } as Task;
const input = (o: object) => ({ original, selected: TaskType.COUNTING, title: '', action: 'Run', goalStr: '26.2', unit: 'mi', countKind: 'continuous', compoundDraft: undefined, compoundBaseline: undefined, ...o });

describe('Board Edit sheet — counter kinds', () => {
  it('parses the goal at the sheet kind', () => {
    expect(parseGoal('26.2', 'continuous')).toBe(26.2);
    expect(parseGoal('26.2', 'discrete')).toBeNull();
    expect(parseGoal('1h 30m', 'duration')).toBe(90);
  });
  it('a staged switch rides on the override', () => {
    expect(buildSheetOverride(input({ countKind: 'discrete', goalStr: '26' }) as never).countKind).toBe('discrete');
  });
  it('duration validates without a unit', () => {
    expect(sheetValidationProblem(input({ countKind: 'duration', goalStr: '1h', unit: '' }) as never)).toBeNull();
  });
});
```

(The model's exports are `SheetInput` (`:88`), `parseGoal` (`:124`), `sheetValidationProblem` (`:138`, returns the message or null) and `buildSheetOverride` (`:169`).) `boardEditCommit.countKind.test.ts` (Dexie; copy the board + placement seeding of `apps/web/src/db/operations/__tests__/boardEditLinkedOverride.test.ts`, which already builds a `CommitSquareEditsInput` around a placed counter):

```ts
const commit = (boardId: string, cells: SquareDraftCell[], rootId: string, override: BoardEditTaskOverride) =>
  commitSquareEdits({
    boardId,
    cells,
    removedBoardTaskIds: [],
    taskOverrides: new Map([[rootId, override]]),
    isLegacyChosenOnDisk: false,
    centerCellKeepLocked: false,
  });

it('kind switch then goal edit, atomic', async () => {
  const { boardId, rootId, cells } = await seedBoardWithCounter({ maxCount: 26.2, countKind: 'continuous' });
  await commit(boardId, cells, rootId, { countKind: 'discrete', maxCount: 30, action: 'Run', unit: 'mi', title: '' });
  const root = await db.tasks.get(rootId);
  expect(root?.countKind).toBe('discrete');
  expect(root?.maxCount).toBe(30);
});
it('a rejected override rolls back the staged switch', async () => {
  const { boardId, rootId, cells } = await seedBoardWithCounter({ maxCount: 26.2, countKind: 'continuous' });
  await expect(commit(boardId, cells, rootId, { countKind: 'discrete', maxCount: 2.5 })).rejects.toThrow();
  expect((await db.tasks.get(rootId))?.countKind).toBe('continuous');
});
```

(`seedBoardWithCounter` is a test-local helper: one active board, one placed COUNTING root with the given `maxCount` / `countKind`, `cells` = the board's current `SquareDraftCell[]` as `boardEditLinkedOverride.test.ts` builds them.)

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST boardEditTaskSheetModel.countKind boardEditCommit.countKind`

- [ ] **Step 3: Implement web.** `parseGoal(goalStr, kind = 'discrete')` → `parseCountInput(goalStr, kind)`; the model input type gains `countKind: CountKind`; validation's unit requirement is gated on `countKindNeedsUnit(input.countKind)`; `buildSheetOverride`'s counting branch (`:178-195`) uses `parseGoal(input.goalStr, input.countKind)`, title via `generateCounterTaskTitle(action, goal, unit, undefined, input.countKind)`, and sets `patch.countKind = input.countKind` (always explicit on a counting override). `BoardEditTaskSheet.tsx`: `const [countKind, setCountKind] = useState<CountKind>(resolveCountKind(task))` + `pendingSwitch` exactly as Task 8; the picker mode is `original.type === TaskType.COUNTING ? 'edit' : 'create'`; linked (`task.sharedCounterId != null`) → `KindTag`; Goal `GoalEntry` with `goalStr`; unit gated; include `countKind` in `input` (`:188`). Delete the `:242` caption node. `applyBoardEditTaskOverrideInTransaction`: before the existing field write,

```ts
  if (fields.countKind !== undefined && existing.type === TaskType.COUNTING && existing.sharedCounterId == null
      && resolveCountKind(existing) !== fields.countKind) {
    await switchCounterKindInTransaction(taskId, fields.countKind, now);
  }
  const { countKind: _kind, ...rest } = fields; // the switch owns countKind; never write it raw
```

and continue with `rest` (re-read `existing` after the switch so the field patch's version bump stacks on the switch's). Guard the goal at the final kind before writing: `const finalKind = fields.countKind ?? resolveCountKind(existing); if (rest.maxCount != null && isWholeCountKind(finalKind) && !Number.isInteger(rest.maxCount)) throw new Error('Whole-number kinds need whole goals');` — the throw rolls the whole Save back (Review Focus 4). iOS `applyStagedOverrides` carries the same guard (`throw BoardEditCommitError.invalidGoal` — add the case).

- [ ] **Step 4: Run** `WEB_TEST boardEdit` (every Board Edit test) — PASS; `WEB_CHECK`.

- [ ] **Step 5: iOS failing test** `BoardEditKindSwitchTests.swift` — seed a board with a Continuous root placed, stage `StagedTaskOverride(title: "", action: "Run", unit: "mi", maxCount: 30, countKind: .discrete)` through `BoardPlayViewModel.stageTaskOverride` and run the commit (copy the harness from `BoardEditCompoundTests.swift`):

```swift
    func testSwitchThenGoalEditAtomic() throws { /* commit → root.countKind == .discrete, maxCount == 30 */ }
    func testRejectedOverrideRollsBackSwitch() throws { /* maxCount 2.5 with .discrete → commit throws; root still .continuous */ }
    func testLinkedCopyIsNeverSwitchedByAnOverride() throws { /* override on a placed linked copy carrying countKind → copy and root unchanged */ }
```

(Each body follows the `BoardEditCompoundTests` pattern verbatim: build `AppDatabase.makeTestInstance()`, seed, `let vm = BoardPlayViewModel(boardId:database:)`, stage, `try await vm.commitEdit()`, assert with `db.fetchTask`.)

- [ ] **Step 6: Run — expect FAIL.** `IOS_TEST -only-testing:OYBCTests/BoardEditKindSwitchTests`

- [ ] **Step 7: Implement iOS.** `EditResult` and `StagedTaskOverride` gain `countKind: CountKind?`; `stageTaskOverride` copies it; `applyingOverride(_:to:)` (pending tasks, `:179-181`) sets `task.countKind` and rounds via `planCountKindSwitch` (a pending task has no events, so the plan is the whole story); `applyStagedOverrides` (`:439`) runs `try AppDatabase.switchCounterKind(db: db, rootTaskId: id, to: kind, now: Date())` first when the target is a live counting ROOT whose kind differs, then the field write. `SquareEditTaskSheet`: `@State private var countKind: CountKind`, `pendingSwitch`, the Kind row between Action and Goal (`KindPickerView(… lock: kindPickerLock(mode: original.type == .counting ? .edit : .create, kind: resolveCountKind(original.countKind)), onRequest: requestKind)` or `KindTagView` when linked), `GoalEntryView(kind: countKind, text: $maxCountStr)` at `:438`, unit gated, validation `:277` → `parseCountInput(maxCountStr, kind: countKind) != nil`, result `:556` → `maxCount: parseCountInput(maxCountStr, kind: countKind), countKind: countKind`. Delete the `:511` caption.

- [ ] **Step 8: Run + snapshots.** `IOS_TEST -only-testing:OYBCTests/BoardEditKindSwitchTests -only-testing:OYBCTests/BoardEditCompoundTests` PASS; run `IOS_SNAP -only-testing:OYBCSnapshotTests/SquareEditTaskSheetSnapshotTests`, re-record the reds listed under Files, add `testCountingContinuousDurationLockedLight` (handoff A3), read each.

- [ ] **Step 9: e2e + Playwright.** Extend `apps/web/e2e/squares-editor.spec.ts` (or `counter-kinds-authoring.spec.ts`) with: seeded Continuous counter on a board → Edit → tap the square → Edit task → Discrete → confirm → Save → the cell's `×` tag reads `×26`. Run `WEB_E2E e2e/squares-editor.spec.ts e2e/counter-kinds-authoring.spec.ts`. Screenshot the sheet light/dark → `.playwright-mcp/task9-a3-{light,dark}.png`.

- [ ] **Step 10: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): A3 Board Edit sheet stages a kind switch applied in the Save transaction; drop 'changes it everywhere' caption (#548 23/24) (PR 3 Task 9)"
```

---

### Task 10: A6 — Counters hub New counter (kind, Start from)

**Files:**
- Modify: `apps/web/src/db/operations/tasks.counter.ts:50-90` (`createCounterTask` input + `countKind`)
- Modify: `apps/web/src/components/counters/CreateCounterSheet.tsx:64,95,120-124,150-215` (Kind row first; "Start from" → `GoalEntry` with `allowZero`; previews via `formatCountTotal`); delete #548 rows 69, 71, 73, 75 (`:164`, `:178`, `:194`, `:204`)
- Modify: `apps/ios/OYBC/Database/AppDatabase+Counters.swift:38` (`createCounterTask(… countKind:)`)
- Modify: `apps/ios/OYBC/Views/ProfileTab/NewCounterSheetView.swift:47,68-70,92,135-145,170-290` (kind state; Start from via `GoalEntryView`; R7 `.formatted()` at `:245`, `:283` → `formatCountTotal`); delete #548 rows 70, 72, 74, 76 (`:188`, `:197`, `:205`, `:250`)
- Test: `apps/web/src/db/operations/__tests__/createCounterTask.countKind.test.ts` (create), `apps/web/src/components/counters/__tests__/CreateCounterSheet.test.ts` (create), `apps/ios/OYBCTests/AppDatabaseCounterCreateKindTests.swift` (create)
- Re-record (intentional): `CountersHubSnapshotTests/testNewCounterSheetDefault{Light,Dark}`, `testNewCounterSheetEstablishedMatch{Light,Dark}`; add `testNewCounterSheetContinuousLight`, `testNewCounterSheetContinuousDark`

**Interfaces:**
- Consumes: `KindPicker`, `GoalEntry`, `parseCountInput(…, { allowZero: true })`, `formatCountTotal`.
- Produces: web `createCounterTask(userId, { action, unit, startingCount?, countKind?: CountKind })`; iOS `createCounterTask(userId:action:unit:startingCount:countKind:)`. Rule (ruling): the hub keeps the noun field for every kind — it names the counter (`formatCounterName`) — and the noun is never appended to a Duration amount (`countUnitSuffix`).

- [ ] **Step 1: Failing tests.** Web:

```ts
it('creates a continuous counter seeded with a fractional starting count', async () => {
  const t = await createCounterTask('u1', { action: 'Run', unit: 'miles', startingCount: 148.6, countKind: 'continuous' });
  expect(t.countKind).toBe('continuous');
  expect((await db.tasks.get(t.id))?.currentCount).toBe(148.6);
  const seed = await db.taskEvents.where('taskId').equals(t.id).first();
  expect(seed?.delta).toBe(148.6);
});
it('a discrete counter refuses a fractional seed', async () => {
  await expect(createCounterTask('u1', { action: 'Do', unit: 'push-ups', startingCount: 2.5 })).rejects.toThrow();
});
```

`CreateCounterSheet.test.ts` — render; assert the Kind group is the first field, no `A plural noun`, `Used in task titles`, `Already partway`, `link up automatically` text, and a Continuous kind renders `inputMode="decimal"` for Start from. iOS `AppDatabaseCounterCreateKindTests` mirrors the two web tests.

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST createCounterTask.countKind CreateCounterSheet` / `IOS_TEST -only-testing:OYBCTests/AppDatabaseCounterCreateKindTests`

- [ ] **Step 3: Implement.** Web `createCounterTask`: `const countKind = input.countKind ?? 'discrete';` validate `isQuantizedCount(startingCount) && startingCount >= 0 && (!isWholeCountKind(countKind) || Number.isInteger(startingCount))`; add `...(countKind !== 'discrete' ? { countKind } : {})` to both the `CreateTaskInputSchema.parse` input and the `task` literal. `CreateCounterSheet`: `const [countKind, setCountKind] = useState<CountKind>('discrete');` render `<KindPicker value={countKind} lock="none" onChange={setCountKind} />` under a "Kind" label as the first field; replace the Start from `<input type="number">` with `<GoalEntry kind={countKind} value={startingCountStr} onChange={setStartingCountStr} aria-label="Start from" placeholder="0" dense />`; `startFromNum = parseCountInput(startingCountStr, countKind, { allowZero: true })` (`:95`, `:120`); `startingCount: startFromNum ?? undefined, countKind`; preview `:200` → `formatCountTotal(previewCount, countKind)`, `:215` → `formatCountTotal(match.lifetime, resolveCountKind(match.task))`; delete the four caption nodes. iOS mirrors exactly (`NewCounterSheetView` passes `countKind` through `startingCountText` parse `parseCountInput(…, kind: countKind, allowZero: true)`; `AppDatabase.createCounterTask` gains `countKind: CountKind = .discrete`, written as `nil` for discrete).

- [ ] **Step 4: Run** both test commands — PASS; `WEB_CHECK`. Re-record / record the four + two `CountersHubSnapshotTests` baselines; read vs handoff A6 (Kind first, decimal pad, 148.6 preview, no captions).

- [ ] **Step 5: Playwright validation.** `/profile/counters` → New counter → Continuous → noun "miles", verb "Run", Start from "148,6" → Create → the hub card reads `148.6`; screenshot the sheet light/dark → `.playwright-mcp/task10-a6-{light,dark}.png`.

- [ ] **Step 6: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): A6 hub New counter picks a kind + fractional Start from; grouped totals (R7); drop four helper captions (#548 69-76) (PR 3 Task 10)"
```

---

### Task 11: Member-rule steppers are kind-aware (R8 / R16)

**Files:**
- Create: `apps/ios/OYBC/Views/Riso/RisoCountStepperView.swift` (`RisoCountStepperView` + `RisoCountStepperMath`) — the compact member-row stepper, moved out of `RisoSpecialTaskPanel.swift`
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/RisoSpecialTaskPanel.swift:630-921` (delete `RisoInlineStepperStyle.compact`, the `compactBody` / `compactText` / `effectiveValue` / `commitDraft` / `step` / `compactStepButton` members and `RisoCompactStepperMath`; `RisoInlineStepperView` keeps `.regular` only — its two callers are the achievement count and the compound threshold, both Int)
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/RisoMemberRuleRowView.swift:117-150` (model resolves `kind`; passes it to `effectiveMemberTarget` / `varyRangeLabel`; suffix via `formatCount(goal, kind:)` + `countUnitSuffix`), `:221` (part caption kind), `:561-568`, `:628-636` (`RisoCountStepperView`)
- Modify: `apps/ios/OYBC/Views/CreateTab/ViewModels/BoardWizardViewModel+MemberRules.swift:148,174,266` (pass the member's kind to `effectiveMemberTarget` / `prefilledOneOffTarget` / `remainingTarget` where they are called without one — `grep -n "effectiveMemberTarget\|remainingTarget\|prefilledOneOffTarget\|varyRangeLabel\|countingSummary" apps/ios/OYBC/Views/CreateTab`)
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/RisoPoolListView.swift:336` (delete the #548 row 48 caption "shares a counter with …") and `RisoMemberRuleRowView.swift:454` (row 48)
- Modify: `apps/ios/OYBCSnapshotTests/RisoKitSnapshotTests.swift:157` (`RisoInlineStepperView(… style: .compact)` → `RisoCountStepperView(value: $target, kind: .discrete, max: 35)`)
- Delete: `apps/ios/OYBCTests/RisoCompactStepperMathTests.swift` → replaced by `apps/ios/OYBCTests/RisoCountStepperMathTests.swift` (create; ports every existing case at `kind: .discrete` plus the continuous / duration cases below)
- Modify: `apps/web/src/components/counterStepperMath.ts` (`compactStepperBase(value, draft, min, max, kind = 'discrete')` via `parseCountInput`; + `compactStepperNext(value, draft, delta, min, max, kind)`)
- Modify: `apps/web/src/components/CounterStepper.tsx:5-130` (`kind?: CountKind`; step `countTargetStep(kind)`; field text `formatCountForInput`; commit via `parseCountInput`; width from `formatCountForInput(max, kind).length`)
- Modify: `apps/web/src/components/wizard/MemberRuleRow.tsx:130-163,319-329,419-469` (kind resolved from the task; passed to `effectiveMemberTarget({ …, kind })`, `varyRangeLabel(…, kind)`, `countingSummary(…, kind)`, `CounterStepper kind={kind} min={countTargetStep(kind)}`; suffix `/ ${formatCount(goal, kind)}${countUnitSuffix(kind, unit)}`; part caption `of ${formatCount(goal, kind)}`); delete the #548 row 47 caption at `:225`
- Modify: `apps/web/src/pages/createHub/wizardMemberRulesLogic.ts` (pass kind wherever a target helper is called without one — `grep -n "effectiveMemberTarget\|remainingTarget\|prefilledOneOffTarget" apps/web/src/pages/createHub`)
- Test: `apps/web/src/components/__tests__/CounterStepper.test.ts` (+kind cases), `apps/web/src/components/wizard/__tests__/MemberRuleRow.countKind.test.ts` (create), `apps/ios/OYBCTests/MemberRuleRowModelTests.swift` (+kind cases)
- Re-record (intentional — #548 row 47/48 caption removal): `BoardWizardTasksStepSnapshotTests/testMemberRowCountingClashExpanded`, `testMemberRowCountingClashExpandedLargeText`, `RisoSourceSnapshotTests/testPoolRowExpandedCounterClashHintLight`. Every other `BoardWizardTasksStepSnapshotTests` / `RisoKitSnapshotTests/testMemberRulePrimitives*` baseline must stay GREEN (discrete renders identically — the pin that the move changed nothing).

**Interfaces:**
- Consumes: `countTargetStep`, `quantizeCount`, `formatCountForInput`, `parseCountInput`, `formatCountRange` (via `varyRangeLabel`).
- Produces:
  - web `CounterStepperProps.kind?: CountKind` (compact only; default `'discrete'`)
  - web `compactStepperNext(value: number, draft: string | null, delta: -1 | 1, min: number, max: number, kind?: CountKind): number` = `clamp(quantizeCount(base + delta * countTargetStep(kind)))`
  - iOS `RisoCountStepperView(value: Binding<CountValue>, kind: CountKind, min: CountValue? = nil, max: CountValue, suffix: String? = nil)` (min defaults to `countTargetStep(kind)`)
  - iOS `enum RisoCountStepperMath { static func committed(draft:kind:min:max:) -> CountValue?; static func base(value:draft:kind:min:max:) -> CountValue; static func stepped(value:draft:delta:kind:min:max:) -> CountValue }`
  - Step sizes: discrete 1, continuous 0.1, duration 1 minute (owner rule — never 15m / 5m).

- [ ] **Step 1: Failing tests.** Web `CounterStepper.test.ts` additions:

```ts
import { compactStepperBase, compactStepperNext } from '../counterStepperMath';

describe('compact stepper — counter kinds', () => {
  it('continuous steps 0.1 and never drifts', () => {
    expect(compactStepperNext(6.1, null, 1, 0.1, 26.2, 'continuous')).toBe(6.2);
    expect(compactStepperNext(0.2, null, -1, 0.1, 26.2, 'continuous')).toBe(0.1);
    expect(compactStepperNext(0.1, null, -1, 0.1, 26.2, 'continuous')).toBe(0.1);
  });
  it('duration steps one minute', () => {
    expect(compactStepperNext(630, null, 1, 1, 630, 'duration')).toBe(630);
    expect(compactStepperNext(630, null, -1, 1, 630, 'duration')).toBe(629);
  });
  it('a typed draft parses at the kind before stepping', () => {
    expect(compactStepperBase(5, '10h 30m', 1, 700, 'duration')).toBe(630);
    expect(compactStepperBase(5, '6,15', 0.1, 26.2, 'continuous')).toBe(6.15);
    expect(compactStepperNext(5, '6,15', 1, 0.1, 26.2, 'continuous')).toBe(6.25);
  });
  it('discrete behaviour is unchanged', () => {
    expect(compactStepperBase(6, '1.5', 1, 35)).toBe(6);
    expect(compactStepperNext(6, null, 1, 1, 35)).toBe(7);
  });
});
```

`MemberRuleRow.countKind.test.ts` — render `MemberRuleRow` (copy the props builder from `apps/web/src/components/wizard/__tests__/MemberRuleRow*.test.ts`) expanded for a Continuous member `Run 26.2 miles` at vary level 1 and assert the HTML contains `/ 26.2 miles`, `21.0–31.4 miles`, `inputMode="decimal"`; for a Duration member `Practice 10h 30m` (goal 630) assert `/ 10h 30m`, `8h 24m–12h 36m`, `value="10h 30m"`; and that `shares a counter with` never appears.

iOS `RisoCountStepperMathTests.swift` — every case of the deleted `RisoCompactStepperMathTests` ported with `kind: .discrete`, plus:

```swift
    func testContinuousStepsTenths() {
        XCTAssertEqual(Math.stepped(value: 6.1, draft: nil, delta: 1, kind: .continuous, min: 0.1, max: 26.2), 6.2)
        XCTAssertEqual(Math.stepped(value: 0.1, draft: nil, delta: -1, kind: .continuous, min: 0.1, max: 26.2), 0.1)
        XCTAssertEqual(Math.committed(draft: "6,15", kind: .continuous, min: 0.1, max: 26.2), 6.15)
    }
    func testDurationStepsOneMinute() {
        XCTAssertEqual(Math.stepped(value: 630, draft: nil, delta: -1, kind: .duration, min: 1, max: 630), 629)
        XCTAssertEqual(Math.committed(draft: "10h 30m", kind: .duration, min: 1, max: 700), 630)
    }
```

`MemberRuleRowModelTests.swift` additions: a Continuous member model has `targetSuffix == "/ 26.2 miles"` and `rangeLabel == "21.0–31.4 miles"` at `.aLittle`; a Duration member `"/ 10h 30m"` and `"8h 24m–12h 36m"`.

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST CounterStepper MemberRuleRow` / `IOS_TEST -only-testing:OYBCTests/RisoCountStepperMathTests -only-testing:OYBCTests/MemberRuleRowModelTests`

- [ ] **Step 3: Implement web.** `counterStepperMath.ts`:

```ts
import { countTargetStep, parseCountInput, quantizeCount, type CountKind } from '@oybc/shared';

export function compactStepperBase(value: number, draft: string | null, min: number, max: number, kind: CountKind = 'discrete'): number {
  if (draft === null) return value;
  const parsed = parseCountInput(draft, kind, { allowZero: true });
  if (parsed === null) return value;
  return Math.min(max, Math.max(min, parsed));
}

/**
 * The value a −/+ tap produces: one kind step (1, 0.1, or 1 minute) off the
 * effective base, quantized, clamped. Twin of iOS `RisoCountStepperMath.stepped`.
 */
export function compactStepperNext(
  value: number, draft: string | null, delta: -1 | 1, min: number, max: number, kind: CountKind = 'discrete',
): number {
  const base = compactStepperBase(value, draft, min, max, kind);
  return Math.min(max, Math.max(min, quantizeCount(base + delta * countTargetStep(kind))));
}
```

(Discrete: `parseCountInput('1.5','discrete')` is null → value, as the old `parseInt` path effectively required for the shipped tests — keep every existing `CounterStepper.test.ts` case green; if one relied on `parseInt('12abc')` = 12, that case now reverts, matching iOS's strict `Int(...)`, which is the twin contract.) `CounterStepper.tsx` compact branch: `const step = countTargetStep(kind); const text = (v: number) => formatCountForInput(v, kind);` input `inputMode={goalEntryInputMode(kind)}`, `value={draft ?? text(value)}`, `onFocus` seeds `text(value)`, `commit` uses `compactStepperBase(value, draft, min, max, kind)`, buttons `onClick={() => onChange(compactStepperNext(value, null, -1, min, max, kind))}` / `+1`, width `${Math.max(2, text(max).length) + 1}ch`. `MemberRuleRow.tsx`: `const kind = task ? resolveCountKind(task) : 'discrete';` threaded into every call listed under Files.

- [ ] **Step 4: Implement iOS.** Move the compact stepper into `RisoCountStepperView.swift` with `Binding<CountValue>`:

```swift
import SwiftUI

/// The wizard member row's compact target stepper (docs/BOARD_SOURCES.md
/// §Member rules), kind-aware (docs/COUNTER_KINDS.md §5): steps 1 for
/// Discrete, 0.1 for Continuous, 1 minute for Duration. Moved out of
/// `RisoSpecialTaskPanel.swift` (was `RisoInlineStepperView(style: .compact)`).
/// Web twin: `CounterStepper size="compact"`.
struct RisoCountStepperView: View {
    @Binding var value: CountValue
    let kind: CountKind
    var min: CountValue? = nil
    let max: CountValue
    var suffix: String? = nil

    @State private var draft: String? = nil
    @FocusState private var isFieldFocused: Bool

    private var lower: CountValue { min ?? countTargetStep(kind) }

    var body: some View {
        HStack(spacing: 0) {
            stepButton("−", label: "Decrease target", disabled: effective <= lower) { step(by: -1) }
            TextField("", text: Binding(get: { draft ?? formatCountForInput(value, kind: kind) }, set: { draft = $0 }))
                .font(.risoBody(13, .extraBold))
                .foregroundStyle(Color.risoInk)
                .multilineTextAlignment(.center)
                .keyboardType(GoalEntryModel.keyboard(for: kind))
                .focused($isFieldFocused)
                .frame(width: CGFloat(Swift.max(2, formatCountForInput(max, kind: kind).count) + 1) * 8)
                .accessibilityLabel("Target")
                .onChange(of: isFieldFocused) { _, focused in
                    if focused {
                        draft = formatCountForInput(value, kind: kind)
                        DispatchQueue.main.async {
                            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                        }
                    } else { commitDraft() }
                }
            if let suffix {
                Text(suffix)
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, 2)
                    .accessibilityHidden(true)
            }
            stepButton("＋", label: "Increase target", disabled: effective >= max) { step(by: 1) }
        }
        .frame(height: 32)
        .background(Color.risoPaper2)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }

    private var effective: CountValue {
        RisoCountStepperMath.base(value: value, draft: draft, kind: kind, min: lower, max: max)
    }

    private func commitDraft() {
        guard let d = draft else { return }
        draft = nil
        if let c = RisoCountStepperMath.committed(draft: d, kind: kind, min: lower, max: max), c != value { value = c }
    }

    private func step(by delta: CountValue) {
        let next = RisoCountStepperMath.stepped(value: value, draft: draft, delta: delta, kind: kind, min: lower, max: max)
        draft = nil
        if next != value { value = next }
    }

    private func stepButton(_ glyph: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(.risoHead(15, .extraBold))
                .foregroundStyle(Color.risoInk)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.4 : 1)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

/// Pure arithmetic behind `RisoCountStepperView` — a −/＋ tap folds the
/// uncommitted draft in first (the B3 ordering rule), now at the kind's step.
enum RisoCountStepperMath {
    static func committed(draft: String, kind: CountKind, min: CountValue, max: CountValue) -> CountValue? {
        guard let parsed = parseCountInput(draft, kind: kind, allowZero: true) else { return nil }
        return Swift.min(max, Swift.max(min, parsed))
    }
    static func base(value: CountValue, draft: String?, kind: CountKind, min: CountValue, max: CountValue) -> CountValue {
        guard let draft, let c = committed(draft: draft, kind: kind, min: min, max: max) else { return value }
        return c
    }
    static func stepped(value: CountValue, draft: String?, delta: CountValue, kind: CountKind, min: CountValue, max: CountValue) -> CountValue {
        let from = base(value: value, draft: draft, kind: kind, min: min, max: max)
        return Swift.min(max, Swift.max(min, quantizeCount(from + delta * countTargetStep(kind))))
    }
}
```

The member-row model gains `let kind: CountKind` (= `task.map { resolveCountKind($0.countKind) } ?? .discrete`), passes `kind:` to `BoardSources.effectiveMemberTarget` and `varyRangeLabel`, and builds `targetSuffix = "/ \(formatCount(goal, kind: kind))\(countUnitSuffix(kind, unit: unit))"`; part caption `"of \(formatCount(partGoal, kind: partKind))"`. Replace both `RisoInlineStepperView(… style: .compact …)` call sites with `RisoCountStepperView(value: Binding(get: { model.target }, set: { onSetTarget($0) }), kind: model.kind, max: model.goal, suffix: model.targetSuffix)` (parts: `max: Swift.max(countTargetStep(part.kind), part.goal)`). Delete the row-48 captions. `xcodegen generate`.

- [ ] **Step 5: Run** the Step 2 commands — PASS; then `IOS_SNAP -only-testing:OYBCSnapshotTests/BoardWizardTasksStepSnapshotTests -only-testing:OYBCSnapshotTests/RisoKitSnapshotTests -only-testing:OYBCSnapshotTests/RisoSourceSnapshotTests`: only the three listed caption baselines may be red; re-record them, read them. Run `node scripts/check-file-sizes.mjs` (RisoSpecialTaskPanel shrank ~290 lines).

- [ ] **Step 6: e2e + Playwright.** `WEB_E2E e2e/member-rules.spec.ts e2e/pool-default-vary.spec.ts` must stay green. Playwright MCP: wizard → Add from a pool or board → a board holding `Run 26.2 miles` (Continuous) → expand the member → step − three times (26.2 → 25.9), dice a little shows `21.0–31.4 miles`; screenshot → `.playwright-mcp/task11-member-{light,dark}.png`.

- [ ] **Step 7: Commit**

```bash
git add apps/web apps/ios
git rm apps/ios/OYBCTests/RisoCompactStepperMathTests.swift
git commit -m "feat(counters): member-row target steppers step per kind (0.1 / 1 min), callers pass the kind (R8, R16); drop 'shares a counter' caption (#548 47/48) (PR 3 Task 11)"
```

---

### Task 12: A5 — pool row editor (staged edits carry the kind)

**Files:**
- Modify: `apps/web/src/db/taskEditPatch.ts:73-90` (`TaskEditPatch.countKind?: CountKind`; `seedPatchForEditor` seeds it; `validatePatch` parses `goal` at it), `readsAsPreview(action, goal, unit, kind?)`
- Modify: `apps/web/src/components/wizard/PoolRowEditor.tsx:100-150` (Kind row; GoalEntry; unit gated; confirm); delete the #548 rows 52/53 at `:86-89`, `:96`
- Modify: `apps/web/src/db/operations/wizardBoard.ts:317-380` (`applyStagedTaskEditsForWizardPersist`: switch first when `patch.countKind` differs, then the patch) and the pending-merge path `applyPatchToTask(patch, base)` (`apps/web/src/db/taskEditPatch.ts:362`, called from `wizardPersist.ts:545-550` for pending tasks) — a pending task takes `countKind` + `planCountKindSwitch` rounding directly
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/TaskEditPatch.swift:76-200` (`countKind` already added in Task 6 — `validate(type:)` uses it; `apply` writes it), `apps/ios/OYBC/Views/CreateTab/Components/RisoPoolRowEditorView.swift:95-150` (Kind row, `GoalEntryView`, unit gated, preview kind), `apps/ios/OYBC/Database/AppDatabase+StagedTaskEdits.swift:40-80` (switch first inside the caller's `db`)
- Test: `apps/web/src/db/operations/__tests__/stagedEdits.countKind.test.ts` (create), `apps/web/src/components/wizard/__tests__/PoolRowEditor.countKind.test.ts` (create), `apps/ios/OYBCTests/StagedTaskEditsKindTests.swift` (create)
- Re-record (intentional — Kind row): `PoolRowEditorSnapshotTests/testCountingEditor{Light,Dark}`, `testCountingValidationBlockedLight`

**Interfaces:**
- Consumes: Tasks 3, 4, 6, 7.
- Produces: `TaskEditPatch.countKind?: CountKind` (web; iOS non-optional with default from Task 6). Rule: pool rows edit EXISTING tasks (mode `edit`); a pending (this-session) task's staged kind change rewrites its payload directly (no events exist yet), a persisted task's goes through `switchCounterKindInTransaction` inside the pool save / wizard persist transaction.

- [ ] **Step 1: Failing tests.** Web `stagedEdits.countKind.test.ts`:

```ts
it('pool save applies a staged Discrete → Continuous switch and a decimal goal', async () => {
  const t = await seedCounting({ maxCount: 26, title: 'Run 26 miles', action: 'Run', unit: 'miles' });
  await db.transaction('rw', [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue], () =>
    applyStagedTaskEditsForWizardPersist(new Map([[t.id, { title: '', action: 'Run', goal: '26.2', unit: 'miles', children: [], countKind: 'continuous' }]]), new Set(), NOW_ISO, { strict: true }),
  );
  const saved = await db.tasks.get(t.id);
  expect(saved?.countKind).toBe('continuous');
  expect(saved?.maxCount).toBe(26.2);
  expect(saved?.title).toBe('Run 26.2 miles');
});
it('strict mode rejects a goal invalid at the staged kind', async () => {
  const t = await seedCounting({ maxCount: 26, title: 'Run 26 miles', action: 'Run', unit: 'miles' });
  await expect(db.transaction('rw', [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue], () =>
    applyStagedTaskEditsForWizardPersist(new Map([[t.id, { title: '', action: 'Run', goal: '26.2', unit: 'miles', children: [], countKind: 'discrete' }]]), new Set(), NOW_ISO, { strict: true }),
  )).rejects.toThrow();
});
```

`PoolRowEditor.countKind.test.ts`: a Discrete row renders the Kind group with Duration `aria-disabled`; no `Staged until you create the board`, no `Esc to discard`. iOS `StagedTaskEditsKindTests` mirrors the first web case through `AppDatabase.applyStagedTaskEdits(db:…)`.

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement.** Web: `TaskEditPatch.countKind?: CountKind` (seeded from the task in `seedPatchForEditor`); `validatePatch` counting branch parses `parseCountInput(patch.goal, patch.countKind ?? 'discrete')`, requires the unit only when `countKindNeedsUnit`; in `applyStagedTaskEditsForWizardPersist`'s non-compound branch, before writing the patch:

```ts
    const stagedKind = patch.countKind;
    if (task.type === TaskType.COUNTING && stagedKind && task.sharedCounterId == null && resolveCountKind(task) !== stagedKind) {
      await switchCounterKindInTransaction(task.id, stagedKind, now);
    }
```

and the field write uses `parseCountInput(patch.goal, stagedKind ?? resolveCountKind(task))` + the kind-aware title; `applyPatchToTask` sets `countKind` (omitted for discrete) and parses `goal` at it — a pending task has no events, so the parsed goal is the whole story. `PoolRowEditor.tsx`: Kind row (`KindPicker lock={kindPickerLock('edit', resolveCountKind(task))}` or `KindTag` for a linked task) with the Task 7 confirm, `GoalEntry`, unit gated, `readsAsPreview(..., draft.countKind)`; delete the two caption nodes. iOS mirrors in `RisoPoolRowEditorView` (`KindPickerView(selection: $draft.countKind, lock: …, onRequest: …)`), `TaskEditPatch.validate(type:)` (parse at `countKind`, unit gated), and `AppDatabase+StagedTaskEdits.applyStagedTaskEdits` (switch first via `AppDatabase.switchCounterKind(db:…)`).

- [ ] **Step 4: Run** tests — PASS; `WEB_CHECK`; `WEB_E2E e2e/pool-row-editor.spec.ts e2e/pool-editor.spec.ts` (update any `getByText('Staged until…')` / `Esc to discard` assertion — delete it, the caption is gone). Re-record the three `PoolRowEditorSnapshotTests` baselines; read vs handoff A5.

- [ ] **Step 5: Playwright validation.** Wizard Tasks step → a counting row → edit → screenshot the row editor with the Kind row light/dark → `.playwright-mcp/task12-a5-{light,dark}.png`.

- [ ] **Step 6: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): A5 pool row editor kind picker; staged switches apply inside the pool save / wizard persist transaction; drop staged-edit captions (#548 52/53) (PR 3 Task 12)"
```

---

### PR 3 gate (before opening the PR)

- [ ] `pnpm --filter @oybc/shared test:coverage` (80% gate), `pnpm -w test`, `WEB_CHECK`, `node scripts/check-file-sizes.mjs`, `node scripts/check-knip.mjs`, `node scripts/check-sync-contract-rules.mjs` — all green (paste outputs untruncated — `reference_verification_traps`).
- [ ] `IOS_TEST -only-testing:OYBCTests` green; full `IOS_SNAP` red SET = the standing reds only.
- [ ] `WEB_E2E e2e/counter-kinds-authoring.spec.ts e2e/squares-editor.spec.ts e2e/member-rules.spec.ts e2e/pool-row-editor.spec.ts` green locally.
- [ ] Self-review the diff for any NEW explanatory sentence (CLAUDE.md rule) — `git diff origin/dev -- apps | grep '^+' | grep -E '"[A-Z][a-z]+ [a-z]+ [a-z]+ .*\."'` and read every hit.
- [ ] Update `docs/COUNTER_KINDS.md` Status ("PR 3 #NNN shipped"), `docs/TASK_SYSTEM.md` (one paragraph: kinds are chosen on every Goal surface), and the CLAUDE.md "No explanatory copy" backlog line if #548 rows were closed (tick them on the issue in the PR body).
- [ ] Push `git push origin HEAD:feature/counter-kinds-authoring`, `git fetch`, verify `git rev-parse HEAD` == `git rev-parse origin/feature/counter-kinds-authoring`. PR body lists every re-recorded baseline and every closed #548 row, and ends with the attribution line.

---

# PR 4 — Logging + Display UI

Branch: cut `feature/counter-kinds-logging` from `dev` after PR 3 merges (the main loop creates the external worktree `/Volumes/Stephen/oybc-worktrees/counter-kinds-logging`, seeds `.env.local` + `GoogleService-Info.plist`, runs `pnpm install && pnpm build`). Push with `git push origin HEAD:feature/counter-kinds-logging`.

### Task 13: Shared log-amount helpers, family kind on counter groups, kind-aware toasts

**Files:**
- Create: `packages/shared/src/algorithms/logAmounts.ts`, `packages/shared/tests/fixtures/logAmountVectors.json`, `packages/shared/tests/algorithms/logAmounts.test.ts`
- Modify: `packages/shared/src/algorithms/sharedCounterGroups.ts:81-102,360-370` (`SharedCounterGroup.countKind`), `packages/shared/tests/fixtures/sharedCounterGroupsVectors.json` (+`countKind` on two expected groups, one continuous source)
- Modify: `packages/shared/src/algorithms/index.ts`
- Modify: `apps/ios/OYBC/Helpers/CounterLogAmount.swift` (Swift twin of `logAmounts.ts`; `parseCustom` delegates to `parseCountInput`), `apps/ios/OYBC/Helpers/SharedCounterGroups.swift:54-76,350-356`
- Modify: `apps/web/src/components/counters/amountChips.ts` (thin wrappers over `logAmounts.ts`; `parseCustomLogAmount(raw, kind = 'discrete')`), `apps/web/src/components/counters/counterLogToastText.ts` (+`kind`), `apps/web/src/components/counters/CounterLogToast.tsx:81` (passes `kind`)
- Modify: `apps/ios/OYBC/Views/Components/CounterLogToastView.swift:25-66` (+`kind: CountKind = .discrete`; verb label via `formatCountWithUnit`), `apps/ios/OYBC/Views/BoardsTab/ViewModels/BoardPlayViewModel.swift:1066-1078` (`sharedCreditToastText` takes the source's kind — net line count must not grow: the kind is read from the existing `sourceTask` local)
- Test: `apps/ios/OYBCTests/CounterLogAmountTests.swift` (+vector test), `apps/ios/OYBCTests/SharedCounterGroupsVectorTests.swift` (decode optional `countKind`), `apps/web/src/components/counters/__tests__/amountChips.test.ts`, `counterLogToastText.test.ts` (+kind cases)

**Interfaces:**
- Consumes: `formatCount`, `formatCountWithUnit`, `countTargetStep`, `roundToCountStep`, `parseCountInput`.
- Produces (TS; Swift twin names in `CounterLogAmount`, same semantics):
  - `interface LogChip { value: number | null; label: string }` (`null` = the custom `#`)
  - `fixedLogChipAmounts(kind): readonly number[]` — `[1,10,25]` / `[0.5,1,5]` / `[15,30,60]`
  - `goalChipAmounts(goal: number, kind): number[]` — `[¼, ½, goal]` stepped + floored at one step, de-duplicated; a goal ≤ 0 falls back to `fixedLogChipAmounts`
  - `boardSheetChips(kind, goal): LogChip[]` — discrete `+1 · +10 · #`; else `goalChipAmounts` labelled `formatCount` + `#`
  - `hubChips(kind): LogChip[]` — fixed set labelled `formatCount` + `#`
  - `lateLogChipAmounts(kind, goal): number[]` — discrete `[1,2,5]`; else `goalChipAmounts`
  - `initialLogSelection(kind, chips: LogChip[], defaultLogAmount: number | null | undefined): { amount: number; isCustom: boolean }`
  - `quickLogAmount(kind, chips, defaultLogAmount): number` — discrete `default ?? 1`; else `default ?? first chip`
  - `customChipLabel(amount, kind): string` — `#3.1`, `#1h 30m`
  - `logPillLabel(kind, defaultLogAmount): string`; `logPillOpensDetail(kind, defaultLogAmount): boolean`
  - `SharedCounterGroup.countKind: CountKind`
  - `formatCounterLogToastText({ amount, unit, verb, counterName?, boardNames?, kind? })`

- [ ] **Step 1: Vectors** `logAmountVectors.json`:

```json
{
  "_note": "Cross-platform vectors for logAmounts.ts <-> CounterLogAmount.swift (docs/COUNTER_KINDS.md §5). Goal chips: [goal/4, goal/2] rounded to the kind's step (0.1 continuous, 1 minute duration — owner rule) and floored at one step, then the goal itself, de-duplicated; a goal <= 0 uses the fixed set.",
  "goalChips": [
    { "name": "continuous marathon", "goal": 26.2, "kind": "continuous", "expected": [6.6, 13.1, 26.2] },
    { "name": "duration 10h 30m quarters to the minute", "goal": 630, "kind": "duration", "expected": [158, 315, 630] },
    { "name": "duration 45m", "goal": 45, "kind": "duration", "expected": [11, 23, 45] },
    { "name": "continuous tiny goal de-duplicates", "goal": 0.1, "kind": "continuous", "expected": [0.1] },
    { "name": "continuous off-step goal kept as-is", "goal": 26.25, "kind": "continuous", "expected": [6.6, 13.1, 26.25] },
    { "name": "goal-less falls back to fixed", "goal": 0, "kind": "duration", "expected": [15, 30, 60] }
  ],
  "boardSheetChipLabels": [
    { "name": "discrete keeps +1 +10 #", "goal": 200, "kind": "discrete", "expected": ["+1", "+10", "#"] },
    { "name": "continuous goal chips", "goal": 26.2, "kind": "continuous", "expected": ["6.6", "13.1", "26.2", "#"] },
    { "name": "duration goal chips", "goal": 630, "kind": "duration", "expected": ["2h 38m", "5h 15m", "10h 30m", "#"] }
  ],
  "hubChipLabels": [
    { "name": "discrete", "kind": "discrete", "expected": ["1", "10", "25", "#"] },
    { "name": "continuous", "kind": "continuous", "expected": ["0.5", "1", "5", "#"] },
    { "name": "duration", "kind": "duration", "expected": ["15m", "30m", "1h", "#"] }
  ],
  "lateLogChips": [
    { "name": "discrete unchanged", "goal": 5, "kind": "discrete", "expected": [1, 2, 5] },
    { "name": "continuous", "goal": 26.2, "kind": "continuous", "expected": [6.6, 13.1, 26.2] }
  ],
  "initialSelection": [
    { "name": "discrete preset default", "kind": "discrete", "goal": 200, "default": 10, "expected": { "amount": 10, "isCustom": false } },
    { "name": "discrete off-preset falls back to 1", "kind": "discrete", "goal": 200, "default": 7, "expected": { "amount": 1, "isCustom": false } },
    { "name": "continuous custom default shows on #", "kind": "continuous", "goal": 26.2, "default": 3.1, "expected": { "amount": 3.1, "isCustom": true } },
    { "name": "continuous default matching a chip", "kind": "continuous", "goal": 26.2, "default": 13.1, "expected": { "amount": 13.1, "isCustom": false } },
    { "name": "duration no default picks the quarter", "kind": "duration", "goal": 630, "default": null, "expected": { "amount": 158, "isCustom": false } }
  ],
  "quickAmount": [
    { "name": "discrete default", "kind": "discrete", "goal": 200, "default": null, "expected": 1 },
    { "name": "continuous default", "kind": "continuous", "goal": 26.2, "default": 3.1, "expected": 3.1 },
    { "name": "duration first chip", "kind": "duration", "goal": 630, "default": null, "expected": 158 }
  ],
  "pill": [
    { "name": "discrete", "kind": "discrete", "default": 10, "label": "+ Log", "opensDetail": false },
    { "name": "continuous with default", "kind": "continuous", "default": 3.1, "label": "+ Log 3.1", "opensDetail": false },
    { "name": "duration with default", "kind": "duration", "default": 30, "label": "+ Log 30m", "opensDetail": false },
    { "name": "continuous never logged", "kind": "continuous", "default": null, "label": "+ Log", "opensDetail": true }
  ],
  "toast": [
    { "name": "continuous logged", "amount": 3.1, "unit": "mi", "verb": "logged", "kind": "continuous", "expected": "Logged +3.1 mi" },
    { "name": "duration logged has no unit", "amount": 90, "unit": "guitar", "verb": "logged", "kind": "duration", "expected": "Logged +1h 30m" },
    { "name": "duration removed", "amount": 30, "unit": "", "verb": "removed", "kind": "duration", "expected": "Removed 30m" },
    { "name": "continuous credited", "amount": 3.1, "unit": "mi", "verb": "logged", "kind": "continuous", "counterName": "Miles", "boardNames": ["Daily grind"], "expected": "+3.1 Miles — also counted on Daily grind." },
    { "name": "discrete unchanged", "amount": 5, "unit": "pages", "verb": "logged", "kind": "discrete", "expected": "Logged +5 pages" }
  ]
}
```

- [ ] **Step 2: Failing test** `logAmounts.test.ts` — `it.each` over every section above (`toEqual` for arrays/objects, `toBe` for strings), calling the Produces functions (`boardSheetChips(kind, goal).map(c => c.label)`, `initialLogSelection(kind, boardSheetChips(kind, goal), v.default)`, `quickLogAmount(kind, boardSheetChips(kind, goal), v.default)`); the `toast` section runs through `formatCounterLogToastText` imported from the web module in `counterLogToastText.test.ts` instead (it lives in `apps/web`) — so put the `toast` vectors' test there, importing the shared fixture as `import vectors from '../../../../../../packages/shared/tests/fixtures/logAmountVectors.json';` (six levels up from `__tests__`; if the web `tsconfig.test.json` rejects a JSON import outside `src`, read it with `JSON.parse(readFileSync(new URL('../../../../../../packages/shared/tests/fixtures/logAmountVectors.json', import.meta.url), 'utf8'))`). Run `SHARED_TEST logAmounts` — FAIL.

- [ ] **Step 3: Implement** `logAmounts.ts`:

```ts
/**
 * Counter kinds — the single owner of LOG-AMOUNT choices (docs/COUNTER_KINDS.md
 * §5): chip sets per surface, the pre-selected amount, the one-tap amount and
 * the "+ Log" pill label. Swift twin: `apps/ios/OYBC/Helpers/CounterLogAmount.swift`,
 * pinned by logAmountVectors.json.
 */
import { countTargetStep, formatCount, roundToCountStep, type CountKind } from './countValue';

/** One chip; `value: null` is the custom `#` chip. */
export interface LogChip {
  value: number | null;
  label: string;
}

const FIXED: Record<CountKind, readonly number[]> = {
  discrete: [1, 10, 25],
  continuous: [0.5, 1, 5],
  duration: [15, 30, 60],
};

/** Hub / Counter Detail presets (no single goal there). */
export function fixedLogChipAmounts(kind: CountKind): readonly number[] {
  return FIXED[kind];
}

/**
 * ¼ · ½ · goal — stepped to the kind (0.1 / 1 minute), floored at one step,
 * de-duplicated; the goal itself is never re-stepped. Goal-less → fixed set.
 */
export function goalChipAmounts(goal: number, kind: CountKind): number[] {
  if (!(goal > 0)) return [...FIXED[kind]];
  const step = countTargetStep(kind);
  const values = [0.25, 0.5].map((f) => Math.max(step, roundToCountStep(goal * f, kind)));
  values.push(goal);
  return values.filter((v, i) => values.indexOf(v) === i);
}

const CUSTOM: LogChip = { value: null, label: '#' };

/** The stepper sheet / DetailModal row. Discrete keeps `+1 · +10 · #`. */
export function boardSheetChips(kind: CountKind, goal: number): LogChip[] {
  if (kind === 'discrete') return [{ value: 1, label: '+1' }, { value: 10, label: '+10' }, CUSTOM];
  return [...goalChipAmounts(goal, kind).map((v) => ({ value: v, label: formatCount(v, kind) })), CUSTOM];
}

/** The Counter Detail Log card row. */
export function hubChips(kind: CountKind): LogChip[] {
  return [...FIXED[kind].map((v) => ({ value: v, label: formatCount(v, kind) })), CUSTOM];
}

/** Closed-board late-log presets. Discrete keeps `+1 · +2 · +5`. */
export function lateLogChipAmounts(kind: CountKind, goal: number): number[] {
  return kind === 'discrete' ? [1, 2, 5] : goalChipAmounts(goal, kind);
}

function presets(chips: LogChip[]): number[] {
  return chips.flatMap((c) => (c.value === null ? [] : [c.value]));
}

/**
 * What a sheet opens on. A remembered default matching a chip selects it; for
 * Continuous / Duration any other default shows on `#`; Discrete keeps
 * `initialChipAmount` (else 1); with nothing remembered, the first chip.
 */
export function initialLogSelection(
  kind: CountKind,
  chips: LogChip[],
  defaultLogAmount: number | null | undefined,
): { amount: number; isCustom: boolean } {
  const p = presets(chips);
  if (defaultLogAmount != null && p.includes(defaultLogAmount)) return { amount: defaultLogAmount, isCustom: false };
  if (kind === 'discrete') return { amount: 1, isCustom: false };
  if (defaultLogAmount != null) return { amount: defaultLogAmount, isCustom: true };
  return { amount: p[0] ?? countTargetStep(kind), isCustom: false };
}

/** The long-press "+ Add {last}" amount. */
export function quickLogAmount(kind: CountKind, chips: LogChip[], defaultLogAmount: number | null | undefined): number {
  if (defaultLogAmount != null) return defaultLogAmount;
  return kind === 'discrete' ? 1 : (presets(chips)[0] ?? countTargetStep(kind));
}

/** The selected custom chip's label — "#3.1", "#1h 30m". */
export function customChipLabel(amount: number, kind: CountKind): string {
  return `#${formatCount(amount, kind)}`;
}

/** "+ Log" / "+ Log 3.1" / "+ Log 30m". */
export function logPillLabel(kind: CountKind, defaultLogAmount: number | null | undefined): string {
  if (kind === 'discrete' || defaultLogAmount == null) return '+ Log';
  return `+ Log ${formatCount(defaultLogAmount, kind)}`;
}

/** A never-logged Continuous / Duration counter's pill opens Counter Detail instead of logging. */
export function logPillOpensDetail(kind: CountKind, defaultLogAmount: number | null | undefined): boolean {
  return kind !== 'discrete' && defaultLogAmount == null;
}
```

`sharedCounterGroups.ts`: `SharedCounterGroup` gains `/** The family's kind (the source's — D5). */ countKind: CountKind;` and the builder adds `countKind: resolveCountKind(source),`. `amountChips.ts`: `buildAmountChipOptions(kind = 'discrete')` → `hubChips(kind)`; `buildBoardQuickAmountOptions(kind = 'discrete', goal = 0)` → `boardSheetChips(kind, goal)`; `initialChipAmount` unchanged (discrete); `parseCustomLogAmount(raw, kind = 'discrete')` → `parseCountInput(raw, kind)`; `PRESET_LOG_AMOUNTS` stays. `counterLogToastText.ts`:

```ts
export function formatCounterLogToastText(input: CounterLogToastTextInput): string {
  const { amount, unit, verb, counterName, boardNames, kind = 'discrete' } = input;
  const amountText = formatCount(amount, kind);
  if (boardNames != null && boardNames.length > 0) {
    const sign = verb === 'logged' ? '+' : '−';
    const verbPhrase = verb === 'logged' ? 'also counted on' : 'also removed from';
    return `${sign}${amountText} ${counterName ?? ''} — ${verbPhrase} ${boardNames.join(', ')}.`;
  }
  const withUnit = `${amountText}${countUnitSuffix(kind, unit)}`;
  return verb === 'logged' ? `Logged +${withUnit}` : `Removed ${withUnit}`;
}
```

(`CounterLogToastTextInput.kind?: CountKind`; `CounterLogToast` gets a `kind?: CountKind` prop and passes it.) Swift: `CounterLogAmount` gains `static func fixedChipAmounts(_:)`, `goalChipAmounts(goal:kind:)`, `boardSheetChips(kind:goal:) -> [LogChip]`, `hubChips(kind:)`, `lateLogChipAmounts(kind:goal:)`, `initialSelection(kind:chips:defaultLogAmount:) -> (amount: CountValue, isCustom: Bool)`, `quickAmount(kind:chips:defaultLogAmount:)`, `customChipLabel(_:kind:)`, `pillLabel(kind:defaultLogAmount:)`, `pillOpensDetail(kind:defaultLogAmount:)`, `struct LogChip: Equatable { let value: CountValue?; let label: String }`; `parseCustom(_ raw: String, kind: CountKind = .discrete)` = `parseCountInput(raw, kind: kind)`. `SharedCounterGroup.countKind`. `CounterLogToastView` gains `var kind: CountKind = .discrete` and `verbLabel` = `"Logged +\(formatCountWithUnit(amount, kind: kind, unit: unit))"` / `"Removed \(…)"` with `bodyText = message ?? verbLabel` (the unit now rides inside `formatCountWithUnit`). `sharedCreditToastText` passes `kind: resolveCountKind(sourceTask?.countKind)` to `formatCount`.

- [ ] **Step 4: Run** `SHARED_TEST logAmounts sharedCounterGroups`, `WEB_TEST amountChips counterLogToastText`, `pnpm --filter @oybc/shared run gen:sync-fixtures`, iOS `CounterLogAmountTests` gets a `testVectors()` reading `logAmountVectors.json` (all sections except `toast`, plus a `toast` test through `CounterLogToastView.bodyText` made `internal` for the test), `IOS_TEST -only-testing:OYBCTests/CounterLogAmountTests -only-testing:OYBCTests/SharedCounterGroupsVectorTests` — PASS. `CountersHubSnapshotTests/testLogToast*` must stay green (discrete text unchanged).

- [ ] **Step 5: Commit**

```bash
git add packages/shared apps/web apps/ios
git commit -m "feat(counters): shared log-amount helpers (chips, initial selection, pill, quick amount), family kind on counter groups, kind-aware toasts (PR 4 Task 13)"
```

---

### Task 14: iOS stepper sheet per kind (B1 iOS)

**Files:**
- Modify: `apps/ios/OYBC/Views/BoardsTab/Components/RisoCountingStepperSheet.swift` (whole body: +`countKind`, chips for every Continuous / Duration square, pinned amount field, kind-aware labels; remove `sharedHint` — #548 row 6)
- Modify: `apps/ios/OYBC/Views/BoardsTab/BoardPlayView+CountingStepper.swift:24-58` (pass `countKind`, `defaultLogAmount` for standalone squares too; drop `sharedHint`)
- Modify: `apps/ios/OYBC/Views/BoardsTab/BoardPlayView.swift:1083-1130` (delete `sharedStepperHint(for:)` — row 6; the file shrinks, so shrink its allowlist entry by the removed count)
- Modify: `apps/ios/OYBC/Views/BoardsTab/ViewModels/BoardPlayViewModel.swift:513-543` (standalone `persistAsDefault` → `setCounterDefaultLogAmount(sourceTaskId: task.id, amount:)`; net-zero lines — replace the `guard task.maxCount != nil` comment block)
- Modify: `scripts/audit/file-size-allowlist.json` (shrink `BoardPlayView.swift`)
- Test: `apps/ios/OYBCSnapshotTests/CountingStepperSheetSnapshotTests.swift` (create), `apps/ios/OYBCTests/BoardPlayViewModelTests.swift` (+standalone persist case)

**Interfaces:**
- Consumes: `CounterLogAmount.boardSheetChips/initialSelection/customChipLabel` (Task 13), `GoalEntryView` (Task 4), `formatCountWithUnit`, `countUnitSuffix`.
- Produces: `RisoCountingStepperSheet(taskTitle:currentCount:maxCount:unitText:countKind:isLinkedCounter:isSharedCounter:defaultLogAmount:onOpenTask:onIncrement:onDecrement:)` — `sharedHint` removed. Behaviour: Discrete = today's sheet verbatim (chips only for shared squares, `+1 · +10 · #`, custom row + OK). Continuous / Duration = chips (¼ · ½ · goal · #) for every square, the amount field always visible (`GoalEntryView` with `suffix: unitText`, Duration wheel open), editing it selects `#` and makes the amount custom (`persistAsDefault: true` on log), no OK; − / + apply the field's amount (disabled when it doesn't parse).

- [ ] **Step 1: Failing snapshot tests** `CountingStepperSheetSnapshotTests.swift` (three sheets of handoff `sheets[]`):

```swift
import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

final class CountingStepperSheetSnapshotTests: XCTestCase {
    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func sheet(_ kind: CountKind, title: String, unit: String, cur: CountValue, max: CountValue, shared: Bool, defaultAmount: CountValue?) -> some View {
        RisoCountingStepperSheet(taskTitle: title, currentCount: cur, maxCount: max, unitText: unit, countKind: kind,
                                 isLinkedCounter: false, isSharedCounter: shared, defaultLogAmount: defaultAmount, onOpenTask: {})
            .frame(width: 393, height: kind == .duration ? 520 : 400)
            .background(Color.risoPaper)
    }

    func testDiscreteSharedLight() {
        assertSnapshot(of: sheet(.discrete, title: "Do 200 push-ups", unit: "push-ups", cur: 132, max: 200, shared: true, defaultAmount: 10),
                       as: .image(layout: .fixed(width: 393, height: 400)), record: recordMode)
    }
    func testContinuousCustomLight() {
        assertSnapshot(of: sheet(.continuous, title: "Run 26.2 mi", unit: "mi", cur: 12.4, max: 26.2, shared: false, defaultAmount: 3.1),
                       as: .image(layout: .fixed(width: 393, height: 400)), record: recordMode)
    }
    func testContinuousCustomDark() {
        assertSnapshot(of: sheet(.continuous, title: "Run 26.2 mi", unit: "mi", cur: 12.4, max: 26.2, shared: false, defaultAmount: 3.1),
                       as: .image(layout: .fixed(width: 393, height: 400), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }
    func testDurationQuarterLight() {
        assertSnapshot(of: sheet(.duration, title: "Practice 10h 30m", unit: "", cur: 270, max: 630, shared: false, defaultAmount: nil),
                       as: .image(layout: .fixed(width: 393, height: 520)), record: recordMode)
    }
    func testDurationQuarterDark() {
        assertSnapshot(of: sheet(.duration, title: "Practice 10h 30m", unit: "", cur: 270, max: 630, shared: false, defaultAmount: nil),
                       as: .image(layout: .fixed(width: 393, height: 520), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }
    func testOvershootLight() {
        assertSnapshot(of: sheet(.continuous, title: "Run 26.2 mi", unit: "mi", cur: 28.4, max: 26.2, shared: false, defaultAmount: 3.1),
                       as: .image(layout: .fixed(width: 393, height: 400)), record: recordMode)
    }
}
```

`BoardPlayViewModelTests` addition: a standalone Continuous square logged with `handleCountingTap(…, amount: 3.1, persistAsDefault: true)` leaves `task.defaultLogAmount == 3.1`; with `persistAsDefault: false` it stays nil.

- [ ] **Step 2: Run — expect build FAIL** (`extra argument 'countKind'`). `IOS_SNAP -only-testing:OYBCSnapshotTests/CountingStepperSheetSnapshotTests`

- [ ] **Step 3: Implement.** In `RisoCountingStepperSheet`: replace `sharedHint` with `let countKind: CountKind` (init parameter after `unitText`, default `.discrete` so previews compile); state seeded from `CounterLogAmount.initialSelection(kind: countKind, chips: chips, defaultLogAmount: defaultLogAmount)` (`selectedAmount`, `isCustomActive`), plus `@State private var amountText: String` seeded `formatCountForInput(selectedAmount, kind: countKind)` for the new kinds. Derived:

```swift
    private var isEntryKind: Bool { countKind != .discrete }
    private var chips: [CounterLogAmount.LogChip] { CounterLogAmount.boardSheetChips(kind: countKind, goal: maxCount) }
    private var showsChips: Bool { isEntryKind || isSharedCounter }
    private var effectiveAmount: CountValue? {
        if isEntryKind { return parseCountInput(amountText, kind: countKind) }
        return isSharedCounter ? selectedAmount : 1
    }
    private var progressText: String { "\(formatCount(currentCount, kind: countKind))/\(formatCount(maxCount, kind: countKind))" }
```

Label pill: `"\(taskTitle) · \(progressText)\(countUnitSuffix(countKind, unit: unitText))"`; the value display `progressText`; − / + call `onDecrement(amount, effectivePersist)` / `onIncrement` only when `effectiveAmount` is non-nil (`.disabled(effectiveAmount == nil)` on +, `|| currentCount == 0` on −). Chip tap for new kinds: `selectedAmount = v; isCustomActive = false; amountText = formatCountForInput(v, kind: countKind)`; `#` focuses the field. Amount field (new kinds, always shown under the chips):

```swift
                if isEntryKind {
                    GoalEntryView(kind: countKind, text: Binding(
                        get: { amountText },
                        set: { amountText = $0; isCustomActive = parseCountInput($0, kind: countKind).map { v in !chips.contains { $0.value == v } } ?? true }
                    ), placeholder: "Amount", suffix: unitText.isEmpty ? nil : unitText, startsOpen: countKind == .duration)
                }
```

Chip highlighting for new kinds: index of the chip whose value equals `parseCountInput(amountText)`, else `#` (labelled `CounterLogAmount.customChipLabel(_:kind:)` when it holds a value). Discrete path: unchanged code, with `formatCount(…, kind: .discrete)` → `countKind`. Bar fill (if the sheet draws one) gold when `currentCount > maxCount`. `sheetHeight`: `+ 56` chips when `showsChips`, `+ 52` amount field for Continuous, `+ 190` (field + wheel) for Duration, custom row only for discrete. Remove the `sharedHint` block and parameter; update the `#Preview`s.

`BoardPlayView+CountingStepper.swift`: pass `countKind: resolveFamilyCountKind(task, lookup: { taskMap[$0] })`, `defaultLogAmount: (sourceId.flatMap { taskMap[$0] } ?? task).defaultLogAmount` (standalone squares remember their own); drop `sharedHint`. `BoardPlayView.swift`: delete `sharedStepperHint(for:)` and its now-unused helpers (`grep -n "sharedStepperHint" apps/ios/OYBC`), shrink the allowlist number to the new `wc -l`. `BoardPlayViewModel.handleCountingTap` standalone branch: after `runOrchestration(…)`, `if persistAsDefault { try? database.setCounterDefaultLogAmount(sourceTaskId: task.id, amount: amount) }` (log failures through the existing `dlog`); keep the file at ≤ 1518 by collapsing the adjacent comment block.

- [ ] **Step 4: Run** `IOS_TEST -only-testing:OYBCTests/BoardPlayViewModelTests` PASS; `xcodegen generate`; record the six snapshots; read each vs handoff B1 iOS (Continuous: chips 6.6 · 13.1 · 26.2 · #3.1 selected, decimal pad field "3.1 mi"; Duration: ¼ = 2h 38m selected — NOT the handoff's 2h 40m, owner override). `node scripts/check-file-sizes.mjs`.

- [ ] **Step 5: Commit**

```bash
git add apps/ios scripts/audit/file-size-allowlist.json
git commit -m "feat(counters): iOS stepper sheet per kind — goal chips, pinned amount field, h:m wheel; standalone counters remember a custom amount; drop shared-hint caption (#548 6) (PR 4 Task 14)"
```

---

### Task 15: Web — every counting tap opens the DetailModal; modal per kind (B1 web)

**Files:**
- Create: `apps/web/src/components/boardPlay/useCountingLogModal.ts` — the modal quick-amount state + builder moved out of `BoardPlaySurface.tsx:228-252,1010-1080`
- Modify: `apps/web/src/components/BoardPlaySurface.tsx:804-827` (counting tap → `setSelectedSquareId(boardTaskId)`), `:1000-1115` (modal props via the hook), `:1149` (drop `menuSharedHint`) — net line count must DROP; shrink the allowlist entry
- Modify: `apps/web/src/components/InteractiveTaskSquare.tsx:418-480` (`DetailModalProps.quickAmount` gains `kind`, `amountText`, `onAmountTextChange`, `addLabel`), `:567-700` (counting body per kind), `:226,699` (drop `sharedHint` — #548 row 5), `:205` + `BoardPlaySurface.tsx:1080` (drop the "Linked counters cannot be decremented directly" title — row 7; the disabled − is the signal), `:393` (delete the "Tap: +1 {unit}" hover hint — row 8)
- Modify: `apps/web/src/components/interactiveTaskSquareUtils.ts:47-60,164-167` (`TaskSquareData.countKind?: CountKind`; `progressBarLabel` via `formatCount` + `countUnitSuffix`), `apps/web/src/db/adapters.ts:158` (`taskToSquareData` sets `countKind` via `resolveFamilyCountKind`)
- Modify: `apps/web/src/hooks/useBoardPlayData.ts:72,270-310` (delete `sharedCounterHintsByTaskId`), `apps/web/src/db/operations/__tests__/sharedCounterWindowRegression.test.ts:150-170` (delete the hint assertions — the hint no longer exists; keep the window assertions)
- Modify: `apps/web/e2e/windowed-completion.spec.ts:205-207` (tap opens the modal; press "Increase")
- Test: `apps/web/src/components/boardPlay/__tests__/useCountingLogModal.test.ts` (create — pure `buildQuickAmount` function exported from the hook module), `apps/web/src/components/__tests__/DetailModalKinds.test.ts` (create), `apps/web/e2e/counter-kinds-logging.spec.ts` (create)

**Interfaces:**
- Consumes: Task 13 helpers, `GoalEntry`, `setCounterDefaultLogAmount`, `handleComplete`, `handleSharedCounterIncrement/Decrement`.
- Produces:
  - `useCountingLogModal(args: { selectedSquareId: string | null; boardTasks: BoardTask[]; taskMap: Record<string, Task>; sharedCounterSourceIds: Set<string>; isSealed: boolean; currentCountFor: (boardTaskId: string) => number; onIncrementShared: (sourceId: string, amount: number, persist: boolean) => Promise<void>; onDecrementShared: (sourceId: string, amount: number, persist: boolean) => Promise<void>; onSetStandaloneCount: (boardTaskId: string, next: number) => Promise<void>; onPersistDefault: (taskId: string, amount: number) => Promise<void> }): DetailModalProps['quickAmount'] | undefined`
  - pure `buildQuickAmount(state: QuickAmountState, ctx: QuickAmountContext): DetailModalProps['quickAmount'] | undefined` (unit-tested)
  - Rules: Discrete standalone → `undefined` (the plain −/+ stepper, ±1); Discrete shared → today's `+1 · +10 · #` row; Continuous / Duration (any) → goal chips + an always-visible `GoalEntry` amount field + "− | cur/max | + {amount} {unit}" (`addLabel` = `+ ${formatCountWithUnit(amount, kind, unit)}`).

- [ ] **Step 1: Failing tests.** `DetailModalKinds.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { DetailModal } from '../InteractiveTaskSquare';

const base = { onClose: () => {}, onToggleComplete: () => {}, onIncrementCount: () => {}, onDecrementCount: () => {} };
const quick = (o: object) => ({
  options: [{ value: 6.6, label: '6.6' }, { value: 13.1, label: '13.1' }, { value: 26.2, label: '26.2' }, { value: null, label: '#' }],
  selected: 3.1, isCustomActive: true, customOpen: false, customDraft: '', unit: 'mi', busy: false,
  onSelectChip: () => {}, onOpenCustom: () => {}, onCustomDraftChange: () => {}, onConfirmCustom: () => {},
  onAdd: () => {}, onRemove: () => {}, removeDisabled: false,
  kind: 'continuous', amountText: '3.1', onAmountTextChange: () => {}, addLabel: '+ 3.1 mi', ...o,
});

describe('DetailModal — counter kinds', () => {
  it('continuous: chips, pinned amount field, + {amount} {unit}, no OK', () => {
    const html = renderToStaticMarkup(React.createElement(DetailModal, {
      ...base, sq: { id: 's', title: 'Run 26.2 mi', type: 'counting', action: 'Run', maxCount: 26.2, unit: 'mi', countKind: 'continuous' },
      state: { isCompleted: false, currentCount: 12.4, completedStepIds: new Set() }, quickAmount: quick({}) as never,
    }));
    expect(html).toContain('#3.1');
    expect(html).toContain('inputMode="decimal"');
    expect(html).toContain('+ 3.1 mi');
    expect(html).toContain('12.4/26.2 mi');
    expect(html).not.toContain('>OK<');
  });
  it('duration: h / m fields and no unit', () => {
    const html = renderToStaticMarkup(React.createElement(DetailModal, {
      ...base, sq: { id: 's', title: 'Practice 10h 30m', type: 'counting', action: 'Practice', maxCount: 630, unit: '', countKind: 'duration' },
      state: { isCompleted: false, currentCount: 270, completedStepIds: new Set() },
      quickAmount: quick({ kind: 'duration', amountText: '2h 38m', unit: '', addLabel: '+ 2h 38m', selected: 158, isCustomActive: false,
        options: [{ value: 158, label: '2h 38m' }, { value: 315, label: '5h 15m' }, { value: 630, label: '10h 30m' }, { value: null, label: '#' }] }) as never,
    }));
    expect(html).toContain('aria-label="Log amount hours"');
    expect(html).toContain('4h 30m/10h 30m');
  });
  it('no shared hint, no hover tap hint, no linked tooltip (#548 5/7/8)', () => {
    const html = renderToStaticMarkup(React.createElement(DetailModal, {
      ...base, sq: { id: 's', title: 'Push', type: 'counting', action: 'Do', maxCount: 10, unit: 'reps', sharedCounterId: 'r' },
      state: { isCompleted: false, currentCount: 3, completedStepIds: new Set() },
    }));
    expect(html).not.toContain('also counts on');
    expect(html).not.toContain('cannot be decremented');
  });
});
```

`useCountingLogModal.test.ts` — `buildQuickAmount` cases: discrete standalone → `undefined`; discrete shared → labels `['+1','+10','#']`; continuous standalone with `defaultLogAmount: 3.1` → `isCustomActive: true`, `amountText: '3.1'`, `addLabel: '+ 3.1 mi'`; `onAdd` on a continuous standalone calls `onSetStandaloneCount(bt, quantizeCount(12.4 + 3.1))` = 15.5 and `onPersistDefault('t', 3.1)` (custom), while a chip amount calls no persist; a typed `'31'` then `onRemove` decrements exactly 31 (Review Focus — the 31-vs-3.1 correction).

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST DetailModalKinds useCountingLogModal`

- [ ] **Step 3: Implement.** `useCountingLogModal.ts` holds the `modalQuickAmount` state (moved from `BoardPlaySurface.tsx:228-252`, extended with `amountText`) and exports `buildQuickAmount` (moved from `:1010-1080`, extended):
  - kind = `resolveFamilyCountKind(task, (id) => taskMap[id])`; source = `resolveSharedCounterSourceId(task, sharedCounterSourceIds)`; `if (kind === 'discrete' && !source) return undefined;`
  - `options = boardSheetChips(kind, task.maxCount ?? 0)`; the initial state from `initialLogSelection(kind, options, (source ? taskMap[source] : task)?.defaultLogAmount)`; `amountText` seeded `formatCountForInput(amount, kind)` for the new kinds.
  - `selected` for new kinds = `parseCountInput(amountText, kind)`; `onAdd`/`onRemove` no-op when it is null; standalone new-kind add → `onSetStandaloneCount(bt.id, quantizeCount(cur + amount))`, remove → `Math.max(0, quantizeCount(cur - amount))`; when `isCustomActive` → `onPersistDefault(task.id, amount)`; shared → the existing `onIncrementShared/onDecrementShared(source, amount, isCustomActive)`.
  - `addLabel = kind === 'discrete' ? `+ ${amount}` : `+ ${formatCountWithUnit(amount, kind, unit)}``.
  - `removeDisabled = isLinkedCounter || current <= 0 || selected === null`.
  In `BoardPlaySurface.tsx` the counting tap branch (`:804-827`) collapses to `setSelectedSquareId(boardTaskId);` for every counting square (not sealed); the modal block uses `const quickAmount = useCountingLogModal({ … })` (call the hook at the top level with `selectedSquareId`, not inside the IIFE); `onPersistDefault` = `setCounterDefaultLogAmount`. Delete `modalSharedHint` / `menuSharedHint` / the `removeTitle` string. `DetailModal` counting body: when `quickAmount?.kind` is continuous/duration render the chip row (custom chip label `customChipLabel(selected, kind)` when custom), then `<GoalEntry kind={kind} value={quickAmount.amountText} onChange={quickAmount.onAmountTextChange} aria-label="Log amount" suffix={unit || undefined} dense />` (no OK button, no `customOpen` row), then the actions row `− | {progress} | {addLabel}` where progress = `${formatCount(cur, kind)}/${formatCount(max, kind)}`; meta line `{action} · {formatCountWithUnit(max, kind, unit)}`; the bar fill class gets `modalProgressFillOver` (gold, `background: var(--riso-gold)`) when `cur > max`. The Discrete paths render exactly as today. Remove `sharedHint` from `DetailModalProps` + `ContextMenuProps` and the "Tap: +1" span; drop the now-unused CSS classes (`.sharedHint`, `.actionHint`).

- [ ] **Step 4: Run** `WEB_TEST DetailModal useCountingLogModal boardPlay sharedCounterWindowRegression` PASS; `WEB_CHECK`; `node scripts/check-file-sizes.mjs` (BoardPlaySurface below 1241 — shrink its entry).

- [ ] **Step 5: e2e.** Update `windowed-completion.spec.ts:205-207`:

```ts
    // Tap opens the stepper modal (counter kinds §5 — web no longer logs +1 on tap).
    await counterSquare.click();
    await page.getByRole('dialog').getByRole('button', { name: 'Increase' }).click();
    await page.keyboard.press('Escape');
    await expect(counterSquare).toContainText('1/10');
```

Create `apps/web/e2e/counter-kinds-logging.spec.ts`: seed a board with a standalone Continuous task (`maxCount: 26.2, countKind: 'continuous', unit: 'mi'`) and a Duration task (`maxCount: 630, countKind: 'duration'`); (1) tap the Continuous square → modal → chip `13.1` → `+ 13.1 mi` → Escape → the cell reads `13.1/26.2`; (2) reopen → type `3,1` into "Log amount" → `+ 3.1 mi` → cell `16.2/26.2`; reload → the modal opens with `#3.1` selected (persisted default); (3) Duration square → `Log amount hours` 1, minutes 30 → `+ 1h 30m` → cell `1h 30m/10h 30m`. Run `WEB_E2E e2e/windowed-completion.spec.ts e2e/counter-kinds-logging.spec.ts` — PASS.

- [ ] **Step 6: Playwright validation.** Screenshot the Continuous and Duration modals light/dark → `.playwright-mcp/task15-b1-{continuous,duration}-{light,dark}.png`; compare to handoff B1 web.

- [ ] **Step 7: Commit**

```bash
git add apps/web scripts/audit/file-size-allowlist.json
git commit -m "feat(counters): web counting tap opens the DetailModal; modal per kind (goal chips, pinned amount field); extract useCountingLogModal; drop shared hint / tap hint / linked tooltip (#548 5, 7, 8) (PR 4 Task 15)"
```

---

### Task 16: Long-press / right-click menu per kind (B2)

**Files:**
- Modify: `apps/ios/OYBC/Views/BoardsTab/BoardPlayView.swift:1397-1424` (counting menu) — net-zero or smaller
- Modify: `apps/web/src/components/InteractiveTaskSquare.tsx:44-60,146-215` (`sharedAmountActions` → `amountActions` for every counting square of a new kind), `apps/web/src/components/BoardPlaySurface.tsx:1151-1200`
- Test: `apps/web/src/components/__tests__/FloatingContextMenuKinds.test.ts` (create), `apps/ios/OYBCTests/BoardPlayContextMenuLabelTests.swift` (create — the label builder is a pure static on a new `enum CountingMenuLabels` in `apps/ios/OYBC/Views/BoardsTab/Components/CountingMenuLabels.swift` so BoardPlayView only calls it)

**Interfaces:**
- Consumes: `quickLogAmount`, `boardSheetChips`, `formatCountWithUnit` (Task 13).
- Produces: web `ContextMenuProps.amountActions?: { kind: CountKind; amount: number; unit: string; onAdd(amount): void; onRemove(amount): void; onOpenCustom(): void; removeDisabled: boolean }`; iOS `enum CountingMenuLabels { static func add(amount:kind:unit:action:) -> String; static func remove(amount:kind:unit:action:) -> String }` — Discrete returns today's iOS strings ("+ Add {n} {action}" / "− Remove {n} {action}"); Continuous / Duration return "+ Add 3.1 mi" / "− Remove 3.1 mi" ("+ Add 1h 30m").
- Menu for Continuous / Duration (both platforms): `+ Add {last} {unit}` · `# Custom amount…` (opens the stepper sheet / modal) · `− Remove {last} {unit}` · (web keeps `↺ Reset`) · divider · `View Details` · `Open in library`. Discrete: unchanged on both platforms.

- [ ] **Step 1: Failing tests.** Web: render `FloatingContextMenu` for a Continuous square with `amountActions: { kind: 'continuous', amount: 3.1, unit: 'mi', … }` → contains `+ Add 3.1 mi`, `# Custom amount…`, `− Remove 3.1 mi`; for a Duration square amount 90 → `+ Add 1h 30m`; for a Discrete standalone square without `amountActions` → `+ Add Do (+1)` (unchanged). iOS `BoardPlayContextMenuLabelTests`:

```swift
    func testLabels() {
        XCTAssertEqual(CountingMenuLabels.add(amount: 3.1, kind: .continuous, unit: "mi", action: "Run"), "+ Add 3.1 mi")
        XCTAssertEqual(CountingMenuLabels.remove(amount: 90, kind: .duration, unit: "", action: "Practice"), "− Remove 1h 30m")
        XCTAssertEqual(CountingMenuLabels.add(amount: 1, kind: .discrete, unit: "reps", action: "Do"), "+ Add 1 Do")
    }
```

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement.** iOS: in `risoContextMenu`'s `.counting` case, `let kind = resolveFamilyCountKind(t, lookup: { taskMap[$0] })`, `let amount = CounterLogAmount.quickAmount(kind: kind, chips: CounterLogAmount.boardSheetChips(kind: kind, goal: t.maxCount ?? 0), defaultLogAmount: (viewModel.sharedCounterSourceId(for: t).flatMap { taskMap[$0] } ?? t).defaultLogAmount)`; buttons use `CountingMenuLabels.add/remove(…)`; for `kind != .discrete` insert `Button("Custom amount…", systemImage: "number") { countingStepperBoardTaskId = boardTask.id }` between Add and Remove. Web: `BoardPlaySurface` builds `amountActions` for every new-kind counting square (shared or not) using `quickLogAmount`; discrete shared squares keep `sharedAmountActions` (unchanged); `FloatingContextMenu` renders the new block when `amountActions` is set (`+ Add {formatCountWithUnit}` → `onAdd(amount)`, `# Custom amount…` → `onOpenCustom` = `setSelectedSquareId(bt.id)`, `− Remove …` disabled by `removeDisabled`).

- [ ] **Step 4: Run** tests PASS; `WEB_CHECK`; `node scripts/check-file-sizes.mjs`; `xcodegen generate`. Extend `counter-kinds-logging.spec.ts`: right-click the Continuous square → `+ Add 3.1 mi` → the cell grows by 3.1.

- [ ] **Step 5: Commit**

```bash
git add apps/web apps/ios scripts/audit/file-size-allowlist.json
git commit -m "feat(counters): long-press / right-click menu adds and removes the last amount per kind, Custom amount opens the sheet (PR 4 Task 16)"
```

---

### Task 17: Closed-board late log per kind (B3)

**Files:**
- Modify: `apps/ios/OYBC/Views/BoardsTab/LateLog/LateLogSheetView.swift:30-36` (`Kind.counting(current:max:unit:countKind:)`), `:156-192` (chips, custom entry via `GoalEntryView`, readout)
- Modify: `apps/ios/OYBC/Views/BoardsTab/BoardPlayView+LateLog.swift:118` (passes `countKind: resolveFamilyCountKind(task, lookup:)`)
- Modify: `apps/web/src/components/lateLog/LateLogSheet.tsx:23-24,236-330` (chips via `lateLogChipAmounts`; custom `GoalEntry`; readout `formatCount`; button label)
- Test: `apps/ios/OYBCSnapshotTests/BoardCloseReopenSnapshotTests.swift` (+`testLateLogContinuous{Light,Dark}`, `testLateLogDuration{Light,Dark}`), `apps/web/e2e/late-log-counting.spec.ts` (+Continuous case), `apps/web/src/components/lateLog/__tests__/LateLogSheet.kinds.test.ts` (create — renders the counting body through a test-exported `CountingLateLogBody` with a stubbed `state`)

**Interfaces:**
- Consumes: `lateLogChipAmounts`, `parseCountInput`, `formatCountWithUnit`, `GoalEntry(View)`.
- Produces: iOS `LateLogSheetView.Kind.counting(current:max:unit:countKind:)`; web button label: Discrete `Log` (unchanged); Continuous / Duration `Log +{amount}{ unit}` ("Log +4.9 mi", "Log +1h 30m"). Chip labels `+{formatCount}` (`+6.6`, `+2h 38m`) followed by `Custom…`.

- [ ] **Step 1: Failing tests.** Web `LateLogSheet.kinds.test.ts`: Continuous goal 26.2, count 21.3 → chips `+6.6`, `+13.1`, `+26.2`, `Custom…`; readout `21.3/26.2`; with custom `4.9` the button reads `Log +4.9 mi`; Discrete → chips `+1 +2 +5`, button `Log`. iOS snapshot cases render `LateLogSheetView(windowLabel: "Mar 1 – 31", taskTitle: "Run 26.2 mi", kind: .counting(current: 21.3, max: 26.2, unit: "mi", countKind: .continuous))` and the Duration twin (`540`, `630`, `""`, `.duration`) at 393×360 / 393×520.

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement.** iOS `countingBody(current:max:unit:countKind:)`: readout `"\(formatCount(current, kind: countKind))/\(formatCount(max, kind: countKind))\(countUnitSuffix(countKind, unit: unit))"`; `ForEach(CounterLogAmount.lateLogChipAmounts(kind: countKind, goal: max), id: \.self)` buttons titled `"+\(formatCount(amount, kind: countKind))"`; the custom row's `RisoNumberField` → `GoalEntryView(kind: countKind, text: $customAmountDraft, placeholder: "Amount", startsOpen: countKind == .duration)`; parse with `CounterLogAmount.parseCustom(customAmountDraft, kind: countKind)`; `sheetHeight` `.counting` = `countKind == .duration ? 470 : 280`. Web: `const kind = resolveCountKind(task); const chips = lateLogChipAmounts(kind, task.maxCount ?? 0);` `useState<number>(chips[0])` for `selected`; chip text `+${formatCount(amount, kind)}`; custom `GoalEntry kind={kind} value={customDraft} onChange={setCustomDraft} aria-label="Custom amount" placeholder="Amount" dense`; `customAmount = parseCustomLogAmount(customDraft, kind)`; readout `formatCount(state.count, kind)` / `formatCount(max, kind)`, unit hidden for Duration; button label `kind === 'discrete' ? 'Log' : `Log +${formatCountWithUnit(customOpen ? customAmount ?? 0 : selected, kind, task.unit)}``.

- [ ] **Step 4: Run** tests; `WEB_E2E e2e/late-log-counting.spec.ts` — the existing discrete cases unchanged + new: a closed board with a Continuous `Run 26.2 mi` square → tap → `+6.6` → `Log +6.6 mi` → the frozen record shows `6.6/26.2`. Record the four iOS snapshots; read vs handoff B3.

- [ ] **Step 5: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): closed-board late log per kind — goal chips, decimal / h:m custom entry, Log +amount (PR 4 Task 17)"
```

---

### Task 18: Hub ledger cards, Profile rows, "+ Log" pills (B4)

**Files:**
- Modify: `apps/web/src/components/counters/CounterLedgerCard.tsx:61-190` (pill label/behaviour; lifetime `formatCountTotal`; row values `formatCount` — R7 sites `:65`, `:174-175`)
- Modify: `apps/web/src/pages/ProfilePage.tsx:338-416` (compact rows: pill + lifetime + member value — R7 `:392-393`, `:404`)
- Modify: `apps/web/src/pages/CountersHubPage.tsx:113-116` (delete the #548 row 85 intro `<p>`); the toast gets `kind`
- Modify: `apps/ios/OYBC/Views/ProfileTab/Components/SharedCounterLedgerCard.swift:51,81,100,107-118,136,189,236,270` (R7 `.formatted()` ×3 → `formatCountTotal` / `formatCount`; pill), `apps/ios/OYBC/Views/ProfileTab/CountersHubView.swift:141-160,232-236` (pill opens detail when `pillOpensDetail`; delete the row 86 intro `Text`), `apps/ios/OYBC/Views/ProfileTab/ViewModels/ProfileHomeViewModel.swift:143-160`, `apps/ios/OYBC/Views/ProfileTab/Components/ProfileCountersSection.swift` (pill → detail)
- Test: `apps/web/src/components/counters/__tests__/CounterLedgerCard.test.ts` (create), `apps/ios/OYBCTests/ProfileHomeViewModelTests.swift` (+pill cases), snapshots
- Re-record (intentional): `CountersHubSnapshotTests/testHubPopulated{Light,Dark}`, `testHubEmpty{Light,Dark}` (row 86 intro removal); add `testHubContinuousDurationLight`, `testHubContinuousDurationDark` (handoff `ledgers[]`); `RisoProfileSnapshotTests/testPopulated{Light,Dark}` only if red (discrete rows should be pixel-identical — `formatCountTotal` = the old `.formatted()` for integers; a red there is a regression to fix, not re-record)

**Interfaces:**
- Consumes: `logPillLabel`, `logPillOpensDetail`, `formatCountTotal`, `SharedCounterGroup.countKind`.
- Produces: pill behaviour — `logPillOpensDetail(group.countKind, group.defaultLogAmount)` ⇒ navigate to Counter Detail (`/profile/counters/:id` ↔ `navigateToCounterId`), else log `group.defaultLogAmount ?? 1` exactly as today; label `logPillLabel(…)`; aria/VoiceOver `Log {formatCountWithUnit} for {name}`.

- [ ] **Step 1: Failing tests.** Web `CounterLedgerCard.test.ts`: a Continuous group (`lifetime 148.6`, `defaultLogAmount 3.1`) renders `148.6`, `+ Log 3.1`, rows `12.4/26.2` and `28.4/26.2`; a Duration group (`lifetime 6735`, default 30) renders `112h 15m`, `+ Log 30m`; a discrete group `lifetime 1240` renders `1,240` and `+ Log`; a never-logged Continuous group renders a `+ Log` link whose `href` is `/profile/counters/{id}`. iOS `ProfileHomeViewModelTests`: `pillAction(for:)` (new pure static on the VM: `.log(amount)` / `.openDetail`) returns `.openDetail` for a never-logged Continuous group and `.log(30)` for Duration default 30.

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement.** Web `CounterLedgerCard`: `const kind = group.countKind; const lifetimeStr = formatCountTotal(group.lifetime, kind); const opensDetail = logPillOpensDetail(kind, group.defaultLogAmount);` — when `opensDetail`, render the pill as a `<Link to={`/profile/counters/${group.counterId}`}>` with the same class; else the existing button with label `logPillLabel(kind, group.defaultLogAmount)`; `onLogged({ …, kind })`; rows `formatCount(task.logged, kind)` / `formatCount(task.goal, kind)`; the progress bar for an overshoot row keeps the existing green "met" styling (handoff `ledgers[].rows` — met = green; gold is cells only). `ProfilePage` compact row mirrors the same three changes (`:355` amount, `:392-404` values, `:411-415` pill). `CountersHubPage`: delete the intro `<p>`; pass `kind` to `CounterLogToast`. iOS mirrors: `SharedCounterLedgerCard` `logPillButton` label `CounterLogAmount.pillLabel(kind: group.countKind, defaultLogAmount: group.defaultLogAmount)`; `onLog` callers (`CountersHubView.handleLog`, `ProfileHomeViewModel.handleLog`) first check `CounterLogAmount.pillOpensDetail(…)` and set `navigateToCounterId` instead of logging; the three `.formatted()` lifetimes → `formatCountTotal(group.lifetime, kind: group.countKind)`, member values → `formatCount(…, kind: group.countKind)`; delete the row 86 `Text`; toasts pass `kind: group.countKind`.

- [ ] **Step 4: Run** tests PASS; snapshots per the Files list; read `testHubContinuousDuration*` vs handoff B4 ledgers (`148.6 ALL-TIME`, `+ Log 3.1`, `112h 15m`, `+ Log 30m`). Extend `counter-kinds-logging.spec.ts`: hub → a Continuous counter with default 3.1 → `+ Log 3.1` → toast `Logged +3.1 mi` → Undo. `WEB_E2E e2e/profile-home.spec.ts e2e/counter-kinds-logging.spec.ts`.

- [ ] **Step 5: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): hub + Profile '+ Log' pills carry the amount per kind (never-logged opens Counter Detail); grouped totals (R7); drop hub intro caption (#548 85/86) (PR 4 Task 18)"
```

---

### Task 19: Counter Detail per kind (B4 Detail)

**Files:**
- Create: `apps/ios/OYBC/Views/ProfileTab/Components/CounterDetailLogCard.swift` — `CounterDetailContent`'s Log card + chip state + custom row moved out of `CounterDetailView.swift:303-306,351-395,597-730`
- Modify: `apps/ios/OYBC/Views/ProfileTab/CounterDetailView.swift` (uses `CounterDetailLogCard`; R7 `.formatted()` at `:497`, `:548`, `:555-558`, `:572`, `:779`, `:819`, `:825`, `:884` → `formatCountTotal` / `formatCount` with `group.countKind`; kind-blind `:383`, `:525`, `:651`, `:702`, `:713`, `:727`, `:806`; delete #548 row 80 explainer `:427` and row 82 captions `:875-876`; shrink the allowlist entry — the file drops ~180 lines, below 1000, so DELETE its allowlist entry)
- Modify: `apps/web/src/pages/CounterDetailPage.tsx:75-165,239-425` (chips `hubChips(kind)`; custom entry `GoalEntry`; values; R7 `:239`, `:310`, `:334-342`; delete row 79 explainer `:430-433`), `apps/web/src/components/counters/CounterDetailTaskCard.tsx:65-140` (values `formatCount`; "{n} {unit} to go" / "✓ Goal met · {over} over" per kind — R7 `:90-91,133,139`; delete row 81 captions `:69-73`)
- Test: `apps/web/src/components/counters/__tests__/CounterDetailTaskCard.test.ts` (create), `apps/ios/OYBCTests/CounterDetailLogCardTests.swift` (create — pure `CounterDetailLogCard.Model`), snapshots
- Re-record (intentional — captions 80/82): `CountersHubSnapshotTests/testDetailSingleMember{Light,Dark}`, `testDetailCustomChipActive{Light,Dark}`, `testDetailLoggingStateLight`; add `testDetailContinuous{Light,Dark}`, `testDetailDurationLight` (handoff `logCards[]` / `detailCards[]`)

**Interfaces:**
- Consumes: `hubChips`, `initialLogSelection`, `customChipLabel`, `formatCountTotal`, `formatCountWithUnit`, `GoalEntry(View)`.
- Produces: iOS `CounterDetailLogCard(group: SharedCounterGroup, activeMemberCount: Int, isLogging: Bool, logError: String?, onLog: (CountValue, CounterLogDirection, Bool) -> Void)` with `struct Model` (chips, selection, custom draft parse — unit-tested); the hub keeps the custom row + OK (handoff `logCards[].customOpen` shows "OK") — this is the one log surface that keeps OK, since the chips are fixed and the field is a secondary entry. Task card copy: `"{formatCountWithUnit(remaining)} to go"` ("13.8 mi to go", "6h to go"), `"✓ Goal met · {formatCount(over)} over"` ("2.2 over").

- [ ] **Step 1: Failing tests.** Web `CounterDetailTaskCard.test.ts`: Continuous member logged 12.4 / goal 26.2 → `12.4/26.2`, `13.8 mi to go`; logged 28.4 → `✓ Goal met · 2.2 over`; Duration 270/630 → `4h 30m/10h 30m`, `6h to go`; none of the cards contain `Not on any board yet` / `Starts counting when`. iOS `CounterDetailLogCardTests`: `Model(kind: .continuous, defaultLogAmount: 3.1)` → chip labels `["0.5","1","5","#"]`, selection custom 3.1, custom chip label `#3.1`, add label `＋ Add 3.1 mi`; `Model(kind: .duration, defaultLogAmount: 30)` → chips `["15m","30m","1h","#"]`, selected index 1.

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement.** Move the Log card verbatim into `CounterDetailLogCard.swift` first (one commit-able step: run `IOS_SNAP -only-testing:OYBCSnapshotTests/CountersHubSnapshotTests` — the `testDetail*` baselines must be GREEN after the pure move), then make it kind-aware: chips `CounterLogAmount.hubChips(kind: group.countKind)`, initial selection via `initialSelection`, custom row `GoalEntryView(kind: kind, text: $customDraft, placeholder: "Amount", suffix: unitLabel)` + OK (`parseCustom(customDraft, kind:)`), labels via `formatCountWithUnit`. Then the remaining `CounterDetailView` sites and caption deletions. Web mirrors (`CounterDetailPage` chips `hubChips(group.countKind)`, `GoalEntry` custom input, `formatCountTotal` for the hero / milestone / today stat, `formatCountWithUnit` in the Add / Remove aria labels and `＋ Add {amount}` button). Milestone line: `"{formatCountWithUnit(remaining)} to {formatCountTotal(next)}"` ("1.4 mi to 150", "12h 45m to 125h").

- [ ] **Step 4: Run** tests; snapshots per Files; read vs handoff B4 Detail cards. Delete the `CounterDetailView.swift` allowlist entry (the guardrail script notes it as stale otherwise). `WEB_E2E e2e/counter-kinds-logging.spec.ts` + a Detail case: Continuous counter → chip `0.5` → `＋ Add 0.5 mi` → hero `149.1`.

- [ ] **Step 5: Commit**

```bash
git add apps/web apps/ios scripts/audit/file-size-allowlist.json
git commit -m "feat(counters): Counter Detail per kind — fixed chips per kind, decimal / h:m custom entry, kind-aware cards and milestone; extract CounterDetailLogCard; drop detail captions (#548 79-82) (PR 4 Task 19)"
```

---

### Task 20: Board cells — fit tiers, ×goal tag, gold overshoot (C1)

**Files:**
- Modify: `apps/web/src/components/board/RisoBoardCell.tsx:5-60,107-128` (`count.kind`; tier text; `.over` bar), `RisoBoard.module.css:140-160` (`.cbar.over > i { background: var(--riso-gold); }`)
- Modify: `apps/web/src/components/board/cellModel.ts:20-74` (`count: { cur, max, kind }`; `taskCellLabel` passes the kind to the title; `cellCountFit` pure function)
- Modify: `apps/web/src/components/board/RisoBoardGrid.tsx` / `RisoBoard.tsx` (pass `cellSize` down so a cell can size its text — `RisoBoardCell` gains `cellSize?: number`, default 88; `BoardPlaySurface.tsx:670` already uses 90)
- Modify: `apps/ios/OYBC/Views/BoardsTab/Components/RisoBoardPlayCell.swift:37-38,146-160,245-255,336-386` (`countKind`; three-tier `ViewThatFits`; gold fill on overshoot; ×tag and VoiceOver via `formatCount`), `apps/ios/OYBC/Views/BoardsTab/BoardPlayView.swift:1174-1200,1321-1350` (pass `countKind: resolveFamilyCountKind(task, lookup:)` — net-zero lines), `SquaresEditGrid.swift:266-290`, `RearrangeGrid.swift:335-350`
- Test: `apps/web/src/components/board/__tests__/cellModel.test.ts` (+`cellCountFit` cases), `RisoBoardCell.test.ts` (+kind cases), `apps/ios/OYBCSnapshotTests/RisoBoardCellKindsSnapshotTests.swift` (create — handoff `boards[]`: 3×3 @113, 4×4 @83, 5×5 @65, light + dark)
- Existing baselines that must stay GREEN (discrete, no overshoot): `RisoPlayBoardSnapshotTests/*`, `RisoBoardGridSnapshotTests/*`, `SquaresEditSnapshotTests/*`, `RearrangeGridSnapshotTests/*`, `WindowedCompletionSealingSnapshotTests/testSealedGrid*` — with ONE allowed exception: a discrete cell whose bar previously hid its count (too narrow for `cur/max`) now shows the `cur` tier. That is the designed change; re-record exactly those baselines and list each in the commit body. Any other diff is a regression to fix.

**Interfaces:**
- Consumes: `formatCount`, `resolveFamilyCountKind`.
- Produces:
  - web `BoardCellModel.count?: { cur: number; max: number; kind: CountKind }`
  - web `cellCountFit(cur: number, max: number, kind: CountKind, cellSize: number): { text: string; tier: 'full' | 'cur' | 'none' }` — inner width `cellSize - 25` (7px padding ×2 + 1.5px border ×2 + 6px slack), char width `9.5 × 0.56`; `full` = `cur/max` fits, else `cur`, else `none`
  - iOS `RisoBoardPlayCell.countKind: CountKind = .discrete`
  - Overshoot: bar fill `--riso-gold` / `Color.risoGold` when `cur > max`, width 100%; the text is the real value.

- [ ] **Step 1: Failing tests.** `cellModel.test.ts`:

```ts
describe('cellCountFit', () => {
  it.each([
    { cur: 12.75, max: 26.2, kind: 'continuous', size: 90, tier: 'full', text: '12.75/26.2' },
    { cur: 128.5, max: 1000, kind: 'continuous', size: 90, tier: 'full', text: '128.5/1000' },
    { cur: 6735, max: 30000, kind: 'duration', size: 90, tier: 'cur', text: '112h 15m' },
    { cur: 270, max: 600, kind: 'duration', size: 90, tier: 'full', text: '4h 30m/10h' },
    { cur: 6735, max: 30000, kind: 'duration', size: 58, tier: 'none', text: '' },
    { cur: 28.4, max: 26.2, kind: 'continuous', size: 90, tier: 'full', text: '28.4/26.2' },
    { cur: 3, max: 5, kind: 'discrete', size: 58, tier: 'full', text: '3/5' },
  ] as const)('$text @ $size', ({ cur, max, kind, size, tier, text }) => {
    expect(cellCountFit(cur, max, kind, size)).toEqual({ tier, text });
  });
});
```

(Check the arithmetic in the implementation step — `90 − 25 = 65px / 5.32 ≈ 12.2 chars`; `112h 15m/500h` is 13 → `cur`; at 58px, 33 / 5.32 ≈ 6.2 chars: `112h 15m` (8) → `none`; `3/5` (3) → `full`.) `RisoBoardCell.test.ts`: an overshoot Continuous cell renders the class `over` on `.cbar` and the tag `×26.2`; a Duration cell's tag `×10h 30m`. iOS snapshots `RisoBoardCellKindsSnapshotTests` — a `LazyVGrid` of `RisoBoardPlayCell`s built from the handoff `cells(n, size)` worst-case list (`Run 26.2 mi` 12.75/26.2, `Swim 1000 m` 128.5/1000, `Practice 10h` 270/600, `Code 500h` 6735/30000, overshoot 28.4/26.2 done, `Read 300 pages` 120/300 shared) for n = 3, 4, 5 at the stated cell sizes, light + dark (`testGrid3{Light,Dark}`, `testGrid4{Light,Dark}`, `testGrid5{Light,Dark}`).

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement.** Web `cellModel.ts`:

```ts
const BAR_CHAR_PX = 9.5 * 0.56;
const BAR_INSET_PX = 25;

/**
 * The counting bar's text tier (docs/COUNTER_KINDS.md §5): `cur/max`, else
 * `cur` (the ×tag already carries the goal), else nothing (fill only).
 * Deterministic from the cell size — no measurement, no post-paint change.
 */
export function cellCountFit(cur: number, max: number, kind: CountKind, cellSize: number): { text: string; tier: 'full' | 'cur' | 'none' } {
  const room = (cellSize - BAR_INSET_PX) / BAR_CHAR_PX;
  const curText = formatCount(cur, kind);
  const full = `${curText}/${formatCount(max, kind)}`;
  if (full.length <= room) return { text: full, tier: 'full' };
  if (curText.length <= room) return { text: curText, tier: 'cur' };
  return { text: '', tier: 'none' };
}
```

`toBoardCellModel` sets `count: { cur, max, kind: resolveCountKind(task) }` (callers that know the family pass the root-resolved kind — `BoardPlaySurface` uses `resolveFamilyCountKind(task, (id) => taskMap[id])` and spreads it into the model input via a new optional `countKind` field on `TaskCellModelInput`). `RisoBoardCell`: tag `×${formatCount(cell.count.max, cell.count.kind)}`; bar width `Math.min(100, …)`; `className={[styles.cbar, over ? styles.over : ''].join(' ')}`; `<span>{fit.text}</span>` only when `fit.tier !== 'none'`. iOS `bottomProgressBar`: color `taskType == .counting && cur > max ? Color.risoGold : color`; replace the two-branch `ViewThatFits` with three:

```swift
            ViewThatFits(in: [.horizontal, .vertical]) {
                barText("\(formatCount(cur, kind: barKind))/\(formatCount(max, kind: barKind))")
                barText(formatCount(cur, kind: barKind))
                Color.clear.frame(width: 0, height: 0)
            }
```

with `private var barKind: CountKind { taskType == .counting ? countKind : .discrete }` and `barText` = the existing `Text(...).font(.risoHead(9, .extraBold)).foregroundStyle(Color.risoInk).lineLimit(1).fixedSize()`. Gold fill text stays `risoInkStatic` (content on gold — `reference_riso_dark_mode_tokens`). ×tag `formatCount(maxCount, kind: countKind)`, VoiceOver `formatCount(…, kind: countKind)` (+ `countUnitSuffix` not needed — the title carries the unit).

- [ ] **Step 4: Run** web tests, `WEB_CHECK`; `IOS_SNAP` for every file listed as must-stay-green (red ⇒ fix, except the one `cur`-tier exception named under Files) + record `RisoBoardCellKindsSnapshotTests`, read all six vs handoff C1 (5×5 @65: `112h 15m` drops to fill only; overshoot cell gold full bar `28.4/26.2`).

- [ ] **Step 5: Playwright validation.** A seeded 5×5 board with the worst-case cells → screenshot light/dark → `.playwright-mcp/task20-c1-5x5-{light,dark}.png`; vs handoff C1 web (`88px` cells).

- [ ] **Step 6: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): board cells format per kind with cur/max → cur → fill tiers, ×goal tag, gold overshoot fill (PR 4 Task 20)"
```

---

### Task 21: Rows, titles, previews and wizard rows read the family kind (C2, R19)

**Files:**
- Modify: `apps/web/src/pages/tasks/taskCountDisplay.ts:55-64` (`computeStatusLabel` → `${formatCount(cur, kind)} / ${formatCount(max, kind)}`)
- Modify: `apps/web/src/pages/tasks/TaskRow.tsx:95-105`, `apps/web/src/components/wizard/TaskRow.tsx:40-50`, `apps/web/src/components/wizard/LibrarySheet.tsx:135-145`, `apps/web/src/components/board/cellModel.ts:20-27` (`taskCellLabel` → `generateCounterTaskTitle(…, undefined, resolveCountKind(task))`)
- Modify: `apps/web/src/components/wizard/BoardWizardPreviewStep.tsx:95-107` (pass the family kind into `toBoardCellModel` — R19), `apps/web/src/hooks/useSquaresEditDraft.ts:249` (same)
- Modify: `apps/ios/OYBC/Helpers/TaskCountDisplay.swift:60-70` (unit suffix via `countUnitSuffix`), `apps/ios/OYBC/Views/TasksTab/Components/RisoTaskRowView.swift:118-122`, `apps/ios/OYBC/Views/CreateTab/Components/RisoLibrarySheetView.swift:428-433` (`"\(a) · goal \(formatCountWithUnit(m, kind:, unit:))"`; Duration rows without a unit), `apps/ios/OYBC/Views/CreateTab/Components/BoardWizardPreviewStepView.swift` + `BoardWizardPreviewDerived.swift` (cells get `countKind: resolveFamilyCountKind`)
- Test: `apps/web/src/pages/tasks/__tests__/taskCountDisplay.test.ts` (+cases), `apps/web/src/components/board/__tests__/cellModel.test.ts` (+R19 case), `apps/ios/OYBCTests/TaskCountDisplayTests.swift` (+cases)
- Add snapshots: `RisoTasksTabSnapshotTests/testRowContinuousLight`, `testRowDurationLight` (handoff `taskRows[]`)

**Interfaces:**
- Consumes: `resolveFamilyCountKind`, `formatCount`, `formatCountWithUnit`, `generateCounterTaskTitle(…, countKind)`.
- Produces: no new API. Rule (R19): every cell / row builder that receives a `taskMap` resolves the kind through `resolveFamilyCountKind`, so a wizard-pending linked task renders its root's kind before the drain stamps it.

- [ ] **Step 1: Failing tests.** `taskCountDisplay.test.ts`: Continuous 12.4/26.2 → `12.4 / 26.2`; Duration 270/630 → `4h 30m / 10h 30m`; Discrete 6/10 → `6 / 10` (unchanged). `cellModel.test.ts`: `toBoardCellModel({ key, task: pendingLinked /* sharedCounterId: 'root', no countKind */, done: false, currentCount: 3.1, countKind: resolveFamilyCountKind(pendingLinked, lookup) })` → `count.kind === 'continuous'`. iOS `TaskCountDisplayTests`: `"Practice · 4h 30m / 10h 30m"` (no trailing unit space), `"Run · 12.4 / 26.2 mi"`.

- [ ] **Step 2: Run — FAIL.** **Step 3: Implement** the listed sites (each a one-line `formatCount` / kind-thread change). **Step 4: Run** tests + `IOS_SNAP -only-testing:OYBCSnapshotTests/RisoTasksTabSnapshotTests` (the new two recorded; the standing `RisoTasksTab` reds unchanged in SET), `-only-testing:OYBCSnapshotTests/WizardArrangePreviewSnapshotTests` green.

- [ ] **Step 5: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): task rows, library rows, titles and wizard previews read the family kind (R19) (PR 4 Task 21)"
```

---

### Task 22: Kind-blind sweep, R7 remainder, linked-counter row, guard

**Files:**
- Modify: `apps/web/src/pages/tasks/LinkedCounterCaptionView.tsx:26-55` + `apps/ios/OYBC/Views/TasksTab/Components/LinkedCounterCaptionView.swift:90-125` — #548 rows 91/92: drop the "Linked to" label word and the loading / not-found captions (render nothing in those states); the found row stays a navigation row: `{title} · {formatCountTotal(lifetime, kind)}{countUnitSuffix} ›` (R7 site `:104`)
- Modify: every remaining `formatCount(…, kind: .discrete)` UI call site on iOS that is a counting value (re-run `grep -rn "kind: \.discrete" apps/ios/OYBC/Views apps/ios/OYBC/Helpers` — after Tasks 13–21 only intentional ones may remain, each with a `// discrete by definition: …` comment) and every `.toLocaleString()` / raw `${…count}` counting display on web (`grep -rn "toLocaleString()\|currentCount}\|maxCount}" apps/web/src --include=*.tsx`)
- Create: `scripts/audit/check-count-formatting.mjs` — fails when a NEW `formatCount(` with a hard-coded `.discrete` / `'discrete'` kind, or a counting `.formatted()` / `.toLocaleString()`, appears outside an allowlist file (`scripts/audit/count-formatting-allowlist.json`, seeded with the intentional sites from the sweep); wire into `.github/workflows/drift-guardrails.yml` beside `check-file-sizes`
- Re-record (intentional): `LinkedCounterCaptionSnapshotTests/testLinked{Light,Dark}`, `testSourceNotFound{Light,Dark}` (the not-found case now renders nothing — replace those two tests with `testSourceNotFoundRendersNothing` asserting the view's body is empty via a 1×1 image or delete them and say so in the commit)
- Docs: `docs/COUNTER_KINDS.md` Status ("PR 3 #NNN, PR 4 #MMM shipped — feature complete"), §7 items struck through; `docs/TASK_SYSTEM.md` logging paragraph; CLAUDE.md §Windowed Completion untouched; tick closed #548 rows in the PR body

**Interfaces:** none new (sweep + guard).

- [ ] **Step 1: Failing guard test.** `scripts/audit/check-count-formatting.mjs` gets a self-test mode (`--self-test` runs it over a fixture string containing `formatCount(x, kind: .discrete)` and expects exit 1); run `node scripts/audit/check-count-formatting.mjs --self-test` — FAIL (script missing).
- [ ] **Step 2: Implement** the script (pure Node, regex over `apps/ios/OYBC/**/*.swift` and `apps/web/src/**/*.{ts,tsx}` excluding tests; allowlist entries are `path:line-content` strings so a moved line re-flags), seed the allowlist from the sweep, add the workflow step.
- [ ] **Step 3: Sweep** the sites; update LinkedCounterCaptionView both platforms; re-record per Files.
- [ ] **Step 4: Run** the full PR 4 gate (below).
- [ ] **Step 5: Commit**

```bash
git add apps scripts .github docs
git commit -m "feat(counters): kind-blind sweep + count-formatting drift guard; linked-counter row shows the thing, not a caption (#548 91/92, R7) (PR 4 Task 22)"
```

### PR 4 gate

- [ ] Same checks as the PR 3 gate, plus `node scripts/audit/check-count-formatting.mjs`, plus `WEB_E2E e2e/counter-kinds-logging.spec.ts e2e/windowed-completion.spec.ts e2e/late-log-counting.spec.ts e2e/profile-home.spec.ts`.
- [ ] `IOS_SNAP` red SET = standing reds only; every re-recorded baseline is listed in the PR body with its reason (kind row / caption removal / new section).
- [ ] Owner device-test relay (CLAUDE.md — never drive the sim): numbered steps in the PR body — 1. Tasks → new Counting → Continuous "Run 26.2 miles"; 2. put it on a board, tap the square, tap 6.6, +; 3. type 3,1, +; 4. long-press → "+ Add 3.1 mi"; 5. Edit task → Discrete → confirm shows "Run 26 miles", "13 logged"; 6. a Duration "Practice 10h 30m" on a 5×5 board shows `4h 30m/10h 30m` or `4h 30m`.

---

## Self-review

**Spec coverage** (`docs/COUNTER_KINDS.md` §5 + brief §3 + handoff decisions):

| Requirement | Task |
| --- | --- |
| Kind labels Discrete / Continuous / Duration; never "Amount" | 1, 3 (test `never says Amount`) |
| Kind picker states (create / Duration locked out / locked in / linked tag) | 1 (vectors), 3 |
| Goal entry: number pad / decimal pad / h:m wheel / web h·m fields | 4 |
| A1 special panel + Tasks-tab quick-add | 5 |
| A2 compound sub-task create + edit | 6 |
| A3 Board Edit sheet | 9 |
| A4 Task Detail edit | 8 |
| A5 pool row editor | 12 |
| A6 hub New counter | 10 |
| Unit hidden for Duration; Duration titles "Practice 10h 30m" | 1, 5, 6 |
| Only Continuous → Discrete confirms; copy; family line | 7, 8, 9, 12 |
| Switch through `switchCounterKind`, staged surfaces atomic | 7, 8, 9, 12 |
| Tap opens the sheet on both platforms; web Discrete +1 tap removed | 14, 15 |
| Continuous/Duration sheet: pinned field, no OK, chips ¼ · ½ · goal · # | 13, 14, 15 |
| Chips without a goal per kind | 13, 19 |
| Last-used pre-selects, else # | 13, 14, 15 |
| Long-press "+ Add {last} unit" / "− Remove" / Custom… | 16 |
| Late log | 17 |
| "+ Log {amount}" pills; never-logged opens Detail | 13, 18 |
| Toasts per kind | 13, 18 |
| Counter Detail | 19 |
| Board cells fit tiers, ×goal, gold overshoot | 20 |
| Rows / titles / member stepper / vary range precision | 1, 11, 21 |
| Owner override: Duration 1-minute steps everywhere | 1 (`goalChipAmounts` vectors 158/315), 11 (stepper), 13 |
| Owner override: Duration ships now | all tasks carry Duration |
| §7 carried items | Task numbers recorded in `docs/COUNTER_KINDS.md` §7 |
| No explanatory copy; #548 rows on touched surfaces | 5, 6, 9, 10, 11, 12, 14, 15, 18, 19, 22 |

**Placeholder scan:** where a step says "use the real name — grep …" it names the exact grep and the exact symbol to match; no step defers content.

**Type consistency:** `KindPickerLock` (`'none' | 'duration' | 'all'`), `parseCountInput(raw, kind, { allowZero })` / Swift `parseCountInput(_:kind:allowZero:)`, `LogChip`, `boardSheetChips(kind, goal)`, `initialLogSelection(kind, chips, default)`, `SharedCounterGroup.countKind`, `switchCounterKindInTransaction` / `AppDatabase.switchCounterKind(db:rootTaskId:to:now:)`, `KindSwitchPreview` fields — used with the same names and orders in every task.

**Review Focus → owning tests:** 1 → Task 1 vectors + Task 4; 2 → Task 1 vectors; 3 → Task 5 (`linked create takes the root kind`, `testLinkedCreateTakesRootKind`); 4 → Task 9 (`kind switch then goal edit, atomic`, `testSwitchThenGoalEditAtomic`); 5 → Task 20 (`cellCountFit` table + `RisoBoardCellKindsSnapshotTests`).
