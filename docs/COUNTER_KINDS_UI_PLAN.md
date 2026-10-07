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
- Duration hides the Unit field on TASK surfaces; a Duration title is `{Action} {Xh Ym}` ("Practice 10h 30m"). The hub New counter keeps its noun for every kind (it names the counter — Ruling U4), and a Duration task never auto-links by name.
- Board cells: bar text tiers **`cur/max` → `cur` → fill only**; the `×goal` tag always shows the goal; overshoot shows the real value with a **gold** bar fill; never clamp. Gold appears exactly where the handoff draws it (Ruling U5): board cells (both platforms) and the web DetailModal's progress bar (`LogSheet.dc.html` web frame); the iOS stepper sheet has no bar; hub / Counter Detail rows keep the green "met" fill.
- Vary range: both ends at the more precise end's precision for Continuous ("21.0–31.4 miles"); Duration ranges are whole minutes ("8h 24m–12h 36m").
- Lifetime totals keep thousands grouping (`formatCountTotal`, R7): "1,240", "148.6", "112h 15m".
- **No explanatory copy** (CLAUDE.md, owner rule 2026-09-30/10-06): no helper lines, tips, provenance captions. Every task that touches a surface carrying a #548 caption removes it on both platforms (rows listed per task) and updates the snapshot / e2e that pinned it. Kept on purpose: validation errors, loading/error states, the switch-confirm consequence body, empty-state one-liners.
- Rule 6: every task that touches a twin lands web + iOS in the same commit (Ruling U3 — the one justified exception is Task 1 → Task 2, inert shared helpers, stated in Task 1's commit message).
- Barrel exports (Ruling U2): `packages/shared/src/algorithms/index.ts` uses explicit named lists; the task that creates a shared helper adds it there in the same commit (Tasks 1, 13), and its test asserts the barrel exposes it.
- Extract-at-three (Ruling U7): the "switch kind, then guard the goal" step and the Continuous → Discrete confirm seam exist ONCE per platform (Task 8) and are reused by Tasks 9, 10, 12.
- Reuse the Riso kit (`RisoSegmented`, `RisoNumberField`, `RisoChip`, `RisoButton`, `RisoSectionLabel`) — extend, never fork. Tokens only; no new colours (gold = `--riso-gold` / `Color.risoGold`, on gold use `--riso-ink-static` / `Color.risoInkStatic`).
- File-size guardrail (`node scripts/check-file-sizes.mjs`): no source file > 1000 lines; allowlisted files may not grow (`BoardPlayView.swift` 1996, `BoardPlayViewModel.swift` 1518, `BoardPlaySurface.tsx` 1241, `CounterDetailView.swift` 1009). Never bump a cap; extract helpers instead (Ruling U8): Task 5's stepper extraction runs before Task 6 so `RisoSpecialTaskPanel.swift` (921) has headroom; PR 4's per-file budget table (top of PR 4) keeps the three shared god-files within their caps, and only Task 21 lowers caps, to the final counts. `BoardWizardTasksStep.tsx` (994, not allow-listed) may only shrink.
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

1. **Typing a partial or locale-formatted decimal** — "3," / "3." / ",5" / "26,2" in a Continuous field must parse (3, 3, 0.5, 26.2) and never silently drop to an integer; "3.125" must be refused, not rounded. Pinned by Task 1's `parseCountInput` vectors (`continuous partial separator`, `continuous comma decimal`, `continuous three places refused`) and their Swift run in Task 2.
2. **A Duration goal typed as minutes vs hours** — "90", "1:30", "1h 30m" and "1h30m" all mean 90 minutes; "1.5h" is refused. Pinned by Task 1 vectors (`duration bare minutes`, `duration colon`, `duration compact`, `duration fractional hours refused`) + Task 2.
3. **An auto-linking create whose picker said another kind** — a 6.2 goal typed while the picker shows Discrete, auto-linking to a Continuous root, must parse AND save as Continuous (and a pending wizard copy must carry the root kind before the drain — R19). Pinned by Task 6: web `createFormCounting.test.ts` "linked create takes the root kind…", iOS `testLinkedCreateSavesRootKindAndParsesAtIt` (goes through `handleCreateAndAddToPool` and reads the stored row) and `testDeferredLinkedCreateCarriesRootKindOnThePayload`.
4. **Board Edit Save with a staged Continuous → Discrete switch plus a goal edit** — one transaction: the switch rounds, the typed goal wins; a fractional goal at the new whole kind rolls the switch back. Pinned by Task 8's guard tests (both platforms) and Task 10: web `boardEditCommit.countKind.test.ts` "kind switch then goal edit, atomic" / "…rolls the whole Save back", iOS `BoardEditKindSwitchTests.testSwitchThenGoalEditAtomic` / `testFractionalGoalAtTheNewWholeKindRollsTheSaveBack` (real `handleEditTaskOverride` → `handleEditSave` path).
5. **The widest Duration value in a small cell, and overshoot** — `112h 15m/500h` drops to `112h 15m` in a 90px web cell and to fill only at 58px; an overshoot `28.4/26.2` keeps its real value with a full gold bar. Pinned by Task 19's `cellCountFit` table + `RisoBoardCell` tests (web) and `RisoBoardCellKindsSnapshotTests` (iOS 3×3 / 4×4 / 5×5, measured by `ViewThatFits`).

---

## File map

**Shared (PR 3)** — `packages/shared/src/algorithms/countEntry.ts` (create), `countValue.ts` (+`formatCountTotal`, `formatCountRange`), `taskTitle.ts` (kind-aware), `memberRulesDisplay.ts` (`varyRangeLabel` via `formatCountRange`), `validation/schemas.ts` (Duration needs no unit), `types/task.ts` (`AutoCreateCompoundChildTask.countKind`), fixtures `countEntryVectors.json` (create), `countValueVectors.json`, `taskTitleVectors.json`, `memberRuleVectors.json`.
**Shared (PR 4)** — `packages/shared/src/algorithms/logAmounts.ts` (create), `sharedCounterGroups.ts` (+`countKind`), fixture `logAmountVectors.json` (create), `sharedCounterGroupsVectors.json`.
**iOS helpers** — `Helpers/CountEntry.swift` (create), `Helpers/CountValue.swift`, `Helpers/TaskTitle.swift`, `Helpers/BoardSourceMemberRulesDisplay.swift`, `Helpers/CounterLogAmount.swift`, `Helpers/SharedCounterGroups.swift`.
**Components** — web `components/counters/KindPicker.tsx`, `KindTag.tsx`, `GoalEntry.tsx`, `KindSwitchConfirmDialog.tsx` (create, each with `.module.css`), `components/riso/RisoSegmented.tsx` (+`lockedValues`); iOS `Views/Riso/KindPickerView.swift`, `Views/Riso/GoalEntryView.swift`, `Views/Components/KindSwitchConfirmView.swift`, `Views/Riso/RisoCountStepperView.swift` (create), `Views/Riso/RisoControls.swift` (`RisoSegmented.lockedValues`, `RisoNumberField.keyboard`).
**Switch seam (Task 8)** — web `db/operations/countKindSwitch.ts` (+`switchCounterKindInTransaction`, `applyKindSwitchThenGoalGuard`, `previewCounterKindSwitch`, `planKindSwitchPreview`), `components/counters/{kindSwitchModel.ts, KindSwitchConfirmDialog.tsx, useKindSwitchRequest.tsx}`; iOS `AppDatabase+CountKindSwitch.swift`, `Views/Components/KindSwitchConfirmView.swift`.
**PR 4 extractions** — web `components/boardPlay/{countingLogModel.ts, useCountingLogModal.ts}` (shrinks `BoardPlaySurface.tsx`), `components/lateLog/lateLogCountingModel.ts`, `components/counters/{ledgerPill.ts, counterDetailCaption.ts, counterRowTitle.ts}`; iOS `Views/BoardsTab/Components/{CountingStepperModel.swift, CountingMenuLabels.swift}`, `Views/ProfileTab/Components/CounterDetailLogCard.swift` (shrinks `CounterDetailView.swift` under 1000).
**Guard (Task 21)** — `scripts/audit/check-count-formatting.mjs` + allow-list.

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
- Modify: `packages/shared/src/algorithms/index.ts:12-27` — the barrel uses EXPLICIT named lists (no `export *`): add `formatCountForInput`, `formatCountTotal`, `formatCountRange` to the `./countValue` list and a new explicit `./countEntry` block (Ruling U2 — a helper not in the barrel is `undefined` to every `@oybc/shared` importer)
- Modify: `packages/shared/src/validation/schemas.ts:262-271` (create refine), `:369-386` (`AutoCreateCompoundChildTaskSchema` + `countKind`)
- Modify: `packages/shared/src/types/task.ts:348-371` (`AutoCreateCompoundChildTask.countKind?: CountKind`)
- Modify: `packages/shared/tests/fixtures/countValueVectors.json` (+`formatTotal`, `formatRange`), `taskTitleVectors.json` (+duration cases), `memberRuleVectors.json` (`display.varyRangeLabel` +2 cases)
- Test: `packages/shared/tests/algorithms/countValue.test.ts:9-19` (`CountValueFixture` gains `formatTotal` / `formatRange`), `taskTitleVectors.test.ts:24,36` (pass `v.countKind`), `memberRulesDisplay.test.ts`, `packages/shared/tests/algorithms/countEntrySchemas.test.ts` (create)

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
import * as fs from 'fs';
import * as path from 'path';
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
import * as barrel from '../../src/algorithms';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const vectors: any = JSON.parse(fs.readFileSync(path.join(__dirname, '../fixtures/countEntryVectors.json'), 'utf8'));

describe('barrel (Ruling U2)', () => {
  it('re-exports every helper a web surface imports from @oybc/shared', () => {
    for (const name of ['parseCountInput', 'kindPickerLock', 'isKindSegmentLocked', 'kindSegmentShowsLock', 'COUNT_KIND_LABELS',
      'durationToFields', 'durationFromFields', 'countUnitSuffix', 'formatCountWithUnit', 'resolveFamilyCountKind',
      'countKindNeedsUnit', 'formatCountForInput', 'formatCountTotal', 'formatCountRange']) {
      expect(typeof (barrel as Record<string, unknown>)[name]).not.toBe('undefined');
    }
  });
});

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

Barrel (`algorithms/index.ts`) — add to the existing `./countValue` list `formatCountForInput, formatCountTotal, formatCountRange,` and below it:

```ts
export {
  COUNT_KIND_LABELS,
  kindPickerLock,
  isKindSegmentLocked,
  kindSegmentShowsLock,
  parseCountInput,
  durationToFields,
  durationFromFields,
  countKindNeedsUnit,
  countUnitSuffix,
  formatCountWithUnit,
  resolveFamilyCountKind,
} from './countEntry';
export type { KindPickerLock } from './countEntry';
```

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

extend `CountValueFixture` (`countValue.test.ts:9-19`) with

```ts
  formatTotal: Array<{ name: string; value: number; kind: string; locale: string; expected: string }>;
  formatRange: Array<{ name: string; lo: number; hi: number; kind: string; locale: string; expected: string }>;
```

(import `formatCountTotal`, `formatCountRange` beside the existing imports) and add the tests:

```ts
  it.each(vectors.formatTotal)('formatTotal: $name', ({ value, kind, locale, expected }) => {
    expect(formatCountTotal(value, kind as CountKind, locale)).toBe(expected);
  });
  it.each(vectors.formatRange)('formatRange: $name', ({ lo, hi, kind, locale, expected }) => {
    expect(formatCountRange(lo, hi, kind as CountKind, locale)).toBe(expected);
  });
```

In `taskTitleVectors.test.ts` change the two calls to pass the kind (absent ⇒ the default):

```ts
      generateCounterTaskTitle(v.action, v.maxCount ?? null, v.unit, v.providedTitle ?? undefined, v.countKind ?? undefined)
```

```ts
    expect(isAutoCounterTitle(v.title, v.action, v.maxCount ?? null, v.unit, v.countKind ?? undefined)).toBe(v.expected);
```

Append to `taskTitleVectors.json` `generateCounterTaskTitle`:

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

Create `packages/shared/tests/algorithms/countEntrySchemas.test.ts`:

```ts
import { TaskType } from '../../src/constants/enums';
import { AutoCreateCompoundChildTaskSchema, CreateTaskInputSchema } from '../../src/validation/schemas';

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
git commit -m "feat(counters): shared count-entry module, kind-aware titles/ranges/totals, duration needs no unit (PR 3 Task 1)

Rule-6 gap, justified (Ruling U3): inert shared helpers plus the TS half of
two display helpers; nothing user-visible calls them until Task 3+. The
Swift twin lands in the next commit (Task 2); the synced iOS fixture
copies are committed here so fixtureSync stays green.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VMfDbTv2B1UEUUgsnYEFag"
```

(The iOS `TaskTitleVectorTests` / `MemberRuleVectorTests` decode the new vectors only after Task 2; run Task 2 before pushing.)

---

### Task 2: Swift twin — CountEntry.swift, totals/ranges, kind-aware titles

**Files:**
- Create: `apps/ios/OYBC/Helpers/CountEntry.swift`
- Create: `apps/ios/OYBCTests/CountEntryVectorTests.swift`
- Modify: `apps/ios/OYBC/Helpers/CountValue.swift` (append `formatCountTotal`, `formatCountRange` after `formatCountForInput`, line ~66)
- Modify: `apps/ios/OYBC/Helpers/TaskTitle.swift:25-50` (+`countKind:`), `isAutoCounterTitle`, `counterCopyTitle`
- Modify: `apps/ios/OYBC/Helpers/BoardSourceMemberRulesDisplay.swift:120-129` (`varyRangeLabel` → `formatCountRange`)
- Modify: `apps/ios/OYBCTests/CountValueVectorTests.swift` (Fixture + 2 tests), `TaskTitleVectorTests.swift` (decode `countKind`). `MemberRuleVectorTests.swift` needs no change — its `varyRangeLabel` vector struct already decodes `countKind` (PR 2) and calls `BoardSources.varyRangeLabel(…, kind:)`

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
        var root = LinkedWindowKit.task("root", maxCount: 26.2)
        root.countKind = .continuous
        let linked = LinkedWindowKit.task("row", maxCount: 6.2, sharedCounterId: "root", baseline: 0)
        XCTAssertEqual(resolveFamilyCountKind(linked, lookup: { $0 == "root" ? root : nil }), .continuous)
        XCTAssertEqual(resolveFamilyCountKind(linked, lookup: { _ in nil }), .discrete)
    }
}
```

(`LinkedWindowKit.task(_:maxCount:sharedCounterId:…)` is the shared counting-task builder in `apps/ios/OYBCTests/LinkedCounterWindowHealTests.swift:20`; later tasks reuse it.)

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

`TaskTitle.generateCounterTaskTitle` (`TaskTitle.swift:25-50`, whose body already binds `trimmedAction` and the unwrapped `maxCount`) gains `countKind: CountKind = .discrete` (last parameter) and, after the `guard let maxCount` line:

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
  - iOS `KindPickerView(selection: Binding<CountKind>, lock: KindPickerLock, onRequest: ((CountKind) -> Void)? = nil)` — when `onRequest` is set, a tap calls it INSTEAD of writing the binding (the caller confirms then writes; Task 8). iOS `.card` has no compact size, so every surface uses the one size
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
        // card-only by contract: the pill variants ignore locks.
        const locked = variant === 'card' && (lockedValues?.includes(opt.value) ?? false);
        const glyph = variant === 'card' && (lockGlyphValues?.includes(opt.value) ?? false);
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
.lockGlyph { display: inline-grid; place-items: center; margin-left: 5px; vertical-align: -1px; }
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
  /** Called with a live (unlocked) segment's kind. The caller confirms Continuous → Discrete (Task 8). */
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
/// (`KindSwitchConfirmView`, Task 8) and write the binding itself.
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

(`Color.risoPaper` on blue follows the iOS on-colour divergence — CLAUDE.md C8.) In `RisoKitGallery.swift` add, after the last existing `sectionLabel(...)` block, `sectionLabel("Kind picker")` followed by `KindPickerView(selection: $sampleKind, lock: .duration)`, with `@State private var sampleKind: CountKind = .continuous` beside the gallery's other sample state.

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
### Task 5: Member-rule steppers are kind-aware (R8 / R16) — runs before A1 (Ruling U8)

Ordering: this task moves ~290 lines of compact-stepper code out of `RisoSpecialTaskPanel.swift` (921 lines), so Task 6 (A1) has headroom under the 1000-line guardrail. It has no dependency on the picker / goal-entry components beyond Task 4's `GoalEntryModel`.

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
- Test: `apps/web/src/components/__tests__/CounterStepper.test.ts` (+kind cases), `apps/web/src/components/wizard/__tests__/MemberRuleRow.test.ts` (+3 cases in a new `describe`), `apps/ios/OYBCTests/MemberRuleRowModelTests.swift` (+kind cases)
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

`MemberRuleRow.test.ts` — append (reuses the file's `render`, `makeTask` helpers; rows render COLLAPSED in the node harness, so the pins are the summary chip — the expanded stepper is pinned by the e2e in Step 6):

```ts
describe('MemberRuleRow — counter kinds (collapsed chip)', () => {
  const RUN = makeTask('t-run', { title: 'Run 26.2 miles', type: TaskType.COUNTING, action: 'Run', unit: 'miles', maxCount: 26.2, countKind: 'continuous' });
  const PRACTICE = makeTask('t-prac', { title: 'Practice 10h 30m', type: TaskType.COUNTING, action: 'Practice', unit: '', maxCount: 630, countKind: 'duration' });

  it('a continuous pool member at a little vary shows the precision-matched range', () => {
    expect(render({ task: RUN, fromBoard: false, rule: { vary: 1 } })).toContain('21.0–31.4 miles');
  });
  it('a duration pool member at a little vary shows whole-minute bounds', () => {
    expect(render({ task: PRACTICE, fromBoard: false, rule: { vary: 1 } })).toContain('8h 24m–12h 36m');
  });
  it('a continuous board member pro-rates in tenths (weekly 26.2 → daily 3.8)', () => {
    // autoTarget continuous: ceil(26.2 / 7, 0.1) = 3.8 — the chip shows it with the unit.
    expect(render({ task: RUN, rule: {} })).toContain('3.8 miles');
  });
});
```

(Uses the file's `WEEKLY_SOURCE` → `DAILY_WINDOW` defaults for the board case. `26.2 / 7 = 3.742…` → ceil to 0.1 = 3.8 per `ceilToCountStep`.)

iOS `RisoCountStepperMathTests.swift` — the eleven cases of the deleted `RisoCompactStepperMathTests` ported verbatim at `kind: .discrete` (`Math.committed(draft: "7", kind: .discrete, min: 1, max: 35) == 7`; `"900"` → 35; `"0"` → 1; `"  12  "` → 12; `""`, `"abc"`, `"-"`, `"1.5"` → nil; `base(value: 6, draft: nil…) == 6`; `base(6, "20") == 20`; `base(6, "abc") == 6`, `base(6, "") == 6`; `base(1, "5") == 5`, `base(35, "5") == 5`; `stepped(6, "20", +1) == 21`, `(6, "20", -1) == 19`; `stepped(6, nil, ±1) == 7 / 5`; `stepped(35, nil, +1) == 35`, `(1, nil, -1) == 1`; `stepped(6, "900", +1) == 35`, `(6, "0", -1) == 1`; `stepped(6, "abc", +1) == 7`; `stepped(1000, nil, ±1, max: 5000) == 1001 / 999`), plus:

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

`MemberRuleRowModelTests.swift` additions (use the file's `task(...)` / `model(...)` helpers; set `countKind` on the returned task):

```swift
    func testContinuousMemberSuffixAndRangeUseTheKind() {
        var t = task("c", type: .counting, maxCount: 26.2, unit: "miles"); t.countKind = .continuous
        let m = model(task: t, rule: BoardSourceMemberRule(vary: .little), fromBoard: false)
        XCTAssertEqual(m.kind, .continuous)
        XCTAssertEqual(m.rangeLabel, "21.0\u{2013}31.4 miles")
        let board = model(task: t, rule: BoardSourceMemberRule(vary: .off))
        XCTAssertEqual(board.targetSuffix, "/ 26.2 miles")
    }

    func testDurationMemberSuffixAndRangeAreWholeMinutes() {
        var t = task("d", type: .counting, maxCount: 630, unit: ""); t.countKind = .duration
        let m = model(task: t, rule: BoardSourceMemberRule(vary: .little), fromBoard: false)
        XCTAssertEqual(m.rangeLabel, "8h 24m\u{2013}12h 36m")
        XCTAssertEqual(model(task: t).targetSuffix, "/ 10h 30m")
    }
```

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

- [ ] **Step 5: Run** the Step 2 commands — PASS; then `IOS_SNAP -only-testing:OYBCSnapshotTests/BoardWizardTasksStepSnapshotTests -only-testing:OYBCSnapshotTests/RisoKitSnapshotTests -only-testing:OYBCSnapshotTests/RisoSourceSnapshotTests`: only the three listed caption baselines may be red; re-record them, read them. Run `node scripts/check-file-sizes.mjs` (RisoSpecialTaskPanel shrank ~290 lines — Task 6 depends on that headroom).

- [ ] **Step 6: e2e + Playwright.** `WEB_E2E e2e/member-rules.spec.ts e2e/pool-default-vary.spec.ts` must stay green. Add to `apps/web/e2e/member-rules.spec.ts` a case seeding a MONTHLY source board holding `Run 26.2 miles` (`seedTask(page, { …, countKind: 'continuous' })` — `SeedTask.countKind` is added in Task 6 Step 9; land that one-line fixture field here if this task runs first) into a monthly wizard (no pro-rate, target = goal): expand the member, press the dice once → the inline range reads `21.0–31.4 miles`; press "Decrease target" three times → the field reads `25.9` and the range `20.7–31.1 miles` (`varyRange` is ± around the TARGET: 25.9 × 0.8 = 20.72 → 20.7, × 1.2 = 31.08 → 31.1). Playwright MCP screenshot → `.playwright-mcp/task5-member-{light,dark}.png`.

- [ ] **Step 7: Commit**

```bash
git add apps/web apps/ios
git rm apps/ios/OYBCTests/RisoCompactStepperMathTests.swift
git commit -m "feat(counters): member-row target steppers step per kind (0.1 / 1 min), callers pass the kind (R8, R16); drop 'shares a counter' caption (#548 47/48) (PR 3 Task 5)"
```

---

### Task 6: A1 — special panel / Create New Task form (kind row, linked tag, Duration without unit)

**Files:**
- Modify: `packages/shared/src/algorithms/linkableCounter.ts:28-41,109-114` (`LinkableCounter.countKind`), test `packages/shared/tests/algorithms/linkableCounter.test.ts` (+1 case); `apps/ios/OYBC/Helpers/LinkableCounter.swift:34-46,114-119` (`LinkableCounterSuggestion.countKind`), test `apps/ios/OYBCTests/LinkableCounterTests.swift` (+1 case; create the file if `ls apps/ios/OYBCTests | grep -i linkable` is empty)
- Create: `apps/web/src/pages/createPage/createFormCounting.ts` — pure model of the counting fields (effective kind, goal parse, unit visibility, title preview, linked-create input)
- Create: `apps/web/src/pages/createPage/__tests__/createFormCounting.test.ts` (new folder)
- Modify: `apps/web/src/pages/createPage/useCreateFormState.ts:75-123` (`validateForm` + `countKind`), `:286` (state), `:405,:413` (resets), `:511-540`, `:606-625` (create branches), `:667` (deps), `:676-700` (returned object + `UseCreateFormState`)
- Modify: `apps/web/src/pages/createPage/CreateNewTaskForm.tsx:129-200` (model-driven), `:398-468` (Verb → Kind → Goal · Unit); delete the #548 row 67 Achievement explainer `<p>` at `:269` and row 68 `<span className={styles.helpText}>` at `:374`
- Modify: `apps/ios/OYBC/Views/CreateTab/ViewModels/CreateFormViewModel.swift:109-131` (`countingKind`, `countingLinkedRootKind`), `:254-284` (validation), `:319-326` (title), `:780-792` (`buildCreateTask`), `:429-466` (resets)
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/RisoSpecialTaskPanel.swift:199-356` (kind state, row, goal field, unit gating, linked tag, submit) + a `countingSeed` snapshot seam
- Modify: `apps/web/e2e/_fixtures/bypass.ts:376-420` (`SeedTask.countKind?: 'discrete' | 'continuous' | 'duration'` — `seedTask` spreads the row, so the field is the whole change)
- Test: `apps/ios/OYBCTests/CreateFormViewModelCountKindTests.swift` (create), `apps/ios/OYBCSnapshotTests/RisoSpecialPanelCountingSnapshotTests.swift` (create), `apps/web/e2e/counter-kinds-authoring.spec.ts` (create)

**Interfaces:**
- Consumes: `KindPicker`, `KindTag`, `GoalEntry` (Tasks 3–4); `parseCountInput`, `countKindNeedsUnit`, `generateCounterTaskTitle(…, countKind)` (Task 1).
- Produces:
  - `LinkableCounter.countKind: CountKind` / `LinkableCounterSuggestion.countKind: CountKind`
  - web `createFormCounting.ts`:
    - `effectiveCountingKind(picked: CountKind, link: { linked: boolean; countKind: CountKind } | null): CountKind`
    - `countingGoalError(goalText: string, kind: CountKind): string | undefined` (exact messages below)
    - `countingTitlePreview(action: string, goalText: string, unit: string, kind: CountKind): string | null`
    - `buildLinkedCreateInput(args: { source: Task; goalText: string; title: string; action: string; unit: string; baseline: number }): LinkedCounterInput | null` — parses the goal at the SOURCE's kind
  - web `UseCreateFormState.countKind: CountKind`, `setCountKind(kind: CountKind): void`; `validateForm(type, title, description, action, unit, maxCountStr, achievementMode?, achievementReferenceId?, achievementRequiredCountStr?, countKind: CountKind = 'discrete')`
  - iOS `CreateFormViewModel.countingKind: CountKind` (picker), `countingLinkedRootKind: CountKind?` (set by the panel while auto-linking), `effectiveCountingKind: CountKind { countingLinkedRootKind ?? countingKind }` — validation, parse, title and the stored row all use the effective kind (Review Focus 3).
  - Goal messages (both platforms, exact): discrete `Goal must be a positive integer` (unchanged), continuous `Goal must be a number above zero with up to 2 decimals`, duration `Goal must be a duration above zero`.
- The CounterLinkHint sentences (#548 rows 77/78) are removed in Task 7 (the hint is shared with the compound panels; removing it there re-records those baselines once).

- [ ] **Step 1: Failing web tests.** `apps/web/src/pages/createPage/__tests__/createFormCounting.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import {
  buildLinkedCreateInput,
  countingGoalError,
  countingTitlePreview,
  effectiveCountingKind,
} from '../createFormCounting';
import { validateForm } from '../useCreateFormState';

const ROOT = {
  id: 'root', userId: 'u1', title: 'Run 26.2 miles', type: TaskType.COUNTING, action: 'Run', unit: 'miles',
  maxCount: 26.2, countKind: 'continuous', currentCount: 148.6, isCompleted: false, totalCompletions: 0,
  totalInstances: 0, createdAt: 't', updatedAt: 't', version: 1, isDeleted: false,
} as Task;

describe('createFormCounting', () => {
  it('an auto-linking create takes the root kind; opting out restores the picker', () => {
    expect(effectiveCountingKind('discrete', { linked: true, countKind: 'continuous' })).toBe('continuous');
    expect(effectiveCountingKind('discrete', { linked: false, countKind: 'continuous' })).toBe('discrete');
    expect(effectiveCountingKind('duration', null)).toBe('duration');
  });
  it('goal errors per kind', () => {
    expect(countingGoalError('26.2', 'continuous')).toBeUndefined();
    expect(countingGoalError('3.125', 'continuous')).toBe('Goal must be a number above zero with up to 2 decimals');
    expect(countingGoalError('2.5', 'discrete')).toBe('Goal must be a positive integer');
    expect(countingGoalError('1.5h', 'duration')).toBe('Goal must be a duration above zero');
    expect(countingGoalError('', 'continuous')).toBe('Goal is required');
  });
  it('title preview: duration has no unit; continuous keeps decimals', () => {
    expect(countingTitlePreview('Practice', '10h 30m', '', 'duration')).toBe('Practice 10h 30m');
    expect(countingTitlePreview('Run', '26,2', 'miles', 'continuous')).toBe('Run 26.2 miles');
    expect(countingTitlePreview('Run', '26.2', '', 'continuous')).toBeNull();
  });
  it('linked create takes the root kind: a 6.2 goal typed while the picker said Discrete still saves', () => {
    const input = buildLinkedCreateInput({ source: ROOT, goalText: '6.2', title: '', action: 'Run', unit: 'miles', baseline: 148.6 });
    expect(input).toEqual({ source: ROOT, maxCount: 6.2, title: 'Run 6.2 miles', baselineMode: 'startFromZero', baseline: 148.6 });
  });
  it('a linked create with a goal invalid at the root kind is refused', () => {
    expect(buildLinkedCreateInput({ source: { ...ROOT, countKind: undefined }, goalText: '6.2', title: '', action: 'Run', unit: 'miles', baseline: 0 })).toBeNull();
  });
});

describe('validateForm — counter kinds', () => {
  const v = (action: string, unit: string, goal: string, kind: 'discrete' | 'continuous' | 'duration') =>
    validateForm(TaskType.COUNTING, '', '', action, unit, goal, undefined, undefined, undefined, kind);
  it('duration needs no unit', () => {
    const e = v('Practice', '', '10h 30m', 'duration');
    expect(e.unit).toBeUndefined();
    expect(e.maxCount).toBeUndefined();
  });
  it('continuous still needs the unit and takes a decimal goal', () => {
    expect(v('Run', '', '26.2', 'continuous').unit).toBe('Counting is required');
    expect(v('Run', 'miles', '26.2', 'continuous').maxCount).toBeUndefined();
  });
  it('discrete is unchanged', () => {
    expect(v('Read', 'pages', '2.5', 'discrete').maxCount).toBe('Goal must be a positive integer');
  });
});
```

Add to `packages/shared/tests/algorithms/linkableCounter.test.ts`:

```ts
it('a suggestion carries the matched root kind', () => {
  const root = { ...counting('r', 'Run', 'miles'), countKind: 'continuous' as const };
  expect(findLinkableCounter({ action: 'run', unit: 'miles' }, [root])?.countKind).toBe('continuous');
  expect(findLinkableCounter({ action: 'run', unit: 'miles' }, [{ ...root, countKind: undefined }])?.countKind).toBe('discrete');
});
```

(`counting(id, action, unit)` = whatever the file's existing counting-task builder is called; read the top of the file and use it.)

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST createFormCounting` and `SHARED_TEST linkableCounter`

- [ ] **Step 3: Implement web.** `linkableCounter.ts`: add `/** The counter's kind (D5) — a linked create takes it. */ countKind: CountKind;` to `LinkableCounter`, return `countKind: resolveCountKind(best),`. Create `createFormCounting.ts`:

```ts
import {
  countKindNeedsUnit,
  generateCounterTaskTitle,
  parseCountInput,
  resolveCountKind,
  type CountKind,
  type Task,
} from '@oybc/shared';
import type { LinkedCounterInput } from '../../components/wizard/CountingTemplatePicker';

/**
 * The kind a counting create saves (docs/COUNTER_KINDS.md §5, D5): an
 * auto-linking create follows the matched root; otherwise the picker.
 */
export function effectiveCountingKind(
  picked: CountKind,
  link: { linked: boolean; countKind: CountKind } | null,
): CountKind {
  return link?.linked ? link.countKind : picked;
}

/** The Goal field's validation message at a kind, or undefined when valid. */
export function countingGoalError(goalText: string, kind: CountKind): string | undefined {
  if (goalText.trim() === '') return 'Goal is required';
  if (parseCountInput(goalText, kind) !== null) return undefined;
  if (kind === 'discrete') return 'Goal must be a positive integer';
  return kind === 'continuous'
    ? 'Goal must be a number above zero with up to 2 decimals'
    : 'Goal must be a duration above zero';
}

/** The live "Title:" preview, or null until Action, Goal (and Unit, unless Duration) are valid. */
export function countingTitlePreview(action: string, goalText: string, unit: string, kind: CountKind): string | null {
  const a = action.trim();
  const u = unit.trim();
  const goal = parseCountInput(goalText, kind);
  if (!a || goal === null || (countKindNeedsUnit(kind) && !u)) return null;
  return generateCounterTaskTitle(a, goal, countKindNeedsUnit(kind) ? u : '', undefined, kind);
}

/**
 * The auto-link create input, with the goal parsed at the SOURCE's kind
 * (Review Focus 3 — the picker may have shown another kind).
 *
 * @returns The input, or null when the goal is invalid at the root kind.
 */
export function buildLinkedCreateInput(args: {
  source: Task; goalText: string; title: string; action: string; unit: string; baseline: number;
}): LinkedCounterInput | null {
  const kind = resolveCountKind(args.source);
  const maxCount = parseCountInput(args.goalText, kind);
  if (maxCount === null) return null;
  const title = args.title.trim() || generateCounterTaskTitle(args.action.trim(), maxCount, args.unit.trim(), undefined, kind);
  return { source: args.source, maxCount, title, baselineMode: 'startFromZero', baseline: args.baseline };
}
```

  `useCreateFormState.ts`: `const [countKind, setCountKind] = useState<CountKind>('discrete');` (beside `maxCountStr`, `:286`); expose `countKind`, `setCountKind` on `UseCreateFormState` and the returned object; reset to `'discrete'` in both reset helpers (`:405`, `:413`). `validateForm` gains the trailing `countKind: CountKind = 'discrete'` and its counting branch becomes:

```ts
    if (countKindNeedsUnit(countKind)) {
      if (unit.trim().length === 0) {
        errors.unit = 'Counting is required';
      } else if (unit.trim().length > UNIT_MAX_LENGTH) {
        errors.unit = `Counting must be ${UNIT_MAX_LENGTH} characters or less`;
      }
    }
    errors.maxCount = countingGoalError(maxCountStr, countKind);
```

  (keep the `errors.maxCount` key absent when undefined — `if (goalError) errors.maxCount = goalError;`). The hook's own `validateForm(...)` call passes `countKind` as the 10th argument. Both COUNTING create branches (`:511-540` pending payload, `:606-625` `createTask` input) use `const parsedMaxCount = parseCountInput(maxCountStr, countKind) as number;` (validation already passed), pass `countKind` as `generateCounterTaskTitle`'s 5th argument, write `unit: countKindNeedsUnit(countKind) ? unit.trim() : ''`, and add `...(countKind !== 'discrete' ? { countKind } : {})`. Add `countKind` to the `useCallback` deps (`:667`).
  `CreateNewTaskForm.tsx`: replace `:129-130` with

```ts
  const counterMatch = useMemo(
    () =>
      form.taskType === TaskType.COUNTING && form.countKind !== 'duration' && trimmedAction && trimmedUnit
        ? findLinkableCounter({ action: trimmedAction, unit: trimmedUnit }, matchPool)
        : null,
    [form.taskType, form.countKind, trimmedAction, trimmedUnit, matchPool],
  );
  const linked = Boolean(counterMatch && onCreateLinked && !linkDisabled);
  const kind = effectiveCountingKind(form.countKind, counterMatch ? { linked, countKind: counterMatch.countKind } : null);
  const titlePreview = countingTitlePreview(form.action, form.maxCountStr, form.unit, kind);
  const goalValid = parseCountInput(form.maxCountStr, kind) !== null;
```

  (the old `counterMatch` memo moves up; `linkHint.goal` keeps `parseCountInput(form.maxCountStr, kind) ?? 0`). `handleFormSubmit`'s linked branch replaces the inline title/`maxCount` code with `const input = buildLinkedCreateInput({ source: sourceTask, goalText: form.maxCountStr, title: form.title, action: trimmedAction, unit: trimmedUnit, baseline: counterMatch.lifetime }); if (!input) { void form.handleSubmit(e); return; } onCreateLinked(input);`. Fields: between the Verb `fieldGroup` and the Goal `fieldGroup` insert

```tsx
              <div className={styles.fieldGroup}>
                <span className={styles.label}>Kind</span>
                {linked && counterMatch ? (
                  <KindTag kind={counterMatch.countKind} counterName={counterMatch.name} lifetime={counterMatch.lifetime} />
                ) : (
                  <KindPicker value={form.countKind} lock="none" onChange={form.setCountKind} />
                )}
              </div>
```

  replace the Goal `<input type="number" …>` with

```tsx
                <GoalEntry
                  id="create-task-maxcount"
                  aria-label="Goal"
                  kind={kind}
                  value={form.maxCountStr}
                  onChange={form.setMaxCountStr}
                  placeholder={kind === 'duration' ? '0h 0m' : '100'}
                  invalid={Boolean(form.errors.maxCount)}
                />
```

  wrap the Counting (unit) `fieldGroup` in `{countKindNeedsUnit(kind) && ( … )}`, and the title preview becomes `{titlePreview && (<div className={styles.titlePreview}>Title: <strong>{titlePreview}</strong></div>)}`. Delete the two caption nodes (rows 67/68) and the now-unused `.helpText` CSS rule if nothing else uses it (`grep -n helpText apps/web/src/pages/createPage/*.tsx`). `bypass.ts`: add to `SeedTask`

```ts
  /** Counter kinds — absent = discrete. */
  countKind?: 'discrete' | 'continuous' | 'duration';
```

- [ ] **Step 4: Run** `WEB_TEST createFormCounting` and `SHARED_TEST linkableCounter` — PASS; `WEB_CHECK`.

- [ ] **Step 5: iOS failing tests.** `CreateFormViewModelCountKindTests.swift`:

```swift
import XCTest
import GRDB
@testable import OYBC

@MainActor
final class CreateFormViewModelCountKindTests: XCTestCase {
    private typealias K = LinkedWindowKit

    private func form(_ db: AppDatabase, kind: CountKind, goal: String, unit: String, action: String = "Run") -> CreateFormViewModel {
        let f = CreateFormViewModel(database: db)
        f.taskType = .counting
        f.countingAction = action
        f.countingUnit = unit
        f.countingMaxCount = goal
        f.countingKind = kind
        return f
    }

    private func create(_ f: CreateFormViewModel) -> String? {
        let done = expectation(description: "created")
        var id: String?
        f.handleCreateAndAddToPool(userId: K.userId, onTaskCreated: { tid, _, _ in id = tid; done.fulfill() }, onLibraryReloadRequested: {})
        wait(for: [done], timeout: 5)
        return id
    }

    func testDurationCreateHasNoUnitAndStoresMinutes() throws {
        let db = try AppDatabase.makeTestInstance(); try K.seedUser(db)
        let id = try XCTUnwrap(create(form(db, kind: .duration, goal: "10h 30m", unit: "", action: "Practice")))
        let task = try XCTUnwrap(db.fetchTask(id: id))
        XCTAssertEqual(task.countKind, .duration)
        XCTAssertEqual(task.maxCount, 630)
        XCTAssertEqual(task.unit, "")
        XCTAssertEqual(task.title, "Practice 10h 30m")
    }

    func testContinuousRejectsThreePlaces() throws {
        let db = try AppDatabase.makeTestInstance(); try K.seedUser(db)
        let f = form(db, kind: .continuous, goal: "3.125", unit: "mi")
        f.handleCreateAndAddToPool(userId: K.userId, onTaskCreated: { _, _, _ in XCTFail("must not create") }, onLibraryReloadRequested: {})
        XCTAssertEqual(f.errorMessage, "Goal must be a number above zero with up to 2 decimals")
    }

    /// Review Focus 3 — the picker said Discrete, the create auto-links to a
    /// Continuous root: the 6.2 goal must PARSE at the root kind and the row
    /// must SAVE as Continuous.
    func testLinkedCreateSavesRootKindAndParsesAtIt() throws {
        let db = try AppDatabase.makeTestInstance(); try K.seedUser(db)
        var root = K.task("root", maxCount: 26.2, currentCount: 148.6); root.countKind = .continuous
        try db.saveTask(root)
        let f = form(db, kind: .discrete, goal: "6.2", unit: "miles")
        f.countingSharedCounterId = "root"
        f.countingBaseline = 148.6
        f.countingLinkedRootKind = .continuous
        let id = try XCTUnwrap(create(f))
        let row = try XCTUnwrap(db.fetchTask(id: id))
        XCTAssertEqual(row.countKind, .continuous)
        XCTAssertEqual(row.maxCount, 6.2)
        XCTAssertEqual(row.title, "Run 6.2 miles")
    }

    /// R19 — a deferred (wizard) create carries the root kind on the pending
    /// payload itself, before the drain's `withRootCountKind`.
    func testDeferredLinkedCreateCarriesRootKindOnThePayload() throws {
        let db = try AppDatabase.makeTestInstance(); try K.seedUser(db)
        let f = form(db, kind: .discrete, goal: "6.2", unit: "miles")
        f.countingSharedCounterId = "root"; f.countingBaseline = 0; f.countingLinkedRootKind = .continuous
        let done = expectation(description: "pending")
        var payload: PendingTaskPayload?
        f.handleCreateAndAddToPool(userId: K.userId, onTaskCreated: { _, _, _ in }, onLibraryReloadRequested: {},
                                   deferPersist: true, onPendingCreated: { payload = $0; done.fulfill() })
        wait(for: [done], timeout: 5)
        XCTAssertEqual(payload?.task.countKind, .continuous)
    }
}
```

`LinkableCounterTests.swift` (+case): a root with `countKind = .continuous` → `findLinkableCounter(action: "run", unit: "miles", tasks: [root])?.countKind == .continuous`.

Snapshot `RisoSpecialPanelCountingSnapshotTests.swift`:

```swift
import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

final class RisoSpecialPanelCountingSnapshotTests: XCTestCase {
    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func panel(_ seed: RisoSpecialTaskPanel.CountingSeed) -> some View {
        RisoSpecialTaskPanel(
            userId: "u1", defaultStartDate: nil, defaultEndDate: nil,
            onTaskCreated: { _, _, _ in }, onCompoundCreated: { _ in }, onPendingCreated: nil,
            onLibraryReloadRequested: {}, countingSeed: seed
        )
        .padding(16)
        .background(Color.risoPaper)
    }

    func testContinuousLight() { snap(.init(action: "Run", goal: "26.2", unit: "miles", kind: .continuous), dark: false) }
    func testContinuousDark() { snap(.init(action: "Run", goal: "26.2", unit: "miles", kind: .continuous), dark: true) }
    func testDurationLight() { snap(.init(action: "Practice", goal: "10h 30m", unit: "", kind: .duration), dark: false) }
    func testDiscreteLight() { snap(.init(action: "Read", goal: "300", unit: "pages", kind: .discrete), dark: false) }

    private func snap(_ seed: RisoSpecialTaskPanel.CountingSeed, dark: Bool, file: StaticString = #file, testName: String = #function, line: UInt = #line) {
        assertSnapshot(of: panel(seed), as: .image(layout: .fixed(width: 393, height: 460), traits: .init(userInterfaceStyle: dark ? .dark : .light)),
                       record: recordMode, file: file, testName: testName, line: line)
    }
}
```

(Those are the panel's non-defaulted stored properties, `RisoSpecialTaskPanel.swift:22-33`; `countingSeed` is declared LAST so the memberwise order holds.)

- [ ] **Step 6: Run — expect FAIL.** `cd apps/ios && xcodegen generate && cd - && IOS_TEST -only-testing:OYBCTests/CreateFormViewModelCountKindTests -only-testing:OYBCTests/LinkableCounterTests`

- [ ] **Step 7: Implement iOS.**
  - `LinkableCounter.swift`: `let countKind: CountKind` on the struct; `countKind: resolveCountKind(best.countKind)` at `:114-119`.
  - `CreateFormViewModel.swift`: beside `countingMaxCount` add `var countingKind: CountKind = .discrete`, `var countingLinkedRootKind: CountKind? = nil` and `var effectiveCountingKind: CountKind { countingLinkedRootKind ?? countingKind }`. Validation `:269-284`:

```swift
            let kind = effectiveCountingKind
            if countKindNeedsUnit(kind) {
                guard !u.isEmpty else { errorMessage = "Counting is required"; return }
                guard u.count <= CreateFormLimits.unit else {
                    errorMessage = "Counting must be \(CreateFormLimits.unit) characters or less"; return
                }
            }
            guard !m.isEmpty else { errorMessage = "Goal is required"; return }
            guard parseCountInput(m, kind: kind) != nil else {
                switch kind {
                case .discrete: errorMessage = "Goal must be a positive integer"
                case .continuous: errorMessage = "Goal must be a number above zero with up to 2 decimals"
                case .duration: errorMessage = "Goal must be a duration above zero"
                }
                return
            }
```

    `:322` and `:783`: `let m = parseCountInput(countingMaxCount, kind: effectiveCountingKind) ?? 0`; `:323` passes `countKind: effectiveCountingKind`; `buildCreateTask`'s `.counting` case writes `unit: countKindNeedsUnit(effectiveCountingKind) ? u : ""` and becomes `var t = Task(…); t.countKind = effectiveCountingKind == .discrete ? nil : effectiveCountingKind; return t`. Every reset that clears `countingMaxCount` (`:429`, `:455`, `:465`) also sets `countingKind = .discrete; countingLinkedRootKind = nil`.
  - `RisoSpecialTaskPanel.swift`: `@State private var countingKind: CountKind = .discrete`; `struct CountingSeed { var action = ""; var goal = ""; var unit = ""; var kind: CountKind = .discrete }` and a stored `var countingSeed: CountingSeed? = nil` applied in the body's `.onAppear { if let s = countingSeed { isExpanded = true; selectedType = .counting; countingActionText = s.action; countingGoalText = s.goal; countingUnitText = s.unit; countingKind = s.kind } }` (a defaulted stored property keeps every memberwise call compiling). Derived:

```swift
    private var linkedSuggestion: LinkableCounterSuggestion? { linkDisabled ? nil : linkSuggestion }
    private var effectiveKind: CountKind { linkedSuggestion?.countKind ?? countingKind }
```

    `countingGoal` (`:225-228`) = `parseCountInput(countingGoalText, kind: effectiveKind)`; `countingTitle` passes `countKind: effectiveKind` and drops the unit requirement for Duration; `canSubmitCounting` requires the unit only when `countKindNeedsUnit(effectiveKind)`; `updateLinkSuggestion()` starts with `guard countingKind != .duration else { linkSuggestion = nil; return }` and also runs `.onChange(of: countingKind)`. `countingFields` (`:236-278`):

```swift
            fieldRow(label: "Verb", required: true) {
                RisoTextField(placeholder: "Do", text: $countingActionText)
            }
            fieldRow(label: "Kind") {
                if let s = linkedSuggestion {
                    KindTagView(kind: s.countKind, counterName: s.name, lifetime: s.lifetime)
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

    `submitCounting()` additionally sets `form.countingKind = countingKind`, `form.countingLinkedRootKind = linkedSuggestion?.countKind`, `form.countingUnit = countKindNeedsUnit(effectiveKind) ? <trimmed unit> : ""`; the post-submit reset clears `countingKind = .discrete`. `wc -l` must stay < 1000 (≈ 670 after Task 5).

- [ ] **Step 8: Run iOS** `IOS_TEST -only-testing:OYBCTests/CreateFormViewModelCountKindTests -only-testing:OYBCTests/LinkableCounterTests` — PASS. Record `RisoSpecialPanelCountingSnapshotTests` (4 new), read each against handoff A1 (Kind between Verb and Goal; Duration: no Counting field, field reads "10h 30m"). `RisoNewTaskSheetSnapshotTests/testDefault{Light,Dark}` (collapsed panel) must stay green.

- [ ] **Step 9: e2e + Playwright validation.** Create `apps/web/e2e/counter-kinds-authoring.spec.ts`:

```ts
import { test, expect } from './_fixtures/bypass';

test.describe('Counter kinds — authoring (A1)', () => {
  test('Tasks tab: create a Continuous and a Duration counting task', async ({ page }) => {
    await page.goto('/tasks?__oybc_test_bypass=1');
    await page.getByRole('button', { name: '+ New task' }).click();
    await page.getByRole('button', { name: 'Counting', exact: true }).click();
    await page.getByLabel('Verb').fill('Run');
    await page.getByRole('group', { name: 'Kind' }).getByRole('button', { name: 'Continuous' }).click();
    await page.getByLabel('Goal', { exact: true }).fill('26,2');
    await page.getByLabel('Counting', { exact: true }).fill('miles');
    await expect(page.getByText('Run 26.2 miles')).toBeVisible();
    await page.getByRole('button', { name: 'Add to library' }).click();
    await expect(page.getByRole('button', { name: 'Open Run 26.2 miles details' })).toBeVisible();

    await page.getByRole('button', { name: '+ New task' }).click();
    await page.getByRole('button', { name: 'Counting', exact: true }).click();
    await page.getByLabel('Verb').fill('Practice');
    await page.getByRole('group', { name: 'Kind' }).getByRole('button', { name: 'Duration' }).click();
    await expect(page.getByLabel('Counting', { exact: true })).toHaveCount(0);
    await page.getByLabel('Goal hours').fill('10');
    await page.getByLabel('Goal minutes').fill('30');
    await page.getByRole('button', { name: 'Add to library' }).click();
    await expect(page.getByRole('button', { name: 'Open Practice 10h 30m details' })).toBeVisible();
  });
});
```

(`+ New task` is the Tasks tab header button and `Add to library` the form's `submitLabel` on that page — `TasksPage.tsx:35,290`; `Open {title} details` is the row name `windowed-completion.spec.ts:218` already uses.) Run `WEB_E2E e2e/counter-kinds-authoring.spec.ts` — PASS. Playwright MCP: screenshot the panel with Continuous and with Duration, light + dark → `.playwright-mcp/task6-a1-{continuous,duration}-{light,dark}.png`; compare to handoff A1 web.

- [ ] **Step 10: Commit**

```bash
git add packages/shared apps/web apps/ios
git commit -m "feat(counters): A1 kind picker + goal entry in the special panel / create form; linked creates parse and save at the root kind (R19); drop achievement captions (#548 67/68) (PR 3 Task 6)"
```

---

### Task 7: A2 — compound sub-tasks (create + edit) carry a kind; link hint loses its sentences

**Files:**
- Modify: `apps/web/src/components/compoundWizard/compoundSubtaskDraft.ts:22-43` (`InlineSubtaskDraft.countKind?: CountKind`), `:75-90` (readiness per kind); add `inlineSubtaskToAutoCreate(subtask, allTasks)` (moved out of `CompoundTaskWizard.tsx:255-283`, now generating the counting title)
- Modify: `apps/web/src/components/compoundWizard/CompoundTaskWizard.tsx:255-283` (calls `inlineSubtaskToAutoCreate`)
- Modify: `apps/web/src/components/CountingStepFields.tsx:14-95` (+`countKind`, `onKindChange`)
- Modify: `apps/web/src/components/compoundWizard/SubtaskCard.tsx:312-330` (kind props), `:360-380` (`InlineCounterLinkHint` hidden for Duration); delete the #548 row 65 caption at `:292`
- Modify: `apps/web/src/components/wizard/CountingSubConfigRow.tsx` (+`kind`, `onKindChange`; `GoalEntry`; unit hidden for Duration)
- Modify: `apps/web/src/db/taskEditPatch.ts:21-62` (`ChildPatch.countKind`), `:218-226` (`parsePositiveGoal(goal, kind)`), `:240` (`canAppendCounting(…, kind)`), `:257-290` (`appendTypedChild(…, kind)`), `:331-339` (`validatePatch`'s compound-child loop parses each counting child at its kind; unit required only when `countKindNeedsUnit`)
- Modify: `apps/web/src/components/wizard/CompoundFields.tsx:105-190` (new-sub kind state + row), `:229-245` (existing counting child: `GoalEntry` at its kind; unit hidden for Duration); delete row 61 caption `:187-189`; shorten row 63 `:182-186` to `Couldn't load your tasks.`
- Modify: `apps/web/src/db/operations/compoundStructureEdit.ts:69-140` (`applyStagedCompoundChildEdits` writes `countKind` + parses at it for a new counting child), `apps/web/src/db/operations/tasks.crud.ts:243-260` (`autoCreate.countKind` written)
- Modify: `apps/web/src/components/counters/CounterLinkHint.tsx` — #548 rows 77/78: render `{counterName}` + the pill only; props `lifetime` / `goal` removed; call sites `CountingTemplatePicker.tsx:113-119`, `SubtaskCard.tsx:372-378`
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/RisoCounterLinkHintView.swift` — same reduction (rows 77/78); call sites `RisoSpecialTaskPanel.swift:304`, `RisoCompoundFieldsView.swift:544`
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/RisoCountingSubConfigRow.swift` (+`kind: Binding<CountKind>`)
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/RisoCompoundFieldsView.swift:25-33,97-98,154-155,192-231,370,586-604,656` (sub kind state + seed + parse)
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/RisoCompoundEditFieldsView.swift:108-111` (`parsePositiveGoal(_:kind:)`), `:115-175` (`canAppendCounting` / `appendTyped` + `kind`), `:263-268` (existing child goal), `:350-356` (new-sub kind), `:225` (delete row 62 caption), `:370` (shorten row 63)
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/TaskEditPatch.swift:15-62` (`ChildPatch.countKind`), `:76-100` (`TaskEditPatch.countKind`, used by Task 12), `:105` (`parsedGoal`), `:151` (child goal)
- Modify: `apps/ios/OYBC/Views/CreateTab/ViewModels/CreateFormViewModel.swift:474-500` (`CompoundSubItem.newCounting(…, countKind:)`), `:640-670` (child task kind/unit/title)
- Modify: `apps/ios/OYBC/Database/AppDatabase+CompoundStructureEdit.swift:38-60,107-140` (new counting child gets `countKind`)
- Test: `apps/web/src/db/__tests__/taskEditPatch.countKind.test.ts` (create), `apps/web/src/components/compoundWizard/__tests__/compoundSubtaskDraft.countKind.test.ts` (create, new folder), `apps/web/src/components/counters/__tests__/CounterLinkHint.test.ts` (create), `apps/ios/OYBCTests/CompoundSubKindTests.swift` (create)
- Re-record (intentional — kind row in the sub config + rows 62/77/78): `RisoCompoundPanelSnapshotTests/testCompoundNewSubCounting{Light,Dark}`, `testCompoundNewSubCountingLinked{Light,Dark}`, `testCompoundNewSubCountingOptedOut{Light,Dark}`; `PoolRowEditorSnapshotTests/testCompoundEditorNewSubCountingLight`; `RisoEditTaskSheetSnapshotTests/testCompound{Light,Dark}`. Must stay GREEN: `RisoCompoundPanelSnapshotTests/testCompoundEmpty*`, `testCompoundAtLeastN*`, `testCompoundWithSubs*` (no counting new-sub row is open in those fixtures).

**Interfaces:**
- Consumes: Tasks 1–4, 6.
- Produces:
  - web `CountingSubConfigRowProps.kind: CountKind`, `onKindChange: (kind: CountKind) => void` (always `lock="none"` — only a NEW sub-task shows the picker)
  - web `ChildPatch.countKind: CountKind`; `canAppendCounting(text, goal, unit, kind: CountKind = 'discrete')`; `appendTypedChild(draft, text, isCounting, goal = '', unit = '', kind: CountKind = 'discrete')`
  - web `inlineSubtaskToAutoCreate(subtask: InlineSubtaskDraft, allTasks: Task[]): CreateCompoundChildEntry`
  - web `CounterLinkHintProps = { counterName: string; linked: boolean; onToggle: () => void }`
  - iOS `RisoCountingSubConfigRow(goal:unit:kind:)`; `ChildPatch.countKind: CountKind`; `TaskEditPatch.countKind: CountKind`; `CompoundSubItem.newCounting(action:goal:unit:sharedCounterId:baseline:countKind:)`; `RisoCompoundEditFieldsView.canAppendCounting(text:goal:unit:kind:)`, `appendTyped(_:isCounting:goal:unit:kind:to:)`; `RisoCounterLinkHintView(counterName:linked:onToggle:)`
  - Rule (ruling): an EXISTING sub-task's goal edits at its own kind, no picker.

- [ ] **Step 1: Failing web tests.** `apps/web/src/db/__tests__/taskEditPatch.countKind.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { appendTypedChild, canAppendCounting, childPatchFromTask, newChildPatch, validatePatch, type TaskEditPatch } from '../taskEditPatch';

const EMPTY: TaskEditPatch = { title: 'Music week', action: '', goal: '', unit: '', children: [] };

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
  it('a Duration child validates without a unit; a continuous child refuses 3 places', () => {
    const dur = appendTypedChild(EMPTY, 'Practice', true, '1h 30m', '', 'duration');
    expect(validatePatch(dur, TaskType.COMPOUND)).toBeNull();
    const bad = { ...EMPTY, children: [{ ...newChildPatch(true), title: 'Run', action: 'Run', goal: '3.125', unit: 'mi', countKind: 'continuous' as const }] };
    expect(validatePatch(bad, TaskType.COMPOUND)).toBe('Counting sub-task "Run" needs a goal and a unit.');
  });
  it('appendTypedChild titles a Duration sub-task without a unit', () => {
    const next = appendTypedChild(EMPTY, 'Practice', true, '1h 30m', '', 'duration');
    expect(next.children[0]).toMatchObject({ title: 'Practice 1h 30m', countKind: 'duration', goal: '1h 30m', unit: '' });
  });
});
```

`apps/web/src/components/compoundWizard/__tests__/compoundSubtaskDraft.countKind.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { TaskType } from '@oybc/shared';
import { evaluateSubtaskReadiness, inlineSubtaskToAutoCreate, type InlineSubtaskDraft } from '../compoundSubtaskDraft';

const draft = (o: Partial<InlineSubtaskDraft>): InlineSubtaskDraft => ({
  id: 'd', mode: 'inline', inlineType: 'counting', title: '', action: 'Practice', unit: '', maxCountStr: '1h 30m', steps: [], ...o,
});

describe('inline counting sub-task — counter kinds', () => {
  it('a blank-titled Duration sub-task gets a generated title, minutes and no unit', () => {
    expect(inlineSubtaskToAutoCreate(draft({ countKind: 'duration' }), [])).toEqual({
      autoCreate: { type: TaskType.COUNTING, title: 'Practice 1h 30m', action: 'Practice', unit: undefined, maxCount: 90, countKind: 'duration', sharedCounterId: undefined, baseline: undefined },
    });
  });
  it('a continuous sub-task keeps its typed title and decimal goal', () => {
    const entry = inlineSubtaskToAutoCreate(draft({ countKind: 'continuous', title: 'Long run', action: 'Run', unit: 'mi', maxCountStr: '3,1' }), []);
    expect(entry.autoCreate).toMatchObject({ title: 'Long run', maxCount: 3.1, countKind: 'continuous', unit: 'mi' });
  });
  it('readiness: duration needs no unit; continuous refuses 3 places', () => {
    expect(evaluateSubtaskReadiness(draft({ countKind: 'duration' }), new Set()).ready).toBe(true);
    expect(evaluateSubtaskReadiness(draft({ countKind: 'continuous', unit: 'mi', maxCountStr: '3.125' }), new Set()).ready).toBe(false);
  });
});
```

(`evaluateSubtaskReadiness(draft: SubtaskDraft, excludedIds: Set<string>)` is at `compoundSubtaskDraft.ts:61`.) `CounterLinkHint.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { CounterLinkHint } from '../CounterLinkHint';

describe('CounterLinkHint (#548 rows 77/78)', () => {
  it('shows the counter and the pill, never a sentence', () => {
    const html = renderToStaticMarkup(React.createElement(CounterLinkHint, { counterName: 'Miles', linked: true, onToggle: () => {} }));
    expect(html).toContain('Miles');
    expect(html).toContain("Don&#x27;t link");
    expect(html).not.toContain('all-time');
    expect(html).not.toContain('keeps its own');
    expect(html).not.toContain('Creates a separate');
  });
});
```

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST taskEditPatch.countKind compoundSubtaskDraft.countKind CounterLinkHint`

- [ ] **Step 3: Implement web.**
  - `taskEditPatch.ts`: `ChildPatch` gains `countKind: CountKind;`; `newChildPatch` sets `countKind: 'discrete'`; `childPatchFromTask` sets `countKind: resolveCountKind(child)` and `goal: child.maxCount !== undefined ? formatCountForInput(child.maxCount, resolveCountKind(child)) : ''`. `parsePositiveGoal(goal: string, kind: CountKind = 'discrete'): number | undefined` returns `parseCountInput(goal, kind) ?? undefined`; every call in the file passes the child's / draft's kind. `canAppendCounting(text, goal, unit, kind = 'discrete')`:

```ts
export function canAppendCounting(text: string, goal: string, unit: string, kind: CountKind = 'discrete'): boolean {
  return text.trim().length > 0 && parsePositiveGoal(goal, kind) !== undefined && (!countKindNeedsUnit(kind) || unit.trim().length > 0);
}
```

    `validatePatch`'s compound-child loop (`:331-339`) becomes

```ts
      for (const child of kept) {
        if (!child.isCounting) continue;
        const ok = parsePositiveGoal(child.goal, child.countKind) !== undefined
          && (!countKindNeedsUnit(child.countKind) || child.unit.trim().length > 0);
        if (!ok) return `Counting sub-task "${child.title.trim()}" needs a goal and a unit.`;
      }
```

    (a Duration child has no unit; a `parseInt` goal would have accepted "1h 30m" as 1). `appendTypedChild(draft, text, isCounting, goal = '', unit = '', kind = 'discrete')` counting branch:

```ts
    const parsedGoal = parsePositiveGoal(goal, kind);
    const trimmedUnit = countKindNeedsUnit(kind) ? unit.trim() : '';
    const title =
      parsedGoal !== undefined && (trimmedUnit.length > 0 || !countKindNeedsUnit(kind))
        ? generateCounterTaskTitle(text, parsedGoal, trimmedUnit, undefined, kind)
        : text;
    child = {
      ...newChildPatch(true),
      title,
      action: text,
      goal: parsedGoal !== undefined ? formatCountForInput(parsedGoal, kind) : '',
      unit: trimmedUnit,
      countKind: kind,
    };
```

  - `compoundSubtaskDraft.ts`: `InlineSubtaskDraft.countKind?: CountKind` (absent = discrete). Readiness counting branch:

```ts
    case 'counting': {
      const kind = draft.countKind ?? 'discrete';
      if (!draft.action.trim()) return { ready: false, message: 'Add an action (e.g. "Run").' };
      if (countKindNeedsUnit(kind) && !draft.unit.trim()) return { ready: false, message: 'Add a unit (e.g. "miles").' };
      if (parseCountInput(draft.maxCountStr, kind) === null) return { ready: false, message: 'Add a goal above zero.' };
      return { ready: true, message: null };
    }
```

    and add (moved from `CompoundTaskWizard.tsx:257-281`, now title-generating — the wizard used to send `subtask.title.trim()`, which is `''` for a blank-titled counting sub-task):

```ts
/**
 * An inline sub-task's `createCompound` entry. A blank-titled counting
 * sub-task gets the generated "{Action} {Goal} {Unit}" / "{Action} {Xh Ym}"
 * title; the auto-link match is skipped for Duration (no noun to match).
 */
export function inlineSubtaskToAutoCreate(subtask: InlineSubtaskDraft, allTasks: Task[]): CreateCompoundChildEntry {
  if (subtask.inlineType !== 'counting') return { autoCreate: { type: TaskType.NORMAL, title: subtask.title.trim() } };
  const kind = subtask.countKind ?? 'discrete';
  const action = subtask.action.trim();
  const unit = countKindNeedsUnit(kind) ? subtask.unit.trim() : '';
  const maxCount = parseCountInput(subtask.maxCountStr, kind) ?? undefined;
  const match =
    !subtask.linkDisabled && kind !== 'duration' && action && unit
      ? findLinkableCounter({ action, unit }, allTasks)
      : null;
  const title = subtask.title.trim() || (maxCount !== undefined ? generateCounterTaskTitle(action, maxCount, unit, undefined, kind) : action);
  return {
    autoCreate: {
      type: TaskType.COUNTING,
      title,
      action: action || undefined,
      unit: unit || undefined,
      maxCount,
      ...(kind !== 'discrete' ? { countKind: kind } : {}),
      sharedCounterId: match ? match.counterId : undefined,
      baseline: match ? match.lifetime : undefined,
    },
  };
}
```

    `CompoundTaskWizard.tsx`: the inline branch becomes `return inlineSubtaskToAutoCreate(subtask, allTasks);`.
  - `CountingSubConfigRow.tsx`: props gain `kind: CountKind; onKindChange: (kind: CountKind) => void;`; render `<KindPicker value={kind} lock="none" onChange={onKindChange} size="compact" />` first; Goal `<GoalEntry kind={kind} value={goal} onChange={onGoalChange} id={`${idPrefix}-goal`} aria-label="Goal" dense invalid={Boolean(goalError)} placeholder={kind === 'duration' ? '0h 0m' : '100'} />`; the Counting field only `{countKindNeedsUnit(kind) && …}`.
  - `CountingStepFields.tsx`: props gain `countKind: CountKind; onKindChange: (kind: CountKind) => void;`, passed to `CountingSubConfigRow`; title preview `const parsed = parseCountInput(maxCount, countKind); … parsed !== null && trimmedAction && (trimmedUnit || countKind === 'duration') ? generateCounterTaskTitle(trimmedAction, parsed, countKindNeedsUnit(countKind) ? trimmedUnit : '', undefined, countKind) : null`.
  - `SubtaskCard.tsx` `:312-330`: `countKind={draft.countKind ?? 'discrete'}`, `onKindChange={(k) => onUpdate({ countKind: k, linkDisabled: false } as Partial<InlineSubtaskDraft>)}`; `InlineCounterLinkHint` returns null when `(draft.countKind ?? 'discrete') === 'duration'` and its `goalValid` uses `parseCountInput(draft.maxCountStr, draft.countKind ?? 'discrete')`; pass `counterName={match.name} linked={linked} onToggle={…}` only. Delete the `:292` caption node.
  - `CompoundFields.tsx`: `const [newSubKind, setNewSubKind] = useState<CountKind>('discrete');` → `CountingSubConfigRow kind={newSubKind} onKindChange={setNewSubKind}`, `canAppendCounting(newSubText, newSubGoal, newSubUnit, newSubKind)` (`:157`), `appendTypedChild(draft, text, newSubCounting, newSubGoal, newSubUnit, newSubKind)` (`:114`), `readsAsPreview(...)` unchanged. Existing child row `:229-245`: replace the `type="number"` input with `<GoalEntry kind={child.countKind} value={child.goal} onChange={(v) => onUpdate({ goal: v })} aria-label={`Sub-task ${index} goal`} dense />` and render the unit input only when `countKindNeedsUnit(child.countKind)`. Delete the `:187-189` `subtaskNote` span (row 61). Row 63 (`:182-186`): the `role="alert"` paragraph text becomes `Couldn&apos;t load your tasks.` (error state — shortened per #548's note, not removed).
  - `compoundStructureEdit.ts` `applyStagedCompoundChildEdits` new-counting-child branch: `maxCount: parseCountInput(step.goal, step.countKind) ?? undefined`, `unit: countKindNeedsUnit(step.countKind) ? step.unit.trim() : ''`, `...(step.countKind !== 'discrete' ? { countKind: step.countKind } : {})`, title via `generateCounterTaskTitle(…, step.countKind)` when the staged title is auto/blank.
  - `tasks.crud.ts:243-260`: add `...(entry.autoCreate.countKind ? { countKind: entry.autoCreate.countKind } : {}),` to the inline-created child (`withRootCountKind` still overrides a linked child).
  - `CounterLinkHint.tsx`:

```tsx
export interface CounterLinkHintProps {
  /** The matched counter's pair-derived display name. */
  counterName: string;
  /** Whether this create currently links to the counter. */
  linked: boolean;
  /** Toggles the link on/off for this create. */
  onToggle: () => void;
}

/** The matched counter + the link toggle. The kind tag beside the Goal shows the family's total (#548 77/78). */
export function CounterLinkHint({ counterName, linked, onToggle }: CounterLinkHintProps): React.ReactElement {
  return (
    <div className={styles.hint} role="region" aria-label="Counter link">
      <p className={styles.hintTitle}>{counterName}</p>
      <button type="button" className={styles.hintPill} onClick={onToggle} aria-label={linked ? `Don't link to ${counterName}` : `Link to ${counterName}`}>
        {linked ? "Don't link" : 'Link'}
      </button>
    </div>
  );
}
```

    (drop the `.hintText` / `.hintSub` CSS rules). Fix `CountingTemplatePicker.tsx:113-119` to pass the three props.

- [ ] **Step 4: Run** `WEB_TEST taskEditPatch compoundSubtaskDraft CounterLinkHint compoundFields createFormCounting` — PASS (the existing `compoundFields.test.ts` must stay green); `WEB_CHECK`.

- [ ] **Step 5: iOS failing tests** `apps/ios/OYBCTests/CompoundSubKindTests.swift`:

```swift
import XCTest
import GRDB
@testable import OYBC

@MainActor
final class CompoundSubKindTests: XCTestCase {
    func testNewDurationSubCarriesKindIntoTheChildTask() throws {
        let db = try AppDatabase.makeTestInstance(); try LinkedWindowKit.seedUser(db)
        let form = CreateFormViewModel(database: db)
        let done = expectation(description: "created")
        form.handleCreateCompoundAndAddToPool(
            userId: LinkedWindowKit.userId,
            title: "Music week",
            rule: .allOf,
            subs: [.newCounting(action: "Practice", goal: 90, unit: "", sharedCounterId: nil, baseline: nil, countKind: .duration)],
            onTaskCreated: { _, _, _ in done.fulfill() },
            onLibraryReloadRequested: {}
        )
        wait(for: [done], timeout: 5)
        let child = try XCTUnwrap(try db.read { try Task.filter(Column("action") == "Practice").fetchOne($0) })
        XCTAssertEqual(child.countKind, .duration)
        XCTAssertEqual(child.maxCount, 90)
        XCTAssertEqual(child.unit, "")
        XCTAssertEqual(child.title, "Practice 1h 30m")
    }

    func testChildPatchSeedsKindAndTheAppendGateParsesPerKind() {
        var t = LinkedWindowKit.task("c", maxCount: 26.2); t.countKind = .continuous
        let patch = ChildPatch(from: t)
        XCTAssertEqual(patch.countKind, .continuous)
        XCTAssertEqual(patch.goal, "26.2")
        XCTAssertTrue(RisoCompoundEditFieldsView.canAppendCounting(text: "Run", goal: "3.1", unit: "mi", kind: .continuous))
        XCTAssertFalse(RisoCompoundEditFieldsView.canAppendCounting(text: "Run", goal: "3.1", unit: "mi", kind: .discrete))
        XCTAssertTrue(RisoCompoundEditFieldsView.canAppendCounting(text: "Practice", goal: "90", unit: "", kind: .duration))
    }

    func testAppendTypedDurationTitlesWithoutAUnit() {
        var draft = TaskEditPatch(title: "Music week")
        RisoCompoundEditFieldsView.appendTyped("Practice", isCounting: true, goal: "1h 30m", unit: "ignored", kind: .duration, to: &draft)
        XCTAssertEqual(draft.children.first?.title, "Practice 1h 30m")
        XCTAssertEqual(draft.children.first?.unit, "")
        XCTAssertEqual(draft.children.first?.countKind, .duration)
    }
}
```

- [ ] **Step 6: Run — expect build FAIL.** `IOS_TEST -only-testing:OYBCTests/CompoundSubKindTests`

- [ ] **Step 7: Implement iOS.**
  - `RisoCountingSubConfigRow`:

```swift
struct RisoCountingSubConfigRow: View {
    @Binding var goal: String
    @Binding var unit: String
    @Binding var kind: CountKind

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            KindPickerView(selection: $kind, lock: .none)
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    requiredLabel("Goal")
                    GoalEntryView(kind: kind, text: $goal, placeholder: kind == .duration ? "0h 0m" : "100")
                }
                if countKindNeedsUnit(kind) {
                    VStack(alignment: .leading, spacing: 5) {
                        requiredLabel("Counting")
                        RisoTextField(placeholder: "push-ups", text: $unit)
                    }
                }
            }
        }
    }
    // requiredLabel(_:) unchanged
}
```

  - `TaskEditPatch.swift`: `ChildPatch` gains `var countKind: CountKind = .discrete` (and the `init(id:…)` gains `countKind: CountKind = .discrete` last); `init(from child:)` sets `countKind = resolveCountKind(child.countKind)`. `TaskEditPatch` gains `var countKind: CountKind = .discrete`, seeded at `:98` from `resolveCountKind(task.countKind)`; `parsedGoal` = `parseCountInput(goal, kind: countKind)`; child goal at `:151` = `parseCountInput(child.goal, kind: child.countKind) ?? 0`, and the counting-child unit requirement there is gated on `countKindNeedsUnit(child.countKind)`.
  - `RisoCompoundEditFieldsView`: `private static func parsePositiveGoal(_ goal: String, kind: CountKind) -> CountValue? { parseCountInput(goal, kind: kind) }`; `static func canAppendCounting(text:goal:unit:kind:)` = non-blank text && `parsePositiveGoal(goal, kind:) != nil` && (`!countKindNeedsUnit(kind)` || non-blank unit); `appendTyped(_:isCounting:goal:unit:kind: CountKind = .discrete, to:)` counting branch mirrors the web code (unit `""` for Duration, title via `TaskTitle.generateCounterTaskTitle(…, countKind: kind)`, `goal: formatCountForInput(g, kind: kind)`, `countKind: kind`). `@State private var newSubKind: CountKind = .discrete` → `RisoCountingSubConfigRow(goal: $newSubGoal, unit: $newSubUnit, kind: $newSubKind)` at `:355`, passed to both static calls in the private `appendTyped` (`:304`). Existing child `:266`: `GoalEntryView(kind: child.wrappedValue.countKind, text: child.goal).frame(width: 84)` and the unit field only when `countKindNeedsUnit(child.wrappedValue.countKind)`. Delete the `:225` caption `Text` (row 62); `:370` text becomes `"Couldn't load your tasks."` (row 63).
  - `RisoCompoundFieldsView`: `Seed` gains `var subKind: CountKind = .discrete`; `@State private var subKind: CountKind` seeded in both inits (`:154`, `:192`); goal parse `:217` = `parseCountInput(subGoalText, kind: subKind)`; unit gate `:231` = `!countKindNeedsUnit(subKind) || !subUnitText…isEmpty`; `RisoCountingSubConfigRow(goal: $subGoalText, unit: $subUnitText, kind: $subKind)` at `:370`; the appended item `.newCounting(…, countKind: subKind)` (`:586-600`) with `unit: countKindNeedsUnit(subKind) ? unit : ""`; resets at `:603`/`:656` set `subKind = .discrete`; `updateSubLinkSuggestion()` returns nil for Duration; `subCounterLinkBanner` passes `RisoCounterLinkHintView(counterName: suggestion.name, linked: !subLinkDisabled, onToggle: …)`.
  - `CreateFormViewModel.swift`: `case newCounting(action: String, goal: CountValue, unit: String, sharedCounterId: String?, baseline: CountValue?, countKind: CountKind)`; `displayTitle` passes `countKind:`; the child-builder (`:648-668`) uses `TaskTitle.generateCounterTaskTitle(action: action, maxCount: goal, unit: unit, countKind: countKind)`, `unit: countKindNeedsUnit(countKind) ? trimmedUnit : ""`, then `child.countKind = countKind == .discrete ? nil : countKind`.
  - `AppDatabase+CompoundStructureEdit.swift`: the new-child builder parses `step.goal` with `step.countKind`, writes `unit` `""` for Duration and sets `countKind` (nil for discrete).
  - `RisoCounterLinkHintView`: properties `counterName`, `linked`, `onToggle`; body = `HStack { Text(counterName).font(.risoHead(13, .bold)).foregroundStyle(Color.risoPaper); Spacer(minLength: 0); <the existing pill button> }` with `.accessibilityLabel(linked ? "Don't link to \(counterName)" : "Link to \(counterName)")` on the pill. Fix the two call sites.

- [ ] **Step 8: Run iOS** `IOS_TEST -only-testing:OYBCTests/CompoundSubKindTests -only-testing:OYBCTests/BoardEditCompoundTests -only-testing:OYBCTests/AppDatabaseTaskEditTests` — PASS. Re-record exactly the seven baselines listed under Files (delete → record → green), confirm the must-stay-green ones are green, read each re-record against handoff A2 (Duration sub-task: no Counting field; link hint = name + pill).

- [ ] **Step 9: e2e + Playwright.** `WEB_E2E e2e/task-detail-compound-edit.spec.ts e2e/pool-row-editor.spec.ts` must stay green (update any assertion on the removed "A sub-task's type is fixed…" caption by deleting it). Playwright MCP validation (the compound wizard's multi-step flow is covered by the unit tests above): `/tasks?__oybc_test_bypass=1` → `+ New task` → Compound → Title "Music week" → `Next ›` → add an inline Counting sub-task, Verb "Practice", Kind Duration, 1 h 30 m → `Next ›` → create; confirm the library shows `Practice 1h 30m`; screenshot the sub-task card with Duration selected light/dark → `.playwright-mcp/task7-a2-{light,dark}.png`.

- [ ] **Step 10: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): A2 compound sub-tasks pick a kind (create + edit); blank counting sub-tasks get a generated title; link hint keeps only the counter + toggle (#548 61-63, 65, 77/78) (PR 3 Task 7)"
```

---

### Task 8: Kind-switch infrastructure — in-transaction switch, switch-then-guard helper, preview, confirm (Ruling U7)

One helper per platform owns "switch the kind if it changed, then refuse a fractional goal at a whole kind"; Tasks 9, 10 and 12 call it inside their own transactions and never restate it. One confirm seam per platform (`useKindSwitchRequest` ↔ `.kindSwitchConfirm`) owns the Continuous → Discrete dialog + goal rounding for every editing sheet.

**Files:**
- Modify: `apps/web/src/db/operations/countKindSwitch.ts:73-140` — extract `switchCounterKindInTransaction`; add `KindGoalError`, `applyKindSwitchThenGoalGuard`, `planKindSwitchPreview` (pure), `previewCounterKindSwitch`
- (No `db/operations/index.ts` change: `countKindSwitch.ts` is not in that barrel today — callers import it by path, as PR 2's tests do.)
- Create: `apps/web/src/components/counters/kindSwitchModel.ts`, `KindSwitchConfirmDialog.tsx` (+`.module.css`), `useKindSwitchRequest.tsx`
- Modify: `apps/ios/OYBC/Database/AppDatabase+CountKindSwitch.swift:13-106` (`CountKindSwitchError.goalNotWhole`; `static func switchCounterKind(db:…)`; `static func applyKindSwitchThenGoalGuard(db:…)`; `KindSwitchPreview` + `previewCounterKindSwitch`)
- Modify: `apps/ios/OYBC/Database/AppDatabase+Tasks.swift:75` (+`runBoardCascadeForTasks(db:changedTaskIds:now:)` — one snapshot, each affected board derived once; carried perf item)
- Create: `apps/ios/OYBC/Views/Components/KindSwitchConfirmView.swift` (`KindSwitchCopy`, `KindSwitchConfirmView`, `View.kindSwitchConfirm(pending:onConfirm:)`)
- Test: `apps/web/src/db/operations/__tests__/countKindSwitch.test.ts` (+cases, reusing its `seedFamily(opts: FamilyOptions)`, `ROOT`, `LIVE`, `ENDED`, `NOW`), `apps/web/src/components/counters/__tests__/kindSwitchModel.test.ts` (create), `apps/ios/OYBCTests/AppDatabaseCountKindSwitchTests.swift` (+cases, reusing its `seedFamily(kind:rootGoal:liveTarget:endedTarget:deltas:)` and `now`), `apps/ios/OYBCSnapshotTests/KindSwitchConfirmSnapshotTests.swift` (create)

**Interfaces:**
- Consumes: `switchCounterKind` (PR 2), `planCountKindSwitch`, `isAutoCounterTitle(…, kind)`, `generateCounterTaskTitle(…, kind)`, `finalizeWindowCount`, `quantizeCount`, `isFrozenDerivedRow`, `formatCount`, `formatCountForInput`, `parseCountInput`.
- Produces (web):
  - `switchCounterKindInTransaction(rootTaskId: string, to: CountKind, nowIso: string): Promise<string[]>` — inside a caller `rw` transaction over `boards, boardTasks, tasks, compoundChildren, taskEvents, syncQueue`
  - `class KindGoalError extends Error` (message `Whole-number kinds need whole goals`)
  - `applyKindSwitchThenGoalGuard(taskId: string, to: CountKind | undefined, maxCount: number | null | undefined, nowIso: string): Promise<boolean>` — switches only a live COUNTING ROOT whose kind differs (returns true when it switched), then throws `KindGoalError` when `maxCount` is fractional at the FINAL kind and that kind is whole. Throwing after the switch rolls the caller's whole transaction back.
  - `interface KindSwitchPreview { from: CountKind; to: CountKind; titleBefore: string; titleAfter: string; loggedBefore: number; loggedAfter: number; linkedCount: number }`
  - `planKindSwitchPreview(task: Pick<Task, 'title' | 'action' | 'unit' | 'maxCount' | 'currentCount' | 'countKind'>, to: CountKind, linkedCount: number): KindSwitchPreview | null` (pure — used for pending tasks too)
  - `previewCounterKindSwitch(rootTaskId: string, to: CountKind, now?: Date): Promise<KindSwitchPreview | null>`
  - `needsKindSwitchConfirm(from, to): boolean`; `kindSwitchConfirmLines(p): { title: string; rows: [string, string][]; body: string }`; `switchedGoalText(goalText: string, from: CountKind, to: CountKind): string`
  - `type KindSwitchSubject = Pick<Task, 'id' | 'title' | 'action' | 'unit' | 'maxCount' | 'currentCount' | 'countKind'>`
  - `useKindSwitchRequest(args: { subject: KindSwitchSubject; kind: CountKind; goalText: string; onSwitched: (kind: CountKind, goalText: string) => void; setKind: (k: CountKind) => void }): { requestKind: (next: CountKind) => void; dialog: React.ReactElement | null }` — `setKind` applies a change that needs no confirm; `onSwitched` receives the confirmed kind AND the rounded goal text in ONE call (pool rows hold both in one draft object)
- Produces (iOS): `CountKindSwitchError.goalNotWhole`; `static func switchCounterKind(db: Database, rootTaskId: String, to: CountKind, now: Date) throws -> [String]`; `@discardableResult static func applyKindSwitchThenGoalGuard(db: Database, taskId: String, to: CountKind?, maxCount: CountValue?, now: Date) throws -> Bool`; `struct KindSwitchPreview: Equatable, Identifiable` (same fields; `id` = `"\(from.rawValue)-\(to.rawValue)"`) with `static func planned(task: Task, to: CountKind, linkedCount: Int) -> KindSwitchPreview?`; `func previewCounterKindSwitch(rootTaskId: String, to: CountKind, now: Date = Date()) throws -> KindSwitchPreview?`; `static func runBoardCascadeForTasks(db: Database, changedTaskIds: [String], now: String) throws`; `enum KindSwitchCopy { static func needsConfirm(from:to:) -> Bool; static func lines(_:) -> (title: String, rows: [(String, String)], body: String); static func switchedGoalText(_:from:to:) -> String }`; `KindSwitchConfirmView(preview:onCancel:onConfirm:)`; `extension View { func kindSwitchConfirm(pending: Binding<KindSwitchPreview?>, onConfirm: @escaping (KindSwitchPreview) -> Void) -> some View }`.
- Preview rules: `titleAfter` regenerates only an auto title (`isAutoCounterTitle` at `from`) else keeps it; `loggedBefore` = `quantizeCount(root.currentCount ?? 0)` (lifetime); `loggedAfter` = `finalizeWindowCount(loggedBefore, to)`; `linkedCount` = live family rows the switch would write (not `isFrozenDerivedRow` at `now`).

- [ ] **Step 1: Failing web tests.** Append to `countKindSwitch.test.ts`:

```ts
describe('previewCounterKindSwitch', () => {
  it('continuous → discrete: rounded logged, custom title kept, live linked count only', async () => {
    await seedFamily({ countKind: 'continuous', rootGoal: 26.2, deltas: [12.75] });
    expect(await previewCounterKindSwitch(ROOT, 'discrete', NOW)).toEqual({
      from: 'continuous', to: 'discrete', titleBefore: 'Run', titleAfter: 'Run',
      loggedBefore: 12.75, loggedAfter: 13, linkedCount: 1, // LIVE counts, ENDED is frozen
    });
  });
  it('an auto title regenerates at the rounded goal', async () => {
    await seedFamily({ countKind: 'continuous', rootGoal: 26.2, deltas: [] });
    await db.tasks.update(ROOT, { title: 'Run 26.2 km' });
    expect((await previewCounterKindSwitch(ROOT, 'discrete', NOW))?.titleAfter).toBe('Run 26 km');
  });
  it('refused switches and linked rows preview null', async () => {
    await seedFamily({ countKind: 'continuous', rootGoal: 26.2 });
    expect(await previewCounterKindSwitch(ROOT, 'duration', NOW)).toBeNull();
    expect(await previewCounterKindSwitch(LIVE, 'discrete', NOW)).toBeNull();
  });
});

describe('applyKindSwitchThenGoalGuard', () => {
  const TABLES = () => [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue];
  it('switches the root and the live family, then accepts a whole goal', async () => {
    await seedFamily({ countKind: 'continuous', rootGoal: 26.2, liveTarget: 6.1 });
    const switched = await db.transaction('rw', TABLES(), () => applyKindSwitchThenGoalGuard(ROOT, 'discrete', 30, NOW.toISOString()));
    expect(switched).toBe(true);
    expect(await db.tasks.get(ROOT)).toMatchObject({ countKind: 'discrete', maxCount: 26 });
    expect((await db.tasks.get(LIVE))?.countKind).toBe('discrete');
  });
  it('a fractional goal at the new whole kind throws AFTER the switch and rolls the switch back', async () => {
    await seedFamily({ countKind: 'continuous', rootGoal: 26.2 });
    await expect(
      db.transaction('rw', TABLES(), () => applyKindSwitchThenGoalGuard(ROOT, 'discrete', 26.5, NOW.toISOString())),
    ).rejects.toBeInstanceOf(KindGoalError);
    expect(await db.tasks.get(ROOT)).toMatchObject({ countKind: 'continuous', maxCount: 26.2, version: 1 });
  });
  it('never switches a linked row; an unchanged kind writes nothing', async () => {
    await seedFamily({ countKind: 'continuous', rootGoal: 26.2 });
    expect(await db.transaction('rw', TABLES(), () => applyKindSwitchThenGoalGuard(LIVE, 'discrete', undefined, NOW.toISOString()))).toBe(false);
    expect(await db.transaction('rw', TABLES(), () => applyKindSwitchThenGoalGuard(ROOT, 'continuous', 26.3, NOW.toISOString()))).toBe(false);
    expect((await db.tasks.get(ROOT))?.version).toBe(1);
    expect((await db.tasks.get(LIVE))?.countKind).toBe('continuous');
  });
});
```

(`seedFamily` sets the root's `currentCount` to the delta sum — `[12.75]` gives exactly 12.75; the root title from the file's `counting()` builder is `'Run'`, unit `'km'`.) `kindSwitchModel.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { kindSwitchConfirmLines, needsKindSwitchConfirm, switchedGoalText } from '../kindSwitchModel';
import { planKindSwitchPreview } from '../../../db/operations/countKindSwitch';

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
  it('family line: absent at 0, singular at 1', () => {
    const base = { from: 'continuous' as const, to: 'discrete' as const, titleBefore: 'a', titleAfter: 'a', loggedBefore: 0, loggedAfter: 0 };
    expect(kindSwitchConfirmLines({ ...base, linkedCount: 0 }).body).toBe('Switching back restores the exact values.');
    expect(kindSwitchConfirmLines({ ...base, linkedCount: 1 }).body).toBe('Switching back restores the exact values. Follows on 1 linked square.');
  });
  it('switchedGoalText rounds a typed decimal goal for the new whole kind', () => {
    expect(switchedGoalText('26.2', 'continuous', 'discrete')).toBe('26');
    expect(switchedGoalText('0.3', 'continuous', 'discrete')).toBe('1');
    expect(switchedGoalText('26', 'discrete', 'continuous')).toBe('26');
    expect(switchedGoalText('', 'continuous', 'discrete')).toBe('');
  });
  it('a pending task previews from its own fields', () => {
    expect(planKindSwitchPreview({ title: 'Run 26.2 mi', action: 'Run', unit: 'mi', maxCount: 26.2, currentCount: 0, countKind: 'continuous' }, 'discrete', 0))
      .toEqual({ from: 'continuous', to: 'discrete', titleBefore: 'Run 26.2 mi', titleAfter: 'Run 26 mi', loggedBefore: 0, loggedAfter: 0, linkedCount: 0 });
  });
});
```

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST countKindSwitch kindSwitchModel`

- [ ] **Step 3: Implement web.** In `countKindSwitch.ts`, move the transaction callback body of `switchCounterKind` into

```ts
export async function switchCounterKindInTransaction(rootTaskId: string, to: CountKind, nowIso: string): Promise<string[]> {
  // … the existing body verbatim (root read + refusals, root write, family loop, cascade) …
  await runBoardCascadeForTasks(writtenIds);
  return writtenIds;
}
```

and make `switchCounterKind` = `await db.transaction('rw', [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue], () => switchCounterKindInTransaction(rootTaskId, to, now.toISOString()));`. Add:

```ts
/** A whole kind received a fractional goal (D4) — the caller's transaction rolls back. */
export class KindGoalError extends Error {
  constructor() {
    super('Whole-number kinds need whole goals');
    this.name = 'KindGoalError';
  }
}

/**
 * The ONE "switch if changed, then guard the goal" step every editing save
 * runs inside its own transaction (Task Detail, Board Edit, staged pool /
 * wizard edits — Ruling U7).
 *
 * @param taskId - The edited task.
 * @param to - The kind the editor chose; undefined = unchanged.
 * @param maxCount - The goal the caller is about to write, if any.
 * @param nowIso - Switch instant / freeze clock.
 * @returns True when a switch was written.
 * @throws {KindGoalError} when `maxCount` is fractional at a whole final kind.
 */
export async function applyKindSwitchThenGoalGuard(
  taskId: string,
  to: CountKind | undefined,
  maxCount: number | null | undefined,
  nowIso: string,
): Promise<boolean> {
  const task = await db.tasks.get(taskId);
  if (!task || task.isDeleted || task.type !== TaskType.COUNTING) return false;
  const from = resolveCountKind(task);
  let switched = false;
  if (to !== undefined && to !== from && task.sharedCounterId == null) {
    await switchCounterKindInTransaction(taskId, to, nowIso);
    switched = true;
  }
  const finalKind = switched && to !== undefined ? to : from;
  if (maxCount != null && isWholeCountKind(finalKind) && !Number.isInteger(maxCount)) throw new KindGoalError();
  return switched;
}

export interface KindSwitchPreview {
  from: CountKind;
  to: CountKind;
  titleBefore: string;
  titleAfter: string;
  loggedBefore: number;
  loggedAfter: number;
  linkedCount: number;
}

/** Pure preview from a task's own fields (pending tasks use it directly). */
export function planKindSwitchPreview(
  task: Pick<Task, 'title' | 'action' | 'unit' | 'maxCount' | 'currentCount' | 'countKind'>,
  to: CountKind,
  linkedCount: number,
): KindSwitchPreview | null {
  const from = resolveCountKind(task);
  const patch = planCountKindSwitch(task, from, to);
  if (!patch) return null;
  const action = task.action ?? '';
  const unit = task.unit ?? '';
  const auto = isAutoCounterTitle(task.title, action, task.maxCount, unit, from);
  const loggedBefore = quantizeCount(task.currentCount ?? 0);
  return {
    from,
    to,
    titleBefore: task.title,
    titleAfter: auto ? generateCounterTaskTitle(action, patch.maxCount ?? task.maxCount, unit, undefined, to) : task.title,
    loggedBefore,
    loggedAfter: finalizeWindowCount(loggedBefore, to),
    linkedCount,
  };
}

/** Read-only preview of {@link switchCounterKind} for a stored root. */
export async function previewCounterKindSwitch(rootTaskId: string, to: CountKind, now: Date = new Date()): Promise<KindSwitchPreview | null> {
  const root = await db.tasks.get(rootTaskId);
  if (!root || root.isDeleted || root.type !== TaskType.COUNTING || root.sharedCounterId != null) return null;
  const nowIso = now.toISOString();
  const family = await db.tasks.where('sharedCounterId').equals(root.id).filter((t) => !t.isDeleted).toArray();
  return planKindSwitchPreview(root, to, family.filter((row) => !isFrozenDerivedRow(row, nowIso)).length);
}
```

(imports: `isAutoCounterTitle`, `generateCounterTaskTitle`, `finalizeWindowCount`, `quantizeCount`, `isWholeCountKind` from `@oybc/shared`.) `kindSwitchModel.ts`:

```ts
import { COUNT_KIND_LABELS, formatCount, formatCountForInput, parseCountInput, planCountKindSwitch, type CountKind } from '@oybc/shared';
import type { KindSwitchPreview } from '../../db/operations/countKindSwitch';

/** D4 / §5: only the rounding direction confirms. */
export function needsKindSwitchConfirm(from: CountKind, to: CountKind): boolean {
  return from === 'continuous' && to === 'discrete';
}

/** The confirm's copy — the one consequence body the no-explanatory-copy rule allows. */
export function kindSwitchConfirmLines(p: KindSwitchPreview): { title: string; rows: [string, string][]; body: string } {
  const family = p.linkedCount === 0 ? '' : ` Follows on ${p.linkedCount} linked square${p.linkedCount === 1 ? '' : 's'}.`;
  return {
    title: `Switch to ${COUNT_KIND_LABELS[p.to]}?`,
    rows: [
      [p.titleBefore, p.titleAfter],
      [`${formatCount(p.loggedBefore, p.from)} logged`, `${formatCount(p.loggedAfter, p.to)} logged`],
    ],
    body: `Switching back restores the exact values.${family}`,
  };
}

/** The Goal field's text after a confirmed switch (rounded for a whole kind). */
export function switchedGoalText(goalText: string, from: CountKind, to: CountKind): string {
  const goal = parseCountInput(goalText, from);
  if (goal === null) return goalText;
  const patch = planCountKindSwitch({ maxCount: goal }, from, to);
  return patch?.maxCount != null ? formatCountForInput(patch.maxCount, to) : goalText;
}
```

`KindSwitchConfirmDialog.tsx` (chrome copied from `CounterDeleteConfirmDialog.tsx:78-110` — `backdrop` / `sheet` / `role="alertdialog"` / `useModalA11y({ open: true, onCancel, initialFocus: 'cancel' })` from `../../hooks/useModalA11y`):

```tsx
export function KindSwitchConfirmDialog({ preview, onCancel, onConfirm }: KindSwitchConfirmDialogProps): React.ReactElement {
  const { ref, props } = useModalA11y<HTMLDivElement>({ open: true, onCancel, initialFocus: 'cancel' });
  const lines = kindSwitchConfirmLines(preview);
  return (
    <div className={styles.backdrop} onClick={onCancel}>
      <div ref={ref} className={styles.sheet} role="alertdialog" aria-label={lines.title} {...props} onClick={(e) => e.stopPropagation()}>
        <h2 className={styles.heading}>{lines.title}</h2>
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
        <div className={styles.sheetActions}>
          <button type="button" className={styles.cancelButton} data-modal-cancel onClick={onCancel}>Cancel</button>
          <button type="button" className={styles.switchButton} onClick={onConfirm}>Switch</button>
        </div>
      </div>
    </div>
  );
}
```

(Copy `CounterDeleteConfirmDialog.module.css`'s `.backdrop` / `.sheet` / `.sheetHeading` (as `.heading`) / `.sheetActions` / `.cancelButton` rules; `.switchButton` = `.deleteButton` with `background: var(--riso-blue)`; add `.rows { display: grid; gap: 6px; margin: 12px 0; } .row { display: flex; gap: 8px; font-weight: 600; } .before { color: var(--riso-muted); text-decoration: line-through; }`. `data-modal-cancel` is what `initialFocus: 'cancel'` targets — `useModalA11y.ts:23`.) `useKindSwitchRequest.tsx`:

```tsx
import { useState } from 'react';
import type { CountKind, Task } from '@oybc/shared';
import { planKindSwitchPreview, previewCounterKindSwitch, type KindSwitchPreview } from '../../db/operations/countKindSwitch';
import { KindSwitchConfirmDialog } from './KindSwitchConfirmDialog';
import { needsKindSwitchConfirm, switchedGoalText } from './kindSwitchModel';

/** What a preview needs — a stored task, or an editor draft for a pending one. */
export type KindSwitchSubject = Pick<Task, 'id' | 'title' | 'action' | 'unit' | 'maxCount' | 'currentCount' | 'countKind'>;

/**
 * The one confirm seam for every editing sheet's kind picker (Ruling U7):
 * Continuous → Discrete opens the dialog (DB preview for a stored root, the
 * pure preview of `subject` for a pending task); confirming hands the new
 * kind and the rounded Goal text to `onSwitched` in one call. Every other
 * permitted change applies at once through `setKind`.
 */
export function useKindSwitchRequest(args: {
  subject: KindSwitchSubject;
  kind: CountKind;
  goalText: string;
  onSwitched: (kind: CountKind, goalText: string) => void;
  setKind: (k: CountKind) => void;
}): { requestKind: (next: CountKind) => void; dialog: React.ReactElement | null } {
  const [pending, setPending] = useState<KindSwitchPreview | null>(null);
  const requestKind = (next: CountKind): void => {
    if (!needsKindSwitchConfirm(args.kind, next)) { args.setKind(next); return; }
    void previewCounterKindSwitch(args.subject.id, next).then((p) =>
      setPending(p ?? planKindSwitchPreview({ ...args.subject, countKind: args.kind }, next, 0)),
    );
  };
  const dialog = pending ? (
    <KindSwitchConfirmDialog
      preview={pending}
      onCancel={() => setPending(null)}
      onConfirm={() => {
        args.onSwitched(pending.to, switchedGoalText(args.goalText, args.kind, pending.to));
        setPending(null);
      }}
    />
  ) : null;
  return { requestKind, dialog };
}
```

- [ ] **Step 4: Run** `WEB_TEST countKindSwitch kindSwitchModel` — PASS (the existing `countKindSwitch` cases stay green: the wrapper is behaviour-identical); `WEB_CHECK`.

- [ ] **Step 5: iOS failing tests.** Append to `AppDatabaseCountKindSwitchTests.swift`:

```swift
    func test_preview_roundsLogged_keepsCustomTitle_countsLiveFamilyOnly() throws {
        let db = try seedFamily(kind: .continuous, rootGoal: 26.2, deltas: [12.75])
        let p = try XCTUnwrap(db.previewCounterKindSwitch(rootTaskId: "root", to: .discrete, now: now))
        XCTAssertEqual(p, KindSwitchPreview(from: .continuous, to: .discrete, titleBefore: "root", titleAfter: "root",
                                            loggedBefore: 12.75, loggedAfter: 13, linkedCount: 1))
    }

    func test_guard_fractionalGoalAtWholeKind_rollsTheSwitchBack() throws {
        let db = try seedFamily(kind: .continuous, rootGoal: 26.2)
        XCTAssertThrowsError(try db.write { conn in
            try AppDatabase.applyKindSwitchThenGoalGuard(db: conn, taskId: "root", to: .discrete, maxCount: 26.5, now: now)
        }) { XCTAssertEqual($0 as? CountKindSwitchError, .goalNotWhole) }
        let root = try XCTUnwrap(K.fetchTask(db, "root"))
        XCTAssertEqual(root.countKind, .continuous)
        XCTAssertEqual(root.maxCount, 26.2)
        XCTAssertEqual(root.version, 1)
    }

    func test_guard_neverSwitchesALinkedRow_andAnUnchangedKindWritesNothing() throws {
        let db = try seedFamily(kind: .continuous, rootGoal: 26.2)
        let a = try db.write { try AppDatabase.applyKindSwitchThenGoalGuard(db: $0, taskId: "live", to: .discrete, maxCount: nil, now: now) }
        let b = try db.write { try AppDatabase.applyKindSwitchThenGoalGuard(db: $0, taskId: "root", to: .continuous, maxCount: 26.3, now: now) }
        XCTAssertFalse(a); XCTAssertFalse(b)
        XCTAssertEqual(try K.fetchTask(db, "root")?.version, 1)
        XCTAssertEqual(try K.fetchTask(db, "live")?.countKind, .continuous)
    }

    /// Carried perf item: one board placing two switched rows is derived ONCE.
    func test_switch_derivesASharedBoardOnce() throws {
        let db = try seedFamily(kind: .continuous, rootGoal: 26.2)
        try db.saveBoardTask(K.placement(id: "btRootOnLive", boardId: "bLive", taskId: "root", cell: 1, size: 2))
        let before = try XCTUnwrap(db.fetchBoard(id: "bLive")).version
        try db.switchCounterKind(rootTaskId: "root", to: .discrete, now: now)
        XCTAssertEqual(try XCTUnwrap(db.fetchBoard(id: "bLive")).version, before + 1)
    }

    func test_confirmCopy_andGoalRounding() {
        let p = KindSwitchPreview(from: .continuous, to: .discrete, titleBefore: "Run 26.2 miles", titleAfter: "Run 26 miles",
                                  loggedBefore: 12.75, loggedAfter: 13, linkedCount: 2)
        let lines = KindSwitchCopy.lines(p)
        XCTAssertEqual(lines.title, "Switch to Discrete?")
        XCTAssertEqual(lines.rows.map { "\($0.0)→\($0.1)" }, ["Run 26.2 miles→Run 26 miles", "12.75 logged→13 logged"])
        XCTAssertEqual(lines.body, "Switching back restores the exact values. Follows on 2 linked squares.")
        XCTAssertTrue(KindSwitchCopy.needsConfirm(from: .continuous, to: .discrete))
        XCTAssertFalse(KindSwitchCopy.needsConfirm(from: .discrete, to: .continuous))
        XCTAssertEqual(KindSwitchCopy.switchedGoalText("26.2", from: .continuous, to: .discrete), "26")
        XCTAssertEqual(KindSwitchCopy.switchedGoalText("0.3", from: .continuous, to: .discrete), "1")
    }
```

(`K.placement(id:boardId:taskId:cell:size:)` is `LinkedWindowKit.placement`; `seedFamily`'s root is titled `"root"` — a custom title, so `titleAfter` keeps it. If `K.placement`'s `cell` maps to an occupied slot of a 1×1 board, pass `size: 2` as shown so the second placement is valid.) Snapshot `KindSwitchConfirmSnapshotTests.swift`: `testConfirmLight` / `testConfirmDark` rendering `KindSwitchConfirmView(preview: p, onCancel: {}, onConfirm: {})` (the preview above) at `.fixed(width: 393, height: 320)`.

- [ ] **Step 6: Run — expect build FAIL.** `IOS_TEST -only-testing:OYBCTests/AppDatabaseCountKindSwitchTests`

- [ ] **Step 7: Implement iOS.**
  - `CountKindSwitchError` gains `/// A whole kind received a fractional goal (D4). case goalNotWhole`.
  - Extract the `write { db in … }` body (`:47-105`) into `static func switchCounterKind(db: Database, rootTaskId: String, to: CountKind, now: Date) throws -> [String]`; its final loop becomes `try Self.runBoardCascadeForTasks(db: db, changedTaskIds: writtenIds, now: nowIso)` and it returns `writtenIds`. The instance method = `try write { db in _ = try Self.switchCounterKind(db: db, rootTaskId: rootTaskId, to: to, now: now) }`.
  - `AppDatabase+Tasks.swift`: add beside `runBoardCascadeForTask`:

```swift
    /// `runBoardCascadeForTask` for several changed tasks, deriving each
    /// affected board ONCE from one snapshot (kind switches write a root and
    /// its family together — counter kinds carried perf item).
    static func runBoardCascadeForTasks(db: Database, changedTaskIds: [String], now: String) throws {
        let allChildren = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
        let allBoardTasks = try BoardTask.filter(Column("isDeleted") == false).fetchAll(db)
        var boardIds: [String] = []
        for id in changedTaskIds {
            let parents = DerivationPass.findTransitiveParentCompounds(changedTaskId: id, children: allChildren)
            for b in DerivationPass.findAffectedBoardIds(changedTaskId: id, parentCompounds: parents, boardTasks: allBoardTasks)
            where !boardIds.contains(b) { boardIds.append(b) }
        }
        try deriveBoards(db: db, boardIds: boardIds, now: now)
    }
```

    and refactor `runBoardCascadeForTask` into "compute `affectedBoardIds`, then `try deriveBoards(db:boardIds:now:)`", where `private static func deriveBoards(db:boardIds:now:)` holds the existing snapshot (`allTasks`, `allBoards`, `windowContext`, maps) and per-board loop body verbatim (`:88-…`). Net line change ≈ +15.
  - Guard:

```swift
    /// The ONE "switch if changed, then guard the goal" step every editing
    /// save runs inside its own write (Ruling U7). Throwing after the switch
    /// rolls the caller's transaction back.
    @discardableResult
    static func applyKindSwitchThenGoalGuard(db: Database, taskId: String, to: CountKind?, maxCount: CountValue?, now: Date) throws -> Bool {
        guard let task = try Task.fetchOne(db, key: taskId), !task.isDeleted, task.type == .counting else { return false }
        let from = resolveCountKind(task.countKind)
        var switched = false
        if let to, to != from, task.sharedCounterId == nil {
            _ = try switchCounterKind(db: db, rootTaskId: taskId, to: to, now: now)
            switched = true
        }
        let finalKind = switched ? (to ?? from) : from
        if let maxCount, isWholeCountKind(finalKind), maxCount.rounded() != maxCount { throw CountKindSwitchError.goalNotWhole }
        return switched
    }
```

  - `KindSwitchPreview` (`Equatable, Identifiable`, `var id: String { "\(from.rawValue)-\(to.rawValue)" }`), `static func planned(task:to:linkedCount:)` (mirrors `planKindSwitchPreview`: `planCountKindSwitch(maxCount:defaultLogAmount:from:to:)`, `TaskTitle.isAutoCounterTitle(…, countKind: from)`, `TaskTitle.generateCounterTaskTitle(…, countKind: to)`, `quantizeCount`, `finalizeWindowCount`), and `func previewCounterKindSwitch(rootTaskId:to:now:)` = `try read { db in … family filter !BoardSources.isFrozenDerivedRow(row, now: nowIso) … KindSwitchPreview.planned(task: root, to: to, linkedCount: n) }` returning nil for a missing / non-counting / linked task.
  - `KindSwitchConfirmView.swift`:

```swift
import SwiftUI

/// Copy + rounding behind the Continuous → Discrete confirm. Web twin: `kindSwitchModel.ts`.
enum KindSwitchCopy {
    static func needsConfirm(from: CountKind, to: CountKind) -> Bool { from == .continuous && to == .discrete }

    static func lines(_ p: KindSwitchPreview) -> (title: String, rows: [(String, String)], body: String) {
        let family = p.linkedCount == 0 ? "" : " Follows on \(p.linkedCount) linked square\(p.linkedCount == 1 ? "" : "s")."
        return (
            "Switch to \(p.to.label)?",
            [(p.titleBefore, p.titleAfter),
             ("\(formatCount(p.loggedBefore, kind: p.from)) logged", "\(formatCount(p.loggedAfter, kind: p.to)) logged")],
            "Switching back restores the exact values.\(family)"
        )
    }

    static func switchedGoalText(_ goalText: String, from: CountKind, to: CountKind) -> String {
        guard let goal = parseCountInput(goalText, kind: from),
              let rounded = planCountKindSwitch(maxCount: goal, defaultLogAmount: nil, from: from, to: to)?.maxCount
        else { return goalText }
        return formatCountForInput(rounded, kind: to)
    }
}

/// Continuous → Discrete confirm (docs/COUNTER_KINDS.md §5). Web twin: `KindSwitchConfirmDialog.tsx`.
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

extension View {
    /// The one confirm seam for every editing sheet (Ruling U7): presents the
    /// dialog while `pending` is set; `onConfirm` receives the preview so the
    /// sheet sets its kind and rounds its goal with `KindSwitchCopy.switchedGoalText`.
    func kindSwitchConfirm(pending: Binding<KindSwitchPreview?>, onConfirm: @escaping (KindSwitchPreview) -> Void) -> some View {
        sheet(item: pending) { p in
            KindSwitchConfirmView(preview: p, onCancel: { pending.wrappedValue = nil }, onConfirm: {
                onConfirm(p)
                pending.wrappedValue = nil
            })
        }
    }
}
```

- [ ] **Step 8: Run iOS** `IOS_TEST -only-testing:OYBCTests/AppDatabaseCountKindSwitchTests` — PASS (existing switch tests unchanged). `xcodegen generate`; record `KindSwitchConfirmSnapshotTests`; read vs handoff "Switch confirm".

- [ ] **Step 9: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): switchCounterKind in a caller transaction + the shared switch-then-goal-guard step + preview + Continuous→Discrete confirm seam; family cascade derives each board once (PR 3 Task 8)"
```

---

### Task 9: A4 — Task Detail edit picks / switches the kind

**Files:**
- Modify: `apps/web/src/db/operations/compoundStructureEdit.ts:345-371` (`TaskEditSubmit.countKind`; `saveTaskEdit` runs the Task 8 guard + the field patch in one transaction)
- Modify: `apps/web/src/pages/tasks/TaskEditSheet.tsx:77-80` (kind state; goal seeded with `formatCountForInput`), `:200-220` (submit), `:320-352` (Action / Kind / Goal / Unit / Reads as)
- Modify: `apps/ios/OYBC/Views/TasksTab/EditTaskSheet.swift:44-60` (`Patch.countKind: CountKind? = nil`), `:75,:116` (state), `:219-240` (fields), `:470-490` (submit), `.kindSwitchConfirm`
- Modify: `apps/ios/OYBC/Database/AppDatabase+TaskEditing.swift:98-130` (guard first, inside the write), `:231-240` (`applyBasicFields` becomes `throws`; parses the goal at the final kind)
- Test: `apps/web/src/db/operations/__tests__/saveTaskEdit.countKind.test.ts` (create), `apps/ios/OYBCTests/AppDatabaseTaskEditTests.swift` (+3 cases), `apps/web/e2e/counter-kinds-authoring.spec.ts` (+1 case)
- Re-record (intentional — Kind row): `RisoEditTaskSheetSnapshotTests/testCounting{Light,Dark}`; add `testCountingDurationLockedLight`, `testCountingContinuousLight`

**Interfaces:**
- Consumes: `KindPicker`, `KindTag`, `GoalEntry` (Tasks 3–4); `applyKindSwitchThenGoalGuard`, `useKindSwitchRequest` / `.kindSwitchConfirm`, `KindSwitchCopy.switchedGoalText` (Task 8); `kindPickerLock('edit', kind)`, `countingGoalError` (Task 6).
- Produces: `TaskEditSubmit.countKind?: CountKind`; iOS `EditTaskSheet.Patch.countKind: CountKind?` (nil = unchanged). Rule: Save = guard (switch if changed) → field patch, one transaction; the typed goal is parsed at the NEW kind.

- [ ] **Step 1: Failing web test** `saveTaskEdit.countKind.test.ts` (Dexie via `fake-indexeddb`; teardown as in `countKindSwitch.test.ts:156-166`):

```ts
import { afterEach, describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { db } from '../../internal';
import { saveTaskEdit } from '../compoundStructureEdit';
import { KindGoalError } from '../countKindSwitch';

const seed = async (over: Partial<Task>): Promise<Task> => {
  const t = {
    id: 'r', userId: 'u1', title: 'Run 26.2 miles', type: TaskType.COUNTING, action: 'Run', unit: 'miles',
    maxCount: 26.2, countKind: 'continuous', currentCount: 0, isCompleted: false, totalCompletions: 0,
    totalInstances: 0, createdAt: '2026-10-01T00:00:00.000Z', updatedAt: '2026-10-01T00:00:00.000Z', version: 1, isDeleted: false,
    ...over,
  } as Task;
  await db.tasks.add(t);
  return t;
};

afterEach(async () => {
  await Promise.all([db.tasks.clear(), db.taskEvents.clear(), db.boards.clear(), db.boardTasks.clear(), db.compoundChildren.clear(), db.syncQueue.clear()]);
});

describe('saveTaskEdit — counter kinds', () => {
  it('switches continuous → discrete then applies the typed goal', async () => {
    await seed({});
    await saveTaskEdit('r', { countKind: 'discrete', maxCount: 30, action: 'Run', unit: 'miles', title: 'Run 30 miles' });
    expect(await db.tasks.get('r')).toMatchObject({ countKind: 'discrete', maxCount: 30, title: 'Run 30 miles' });
  });
  it('a fractional goal at the new whole kind rolls the switch back', async () => {
    await seed({});
    await expect(saveTaskEdit('r', { countKind: 'discrete', maxCount: 26.5, title: 'Run 26.5 miles' })).rejects.toBeInstanceOf(KindGoalError);
    expect(await db.tasks.get('r')).toMatchObject({ countKind: 'continuous', maxCount: 26.2, version: 1 });
  });
  it('an unchanged kind is one ordinary version bump', async () => {
    await seed({ countKind: undefined, maxCount: 5, title: 'Read 5 pages', unit: 'pages', action: 'Read' });
    await saveTaskEdit('r', { countKind: 'discrete', maxCount: 6, title: 'Read 6 pages' });
    expect((await db.tasks.get('r'))?.version).toBe(2);
  });
});
```

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST saveTaskEdit.countKind`

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
  if (countKind === undefined) {
    await updateTaskAndCascade(taskId, basicPatch);
    return;
  }
  await db.transaction('rw', [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue], async () => {
    await applyKindSwitchThenGoalGuard(taskId, countKind, basicPatch.maxCount, new Date().toISOString());
    await updateTaskAndCascade(taskId, basicPatch);
  });
}
```

(`updateTaskAndCascade` opens nested `rw` transactions over subsets of these six tables — Dexie joins them to the outer one, so a later throw rolls everything back; if a run reports `SubTransaction` scope errors, add the missing table to the outer list.) `TaskEditSheet.tsx`:

```tsx
  const storedKind = resolveCountKind(task);
  const [countKind, setCountKind] = useState<CountKind>(storedKind);
  const [maxCountStr, setMaxCountStr] = useState(task.maxCount !== undefined ? formatCountForInput(task.maxCount, storedKind) : '');
  const { requestKind, dialog: kindDialog } = useKindSwitchRequest({
    subject: task, kind: countKind, goalText: maxCountStr, setKind: setCountKind,
    onSwitched: (k, g) => { setCountKind(k); setMaxCountStr(g); },
  });
```

The counting fields (`:320-352`) become Action → Kind → Goal · Unit → Reads as:

```tsx
            <div className={styles.field}>
              <span className={styles.fieldLabel}>Kind</span>
              {task.sharedCounterId ? (
                <KindTag kind={storedKind} />
              ) : (
                <KindPicker value={countKind} lock={kindPickerLock('edit', storedKind)} onChange={requestKind} />
              )}
            </div>
            <label className={styles.field}>
              <span className={styles.fieldLabel}>Goal</span>
              <GoalEntry kind={countKind} value={maxCountStr} onChange={setMaxCountStr} aria-label="Goal" dense />
            </label>
            {countKindNeedsUnit(countKind) && ( /* the existing Unit field, unchanged */ )}
            {kindDialog}
```

and the submit counting branch:

```ts
    if (task.type === TaskType.COUNTING) {
      patch.action = action.trim();
      patch.unit = countKindNeedsUnit(countKind) ? unit.trim() : '';
      if (maxCountStr.trim() !== '') {
        const error = countingGoalError(maxCountStr, countKind);
        if (error) { setValidationError(error); return; }
        patch.maxCount = parseCountInput(maxCountStr, countKind) as number;
      }
      if (!task.sharedCounterId) patch.countKind = countKind;
    }
```

(`countingGoalError` from `../createPage/createFormCounting`; the Reads-as preview passes `countKind`.)

- [ ] **Step 4: Run** `WEB_TEST saveTaskEdit compoundStructureEdit` — PASS; `WEB_CHECK`.

- [ ] **Step 5: iOS failing tests** — append to `AppDatabaseTaskEditTests.swift`:

```swift
    // MARK: - Counter kinds (PR 3 Task 9)

    private func countingRoot(_ db: AppDatabase, kind: CountKind = .continuous, maxCount: CountValue = 26.2) throws {
        var t = LinkedWindowKit.task("r", maxCount: maxCount, title: "Run 26.2 miles")
        t.countKind = kind
        try db.saveTask(t)
    }

    private func countingPatch(goal: String, kind: CountKind?, title: String = "Run 30 miles") -> EditTaskSheet.Patch {
        EditTaskSheet.Patch(
            title: title, description: "", action: "Run", unit: "miles", maxCountStr: goal,
            trigger: .greenlog, requiredCountStr: "", refMode: .board, selectedBoardId: "", selectedTemplateId: "",
            countKind: kind
        )
    }

    func testEditSwitchesThenAppliesTypedGoal() throws {
        let db = try makeDb(); try countingRoot(db)
        _ = try db.applyTaskEditPatch(taskId: "r", patch: countingPatch(goal: "30", kind: .discrete))
        let saved = try XCTUnwrap(db.fetchTask(id: "r"))
        XCTAssertEqual(saved.countKind, .discrete)
        XCTAssertEqual(saved.maxCount, 30)
    }

    func testFractionalGoalAfterTheSwitchRollsTheSwitchBack() throws {
        let db = try makeDb(); try countingRoot(db)
        XCTAssertThrowsError(try db.applyTaskEditPatch(taskId: "r", patch: countingPatch(goal: "26.2", kind: .discrete)))
        let saved = try XCTUnwrap(db.fetchTask(id: "r"))
        XCTAssertEqual(saved.countKind, .continuous)
        XCTAssertEqual(saved.maxCount, 26.2)
        XCTAssertEqual(saved.version, 1)
    }

    func testContinuousGoalEditKeepsDecimals() throws {
        let db = try makeDb(); try countingRoot(db)
        _ = try db.applyTaskEditPatch(taskId: "r", patch: countingPatch(goal: "13,1", kind: nil, title: "Run 13.1 miles"))
        XCTAssertEqual(try db.fetchTask(id: "r")?.maxCount, 13.1)
    }
```

(`LinkedWindowKit.task` — `LinkedCounterWindowHealTests.swift:20` — builds a COUNTING row with action "Run", unit "miles"; `makeDb()` seeds user `u1`, matching its `userId`. `countKind` is the Patch's LAST stored property so the memberwise init order above holds.)

- [ ] **Step 6: Run — expect FAIL.** `IOS_TEST -only-testing:OYBCTests/AppDatabaseTaskEditTests`

- [ ] **Step 7: Implement iOS.** `Patch` gains `var countKind: CountKind? = nil` after `compound`. `applyTaskEditPatch` (`:103-107`):

```swift
        try write { db in
            guard var task = try Task.fetchOne(db, key: taskId), !task.isDeleted else {
                throw TaskEditError.taskNotFound
            }
            if task.type == .counting,
               try Self.applyKindSwitchThenGoalGuard(db: db, taskId: taskId, to: patch.countKind, maxCount: nil, now: Date()) {
                guard let refreshed = try Task.fetchOne(db, key: taskId) else { throw TaskEditError.taskNotFound }
                task = refreshed
            }
            try Self.applyBasicFields(of: patch, to: &task)
```

`applyBasicFields` (`:231-240`) becomes `throws` and its counting branch:

```swift
        if task.type == .counting {
            let kind = resolveCountKind(task.countKind)
            if !patch.action.isEmpty { task.action = patch.action }
            if countKindNeedsUnit(kind) { if !patch.unit.isEmpty { task.unit = patch.unit } } else { task.unit = "" }
            let goal = patch.maxCountStr.trimmingCharacters(in: .whitespaces)
            if !goal.isEmpty {
                guard let max = parseCountInput(goal, kind: kind) else {
                    switch kind {
                    case .discrete: throw TaskEditError.invalid(message: "Goal must be a positive integer")
                    case .continuous: throw TaskEditError.invalid(message: "Goal must be a number above zero with up to 2 decimals")
                    case .duration: throw TaskEditError.invalid(message: "Goal must be a duration above zero")
                    }
                }
                task.maxCount = max
            }
        }
```

(every other caller of `applyBasicFields` gains `try`). `EditTaskSheet`: `@State private var countKind: CountKind` and `@State private var pendingSwitch: KindSwitchPreview?` seeded in `init` from `resolveCountKind(task.countKind)`; the Counting fields (`:219-240`) become Action → `fieldLabel("Kind")` + (`task.sharedCounterId != nil ? AnyView(KindTagView(kind: resolveCountKind(task.countKind))) : AnyView(KindPickerView(selection: $countKind, lock: kindPickerLock(mode: .edit, kind: resolveCountKind(task.countKind)), onRequest: requestKind))`) → `GoalEntryView(kind: countKind, text: $maxCountStr, placeholder: "5")` → Unit only when `countKindNeedsUnit(countKind)`; attach `.kindSwitchConfirm(pending: $pendingSwitch) { p in maxCountStr = KindSwitchCopy.switchedGoalText(maxCountStr, from: p.from, to: p.to); countKind = p.to }`;

```swift
    private func requestKind(_ next: CountKind) {
        guard KindSwitchCopy.needsConfirm(from: countKind, to: next) else { countKind = next; return }
        pendingSwitch = (try? database.previewCounterKindSwitch(rootTaskId: task.id, to: next))
            ?? KindSwitchPreview.planned(task: task, to: next, linkedCount: 0)
    }
```

The submit (`:479`) passes `countKind: task.sharedCounterId == nil ? countKind : nil`.

- [ ] **Step 8: Run + snapshots.** `IOS_TEST -only-testing:OYBCTests/AppDatabaseTaskEditTests -only-testing:OYBCTests/EditTaskSheetCompoundGateTests` PASS. Re-record `RisoEditTaskSheetSnapshotTests/testCounting{Light,Dark}`; add + record `testCountingDurationLockedLight` (a Duration task: all three segments locked, glyph on Duration, no Unit field — handoff A4) and `testCountingContinuousLight` (Duration locked out), using the file's existing counting fixture with `countKind` set; read them.

- [ ] **Step 9: e2e + Playwright.** Append to `counter-kinds-authoring.spec.ts`:

```ts
  test('Task Detail: Continuous → Discrete confirms, rounds and saves', async ({ page }) => {
    await page.goto('/tasks?__oybc_test_bypass=1');
    await seedTask(page, { id: 'e0000000-0000-0000-0000-000000000001', title: 'Run 26.2 miles', type: 'counting', action: 'Run', unit: 'miles', maxCount: 26.2, currentCount: 12.75, countKind: 'continuous' });
    await page.goto('/tasks/e0000000-0000-0000-0000-000000000001?__oybc_test_bypass=1');
    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    await page.getByRole('group', { name: 'Kind' }).getByRole('button', { name: 'Discrete' }).click();
    const confirm = page.getByRole('alertdialog', { name: 'Switch to Discrete?' });
    await expect(confirm.getByText('Run 26 miles')).toBeVisible();
    await expect(confirm.getByText('13 logged')).toBeVisible();
    await confirm.getByRole('button', { name: 'Switch' }).click();
    await expect(page.getByLabel('Goal', { exact: true })).toHaveValue('26');
    await page.getByRole('button', { name: 'Save changes', exact: true }).click();
    const stored = await readTask(page, 'e0000000-0000-0000-0000-000000000001');
    expect(stored).toMatchObject({ countKind: 'discrete', maxCount: 26 });
  });
```

(import `seedTask`, `readTask` from `./_fixtures/bypass` — both exist (`bypass.ts:425,602`); `Edit` is the Task Detail button `task-detail-compound-edit.spec.ts:95` already clicks, `Save changes` the sheet's submit (`TaskEditSheet.tsx:480`).) Run `WEB_E2E e2e/counter-kinds-authoring.spec.ts`. Screenshot the confirm light/dark → `.playwright-mcp/task9-a4-confirm-{light,dark}.png`.

- [ ] **Step 10: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): A4 Task Detail edit — kind picker, Continuous→Discrete confirm, switch + patch in one transaction (PR 3 Task 9)"
```

---

### Task 10: A3 — Board Edit square sheet (staged; applied in the Save transaction)

**Files:**
- Modify: `apps/web/src/components/boardEdit/boardEditTaskSheetModel.ts:88-115` (`SheetInput.countKind`), `:124-127` (`parseGoal(goalStr, kind)`), `:138-160` (`sheetValidationProblem`), `:169-210` (`buildSheetOverride` carries `countKind`)
- Modify: `apps/web/src/components/boardEdit/BoardEditTaskSheet.tsx:119-125` (kind state + `useKindSwitchRequest`), `:188` (`input.countKind`), `:255-330` (Kind row, `GoalEntry`, unit gating); delete the #548 row 23 caption at `:242`
- Modify: `apps/web/src/db/operations/compoundStructureEdit.ts:410-475` (`applyBoardEditTaskOverrideInTransaction` runs the Task 8 guard for a root, strips `countKind` from the plain field write, writes it on a Simple → Counting conversion)
- Modify: `apps/ios/OYBC/Views/BoardsTab/SquareEditTaskSheet.swift:78-90` (`Patch.countKind: CountKind? = nil`, LAST), `:99,:153` (state), `:268-280` (validation), `:430-445` (fields), `:550-560` (result); delete #548 row 24 (`everywhereHint`, `:504-514`, and its call site) and row 25 (the `achievementSection` sentence `:497` — the section has nothing else, so delete `achievementSection` and its call site; the Title field stays editable)
- Modify: `apps/ios/OYBC/Views/BoardsTab/SquaresDraft.swift:70-80` (`StagedTaskOverride.countKind: CountKind?`)
- Modify: `apps/ios/OYBC/Views/BoardsTab/ViewModels/BoardPlayViewModel+EditCommit.swift:116-125` (`handleEditTaskOverride` copies `patch.countKind`), `:439-470` (`applyStagedOverrides` runs the guard for a root target), `applyingOverride(_:to:)` (sets `countKind`; a pending task gets `planCountKindSwitch` rounding)
- Test: `apps/web/src/components/boardEdit/__tests__/boardEditTaskSheetModel.countKind.test.ts` (create), `apps/web/src/db/operations/__tests__/boardEditCommit.countKind.test.ts` (create), `apps/ios/OYBCTests/BoardEditKindSwitchTests.swift` (create)
- Re-record (intentional — Kind row + rows 24/25 removed from every sheet type): `SquareEditTaskSheetSnapshotTests/testNormalLight`, `testNormalDark`, `testCountingLight`, `testCountingDark`, `testCompoundLight`, `testNormalThreeSegmentPickerLight`, `testConvertedCompoundEditorLight`, `testExistingCompoundFixedTypeEditorLight`, `testLinkedCounterFixedTypeLight` (now shows the kind tag), `testAchievementLight` — all ten. Add `testCountingContinuousLight` (Duration locked out — handoff A3).

**Interfaces:**
- Consumes: Tasks 3, 4, 8 (`applyKindSwitchThenGoalGuard`, `useKindSwitchRequest` / `.kindSwitchConfirm`, `KindSwitchPreview.planned`).
- Produces: web `SheetInput.countKind: CountKind`; `parseGoal(goalStr: string, kind: CountKind = 'discrete'): number | null`; override = `TaskEditSubmit` with `countKind`; iOS `SquareEditTaskSheet.Patch.countKind`, `StagedTaskOverride.countKind`.
- Rules: Simple → Counting starts the picker in `create` mode; an existing counting task uses `edit`; a linked row shows `KindTag`. At Save the switch runs only for a target that IS the staged task and a live root; a remapped placed copy is never switched.

- [ ] **Step 1: Failing web tests.** `boardEditTaskSheetModel.countKind.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { buildSheetOverride, parseGoal, sheetValidationProblem, type SheetInput } from '../boardEditTaskSheetModel';

const original = { id: 't', type: TaskType.COUNTING, title: 'Run 26.2 mi', action: 'Run', unit: 'mi', maxCount: 26.2, countKind: 'continuous' } as Task;
const input = (o: Partial<SheetInput>): SheetInput => ({
  original, selected: TaskType.COUNTING, title: '', action: 'Run', goalStr: '26.2', unit: 'mi', countKind: 'continuous',
  compoundDraft: null, compoundBaseline: null, ...o,
});

describe('Board Edit sheet — counter kinds', () => {
  it('parses the goal at the sheet kind', () => {
    expect(parseGoal('26.2', 'continuous')).toBe(26.2);
    expect(parseGoal('26.2', 'discrete')).toBeNull();
    expect(parseGoal('1h 30m', 'duration')).toBe(90);
  });
  it('a staged switch rides on the override with the goal parsed at the new kind', () => {
    expect(buildSheetOverride(input({ countKind: 'discrete', goalStr: '26' }))).toMatchObject({ countKind: 'discrete', maxCount: 26, title: 'Run 26 mi' });
  });
  it('duration validates without a unit; discrete refuses a decimal', () => {
    expect(sheetValidationProblem(input({ countKind: 'duration', goalStr: '1h', unit: '' }))).toBeNull();
    expect(sheetValidationProblem(input({ countKind: 'discrete', goalStr: '26.2' }))).toBe('Set a goal above zero.');
  });
});
```

(`SheetInput` today = `original, selected, title, action, goalStr, unit, compoundDraft, compoundBaseline?` — `boardEditTaskSheetModel.ts:88-109`; this task adds `countKind`.) `boardEditCommit.countKind.test.ts` — copy the board/placement seeding of `apps/web/src/db/operations/__tests__/boardEditLinkedOverride.test.ts` into a local `seedBoardWithCounter({ maxCount, countKind })` returning `{ boardId, rootId, cells }`:

```ts
const commit = (boardId: string, cells: SquareDraftCell[], taskId: string, override: BoardEditTaskOverride) =>
  commitSquareEdits({ boardId, cells, removedBoardTaskIds: [], taskOverrides: new Map([[taskId, override]]), isLegacyChosenOnDisk: false, centerCellKeepLocked: false });

it('kind switch then goal edit, atomic (Review Focus 4)', async () => {
  const { boardId, rootId, cells } = await seedBoardWithCounter({ maxCount: 26.2, countKind: 'continuous' });
  await commit(boardId, cells, rootId, { countKind: 'discrete', maxCount: 30, action: 'Run', unit: 'mi', title: 'Run 30 mi' });
  expect(await db.tasks.get(rootId)).toMatchObject({ countKind: 'discrete', maxCount: 30, title: 'Run 30 mi' });
});
it('a fractional goal at the new whole kind rolls the whole Save back', async () => {
  const { boardId, rootId, cells } = await seedBoardWithCounter({ maxCount: 26.2, countKind: 'continuous' });
  await expect(commit(boardId, cells, rootId, { countKind: 'discrete', maxCount: 26.5, title: 'x' })).rejects.toBeInstanceOf(KindGoalError);
  expect(await db.tasks.get(rootId)).toMatchObject({ countKind: 'continuous', maxCount: 26.2, version: 1 });
});
it('a Simple square converted to Counting saves the chosen kind', async () => {
  const { boardId, rootId, cells } = await seedBoardWithCounter({ type: TaskType.NORMAL });
  await commit(boardId, cells, rootId, { type: TaskType.COUNTING, countKind: 'duration', action: 'Practice', unit: '', maxCount: 90, title: 'Practice 1h 30m' });
  expect(await db.tasks.get(rootId)).toMatchObject({ type: TaskType.COUNTING, countKind: 'duration', maxCount: 90 });
});
```

(`seedBoardWithCounter` accepts `{ type?, maxCount?, countKind? }` and seeds one active board with that task placed at (0,0).)

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST boardEditTaskSheetModel.countKind boardEditCommit.countKind`

- [ ] **Step 3: Implement web.** Model: `SheetInput.countKind: CountKind`; `parseGoal(goalStr, kind = 'discrete')` → `parseCountInput(goalStr, kind)`; `sheetValidationProblem` counting branch requires the unit only when `countKindNeedsUnit(input.countKind)` and uses `parseGoal(input.goalStr, input.countKind)`; `buildSheetOverride` counting branch (`:178-195`):

```ts
      const goal = parseGoal(input.goalStr, input.countKind) ?? countTargetStep(input.countKind);
      const unit = countKindNeedsUnit(input.countKind) ? input.unit.trim() : '';
      patch.title = title || generateCounterTaskTitle(action, goal, unit, undefined, input.countKind);
      patch.action = action;
      patch.unit = unit;
      patch.maxCount = goal;
      patch.countKind = input.countKind;
```

`BoardEditTaskSheet.tsx`: `const storedKind = resolveCountKind(task); const [countKind, setCountKind] = useState<CountKind>(storedKind);`, `goalStr` seeded with `formatCountForInput(task.maxCount, storedKind)`, `const { requestKind, dialog } = useKindSwitchRequest({ subject: task, kind: countKind, goalText: goalStr, setKind: setCountKind, onSwitched: (k, g) => { setCountKind(k); setGoalStr(g); } });`; the Kind row (between Action and Goal): `task.sharedCounterId != null` → `<KindTag kind={storedKind} />`, else `<KindPicker value={countKind} lock={kindPickerLock(original.type === TaskType.COUNTING ? 'edit' : 'create', storedKind)} onChange={requestKind} />`; Goal `<GoalEntry kind={countKind} value={goalStr} onChange={setGoalStr} aria-label="Goal" dense />`; Unit gated on `countKindNeedsUnit(countKind)`; `{dialog}` at the end of the sheet; `countKind` added to `input` (`:188`). Delete the row-23 caption node at `:242`. `applyBoardEditTaskOverrideInTransaction` — before the `if (compound)` block:

```ts
  const { countKind: stagedKind, ...plainFields } = fields;
  if (!typeChanged && !compound && existing.type === TaskType.COUNTING) {
    await applyKindSwitchThenGoalGuard(taskId, stagedKind, plainFields.maxCount, now);
  }
```

the conversion branch writes `...(fields as Partial<Task>)` (which keeps `countKind` for a new Counting row; omit it when `stagedKind === 'discrete'`), and the final line becomes `await updateTaskAndCascade(taskId, plainFields);` (the switch owns `countKind`; `updateTask` never writes it raw).

- [ ] **Step 4: Run** `WEB_TEST boardEdit` (every Board Edit test) — PASS; `WEB_CHECK`.

- [ ] **Step 5: iOS failing test** `apps/ios/OYBCTests/BoardEditKindSwitchTests.swift`:

```swift
import XCTest
import GRDB
@testable import OYBC

/// Board Edit kind switch through the REAL path: `handleEditTaskOverride` →
/// `handleEditSave` → outcome. Fixtures copied from `BoardEditCompoundTests`.
@MainActor
final class BoardEditKindSwitchTests: XCTestCase {

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(id: "u1", email: "t@example.com", displayName: "T", photoURL: nil,
                             preferences: User.encodePreferences(.defaults), createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1))
        let dict: [String: Any] = [
            "id": "b1", "userId": "u1", "name": "Board b1", "status": BoardStatus.active.rawValue, "boardSize": 3,
            "timeframe": Timeframe.monthly.rawValue, "startDate": "2026-06-21T00:00:00.000", "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue, "isRandomized": false, "totalTasks": 9, "completedTasks": 0,
            "linesCompleted": 0, "createdAt": "2026-06-21T00:00:00.000", "updatedAt": "2026-06-21T00:00:00.000", "version": 1, "isDeleted": false,
        ]
        try db.saveBoard(try JSONDecoder().decode(Board.self, from: JSONSerialization.data(withJSONObject: dict)))
        return db
    }

    private func counting(_ id: String, kind: CountKind, maxCount: CountValue, sharedCounterId: String? = nil) -> Task {
        var t = LinkedWindowKit.task(id, maxCount: maxCount, sharedCounterId: sharedCounterId, baseline: sharedCounterId == nil ? nil : 0, title: "Run \(id)")
        t.countKind = kind
        return t
    }

    private func place(_ db: AppDatabase, _ taskId: String, col: Int) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveBoardTask(BoardTask(id: "bt-\(taskId)", boardId: "b1", taskId: taskId, row: 0, col: col, isCenter: false,
                                       createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1))
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }

    private func loadedVM(_ db: AppDatabase) -> BoardPlayViewModel {
        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)
        vm.reload()
        _ = waitUntil { vm.board?.id == "b1" && !vm.allTasks.isEmpty }
        vm.seedEditDraft(from: vm.board!)
        return vm
    }

    private func save(_ vm: BoardPlayViewModel) -> BoardPlayEditEvent.Outcome? {
        XCTAssertTrue(vm.handleEditSave(), "save should dispatch")
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome != nil }, "no outcome emitted")
        return vm.editEvent?.outcome
    }

    private func patch(goal: CountValue?, kind: CountKind?, title: String = "Run 30 miles") -> SquareEditTaskSheet.Patch {
        .init(title: title, type: .counting, action: "Run", unit: "miles", maxCount: goal, compound: nil, countKind: kind)
    }

    /// Review Focus 4 — a staged Continuous → Discrete switch plus a goal edit commit together.
    func testSwitchThenGoalEditAtomic() throws {
        let db = try makeDb()
        try db.saveTask(counting("root", kind: .continuous, maxCount: 26.2))
        try place(db, "root", col: 0)
        let vm = loadedVM(db)
        vm.handleEditTaskOverride(taskId: "root", patch: patch(goal: 30, kind: .discrete))
        XCTAssertEqual(save(vm), .saved)
        let row = try XCTUnwrap(db.fetchTask(id: "root"))
        XCTAssertEqual(row.countKind, .discrete)
        XCTAssertEqual(row.maxCount, 30)
        XCTAssertEqual(row.title, "Run 30 miles")
    }

    func testFractionalGoalAtTheNewWholeKindRollsTheSaveBack() throws {
        let db = try makeDb()
        try db.saveTask(counting("root", kind: .continuous, maxCount: 26.2))
        try place(db, "root", col: 0)
        let vm = loadedVM(db)
        vm.handleEditTaskOverride(taskId: "root", patch: patch(goal: 26.5, kind: .discrete, title: "x"))
        guard case .saveFailed = try XCTUnwrap(save(vm)) else { return XCTFail("expected saveFailed") }
        let row = try XCTUnwrap(db.fetchTask(id: "root"))
        XCTAssertEqual(row.countKind, .continuous)
        XCTAssertEqual(row.maxCount, 26.2)
        XCTAssertEqual(row.version, 1)
    }

    func testAPlacedLinkedCopyIsNeverSwitched() throws {
        let db = try makeDb()
        try db.saveTask(counting("root", kind: .continuous, maxCount: 26.2))
        try db.saveTask(counting("copy", kind: .continuous, maxCount: 6.2, sharedCounterId: "root"))
        try place(db, "copy", col: 0)
        let vm = loadedVM(db)
        vm.handleEditTaskOverride(taskId: "copy", patch: patch(goal: nil, kind: .discrete, title: "Run copy"))
        XCTAssertEqual(save(vm), .saved)
        XCTAssertEqual(try db.fetchTask(id: "copy")?.countKind, .continuous)
        XCTAssertEqual(try db.fetchTask(id: "root")?.countKind, .continuous)
    }
}
```

(`LinkedWindowKit.task(_:maxCount:sharedCounterId:startDate:endDate:createdInWizard:baseline:currentCount:isCompleted:title:)` — `LinkedCounterWindowHealTests.swift:20`; the fixtures otherwise match `BoardEditCompoundTests.swift:14-110`.)

- [ ] **Step 6: Run — expect build FAIL** (`extra argument 'countKind'`). `IOS_TEST -only-testing:OYBCTests/BoardEditKindSwitchTests`

- [ ] **Step 7: Implement iOS.** `SquareEditTaskSheet.Patch` gains `var countKind: CountKind? = nil` (after `compound`); `StagedTaskOverride` gains `var countKind: CountKind? = nil`; `handleEditTaskOverride` passes `countKind: patch.countKind`. `applyingOverride(_:to:)` (`BoardPlayViewModel+EditCommit.swift:558`) gains `writesKind: Bool = false` and, in its `.counting` case after `maxCount`:

```swift
            if writesKind, let kind = override.countKind {
                // A PENDING task (no events yet) or a Simple → Counting
                // conversion takes the chosen kind directly; a stored counting
                // row's kind changes only through the guard in applyStagedOverrides.
                if let m = updated.maxCount, let rounded = planCountKindSwitch(
                    maxCount: m, defaultLogAmount: nil, from: resolveCountKind(task.countKind), to: kind
                )?.maxCount { updated.maxCount = rounded }
                updated.countKind = kind == .discrete ? nil : kind
            }
            if override.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.title = TaskTitle.generateCounterTaskTitle(
                    action: updated.action ?? "", maxCount: updated.maxCount, unit: updated.unit ?? "",
                    countKind: resolveCountKind(updated.countKind)
                )
            }
```

(the existing title block moves below and gains `countKind:`). Call sites: the pending merge (`:179-181`) passes `writesKind: true`; `applyStagedOverrides` passes `writesKind: input.override.type != base.type`. In `applyStagedOverrides` (`:455`, after the linked-type check):

```swift
                if target == input.stagedId, base.type == .counting, input.override.type == .counting, base.sharedCounterId == nil,
                   try AppDatabase.applyKindSwitchThenGoalGuard(db: db, taskId: target, to: input.override.countKind,
                                                                maxCount: input.override.maxCount, now: Date()) {
                    guard let refreshed = try Task.fetchOne(db, key: target) else { continue }
                    base = refreshed
                }
```

(make `base` a `var`; a `goalNotWhole` throw propagates out of the save transaction — `handleEditSave` already maps a thrown error to `.saveFailed`). `SquareEditTaskSheet`: `@State private var countKind: CountKind`, `@State private var pendingSwitch: KindSwitchPreview?`; Kind row between Action and Goal — linked (`countingSource.sharedCounterId != nil`) → `KindTagView(kind: resolveCountKind(countingSource.countKind))`, else `KindPickerView(selection: $countKind, lock: kindPickerLock(mode: original.type == .counting ? .edit : .create, kind: resolveCountKind(countingSource.countKind)), onRequest: requestKind)` with `requestKind` exactly as Task 9's; `GoalEntryView(kind: countKind, text: $maxCountStr, placeholder: "5")` at `:438`; Unit only when `countKindNeedsUnit(countKind)`; `.kindSwitchConfirm(pending: $pendingSwitch) { p in maxCountStr = KindSwitchCopy.switchedGoalText(maxCountStr, from: p.from, to: p.to); countKind = p.to }`; validation `:277` = `parseCountInput(maxCountStr, kind: countKind) != nil` and the unit check gated; result `:556` = `maxCount: parseCountInput(maxCountStr, kind: countKind), countKind: type == .counting ? countKind : nil`. Delete `everywhereHint` + its call site and `achievementSection` + its call site.

- [ ] **Step 8: Run + snapshots.** `IOS_TEST -only-testing:OYBCTests/BoardEditKindSwitchTests -only-testing:OYBCTests/BoardEditCompoundTests` PASS. `IOS_SNAP -only-testing:OYBCSnapshotTests/SquareEditTaskSheetSnapshotTests`: re-record the ten listed, add + record `testCountingContinuousLight`; read each (rows 24/25 gone; Kind row on counting; tag on the linked one).

- [ ] **Step 9: e2e + Playwright.** Append to `apps/web/e2e/squares-editor.spec.ts` (it already seeds a board and opens the squares editor — reuse its `beforeEach` helpers): a seeded Continuous `Run 26.2 miles` square (`countKind: 'continuous'`) → Edit → tap the square → `Edit task` → Kind `Discrete` → `Switch` in the confirm → the sheet's Goal reads `26` → Done → Save → `readTask` shows `{ countKind: 'discrete', maxCount: 26 }`. Run `WEB_E2E e2e/squares-editor.spec.ts`. Screenshot the sheet light/dark → `.playwright-mcp/task10-a3-{light,dark}.png`.

- [ ] **Step 10: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): A3 Board Edit sheet stages a kind switch applied in the Save transaction; drop the sheet's two captions (#548 23-25) (PR 3 Task 10)"
```

---

### Task 11: A6 — Counters hub New counter (kind, Start from)

**Files:**
- Modify: `apps/web/src/db/operations/tasks.counter.ts:50-90` (`createCounterTask` input + `countKind`)
- Modify: `apps/web/src/components/counters/CreateCounterSheet.tsx:64` (kind state), `:95,:120-124` (parse), `:150-215` (Kind row first; Start from → `GoalEntry`; R7 `:200`, `:215` → `formatCountTotal`); delete #548 rows 69 (`:164`), 71 (`:176-178`), 73 (`:194`), 75 (`:203-205`, the `previewSub` span — the preview card keeps name · total · "All-time")
- Modify: `apps/ios/OYBC/Database/AppDatabase+Counters.swift:38-80` (`createCounterTask(…, countKind: CountKind = .discrete, now:)`)
- Modify: `apps/ios/OYBC/Views/ProfileTab/NewCounterSheetView.swift:47` (kind state), `:68-70,:135-145` (parse + pass), `:170-290` (Kind row first; Start from → `GoalEntryView`; R7 `:245`, `:283` → `formatCountTotal`); delete #548 rows 70 (`:188-190`), 72 (`:195-197`), 74 (`:204-206`), 76 (`:250`)
- Test: `apps/web/src/db/operations/__tests__/createCounterTask.countKind.test.ts` (create), `apps/web/src/components/counters/__tests__/CreateCounterSheet.test.ts` (create), `apps/ios/OYBCTests/AppDatabaseCounterCreateKindTests.swift` (create)
- Re-record (intentional): `CountersHubSnapshotTests/testNewCounterSheetDefault{Light,Dark}`, `testNewCounterSheetEstablishedMatch{Light,Dark}`; add `testNewCounterSheetContinuous{Light,Dark}`

**Interfaces:**
- Consumes: `KindPicker` / `KindPickerView`, `GoalEntry` / `GoalEntryView`, `parseCountInput(…, { allowZero: true })`, `formatCountTotal`, `isWholeCountKind`.
- Produces: web `createCounterTask(userId, { action, unit, startingCount?, countKind?: CountKind })`; iOS `createCounterTask(userId:action:unit:startingCount:countKind:now:)`. Ruling U4: the hub keeps its noun field for every kind (it names the counter); a Duration amount never shows the noun (`countUnitSuffix`).

- [ ] **Step 1: Failing tests.** `createCounterTask.countKind.test.ts` (Dexie; teardown as in `countKindSwitch.test.ts`):

```ts
import { afterEach, describe, expect, it } from 'vitest';
import { db } from '../../internal';
import { createCounterTask } from '../tasks.counter';

afterEach(async () => { await Promise.all([db.tasks.clear(), db.taskEvents.clear(), db.syncQueue.clear()]); });

describe('createCounterTask — counter kinds', () => {
  it('creates a continuous counter seeded with a fractional starting count', async () => {
    const t = await createCounterTask('u1', { action: 'Run', unit: 'miles', startingCount: 148.6, countKind: 'continuous' });
    expect(t.countKind).toBe('continuous');
    expect((await db.tasks.get(t.id))?.currentCount).toBe(148.6);
    expect((await db.taskEvents.where('taskId').equals(t.id).first())?.delta).toBe(148.6);
  });
  it('a discrete (default) counter refuses a fractional seed', async () => {
    await expect(createCounterTask('u1', { action: 'Do', unit: 'push-ups', startingCount: 2.5 })).rejects.toThrow();
  });
  it('a duration counter keeps its noun and seeds minutes', async () => {
    const t = await createCounterTask('u1', { action: 'Practice', unit: 'guitar', startingCount: 90, countKind: 'duration' });
    expect(t).toMatchObject({ countKind: 'duration', unit: 'guitar', currentCount: 90 });
  });
});
```

`CreateCounterSheet.test.ts` (`renderToStaticMarkup` inside a `MemoryRouter` — the sheet calls `useNavigate`; its props are `open, onClose, tasks, userId, onCreated`, `CreateCounterSheet.tsx:30-36`):

```ts
import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { MemoryRouter } from 'react-router-dom';
import { CreateCounterSheet } from '../CreateCounterSheet';

const renderSheet = (): string =>
  renderToStaticMarkup(
    React.createElement(MemoryRouter, null,
      React.createElement(CreateCounterSheet, { open: true, onClose: () => {}, tasks: [], userId: 'u1', onCreated: () => {} })),
  );

it('Kind is the first field and no helper sentence renders (#548 69-76)', () => {
  const html = renderSheet();
  expect(html.indexOf('aria-label="Kind"')).toBeLessThan(html.indexOf('What are you counting?'));
  for (const s of ['A plural noun', 'Used in task titles', 'Already partway', 'link up automatically']) expect(html).not.toContain(s);
});
```

iOS `AppDatabaseCounterCreateKindTests.swift`:

```swift
import XCTest
@testable import OYBC

final class AppDatabaseCounterCreateKindTests: XCTestCase {
    func testContinuousCounterSeedsAFraction() throws {
        let db = try AppDatabase.makeTestInstance(); try LinkedWindowKit.seedUser(db)
        let t = try db.createCounterTask(userId: "u1", action: "Run", unit: "miles", startingCount: 148.6, countKind: .continuous, now: "2026-10-07T00:00:00.000Z")
        XCTAssertEqual(t.countKind, .continuous)
        XCTAssertEqual(try db.fetchTask(id: t.id)?.currentCount, 148.6)
    }
    func testDiscreteRefusesAFractionalSeed() throws {
        let db = try AppDatabase.makeTestInstance(); try LinkedWindowKit.seedUser(db)
        XCTAssertThrowsError(try db.createCounterTask(userId: "u1", action: "Do", unit: "push-ups", startingCount: 2.5, now: "2026-10-07T00:00:00.000Z"))
    }
}
```

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST createCounterTask.countKind CreateCounterSheet` / `IOS_TEST -only-testing:OYBCTests/AppDatabaseCounterCreateKindTests`

- [ ] **Step 3: Implement web.** `createCounterTask`:

```ts
export async function createCounterTask(
  userId: string,
  input: { action: string; unit: string; startingCount?: number; countKind?: CountKind },
): Promise<Task> {
  const action = input.action.trim();
  const unit = input.unit.trim();
  const startingCount = input.startingCount ?? 0;
  const countKind = input.countKind ?? 'discrete';
  if (!action || !unit) throw new Error('createCounterTask: action and unit are required');
  if (!isQuantizedCount(startingCount) || startingCount < 0 || (isWholeCountKind(countKind) && !Number.isInteger(startingCount))) {
    throw new Error('createCounterTask: startingCount must be a non-negative count at the counter kind');
  }
  const kindField = countKind !== 'discrete' ? { countKind } : {};
  const validated = CreateTaskInputSchema.parse({
    title: generateCounterTaskTitle(action, null, unit), type: TaskType.COUNTING, action, unit, isCounter: true, ...kindField,
  });
  // … the existing `task` literal, plus `...kindField,` …
```

`CreateCounterSheet.tsx`: `const [countKind, setCountKind] = useState<CountKind>('discrete');`; first in the form, before the noun label:

```tsx
        <span className={styles.fieldLabel}>Kind</span>
        <KindPicker value={countKind} lock="none" onChange={setCountKind} />
```

Start from (`:182-193`) → `<GoalEntry kind={countKind} value={startingCountStr} onChange={setStartingCountStr} aria-label="Start from" placeholder="0" dense />`; `startFromNum` (`:95`) and the create parse (`:120`) = `parseCountInput(startingCountStr, countKind, { allowZero: true })`; the create call passes `startingCount: startFromNum ?? undefined, countKind`; `:200` → `formatCountTotal(previewCount, countKind)`; `:215` → `formatCountTotal(match.lifetime, resolveCountKind(match.task))`. Delete the three `helperText` divs and the `previewSub` span (keep the `previewFooter` row with "All-time").

- [ ] **Step 4: Implement iOS.** `createCounterTask` gains `countKind: CountKind = .discrete` (before `now:`); its guard becomes `guard count >= 0, isQuantizedCount(count), !isWholeCountKind(countKind) || count.rounded() == count else { throw AppDatabaseError.invalidCounterInput("createCounterTask: startingCount must be a non-negative count at the counter kind") }`; after building `task`, `task.countKind = countKind == .discrete ? nil : countKind` (make it `var`). `NewCounterSheetView`: `@State private var countKind: CountKind = .discrete` passed into the content leaf as `@Binding var countKind: CountKind`; first `fieldBlock(label: "Kind") { KindPickerView(selection: $countKind, lock: .none) }`; Start from → `GoalEntryView(kind: countKind, text: $startingCountText, placeholder: "0")`; parse at `:69` and `:135` = `parseCountInput(startingCountText, kind: countKind, allowZero: true)`; `handleCreate` captures `countKind` and passes `countKind: capturedKind`; `:245` `Text(formatCountTotal(previewCount, kind: countKind))`; `:283` `formatCountTotal(match.lifetime, kind: resolveCountKind(match.task.countKind))` (`CounterCreateMatch.task` — `LinkableCounter.swift:140`). Delete the four caption `Text`s.

- [ ] **Step 5: Run** both test commands — PASS; `WEB_CHECK`. Re-record / record the `CountersHubSnapshotTests` baselines listed under Files; read vs handoff A6 (Kind first, decimal pad, 148.6 preview, no helper lines).

- [ ] **Step 6: Playwright validation.** `/profile/counters?__oybc_test_bypass=1` → `+ New counter` → Kind Continuous → noun `miles`, verb `Run`, Start from `148,6` → `Create counter` → the hub card reads `148.6`; screenshot the sheet light/dark → `.playwright-mcp/task11-a6-{light,dark}.png`.

- [ ] **Step 7: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): A6 hub New counter picks a kind + fractional / h:m Start from; grouped totals (R7); drop four helper captions (#548 69-76) (PR 3 Task 11)"
```

---

### Task 12: A5 — pool row editor (staged edits carry the kind)

**Files:**
- Modify: `apps/web/src/db/taskEditPatch.ts:110-124` (`TaskEditPatch.countKind?: CountKind`), `:135-166` (`patchFromTask` / `seedPatchForEditor` seed it + kind-aware auto-title check), `:314-323` (`validatePatch` counting branch), `:362-372` (`applyPatchToTask` counting branch), `readsAsPreview` (unchanged — it echoes the typed text)
- Modify: `apps/web/src/components/wizard/PoolRowEditor.tsx:15-160` — props `taskId` + `taskType` → one `task: Task` prop (the row's stored task; the kind tag / lock need its kind and link), `usedOnBoardCount` removed (it only fed row 52); Kind row between Title and the Action/Goal/Unit trio; `GoalEntry`; Unit hidden for Duration; `useKindSwitchRequest`; delete #548 row 52 (`stagedUntil` / `everywhereLine` `:84-89` and its render node) and row 53 (the `headerHint` span `:96`)
- Modify: call sites `apps/web/src/components/wizard/BoardWizardTasksStep.tsx:732-742` (994 lines — this edit is net −2: `task={task}` replaces two props and `usedOnBoardCount` goes; delete `taskBoardCounts` there if it has no other reader) and `apps/web/src/components/pools/PoolEditorBody.tsx:360-370`; iOS `RisoPoolRowEditorView(taskId:taskType:…)` → `RisoPoolRowEditorView(task:…)` at `BoardWizardTasksStepView.swift:491` and `PoolEditorBodyView.swift:112`
- Modify: `apps/web/src/db/operations/wizardBoard.ts:317-390` (`applyStagedTaskEditsForWizardPersist` non-compound branch runs the Task 8 guard first)
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/TaskEditPatch.swift:134-142` (`validate` counting branch), `:174-187` (`applied(to:)` counting branch), seed (`:98`, already added in Task 7)
- Modify: `apps/ios/OYBC/Views/CreateTab/Components/RisoPoolRowEditorView.swift:95-150` (Kind row, `GoalEntryView`, Unit gating, `countingDerivedTitle` kind-aware, `.kindSwitchConfirm`)
- Modify: `apps/ios/OYBC/Database/AppDatabase+StagedTaskEdits.swift:40-80` (guard first in the non-compound branch)
- Test: `apps/web/src/db/operations/__tests__/stagedEdits.countKind.test.ts` (create), `apps/web/src/db/__tests__/taskEditPatch.countKind.test.ts` (+3 cases), `apps/ios/OYBCTests/StagedTaskEditsKindTests.swift` (create)
- Re-record (intentional — Kind row; rows 52/53 are web-only): `PoolRowEditorSnapshotTests/testCountingEditor{Light,Dark}`, `testCountingValidationBlockedLight`

**Interfaces:**
- Consumes: Tasks 3, 4, 7 (`TaskEditPatch.countKind` on iOS), 8 (`applyKindSwitchThenGoalGuard`, `useKindSwitchRequest`, `.kindSwitchConfirm`).
- Produces: web `TaskEditPatch.countKind?: CountKind` (absent = the task's own kind). Rules: pool rows edit EXISTING tasks (picker mode `edit`); a pending task's staged kind is applied directly by `applyPatchToTask` / `applied(to:)` (no events exist); a stored ROOT's goes through the guard inside the pool-save / wizard-persist transaction; a linked row never takes a kind from a patch.

- [ ] **Step 1: Failing web tests.** Append to `taskEditPatch.countKind.test.ts`:

```ts
describe('TaskEditPatch countKind (pool rows)', () => {
  const run = { id: 'r', type: TaskType.COUNTING, title: 'Run 26.2 miles', action: 'Run', unit: 'miles', maxCount: 26.2, countKind: 'continuous' } as Task;
  it('seeds the kind and the goal text at it; an auto title seeds blank', () => {
    expect(seedPatchForEditor(run)).toMatchObject({ countKind: 'continuous', goal: '26.2', title: '' });
  });
  it('validates the goal at the patch kind; duration needs no unit', () => {
    expect(validatePatch({ ...seedPatchForEditor(run), goal: '3.125' }, TaskType.COUNTING)).toBe('Set a goal above zero.');
    expect(validatePatch({ ...seedPatchForEditor(run), countKind: 'duration', goal: '1h', unit: '' }, TaskType.COUNTING)).toBeNull();
  });
  it('applyPatchToTask writes the kind on a pending root, never on a linked row', () => {
    expect(applyPatchToTask({ ...seedPatchForEditor(run), countKind: 'discrete', goal: '26' }, run)).toMatchObject({ countKind: 'discrete', maxCount: 26, title: 'Run 26 miles' });
    const linked = { ...run, sharedCounterId: 'root' };
    expect(applyPatchToTask({ ...seedPatchForEditor(linked), countKind: 'discrete', goal: '6' }, linked).countKind).toBe('continuous');
  });
});
```

`stagedEdits.countKind.test.ts` (Dexie; seed + teardown as in `saveTaskEdit.countKind.test.ts`, Task 9):

```ts
const TABLES = () => [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue];
const NOW_ISO = '2026-10-07T12:00:00.000Z';

it('a staged Discrete → Continuous switch and a decimal goal land together', async () => {
  await seed({ countKind: undefined, maxCount: 26, title: 'Run 26 miles' });
  await db.transaction('rw', TABLES(), () => applyStagedTaskEditsForWizardPersist(
    new Map([['r', { title: '', action: 'Run', goal: '26.2', unit: 'miles', children: [], countKind: 'continuous' }]]), new Set(), NOW_ISO, { strict: true }));
  expect(await db.tasks.get('r')).toMatchObject({ countKind: 'continuous', maxCount: 26.2, title: 'Run 26.2 miles' });
});
it('strict mode rejects a goal invalid at the staged kind and writes nothing', async () => {
  await seed({ countKind: undefined, maxCount: 26, title: 'Run 26 miles' });
  await expect(db.transaction('rw', TABLES(), () => applyStagedTaskEditsForWizardPersist(
    new Map([['r', { title: '', action: 'Run', goal: '26.2', unit: 'miles', children: [], countKind: 'discrete' }]]), new Set(), NOW_ISO, { strict: true })))
    .rejects.toThrow();
  expect((await db.tasks.get('r'))?.version).toBe(1);
});
```

(`seed(over)` is the same local helper as Task 9's test — copy it.)

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST taskEditPatch.countKind stagedEdits.countKind`

- [ ] **Step 3: Implement web.** `TaskEditPatch` gains `countKind?: CountKind;`; `patchFromTask` sets `countKind: resolveCountKind(task)` and `goal: task.maxCount !== undefined ? formatCountForInput(task.maxCount, resolveCountKind(task)) : ''`; `seedPatchForEditor`'s auto-title check passes `resolveCountKind(task)` as `generateCounterTaskTitle`'s 5th argument. `validatePatch` counting branch:

```ts
    case TaskType.COUNTING: {
      const kind = patch.countKind ?? 'discrete';
      if (parsePositiveGoal(patch.goal, kind) === undefined) return 'Set a goal above zero.';
      if (countKindNeedsUnit(kind) && patch.unit.trim().length === 0) return 'Add a unit, like km or pages.';
      return null;
    }
```

`applyPatchToTask` counting branch:

```ts
    case TaskType.COUNTING: {
      const kind = base.sharedCounterId == null ? (patch.countKind ?? resolveCountKind(base)) : resolveCountKind(base);
      const a = patch.action.trim();
      const u = countKindNeedsUnit(kind) ? patch.unit.trim() : '';
      const g = parsePositiveGoal(patch.goal, kind) ?? (base.maxCount ?? 0);
      const title = trimmedTitle.length === 0 ? generateCounterTaskTitle(a, g, u, undefined, kind) : trimmedTitle;
      const next: Task = { ...base, action: a, unit: u, maxCount: g, title };
      if (kind === 'discrete') delete next.countKind; else next.countKind = kind;
      return next;
    }
```

`applyStagedTaskEditsForWizardPersist` non-compound branch, before `applyPatchToTask`:

```ts
    if (task.type === TaskType.COUNTING) {
      const kind = patch.countKind ?? resolveCountKind(task);
      await applyKindSwitchThenGoalGuard(taskId, patch.countKind, parseCountInput(patch.goal, kind), now);
      task = (await db.tasks.get(taskId)) ?? task; // the switch bumped the version / rounded fields
    }
```

(make `task` a `let`). `PoolRowEditor.tsx`: `const taskId = task.id; const taskType = task.type; const stored = resolveCountKind(task); const kind = draft.countKind ?? stored;` and

```ts
  const { requestKind, dialog } = useKindSwitchRequest({
    subject: { ...task, title: draft.title || task.title },
    kind,
    goalText: draft.goal,
    setKind: (k) => onDraftChange({ ...draft, countKind: k }),
    onSwitched: (k, g) => onDraftChange({ ...draft, countKind: k, goal: g }),
  });
```

Render between the Title row and the counting trio:

```tsx
          {taskType === TaskType.COUNTING && (
            <div className={styles.kindRow}>
              <RisoSectionLabel variant="kicker">Kind</RisoSectionLabel>
              {task.sharedCounterId ? <KindTag kind={stored} /> : <KindPicker value={kind} lock={kindPickerLock('edit', stored)} onChange={requestKind} size="compact" />}
            </div>
          )}
```

the Goal input → `<GoalEntry kind={kind} value={draft.goal} onChange={(g) => onDraftChange({ ...draft, goal: g })} aria-label="Goal" dense placeholder="5" />`, the Unit field wrapped in `countKindNeedsUnit(kind)`, `{dialog}` at the end. Delete row 52 (`stagedUntil`, `everywhereLine` and its render node) and row 53 (`headerHint`).

- [ ] **Step 4: Run** `WEB_TEST taskEditPatch stagedEdits poolSave wizardPersist` — PASS; `WEB_CHECK`; `WEB_E2E e2e/pool-row-editor.spec.ts e2e/pool-editor.spec.ts` (delete any assertion on the two removed captions).

- [ ] **Step 5: iOS failing tests** `StagedTaskEditsKindTests.swift`:

```swift
import XCTest
import GRDB
@testable import OYBC

final class StagedTaskEditsKindTests: XCTestCase {
    private func seeded(kind: CountKind?, maxCount: CountValue) throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance(); try LinkedWindowKit.seedUser(db)
        var t = LinkedWindowKit.task("r", maxCount: maxCount, title: "Run 26 miles"); t.countKind = kind
        try db.saveTask(t)
        return db
    }

    private func patch(goal: String, kind: CountKind) -> TaskEditPatch {
        var p = TaskEditPatch(title: "")
        p.action = "Run"; p.unit = "miles"; p.goal = goal; p.countKind = kind
        return p
    }

    func testStagedSwitchAndDecimalGoalLandTogether() throws {
        let db = try seeded(kind: nil, maxCount: 26)
        try db.write { try AppDatabase.applyStagedTaskEdits(db: $0, stagedEdits: ["r": patch(goal: "26.2", kind: .continuous)], strict: true, now: "2026-10-07T12:00:00.000Z") }
        let row = try XCTUnwrap(db.fetchTask(id: "r"))
        XCTAssertEqual(row.countKind, .continuous)
        XCTAssertEqual(row.maxCount, 26.2)
        XCTAssertEqual(row.title, "Run 26.2 miles")
    }

    func testStrictRejectsAGoalInvalidAtTheStagedKind() throws {
        let db = try seeded(kind: .continuous, maxCount: 26.2)
        XCTAssertThrowsError(try db.write { try AppDatabase.applyStagedTaskEdits(db: $0, stagedEdits: ["r": patch(goal: "26.2", kind: .discrete)], strict: true, now: "2026-10-07T12:00:00.000Z") })
        XCTAssertEqual(try db.fetchTask(id: "r")?.countKind, .continuous)
    }

    func testAppliedNeverGivesALinkedRowAKind() {
        var linked = LinkedWindowKit.task("c", maxCount: 6.2, sharedCounterId: "root", baseline: 0); linked.countKind = .continuous
        XCTAssertEqual(patch(goal: "6", kind: .discrete).applied(to: linked).countKind, .continuous)
    }
}
```

- [ ] **Step 6: Run — expect FAIL.** `IOS_TEST -only-testing:OYBCTests/StagedTaskEditsKindTests`

- [ ] **Step 7: Implement iOS.** `TaskEditPatch.validate` counting branch: `guard parseCountInput(goal, kind: countKind) != nil else { return "Set a goal above zero." }` and the unit check gated on `countKindNeedsUnit(countKind)`. `applied(to:)` counting branch:

```swift
        case .counting:
            let kind = base.sharedCounterId == nil ? countKind : resolveCountKind(base.countKind)
            let a = action.trimmingCharacters(in: .whitespaces)
            let u = countKindNeedsUnit(kind) ? unit.trimmingCharacters(in: .whitespaces) : ""
            let g = parseCountInput(goal, kind: kind) ?? base.maxCount ?? 0
            t.action = a
            t.unit = u
            t.maxCount = g
            t.countKind = kind == .discrete ? nil : kind
            let typed = trimmedTitle
            t.title = typed.isEmpty ? TaskTitle.generateCounterTaskTitle(action: a, maxCount: g, unit: u, countKind: kind) : typed
```

(`TaskEditPatch.countKind` is seeded from the task, so an untouched patch keeps the task's kind.) `applyStagedTaskEdits` non-compound branch, before `task = patch.applied(to: task)`:

```swift
                if task.type == .counting,
                   try Self.applyKindSwitchThenGoalGuard(db: db, taskId: taskId, to: patch.countKind,
                                                         maxCount: parseCountInput(patch.goal, kind: patch.countKind), now: Date()) {
                    task = try Task.fetchOne(db, key: taskId) ?? task
                }
```

`RisoPoolRowEditorView`: `let taskId: String` + `let taskType: TaskType` → `let task: Task` (`taskId` / `taskType` become computed `task.id` / `task.type`); a `Kind` `labeledField` row above the Action/Goal/Unit `HStack` — `task.sharedCounterId != nil` → `KindTagView(kind: resolveCountKind(task.countKind))`, else `KindPickerView(selection: $draft.countKind, lock: kindPickerLock(mode: .edit, kind: resolveCountKind(task.countKind)), onRequest: requestKind)`; Goal → `GoalEntryView(kind: draft.countKind, text: $draft.goal, placeholder: "5")` (width 84); Unit only when `countKindNeedsUnit(draft.countKind)`; `countingDerivedTitle` (`:137-146`) parses with `parseCountInput(g, kind: draft.countKind)` and passes `countKind:`; `@State private var pendingSwitch: KindSwitchPreview?` with `requestKind` exactly as Task 9's (preview by `task.id`, fallback `KindSwitchPreview.planned(task: task, to: next, linkedCount: 0)`) and `.kindSwitchConfirm(pending: $pendingSwitch) { p in draft.goal = KindSwitchCopy.switchedGoalText(draft.goal, from: p.from, to: p.to); draft.countKind = p.to }`.

- [ ] **Step 8: Run iOS** `IOS_TEST -only-testing:OYBCTests/StagedTaskEditsKindTests -only-testing:OYBCTests/AppDatabasePoolsTests` PASS; re-record the three `PoolRowEditorSnapshotTests` baselines; read vs handoff A5.

- [ ] **Step 9: Playwright validation.** Wizard Tasks step → a counting row → edit → screenshot the row editor with the Kind row light/dark → `.playwright-mcp/task12-a5-{light,dark}.png`.

- [ ] **Step 10: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): A5 pool row editor kind picker; staged switches apply inside the pool save / wizard persist transaction; drop staged-edit captions (#548 52/53) (PR 3 Task 12)"
```

---

### PR 3 gate (before opening the PR)

- [ ] `pnpm --filter @oybc/shared test:coverage` (80% gate), `pnpm -w test`, `WEB_CHECK`, `node scripts/check-file-sizes.mjs`, `node scripts/check-knip.mjs`, `node scripts/check-sync-contract-rules.mjs` — all green; paste outputs untruncated.
- [ ] `IOS_TEST -only-testing:OYBCTests` green; full `IOS_SNAP` red SET = the standing reds only.
- [ ] `WEB_E2E e2e/counter-kinds-authoring.spec.ts e2e/squares-editor.spec.ts e2e/member-rules.spec.ts e2e/pool-row-editor.spec.ts e2e/pool-editor.spec.ts e2e/task-detail-compound-edit.spec.ts` green locally.
- [ ] Self-review the diff for any NEW explanatory sentence — `git diff origin/dev -- apps | grep '^+' | grep -E '"[A-Z][a-z]+ [a-z]+ [a-z]+ .*\."'` — and read every hit. Every #548 row closed in PR 3 (47/48, 52/53, 61–63, 65, 67/68, 69–76, 77/78, 23–25) is ticked in the PR body.
- [ ] Docs: `docs/COUNTER_KINDS.md` Status ("PR 3 #NNN shipped"); one paragraph in `docs/TASK_SYSTEM.md` (kinds are chosen on every Goal surface; switching rules).
- [ ] Push `git push origin HEAD:feature/counter-kinds-authoring`, `git fetch`, verify `git rev-parse HEAD` == `git rev-parse origin/feature/counter-kinds-authoring`. The PR body lists every re-recorded baseline and ends with the attribution line.

# PR 4 — Logging + Display UI

Branch: cut `feature/counter-kinds-logging` from `dev` after PR 3 merges (the main loop creates the external worktree `/Volumes/Stephen/oybc-worktrees/counter-kinds-logging`, seeds `.env.local` + `GoogleService-Info.plist`, runs `pnpm install && pnpm build`). Push with `git push origin HEAD:feature/counter-kinds-logging`.

**File-size budget (Ruling U8).** Three allow-listed files are touched by several PR 4 tasks. No task lowers a cap mid-PR (a later task could not then add its lines); each task only keeps the file ≤ its CURRENT cap, and Task 21 shrinks every cap to the final measured count. Budgets, measured from `dev`:

| File | Cap | Task 14 | Task 15 | Task 19 | Net |
| --- | --- | --- | --- | --- | --- |
| `apps/web/src/components/BoardPlaySurface.tsx` | 1241 | −70 (quick-amount state + builder → `useCountingLogModal.ts`; row-9 stat hint −16; tap branch −20; `removeTitle`/hint props −6) | +12 (`amountActions`) | +2 (`countKind` into the cell model) | ≈ −56 |
| `apps/ios/OYBC/Views/BoardsTab/BoardPlayView.swift` | 1996 | −55 (`sharedStepperHint` + rows 2/4 captions) | +8 (Custom amount… item, `CountingMenuLabels` calls) | +2 (`countKind:` at two cell call sites) | ≈ −45 |
| `apps/ios/OYBC/Views/BoardsTab/ViewModels/BoardPlayViewModel.swift` | 1518 | +3 (standalone default persist) | 0 | 0 | +3 — Task 13's toast change must free ≥ 3 lines (fold `sharedCreditToastText`'s two branches into one `let verb = …` line) |


### Task 13: Shared log-amount helpers, family kind on counter groups, kind-aware toasts

**Files:**
- Create: `packages/shared/src/algorithms/logAmounts.ts`, `packages/shared/tests/fixtures/logAmountVectors.json`, `packages/shared/tests/algorithms/logAmounts.test.ts`
- Modify: `packages/shared/src/algorithms/sharedCounterGroups.ts:81-102,360-370` (`SharedCounterGroup.countKind`), `packages/shared/tests/fixtures/sharedCounterGroupsVectors.json` (+`countKind` on two expected groups, one continuous source)
- Modify: `packages/shared/src/algorithms/index.ts` — explicit block for every `logAmounts.ts` export (Ruling U2): `fixedLogChipAmounts, goalChipAmounts, boardSheetChips, hubChips, lateLogChipAmounts, initialLogSelection, quickLogAmount, customChipLabel, logPillLabel, logPillOpensDetail` + `export type { LogChip }`
- Modify: `apps/ios/OYBC/Helpers/CounterLogAmount.swift` (Swift twin of `logAmounts.ts`; `parseCustom` delegates to `parseCountInput`), `apps/ios/OYBC/Helpers/SharedCounterGroups.swift:54-76,350-356`
- Modify: `apps/web/src/components/counters/amountChips.ts` (thin wrappers over `logAmounts.ts`; `parseCustomLogAmount(raw, kind = 'discrete')`), `apps/web/src/components/counters/counterLogToastText.ts` (+`kind`), `apps/web/src/components/counters/CounterLogToast.tsx:81` (passes `kind`)
- Modify: `apps/ios/OYBC/Views/Components/CounterLogToastView.swift:25-66` (+`kind: CountKind = .discrete`; `static func text(amount:unit:verb:kind:) -> String`; `bodyText = message ?? Self.text(…)`), `apps/ios/OYBC/Views/BoardsTab/ViewModels/BoardPlayViewModel.swift:1066-1078` (`sharedCreditToastText(counterName:amount:otherBoards:isIncrement:kind:)`; its body folds to `let sign = isIncrement ? "+" : "−", phrase = isIncrement ? "also counted on" : "also removed from"; return "\(sign)\(formatCount(amount, kind: kind)) \(counterName) — \(phrase) \(boardNames)."` — net −3 lines, the headroom Task 14 spends; callers pass `resolveCountKind(sourceTask?.countKind)`)
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
    { "name": "discrete keeps initialChipAmount's 25 even without a 25 chip", "kind": "discrete", "goal": 200, "default": 25, "expected": { "amount": 25, "isCustom": false } },
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

- [ ] **Step 2: Failing tests.** `packages/shared/tests/algorithms/logAmounts.test.ts`:

```ts
import * as fs from 'fs';
import * as path from 'path';
import {
  boardSheetChips, goalChipAmounts, hubChips, initialLogSelection, lateLogChipAmounts,
  logPillLabel, logPillOpensDetail, quickLogAmount,
} from '../../src/algorithms/logAmounts';
import * as barrel from '../../src/algorithms';
import type { CountKind } from '../../src/algorithms/countValue';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const V: any = JSON.parse(fs.readFileSync(path.join(__dirname, '../fixtures/logAmountVectors.json'), 'utf8'));

describe('logAmounts vectors', () => {
  it.each(V.goalChips)('goalChips: $name', (v: any) => expect(goalChipAmounts(v.goal, v.kind as CountKind)).toEqual(v.expected));
  it.each(V.boardSheetChipLabels)('boardSheetChips: $name', (v: any) =>
    expect(boardSheetChips(v.kind, v.goal).map((c) => c.label)).toEqual(v.expected));
  it.each(V.hubChipLabels)('hubChips: $name', (v: any) => expect(hubChips(v.kind).map((c) => c.label)).toEqual(v.expected));
  it.each(V.lateLogChips)('lateLogChips: $name', (v: any) => expect(lateLogChipAmounts(v.kind, v.goal)).toEqual(v.expected));
  it.each(V.initialSelection)('initialSelection: $name', (v: any) =>
    expect(initialLogSelection(v.kind, boardSheetChips(v.kind, v.goal), v.default)).toEqual(v.expected));
  it.each(V.quickAmount)('quickAmount: $name', (v: any) =>
    expect(quickLogAmount(v.kind, boardSheetChips(v.kind, v.goal), v.default)).toBe(v.expected));
  it.each(V.pill)('pill: $name', (v: any) => {
    expect(logPillLabel(v.kind, v.default)).toBe(v.label);
    expect(logPillOpensDetail(v.kind, v.default)).toBe(v.opensDetail);
  });
  it('every helper is in the barrel (Ruling U2)', () => {
    for (const n of ['boardSheetChips', 'goalChipAmounts', 'hubChips', 'initialLogSelection', 'lateLogChipAmounts', 'logPillLabel', 'logPillOpensDetail', 'quickLogAmount', 'customChipLabel', 'fixedLogChipAmounts']) {
      expect(typeof (barrel as Record<string, unknown>)[n]).toBe('function');
    }
  });
});
```

Append to `apps/web/src/components/counters/__tests__/counterLogToastText.test.ts`:

```ts
import { readFileSync } from 'fs';
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const LOG: any = JSON.parse(readFileSync(new URL('../../../../../../packages/shared/tests/fixtures/logAmountVectors.json', import.meta.url), 'utf8'));

describe('formatCounterLogToastText — counter kinds (shared vectors)', () => {
  it.each(LOG.toast)('$name', (v: any) => {
    expect(formatCounterLogToastText({ amount: v.amount, unit: v.unit, verb: v.verb, kind: v.kind, counterName: v.counterName, boardNames: v.boardNames })).toBe(v.expected);
  });
});
```

and to `amountChips.test.ts`:

```ts
describe('amountChips wrappers — counter kinds', () => {
  it('hub chips per kind; board chips per kind; discrete defaults unchanged', () => {
    expect(buildAmountChipOptions().map((c) => c.label)).toEqual(['1', '10', '25', '#']);
    expect(buildAmountChipOptions('duration').map((c) => c.label)).toEqual(['15m', '30m', '1h', '#']);
    expect(buildBoardQuickAmountOptions().map((c) => c.label)).toEqual(['+1', '+10', '#']);
    expect(buildBoardQuickAmountOptions('continuous', 26.2).map((c) => c.label)).toEqual(['6.6', '13.1', '26.2', '#']);
  });
  it('parseCustomLogAmount parses at the kind', () => {
    expect(parseCustomLogAmount('3,1', 'continuous')).toBe(3.1);
    expect(parseCustomLogAmount('3.1')).toBeNull();
    expect(parseCustomLogAmount('1h 30m', 'duration')).toBe(90);
  });
});
```

Run `SHARED_TEST logAmounts` and `WEB_TEST counterLogToastText amountChips` — FAIL.

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
  // Discrete keeps `initialChipAmount` verbatim: a 1 / 10 / 25 default, else 1.
  if (kind === 'discrete') return { amount: defaultLogAmount != null && FIXED.discrete.includes(defaultLogAmount) ? defaultLogAmount : 1, isCustom: false };
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

(`CounterLogToastTextInput.kind?: CountKind`; `CounterLogToast` gets a `kind?: CountKind` prop and passes it.) Swift: `CounterLogAmount` gains `static func fixedChipAmounts(_:)`, `goalChipAmounts(goal:kind:)`, `boardSheetChips(kind:goal:) -> [LogChip]`, `hubChips(kind:)`, `lateLogChipAmounts(kind:goal:)`, `initialSelection(kind:chips:defaultLogAmount:) -> (amount: CountValue, isCustom: Bool)`, `quickAmount(kind:chips:defaultLogAmount:)`, `customChipLabel(_:kind:)`, `pillLabel(kind:defaultLogAmount:)`, `pillOpensDetail(kind:defaultLogAmount:)`, `struct LogChip: Equatable { let value: CountValue?; let label: String }`; `parseCustom(_ raw: String, kind: CountKind = .discrete)` = `parseCountInput(raw, kind: kind)`. `SharedCounterGroup` gains `var countKind: CountKind = .discrete` declared LAST (so existing memberwise calls — `CountersHubSnapshotTests.swift:32,46` — compile unchanged). `CounterLogToastView` gains `var kind: CountKind = .discrete` and

```swift
    static func text(amount: CountValue, unit: String, verb: Verb, kind: CountKind) -> String {
        let a = formatCountWithUnit(amount, kind: kind, unit: unit)
        return verb == .logged ? "Logged +\(a)" : "Removed \(a)"
    }
    private var bodyText: String { message ?? Self.text(amount: amount, unit: unit, verb: verb, kind: kind) }
```

(`verbLabel` is deleted — the unit now rides inside `formatCountWithUnit`; `Verb` gains `Equatable` if it lacks it.) `sharedCreditToastText` passes `kind: resolveCountKind(sourceTask?.countKind)` to `formatCount`.

- [ ] **Step 4: Run** `SHARED_TEST logAmounts sharedCounterGroups`, `WEB_TEST amountChips counterLogToastText` — PASS. Then `pnpm --filter @oybc/shared run gen:sync-fixtures` and `cd apps/ios && xcodegen generate` (the new `logAmountVectors.json` must enter the iOS test bundle). Append to `apps/ios/OYBCTests/CounterLogAmountTests.swift`:

```swift
    private struct ChipsV: Decodable { let name: String; let goal: Double?; let kind: CountKind; let expected: [Double] }
    private struct LabelsV: Decodable { let name: String; let goal: Double?; let kind: CountKind; let expected: [String] }
    private struct Sel: Decodable, Equatable { let amount: Double; let isCustom: Bool }
    private struct SelV: Decodable { let name: String; let kind: CountKind; let goal: Double; let `default`: Double?; let expected: Sel }
    private struct QuickV: Decodable { let name: String; let kind: CountKind; let goal: Double; let `default`: Double?; let expected: Double }
    private struct PillV: Decodable { let name: String; let kind: CountKind; let `default`: Double?; let label: String; let opensDetail: Bool }
    private struct ToastV: Decodable { let name: String; let amount: Double; let unit: String; let verb: String; let kind: CountKind; let counterName: String?; let boardNames: [String]?; let expected: String }
    private struct LogFixture: Decodable {
        let goalChips: [ChipsV]; let boardSheetChipLabels: [LabelsV]; let hubChipLabels: [LabelsV]; let lateLogChips: [ChipsV]
        let initialSelection: [SelV]; let quickAmount: [QuickV]; let pill: [PillV]; let toast: [ToastV]
    }

    func testLogAmountVectors() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "logAmountVectors", withExtension: "json"))
        let f = try JSONDecoder().decode(LogFixture.self, from: Data(contentsOf: url))
        for v in f.goalChips { XCTAssertEqual(CounterLogAmount.goalChipAmounts(goal: v.goal ?? 0, kind: v.kind), v.expected, v.name) }
        for v in f.boardSheetChipLabels { XCTAssertEqual(CounterLogAmount.boardSheetChips(kind: v.kind, goal: v.goal ?? 0).map(\.label), v.expected, v.name) }
        for v in f.hubChipLabels { XCTAssertEqual(CounterLogAmount.hubChips(kind: v.kind).map(\.label), v.expected, v.name) }
        for v in f.lateLogChips { XCTAssertEqual(CounterLogAmount.lateLogChipAmounts(kind: v.kind, goal: v.goal ?? 0), v.expected, v.name) }
        for v in f.initialSelection {
            let s = CounterLogAmount.initialSelection(kind: v.kind, chips: CounterLogAmount.boardSheetChips(kind: v.kind, goal: v.goal), defaultLogAmount: v.default)
            XCTAssertEqual(Sel(amount: s.amount, isCustom: s.isCustom), v.expected, v.name)
        }
        for v in f.quickAmount {
            XCTAssertEqual(CounterLogAmount.quickAmount(kind: v.kind, chips: CounterLogAmount.boardSheetChips(kind: v.kind, goal: v.goal), defaultLogAmount: v.default), v.expected, v.name)
        }
        for v in f.pill {
            XCTAssertEqual(CounterLogAmount.pillLabel(kind: v.kind, defaultLogAmount: v.default), v.label, v.name)
            XCTAssertEqual(CounterLogAmount.pillOpensDetail(kind: v.kind, defaultLogAmount: v.default), v.opensDetail, v.name)
        }
        for v in f.toast where v.boardNames == nil {
            XCTAssertEqual(CounterLogToastView.text(amount: v.amount, unit: v.unit, verb: v.verb == "logged" ? .logged : .removed, kind: v.kind), v.expected, v.name)
        }
    }
```

(`CounterLogToastView.text(amount:unit:verb:kind:)` is a new `static` the view's `bodyText` calls — the credited variant is composed by `BoardPlayViewModel.sharedCreditToastText`, pinned by the existing VM tests.) Run `IOS_TEST -only-testing:OYBCTests/CounterLogAmountTests -only-testing:OYBCTests/SharedCounterGroupsVectorTests` — PASS. `CountersHubSnapshotTests/testLogToast*` stay green (discrete text unchanged).

- [ ] **Step 5: Commit**

```bash
git add packages/shared apps/web apps/ios
git add apps/ios/OYBC.xcodeproj/project.pbxproj
git commit -m "feat(counters): shared log-amount helpers (chips, initial selection, pill, quick amount), family kind on counter groups, kind-aware toasts (PR 4 Task 13)"
```

---

### Task 14: B1 — every counting tap opens the stepper sheet / DetailModal, per kind (both platforms, one commit — Ruling U3)

**Files (web):**
- Create: `apps/web/src/components/boardPlay/countingLogModel.ts` (pure state + builder), `apps/web/src/components/boardPlay/useCountingLogModal.ts` (hook holding the state)
- Create: `apps/web/src/components/boardPlay/__tests__/countingLogModel.test.ts`, `apps/web/src/components/__tests__/DetailModalKinds.test.ts`
- Modify: `apps/web/src/components/interactiveTaskSquareUtils.ts:47-60` (`TaskSquareData.countKind?: CountKind`; export `type QuickAmountProps`), `:164-167` (`progressBarLabel` via `formatCount` + `countUnitSuffix`)
- Modify: `apps/web/src/db/adapters.ts:158-200` (`taskToSquareData` sets `countKind: resolveFamilyCountKind(task, (id) => taskMap[id])`)
- Modify: `apps/web/src/components/InteractiveTaskSquare.tsx:418-480` (`DetailModalProps.quickAmount?: QuickAmountProps`), `:567-700` (counting body per kind); delete #548 rows 1 (`:776-778` compound footer), 3 (`:787-790` achievement read-only sentence), 5 (`sharedHint` prop + render `:226`, `:699`, and on `ContextMenuProps`), 7 (`title=…` on the context-menu remove item `:205`), 8 (`:392-394` "Tap: +1 {unit}" span) and their now-unused CSS classes (`.compoundFooter`, `.sharedHint`, `.actionHint`)
- Modify: `apps/web/src/components/BoardPlaySurface.tsx:228-252` (state → hook), `:615-631` (delete row 9 stat-bar hint `<div className={play.hint}>`), `:804-827` (every counting tap → `setSelectedSquareId(boardTaskId)`), `:1000-1115` (modal props from the hook), `:1080`, `:1149` (drop `removeTitle`, `menuSharedHint`)
- Modify: `apps/web/src/hooks/useBoardPlayData.ts:72,270-310` (delete `sharedCounterHintsByTaskId`) and `apps/web/src/db/operations/__tests__/sharedCounterWindowRegression.test.ts:150-170` (delete the hint assertions only)
- Modify: `apps/web/src/components/InteractiveTaskSquare.module.css` (+`.modalProgressFillOver { background: var(--riso-gold); }`)
- Modify: `apps/web/e2e/windowed-completion.spec.ts:205-207`; Create: `apps/web/e2e/counter-kinds-logging.spec.ts`

**Files (iOS):**
- Create: `apps/ios/OYBC/Views/BoardsTab/Components/CountingStepperModel.swift` (pure selection model — the twin of `countingLogModel.ts`)
- Modify: `apps/ios/OYBC/Views/BoardsTab/Components/RisoCountingStepperSheet.swift` (whole view: +`countKind`; chips for every Continuous / Duration square; pinned `GoalEntryView`; kind-aware labels; `sharedHint` removed — row 6)
- Modify: `apps/ios/OYBC/Views/BoardsTab/BoardPlayView+CountingStepper.swift:24-58` (pass `countKind`, standalone `defaultLogAmount`; drop `sharedHint`)
- Modify: `apps/ios/OYBC/Views/BoardsTab/BoardPlayView.swift:1076-1130` (delete `sharedStepperHint(for:)` — row 6), `:1779-1782` (delete row 2 `Text`), `:1884-1888` (delete row 4 `Text`)
- Modify: `apps/ios/OYBC/Views/BoardsTab/ViewModels/BoardPlayViewModel.swift:531-543` (standalone `persistAsDefault` → `database.setCounterDefaultLogAmount(sourceTaskId: task.id, amount:)`)
- Test: `apps/ios/OYBCTests/CountingStepperModelTests.swift` (create), `apps/ios/OYBCTests/BoardPlayViewModelTests.swift` (+1 case), `apps/ios/OYBCSnapshotTests/CountingStepperSheetSnapshotTests.swift` (create)

**Interfaces:**
- Consumes: Task 13 (`boardSheetChips`, `initialLogSelection`, `customChipLabel` ↔ `CounterLogAmount.*`), `GoalEntry(View)`, `formatCountWithUnit`, `resolveFamilyCountKind`, `setCounterDefaultLogAmount`.
- Produces (web): `type QuickAmountProps = { kind: CountKind; options: LogChip[]; selected: number | null; isCustomActive: boolean; customOpen: boolean; customDraft: string; amountText: string; unit: string; addLabel: string; busy: boolean; removeDisabled: boolean; onSelectChip(v: number): void; onOpenCustom(): void; onCustomDraftChange(raw: string): void; onConfirmCustom(): void; onAmountTextChange(raw: string): void; onAdd(): void; onRemove(): void }`; `interface CountingLogState { boardTaskId: string; amount: number; isCustom: boolean; customOpen: boolean; customDraft: string; amountText: string }`; `interface CountingLogContext { boardTaskId: string; task: Task; taskMap: Record<string, Task>; sourceId: string | null; currentCount: number; isSealed: boolean; onIncrementShared(sourceId: string, amount: number, persist: boolean): void; onDecrementShared(sourceId: string, amount: number, persist: boolean): void; onSetStandaloneCount(boardTaskId: string, next: number): void; onPersistDefault(taskId: string, amount: number): void }`; `initialCountingLogState(ctx): CountingLogState | null`; `buildQuickAmount(state: CountingLogState, ctx, setState: (next: CountingLogState) => void): QuickAmountProps | undefined`; `useCountingLogModal(selectedSquareId: string | null, ctxFor: (boardTaskId: string) => CountingLogContext | null): QuickAmountProps | undefined`.
- Produces (iOS): `struct CountingStepperModel: Equatable { let kind: CountKind; let chips: [CounterLogAmount.LogChip]; var amountText: String; var selectedAmount: CountValue; var isCustom: Bool; static func initial(kind:goal:defaultLogAmount:isShared:) -> CountingStepperModel; var amount: CountValue?; mutating func selectChip(_:); mutating func setText(_:); func addLabel(unit:) -> String; var showsChips: Bool }`; `RisoCountingStepperSheet(taskTitle:currentCount:maxCount:unitText:countKind:isLinkedCounter:isSharedCounter:defaultLogAmount:onOpenTask:onIncrement:onDecrement:)`.
- Behaviour (both): Discrete standalone = plain −/+ (±1), Discrete shared = today's `+1 · +10 · #` + custom row + OK; Continuous / Duration (any square) = ¼ · ½ · goal · # chips + the always-visible amount field (no OK), − / + apply the field's amount, an edited field is custom (persisted as the default on log), `#` shows the custom amount. Gold: only the web modal's progress bar when `cur > max` (handoff `LogSheet` web frame); the iOS sheet draws no bar.

- [ ] **Step 1: Failing web tests.** `countingLogModel.test.ts`:

```ts
import { describe, expect, it, vi } from 'vitest';
import { TaskType, type Task } from '@oybc/shared';
import { buildQuickAmount, initialCountingLogState, type CountingLogContext } from '../countingLogModel';

const task = (over: Partial<Task>): Task => ({
  id: 't', userId: 'u1', title: 'Run 26.2 mi', type: TaskType.COUNTING, action: 'Run', unit: 'mi', maxCount: 26.2,
  countKind: 'continuous', currentCount: 0, isCompleted: false, totalCompletions: 0, totalInstances: 0,
  createdAt: 't', updatedAt: 't', version: 1, isDeleted: false, ...over,
} as Task);

const ctx = (t: Task, over: Partial<CountingLogContext> = {}): CountingLogContext => ({
  boardTaskId: 'bt', task: t, taskMap: { [t.id]: t }, sourceId: null, currentCount: 12.4, isSealed: false,
  onIncrementShared: vi.fn(), onDecrementShared: vi.fn(), onSetStandaloneCount: vi.fn(), onPersistDefault: vi.fn(), ...over,
});

describe('countingLogModel', () => {
  it('a discrete standalone square keeps the plain stepper', () => {
    const c = ctx(task({ countKind: undefined, maxCount: 10, unit: 'reps' }));
    expect(initialCountingLogState(c)).toBeNull();
  });
  it('a discrete shared square keeps +1 · +10 · #', () => {
    const c = ctx(task({ countKind: undefined, maxCount: 200 }), { sourceId: 't' });
    const q = buildQuickAmount(initialCountingLogState(c)!, c, () => {});
    expect(q?.options.map((o) => o.label)).toEqual(['+1', '+10', '#']);
    expect(q?.addLabel).toBe('+ 1');
  });
  it('a continuous standalone square opens on its remembered custom amount', () => {
    const c = ctx(task({ defaultLogAmount: 3.1 }));
    const q = buildQuickAmount(initialCountingLogState(c)!, c, () => {})!;
    expect(q).toMatchObject({ kind: 'continuous', isCustomActive: true, amountText: '3.1', selected: 3.1, addLabel: '+ 3.1 mi' });
    expect(q.options.map((o) => o.label)).toEqual(['6.6', '13.1', '26.2', '#']);
  });
  it('adding a custom amount sets the window count and persists the default; a chip does not persist', () => {
    const c = ctx(task({ defaultLogAmount: 3.1 }));
    buildQuickAmount(initialCountingLogState(c)!, c, () => {})!.onAdd();
    expect(c.onSetStandaloneCount).toHaveBeenCalledWith('bt', 15.5);
    expect(c.onPersistDefault).toHaveBeenCalledWith('t', 3.1);
    const c2 = ctx(task({}));
    buildQuickAmount(initialCountingLogState(c2)!, c2, () => {})!.onAdd(); // ¼ chip 6.6 pre-selected
    expect(c2.onSetStandaloneCount).toHaveBeenCalledWith('bt', 19);
    expect(c2.onPersistDefault).not.toHaveBeenCalled();
  });
  it('fixing 31-for-3.1: the field opens on 31 and − removes exactly 31', () => {
    const c = ctx(task({ defaultLogAmount: 31 }), { currentCount: 40 });
    buildQuickAmount(initialCountingLogState(c)!, c, () => {})!.onRemove();
    expect(c.onSetStandaloneCount).toHaveBeenCalledWith('bt', 9);
  });
  it('an invalid field disables + and −', () => {
    const c = ctx(task({}));
    const q = buildQuickAmount({ ...initialCountingLogState(c)!, amountText: '3.125', isCustom: true }, c, () => {})!;
    expect(q.selected).toBeNull();
    expect(q.removeDisabled).toBe(true);
  });
  it('a duration square labels without a unit', () => {
    const c = ctx(task({ countKind: 'duration', maxCount: 630, unit: '' }), { currentCount: 270 });
    expect(buildQuickAmount(initialCountingLogState(c)!, c, () => {})!.addLabel).toBe('+ 2h 38m');
  });
});
```

`DetailModalKinds.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { DetailModal } from '../InteractiveTaskSquare';
import type { QuickAmountProps } from '../interactiveTaskSquareUtils';

const noop = () => {};
const base = { onClose: noop, onToggleComplete: noop, onIncrementCount: noop, onDecrementCount: noop };
const quick = (o: Partial<QuickAmountProps>): QuickAmountProps => ({
  kind: 'continuous', options: [{ value: 6.6, label: '6.6' }, { value: 13.1, label: '13.1' }, { value: 26.2, label: '26.2' }, { value: null, label: '#' }],
  selected: 3.1, isCustomActive: true, customOpen: false, customDraft: '', amountText: '3.1', unit: 'mi', addLabel: '+ 3.1 mi',
  busy: false, removeDisabled: false, onSelectChip: noop, onOpenCustom: noop, onCustomDraftChange: noop, onConfirmCustom: noop,
  onAmountTextChange: noop, onAdd: noop, onRemove: noop, ...o,
});
const render = (sq: object, cur: number, q?: QuickAmountProps) =>
  renderToStaticMarkup(React.createElement(DetailModal, { ...base, sq: sq as never, state: { isCompleted: false, currentCount: cur, completedStepIds: new Set() }, quickAmount: q }));

describe('DetailModal — counter kinds', () => {
  it('continuous: chips with #3.1 selected, pinned decimal field, + {amount} {unit}, no OK', () => {
    const html = render({ id: 's', title: 'Run 26.2 mi', type: 'counting', action: 'Run', maxCount: 26.2, unit: 'mi', countKind: 'continuous' }, 12.4, quick({}));
    expect(html).toContain('#3.1');
    expect(html).toContain('inputMode="decimal"');
    expect(html).toContain('+ 3.1 mi');
    expect(html).toContain('12.4/26.2');
    expect(html).not.toContain('>OK<');
  });
  it('duration: h / m fields, no unit in the meta line', () => {
    const html = render({ id: 's', title: 'Practice 10h 30m', type: 'counting', action: 'Practice', maxCount: 630, unit: '', countKind: 'duration' }, 270,
      quick({ kind: 'duration', amountText: '2h 38m', unit: '', addLabel: '+ 2h 38m', selected: 158, isCustomActive: false,
        options: [{ value: 158, label: '2h 38m' }, { value: 315, label: '5h 15m' }, { value: 630, label: '10h 30m' }, { value: null, label: '#' }] }));
    expect(html).toContain('aria-label="Log amount hours"');
    expect(html).toContain('4h 30m/10h 30m');
    expect(html).toContain('Practice · 10h 30m');
  });
  it('overshoot paints the modal bar gold (handoff LogSheet web frame)', () => {
    const html = render({ id: 's', title: 'Run 26.2 mi', type: 'counting', action: 'Run', maxCount: 26.2, unit: 'mi', countKind: 'continuous' }, 28.4, quick({}));
    expect(html).toMatch(/modalProgressFillOver/);
  });
  it('a linked discrete square renders the plain stepper without the removed captions (#548 5/7/8)', () => {
    const html = render({ id: 's', title: 'Push', type: 'counting', action: 'Do', maxCount: 10, unit: 'reps', sharedCounterId: 'r' }, 3);
    expect(html).toContain('3 / 10');
    expect(html).not.toContain('also counts on');
    expect(html).not.toContain('cannot be decremented');
    expect(html).not.toContain('Tap: +1');
  });
});
```

(The last case still renders the plain stepper — `quickAmount` absent — so its absence checks are against the full counting body that used to carry the hint when `sharedHint` was passed; with the prop deleted the type no longer accepts it.)

- [ ] **Step 2: Run — expect FAIL.** `WEB_TEST countingLogModel DetailModalKinds`

- [ ] **Step 3: Implement web.** `countingLogModel.ts`:

```ts
import {
  boardSheetChips, customChipLabel, formatCountForInput, formatCountWithUnit, initialLogSelection, parseCountInput,
  quantizeCount, resolveFamilyCountKind, type Task,
} from '@oybc/shared';
import type { QuickAmountProps } from '../interactiveTaskSquareUtils';

export interface CountingLogState { boardTaskId: string; amount: number; isCustom: boolean; customOpen: boolean; customDraft: string; amountText: string }

export interface CountingLogContext {
  boardTaskId: string; task: Task; taskMap: Record<string, Task>; sourceId: string | null; currentCount: number; isSealed: boolean;
  onIncrementShared(sourceId: string, amount: number, persist: boolean): void;
  onDecrementShared(sourceId: string, amount: number, persist: boolean): void;
  onSetStandaloneCount(boardTaskId: string, next: number): void;
  onPersistDefault(taskId: string, amount: number): void;
}

const kindOf = (ctx: CountingLogContext) => resolveFamilyCountKind(ctx.task, (id) => ctx.taskMap[id]);

/** The state a square's modal opens with, or null for the plain discrete stepper. */
export function initialCountingLogState(ctx: CountingLogContext): CountingLogState | null {
  const kind = kindOf(ctx);
  if (kind === 'discrete' && !ctx.sourceId) return null;
  const options = boardSheetChips(kind, ctx.task.maxCount ?? 0);
  const remembered = (ctx.sourceId ? ctx.taskMap[ctx.sourceId] : ctx.task)?.defaultLogAmount;
  const sel = initialLogSelection(kind, options, remembered);
  return { boardTaskId: ctx.boardTaskId, amount: sel.amount, isCustom: sel.isCustom, customOpen: false, customDraft: '', amountText: formatCountForInput(sel.amount, kind) };
}

/** The DetailModal quick-amount props for the current state (both rows of §5). */
export function buildQuickAmount(state: CountingLogState, ctx: CountingLogContext, setState: (next: CountingLogState) => void): QuickAmountProps | undefined {
  const kind = kindOf(ctx);
  if (kind === 'discrete' && !ctx.sourceId) return undefined;
  const options = boardSheetChips(kind, ctx.task.maxCount ?? 0);
  const unit = ctx.task.unit ?? '';
  const entry = kind !== 'discrete';
  const selected = entry ? parseCountInput(state.amountText, kind) : state.amount;
  const isLinked = ctx.task.sharedCounterId != null;
  const log = (direction: 1 | -1): void => {
    if (ctx.isSealed || selected === null) return;
    const persist = state.isCustom;
    if (ctx.sourceId) {
      if (direction === 1) ctx.onIncrementShared(ctx.sourceId, selected, persist);
      else ctx.onDecrementShared(ctx.sourceId, selected, persist);
      return;
    }
    ctx.onSetStandaloneCount(ctx.boardTaskId, Math.max(0, quantizeCount(ctx.currentCount + direction * selected)));
    if (persist) ctx.onPersistDefault(ctx.task.id, selected);
  };
  return {
    kind, options, selected, unit,
    isCustomActive: state.isCustom,
    customOpen: state.customOpen,
    customDraft: state.customDraft,
    amountText: state.amountText,
    busy: ctx.isSealed,
    removeDisabled: isLinked || ctx.currentCount <= 0 || selected === null,
    addLabel: entry ? `+ ${formatCountWithUnit(selected ?? 0, kind, unit)}` : `+ ${selected}`,
    onSelectChip: (v) => setState({ ...state, amount: v, isCustom: false, customOpen: false, amountText: formatCountForInput(v, kind) }),
    onOpenCustom: () => setState(entry ? { ...state, isCustom: true } : { ...state, customOpen: true, customDraft: state.isCustom ? String(state.amount) : '' }),
    onCustomDraftChange: (raw) => setState({ ...state, customDraft: raw }),
    onConfirmCustom: () => {
      const parsed = parseCountInput(state.customDraft, kind);
      if (parsed !== null) setState({ ...state, amount: parsed, isCustom: true, customOpen: false, customDraft: '' });
    },
    onAmountTextChange: (raw) => {
      const parsed = parseCountInput(raw, kind);
      setState({ ...state, amountText: raw, isCustom: parsed === null || !options.some((o) => o.value === parsed) });
    },
    onAdd: () => log(1),
    onRemove: () => { if (!isLinked) log(-1); },
  };
}

export { customChipLabel };
```

`useCountingLogModal.ts`:

```ts
import { useEffect, useState } from 'react';
import type { QuickAmountProps } from '../interactiveTaskSquareUtils';
import { buildQuickAmount, initialCountingLogState, type CountingLogContext, type CountingLogState } from './countingLogModel';

/**
 * The open DetailModal's quick-amount props. Seeded when a DIFFERENT square
 * opens (never on a live-query update of the same square — that would clobber
 * an in-progress amount edit; moved verbatim from BoardPlaySurface).
 */
export function useCountingLogModal(
  selectedSquareId: string | null,
  ctxFor: (boardTaskId: string) => CountingLogContext | null,
): QuickAmountProps | undefined {
  const [state, setState] = useState<CountingLogState | null>(null);
  useEffect(() => {
    const ctx = selectedSquareId ? ctxFor(selectedSquareId) : null;
    setState(ctx ? initialCountingLogState(ctx) : null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedSquareId]);
  const ctx = selectedSquareId ? ctxFor(selectedSquareId) : null;
  if (!ctx || !state || state.boardTaskId !== selectedSquareId) return undefined;
  return buildQuickAmount(state, ctx, setState);
}
```

`BoardPlaySurface.tsx`: delete `modalQuickAmount` state + its seeding effect (`:228-252`) and the in-IIFE builder (`:1010-1080`); at the top level add

```ts
  const quickAmount = useCountingLogModal(selectedSquareId, (btId) => {
    const bt = boardTasks.find((b) => b.id === btId);
    const task = bt ? taskMap[bt.taskId] : undefined;
    if (!bt || !task || task.type !== TaskType.COUNTING) return null;
    return {
      boardTaskId: btId, task, taskMap, isSealed,
      sourceId: resolveSharedCounterSourceId(task, sharedCounterSourceIds),
      currentCount: cellStateByBoardTaskId[btId]?.currentCount ?? 0,
      onIncrementShared: (s, a, p) => void handleSharedCounterIncrement(s, a, p),
      onDecrementShared: (s, a, p) => void handleSharedCounterDecrement(s, a, p),
      onSetStandaloneCount: (b, next) => void handleComplete(b, { currentCount: next }),
      onPersistDefault: (id, a) => void setCounterDefaultLogAmount(id, a),
    };
  });
```

(the `currentCount` source is the same windowed value the modal shows today — `modalCurrentCount`; reuse whichever expression `:1000-1008` computes it with) and pass `quickAmount={quickAmount}` to `DetailModal`. The counting tap branch (`:804-827`) becomes `} else if (squareData.type === 'counting') { setSelectedSquareId(boardTaskId); }` (the Discrete +1 tap is gone — §5). Delete the stat-bar hint `<div className={play.hint}>…</div>` (`:618-631`, row 9) and its `.hint` CSS. `DetailModal` counting body: meta line `{sq.action} · {formatCountWithUnit(sq.maxCount ?? 0, kind, sq.unit)}` with `const kind = sq.countKind ?? 'discrete'`; progress fill gets `${cur > max ? styles.modalProgressFillOver : ''}`; then

```tsx
            {quickAmount && quickAmount.kind !== 'discrete' ? (
              <div className={styles.quickAmountRow}>
                <div className={styles.quickChipRow} role="group" aria-label="Log amount presets">
                  {quickAmount.options.map((chip, i) => {
                    const isCustom = chip.value === null;
                    const on = isCustom ? quickAmount.isCustomActive : !quickAmount.isCustomActive && chip.value === quickAmount.selected;
                    return (
                      <button key={isCustom ? 'custom' : `${i}-${chip.value}`} type="button"
                        className={`${styles.quickChip} ${on ? styles.quickChipSelected : ''}`} aria-pressed={on}
                        onClick={() => (isCustom ? quickAmount.onOpenCustom() : quickAmount.onSelectChip(chip.value as number))}>
                        {isCustom && on && quickAmount.selected !== null ? customChipLabel(quickAmount.selected, quickAmount.kind) : chip.label}
                      </button>
                    );
                  })}
                </div>
                <GoalEntry kind={quickAmount.kind} value={quickAmount.amountText} onChange={quickAmount.onAmountTextChange}
                  aria-label="Log amount" suffix={quickAmount.unit || undefined} placeholder="Amount" dense />
                <div className={styles.quickAmountActions}>
                  <button type="button" className={styles.counterButton} onClick={quickAmount.onRemove}
                    disabled={quickAmount.busy || quickAmount.removeDisabled} aria-label={`Remove ${quickAmount.addLabel.slice(2)}`}>−</button>
                  <span className={styles.counterValue}>{formatCount(state.currentCount, quickAmount.kind)}/{formatCount(sq.maxCount ?? 0, quickAmount.kind)}</span>
                  <button type="button" className={styles.quickAddBtn} onClick={quickAmount.onAdd}
                    disabled={quickAmount.busy || quickAmount.selected === null}>{quickAmount.addLabel}</button>
                </div>
              </div>
            ) : quickAmount ? (
              /* the existing discrete shared block (`:594-675`) — unchanged except it reads `quickAmount.options`/`selected` from the new props and drops `title={quickAmount.removeTitle}` */
            ) : (
              /* the existing plain stepper (`:676-695`) — unchanged */
            )}
```

(the two "unchanged" branches are the current JSX moved verbatim; `quickAmount.selected` is non-null for discrete.) `progressBarLabel` = `${formatCount(state.currentCount, kind)}/${formatCount(sq.maxCount ?? 0, kind)}${countUnitSuffix(kind, sq.unit)}` for counting. Delete `sharedHint` from both prop interfaces and every render; delete `sharedCounterHintsByTaskId` from `useBoardPlayData.ts` and its two reads; in `sharedCounterWindowRegression.test.ts` delete only the hint assertions.

- [ ] **Step 4: Run** `WEB_TEST countingLogModel DetailModal boardPlay sharedCounterWindowRegression` — PASS; `WEB_CHECK`; `node scripts/check-file-sizes.mjs` (BoardPlaySurface well under 1241 — do NOT lower the cap; Task 21 does).

- [ ] **Step 5: e2e (web).** `windowed-completion.spec.ts:205-207` →

```ts
    // Tap opens the stepper modal (counter kinds §5 — web no longer logs +1 on tap).
    await counterSquare.click();
    await page.getByRole('dialog').getByRole('button', { name: 'Increase' }).click();
    await page.keyboard.press('Escape');
    await expect(counterSquare).toContainText('1/10');
```

Create `apps/web/e2e/counter-kinds-logging.spec.ts`:

```ts
import { test, expect, seedBoard, seedBoardTask, seedTask, readTask } from './_fixtures/bypass';

const now = new Date();
const iso = (d: Date) => d.toISOString();
const START = iso(new Date(now.getTime() - 2 * 864e5));
const END = iso(new Date(now.getTime() + 5 * 864e5));
const BOARD = 'f1000000-0000-0000-0000-000000000001';
const RUN = 'f1000000-0000-0000-0000-000000000002';
const PRACTICE = 'f1000000-0000-0000-0000-000000000003';

test.describe('Counter kinds — logging (B1)', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await seedTask(page, { id: RUN, title: 'Run 26.2 mi', type: 'counting', action: 'Run', unit: 'mi', maxCount: 26.2, countKind: 'continuous' });
    await seedTask(page, { id: PRACTICE, title: 'Practice 10h 30m', type: 'counting', action: 'Practice', unit: '', maxCount: 630, countKind: 'duration' });
    await seedBoard(page, { id: BOARD, name: 'Kinds board', boardSize: 3, timeframe: 'weekly', status: 'active', startDate: START, endDate: END, centerSquareType: 'none' });
    await seedBoardTask(page, { id: 'f1000000-bt00-0000-0000-000000000001', boardId: BOARD, taskId: RUN, row: 0, col: 0 });
    await seedBoardTask(page, { id: 'f1000000-bt00-0000-0000-000000000002', boardId: BOARD, taskId: PRACTICE, row: 0, col: 1 });
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
  });

  test('Continuous: chip, typed custom amount, remembered on reopen', async ({ page }) => {
    const run = page.getByRole('button', { name: 'Run 26.2 mi' });
    await run.click();
    const modal = page.getByRole('dialog');
    await modal.getByRole('button', { name: '13.1', exact: true }).click();
    await modal.getByRole('button', { name: '+ 13.1 mi' }).click();
    await page.keyboard.press('Escape');
    await expect(run).toContainText('13.1/26.2');
    await run.click();
    await modal.getByLabel('Log amount', { exact: true }).fill('3,1');
    await modal.getByRole('button', { name: '+ 3.1 mi' }).click();
    await page.keyboard.press('Escape');
    await expect(run).toContainText('16.2/26.2');
    expect(await readTask(page, RUN)).toMatchObject({ defaultLogAmount: 3.1 });
    await run.click();
    await expect(modal.getByRole('button', { name: '#3.1' })).toHaveAttribute('aria-pressed', 'true');
  });

  test('Duration: h / m entry', async ({ page }) => {
    const practice = page.getByRole('button', { name: 'Practice 10h 30m' });
    await practice.click();
    const modal = page.getByRole('dialog');
    await modal.getByLabel('Log amount hours').fill('1');
    await modal.getByLabel('Log amount minutes').fill('30');
    await modal.getByRole('button', { name: '+ 1h 30m' }).click();
    await page.keyboard.press('Escape');
    await expect(practice).toContainText('1h 30m');
  });
});
```

Run `WEB_E2E e2e/windowed-completion.spec.ts e2e/counter-kinds-logging.spec.ts` — PASS. Playwright MCP: screenshot both modals light/dark → `.playwright-mcp/task14-b1-web-{continuous,duration}-{light,dark}.png` vs handoff B1 web.

- [ ] **Step 6: iOS failing tests.** `CountingStepperModelTests.swift`:

```swift
import XCTest
@testable import OYBC

final class CountingStepperModelTests: XCTestCase {
    func testContinuousOpensOnTheRememberedCustomAmount() {
        let m = CountingStepperModel.initial(kind: .continuous, goal: 26.2, defaultLogAmount: 3.1, isShared: false)
        XCTAssertEqual(m.chips.map(\.label), ["6.6", "13.1", "26.2", "#"])
        XCTAssertTrue(m.isCustom)
        XCTAssertEqual(m.amountText, "3.1")
        XCTAssertEqual(m.amount, 3.1)
        XCTAssertEqual(m.addLabel(unit: "mi"), "+ 3.1 mi")
    }
    func testChipAndTypedTextSwitchCustomness() {
        var m = CountingStepperModel.initial(kind: .continuous, goal: 26.2, defaultLogAmount: nil, isShared: false)
        XCTAssertEqual(m.amount, 6.6)
        XCTAssertFalse(m.isCustom)
        m.setText("31")
        XCTAssertEqual(m.amount, 31)
        XCTAssertTrue(m.isCustom)
        m.selectChip(13.1)
        XCTAssertEqual(m.amountText, "13.1")
        XCTAssertFalse(m.isCustom)
        m.setText("3.125")
        XCTAssertNil(m.amount, "an invalid entry disables − / +")
    }
    func testDurationQuarterIsToTheMinute() {
        let m = CountingStepperModel.initial(kind: .duration, goal: 630, defaultLogAmount: nil, isShared: false)
        XCTAssertEqual(m.amount, 158)
        XCTAssertEqual(m.addLabel(unit: ""), "+ 2h 38m")
    }
    func testDiscreteStandaloneHasNoChipsAndStepsOne() {
        let m = CountingStepperModel.initial(kind: .discrete, goal: 10, defaultLogAmount: 10, isShared: false)
        XCTAssertFalse(m.showsChips)
        XCTAssertEqual(m.amount, 1)
    }
    func testDiscreteSharedKeepsPlusOnePlusTen() {
        let m = CountingStepperModel.initial(kind: .discrete, goal: 200, defaultLogAmount: 10, isShared: true)
        XCTAssertEqual(m.chips.map(\.label), ["+1", "+10", "#"])
        XCTAssertEqual(m.amount, 10)
    }
}
```

`BoardPlayViewModelTests` addition — use the file's existing standalone-counting fixture (a board + one placed standalone counting task; copy the nearest existing `handleCountingTap` test's setup) with `countKind = .continuous`, then:

```swift
        vm.handleCountingTap(boardTask: bt, task: task, amount: 3.1, persistAsDefault: true)
        XCTAssertTrue(waitUntil { (try? db.fetchTask(id: task.id))??.defaultLogAmount == 3.1 })
        vm.handleCountingTap(boardTask: bt, task: task, amount: 6.6, persistAsDefault: false)
        XCTAssertEqual(try db.fetchTask(id: task.id)?.defaultLogAmount, 3.1, "a chip amount never overwrites the default")
```

Snapshot `CountingStepperSheetSnapshotTests.swift` (handoff `sheets[]`):

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
            .background(Color.risoPaper)
    }
    private func snap(_ v: some View, h: CGFloat, dark: Bool = false, testName: String = #function, line: UInt = #line) {
        assertSnapshot(of: v, as: .image(layout: .fixed(width: 393, height: h), traits: .init(userInterfaceStyle: dark ? .dark : .light)),
                       record: recordMode, testName: testName, line: line)
    }
    func testDiscreteSharedLight() { snap(sheet(.discrete, title: "Do 200 push-ups", unit: "push-ups", cur: 132, max: 200, shared: true, defaultAmount: 10), h: 400) }
    func testContinuousCustomLight() { snap(sheet(.continuous, title: "Run 26.2 mi", unit: "mi", cur: 12.4, max: 26.2, shared: false, defaultAmount: 3.1), h: 420) }
    func testContinuousCustomDark() { snap(sheet(.continuous, title: "Run 26.2 mi", unit: "mi", cur: 12.4, max: 26.2, shared: false, defaultAmount: 3.1), h: 420, dark: true) }
    func testDurationQuarterLight() { snap(sheet(.duration, title: "Practice 10h 30m", unit: "", cur: 270, max: 630, shared: false, defaultAmount: nil), h: 560) }
    func testDurationQuarterDark() { snap(sheet(.duration, title: "Practice 10h 30m", unit: "", cur: 270, max: 630, shared: false, defaultAmount: nil), h: 560, dark: true) }
    func testOvershootLight() { snap(sheet(.continuous, title: "Run 26.2 mi", unit: "mi", cur: 28.4, max: 26.2, shared: false, defaultAmount: 3.1), h: 420) }
}
```

- [ ] **Step 7: Run — expect build FAIL.** `IOS_TEST -only-testing:OYBCTests/CountingStepperModelTests`

- [ ] **Step 8: Implement iOS.** `CountingStepperModel.swift`:

```swift
import Foundation

/// The stepper sheet's chip / amount state (docs/COUNTER_KINDS.md §5). Web
/// twin: `countingLogModel.ts`. Pure — unit-tested without the sheet.
struct CountingStepperModel: Equatable {
    let kind: CountKind
    let chips: [CounterLogAmount.LogChip]
    let isShared: Bool
    var amountText: String
    var selectedAmount: CountValue
    var isCustom: Bool

    static func initial(kind: CountKind, goal: CountValue, defaultLogAmount: CountValue?, isShared: Bool) -> CountingStepperModel {
        let chips = CounterLogAmount.boardSheetChips(kind: kind, goal: goal)
        let sel = CounterLogAmount.initialSelection(kind: kind, chips: chips, defaultLogAmount: defaultLogAmount)
        return CountingStepperModel(kind: kind, chips: chips, isShared: isShared,
                                    amountText: formatCountForInput(sel.amount, kind: kind), selectedAmount: sel.amount, isCustom: sel.isCustom)
    }

    /// Chips show for every Continuous / Duration square and for shared Discrete squares.
    var showsChips: Bool { kind != .discrete || isShared }

    /// The amount − / + apply: the field for the new kinds, the chip for shared Discrete, 1 otherwise.
    var amount: CountValue? {
        if kind != .discrete { return parseCountInput(amountText, kind: kind) }
        return isShared ? selectedAmount : 1
    }

    mutating func selectChip(_ value: CountValue) {
        selectedAmount = value
        isCustom = false
        amountText = formatCountForInput(value, kind: kind)
    }

    mutating func setText(_ raw: String) {
        amountText = raw
        let parsed = parseCountInput(raw, kind: kind)
        isCustom = parsed.map { v in !chips.contains { $0.value == v } } ?? true
        if let parsed { selectedAmount = parsed }
    }

    func addLabel(unit: String) -> String {
        guard let a = amount else { return "+" }
        return kind == .discrete ? "+ \(formatCount(a, kind: .discrete))" : "+ \(formatCountWithUnit(a, kind: kind, unit: unit))"
    }
}
```

`RisoCountingStepperSheet`: replace `sharedHint`, `selectedAmount`, `isCustomActive` state and the private `AmountChipOption`/`chips` with `let countKind: CountKind` (init parameter after `unitText`, default `.discrete`) and `@State private var model: CountingStepperModel` seeded in `init` via `CountingStepperModel.initial(kind: countKind, goal: maxCount, defaultLogAmount: defaultLogAmount, isShared: isSharedCounter)`; keep `customOpen` / `customDraft` for the Discrete shared custom row. Body:

```swift
            VStack(spacing: 12) {
                labelPill
                stepperRow
                if model.showsChips { chipRow }
                if countKind == .discrete, isSharedCounter, customOpen { customInputRow }
                if countKind != .discrete {
                    GoalEntryView(kind: countKind, text: Binding(get: { model.amountText }, set: { model.setText($0) }),
                                  placeholder: "Amount", suffix: unitText.isEmpty ? nil : unitText, startsOpen: countKind == .duration)
                }
                if let onOpenTask { taskDetailsRow(onOpenTask) }
            }
```

`labelPill` text = `"\(taskTitle) · \(progressText)\(countUnitSuffix(countKind, unit: unitText))"` with `progressText = "\(formatCount(currentCount, kind: countKind))/\(formatCount(maxCount, kind: countKind))"`; the stepper's value `Text(progressText)`; − calls `onDecrement(amount, model.isCustom && (countKind != .discrete || isSharedCounter))` only when `model.amount` is non-nil (`.disabled(model.amount == nil || currentCount == 0)`), + likewise; chip row iterates `model.chips` (selected index: custom → last; else first chip whose `value == model.selectedAmount` when `!model.isCustom`), a chip tap → `model.selectChip(v)`, `#` → for Discrete the existing `openCustomInput()`, for the new kinds `model.isCustom = true` (the field is already there); the `#` label when custom and selected = `CounterLogAmount.customChipLabel(model.amount ?? 0, kind: countKind)`. `confirmCustomInput` (Discrete) → `CounterLogAmount.parseCustom(customDraft, kind: .discrete)` → `model.selectedAmount = v; model.isCustom = true`. `sheetHeight` = `140 + (model.showsChips ? 56 : 0) + (countKind == .continuous ? 52 : 0) + (countKind == .duration ? 190 : 0) + (countKind == .discrete && isSharedCounter && customOpen ? 44 : 0) + (onOpenTask != nil ? 56 : 0)`. Remove the four `sharedHint` previews' argument.
  `BoardPlayView+CountingStepper.swift`: drop `sharedHint`; pass `countKind: resolveFamilyCountKind(task, lookup: { taskMap[$0] })` and `defaultLogAmount: (sourceId.flatMap { taskMap[$0] } ?? task).defaultLogAmount`. `BoardPlayView.swift`: delete `sharedStepperHint(for:)` and the two caption `Text`s (rows 2, 4) with their modifiers. `BoardPlayViewModel.handleCountingTap` standalone branch, after `runOrchestration(…)`:

```swift
        if persistAsDefault { try? database.setCounterDefaultLogAmount(sourceTaskId: task.id, amount: amount) }
```

  (the same for `handleCountingDecrement`; both lines fit the budget Task 13 freed).

- [ ] **Step 9: Run iOS** `IOS_TEST -only-testing:OYBCTests/CountingStepperModelTests -only-testing:OYBCTests/BoardPlayViewModelTests` PASS; `xcodegen generate`; record the six snapshots; read each vs handoff B1 iOS (Continuous: `6.6 · 13.1 · 26.2 · #3.1`, decimal pad field "3.1 mi"; Duration: ¼ = 2h 38m selected — NOT the handoff's 2h 40m, owner override). `node scripts/check-file-sizes.mjs` — every file within its cap.

- [ ] **Step 10: Commit (both platforms, one commit)**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): every counting tap opens the stepper sheet / DetailModal per kind (goal chips, pinned amount field, h:m); standalone counters remember a custom amount; drop board-play captions (#548 1-9) (PR 4 Task 14)"
```

---

### Task 15: B2 — long-press / right-click menu per kind

**Files:**
- Create: `apps/ios/OYBC/Views/BoardsTab/Components/CountingMenuLabels.swift`
- Modify: `apps/ios/OYBC/Views/BoardsTab/BoardPlayView.swift:1397-1424` (counting menu; budget +8, Task 13 table)
- Modify: `apps/web/src/components/InteractiveTaskSquare.tsx:44-60` (`ContextMenuProps.amountActions`), `:146-215` (counting block)
- Modify: `apps/web/src/components/BoardPlaySurface.tsx:1151-1170` (build `amountActions`; budget +12)
- Test: `apps/web/src/components/__tests__/FloatingContextMenuKinds.test.ts` (create), `apps/ios/OYBCTests/CountingMenuLabelsTests.swift` (create), `apps/web/e2e/counter-kinds-logging.spec.ts` (+1 case)

**Interfaces:**
- Consumes: `quickLogAmount`, `boardSheetChips`, `formatCountWithUnit` ↔ `CounterLogAmount.quickAmount`, `formatCountWithUnit` (Task 13 / Task 2).
- Produces: web `ContextMenuProps.amountActions?: { kind: CountKind; amount: number; unit: string; onAdd(amount: number): void; onRemove(amount: number): void; onOpenCustom(): void; removeDisabled: boolean }` (Continuous / Duration squares only; Discrete keeps `sharedAmountActions` / the plain items); iOS `enum CountingMenuLabels { static func add(amount:kind:unit:action:) -> String; static func remove(amount:kind:unit:action:) -> String }`.
- Menu for Continuous / Duration: `+ Add {last} {unit}` · `# Custom amount…` (opens the sheet / modal) · `− Remove {last} {unit}` · (web keeps `↺ Reset`) · divider · `View Details` · `Open in library`. `{last}` = `defaultLogAmount ?? first chip`. Discrete menus unchanged on both platforms.

- [ ] **Step 1: Failing tests.** `FloatingContextMenuKinds.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { FloatingContextMenu } from '../InteractiveTaskSquare';

const noop = () => {};
const menu = (sq: object, amountActions?: object) =>
  renderToStaticMarkup(React.createElement(FloatingContextMenu, {
    sq: sq as never, state: { isCompleted: false, currentCount: 12.4, completedStepIds: new Set() }, position: { x: 0, y: 0 },
    onClose: noop, onIncrementCount: noop, onDecrementCount: noop, onResetCount: noop, onViewDetails: noop,
    amountActions: amountActions as never,
  }));

describe('FloatingContextMenu — counter kinds', () => {
  it('continuous: + Add {last} unit / # Custom amount… / − Remove {last} unit', () => {
    const html = menu({ id: 's', title: 'Run', type: 'counting', action: 'Run', maxCount: 26.2, unit: 'mi', countKind: 'continuous' },
      { kind: 'continuous', amount: 3.1, unit: 'mi', onAdd: noop, onRemove: noop, onOpenCustom: noop, removeDisabled: false });
    expect(html).toContain('+ Add 3.1 mi');
    expect(html).toContain('# Custom amount…');
    expect(html).toContain('− Remove 3.1 mi');
  });
  it('duration has no unit', () => {
    const html = menu({ id: 's', title: 'Practice', type: 'counting', action: 'Practice', maxCount: 630, unit: '', countKind: 'duration' },
      { kind: 'duration', amount: 90, unit: '', onAdd: noop, onRemove: noop, onOpenCustom: noop, removeDisabled: false });
    expect(html).toContain('+ Add 1h 30m');
  });
  it('a discrete standalone square keeps today\'s items', () => {
    const html = menu({ id: 's', title: 'Push', type: 'counting', action: 'Do', maxCount: 10, unit: 'reps' });
    expect(html).toContain('+ Add Do (+1)');
    expect(html).toContain('− Remove Do (−1)');
  });
});
```

`CountingMenuLabelsTests.swift`:

```swift
import XCTest
@testable import OYBC

final class CountingMenuLabelsTests: XCTestCase {
    func testLabels() {
        XCTAssertEqual(CountingMenuLabels.add(amount: 3.1, kind: .continuous, unit: "mi", action: "Run"), "+ Add 3.1 mi")
        XCTAssertEqual(CountingMenuLabels.remove(amount: 90, kind: .duration, unit: "", action: "Practice"), "− Remove 1h 30m")
        XCTAssertEqual(CountingMenuLabels.add(amount: 1, kind: .discrete, unit: "reps", action: "Do"), "+ Add 1 Do", "discrete keeps today's iOS string")
        XCTAssertEqual(CountingMenuLabels.remove(amount: 10, kind: .discrete, unit: "reps", action: "Do"), "− Remove 10 Do")
    }
}
```

- [ ] **Step 2: Run — FAIL.** `WEB_TEST FloatingContextMenuKinds` / `IOS_TEST -only-testing:OYBCTests/CountingMenuLabelsTests`

- [ ] **Step 3: Implement.** iOS `CountingMenuLabels.swift`:

```swift
import Foundation

/// Long-press menu labels per kind (docs/COUNTER_KINDS.md §5). Discrete keeps
/// the shipped "+ Add {n} {action}" wording; the new kinds name the amount
/// with its unit ("+ Add 3.1 mi", "+ Add 1h 30m").
enum CountingMenuLabels {
    static func add(amount: CountValue, kind: CountKind, unit: String, action: String) -> String {
        kind == .discrete ? "+ Add \(formatCount(amount, kind: .discrete)) \(action)" : "+ Add \(formatCountWithUnit(amount, kind: kind, unit: unit))"
    }
    static func remove(amount: CountValue, kind: CountKind, unit: String, action: String) -> String {
        kind == .discrete ? "− Remove \(formatCount(amount, kind: .discrete)) \(action)" : "− Remove \(formatCountWithUnit(amount, kind: kind, unit: unit))"
    }
}
```

`BoardPlayView.risoContextMenu` `.counting` case:

```swift
            if let t = task {
                let kind = resolveFamilyCountKind(t, lookup: { taskMap[$0] })
                let source = viewModel.sharedCounterSourceId(for: t).flatMap { taskMap[$0] }
                // Discrete keeps today's rule (the shared source's default, else 1);
                // the new kinds remember per task too.
                let remembered = kind == .discrete ? source?.defaultLogAmount : (source ?? t).defaultLogAmount
                let chips = CounterLogAmount.boardSheetChips(kind: kind, goal: t.maxCount ?? 0)
                let quickAmount = CounterLogAmount.quickAmount(kind: kind, chips: chips, defaultLogAmount: remembered)
                Button(CountingMenuLabels.add(amount: quickAmount, kind: kind, unit: t.unit ?? "", action: t.action ?? "item"), systemImage: "plus") {
                    guard !isBoardLocked else { return }
                    viewModel.handleCountingTap(boardTask: boardTask, task: t, amount: quickAmount)
                }
                .disabled(isProcessing || isBoardLocked)
                if kind != .discrete {
                    Button("Custom amount…", systemImage: "number") { countingStepperBoardTaskId = boardTask.id }
                        .disabled(isBoardLocked)
                }
                Button(CountingMenuLabels.remove(amount: quickAmount, kind: kind, unit: t.unit ?? "", action: t.action ?? "item"), systemImage: "minus") {
                    guard !isBoardLocked else { return }
                    viewModel.handleCountingDecrement(boardTask: boardTask, task: t, amount: quickAmount)
                }
                .disabled(current == 0 || isProcessing || isBoardLocked)
                // View Details / Open in library unchanged
```

(the Discrete `defaultLogAmount` source stays the shared source's only — today's behaviour; a standalone Discrete square adds 1.) Web `ContextMenuProps.amountActions` (doc: "Continuous / Duration squares: + Add / # Custom amount… / − Remove at the last amount"); in the counting block, before the `sharedAmountActions ? … : …` branch:

```tsx
          {amountActions ? (
            <>
              <button className={styles.contextMenuItem} onClick={() => { amountActions.onAdd(amountActions.amount); onClose(); }}>
                + Add {formatCountWithUnit(amountActions.amount, amountActions.kind, amountActions.unit)}
              </button>
              <button className={styles.contextMenuItem} onClick={() => { amountActions.onOpenCustom(); onClose(); }}>
                # Custom amount…
              </button>
              <button className={styles.contextMenuItem} disabled={amountActions.removeDisabled}
                onClick={() => { amountActions.onRemove(amountActions.amount); onClose(); }}>
                − Remove {formatCountWithUnit(amountActions.amount, amountActions.kind, amountActions.unit)}
              </button>
            </>
          ) : ( /* the existing sharedAmountActions / plain block, then its − Remove item — unchanged */ )}
```

(the existing `↺ Reset` item stays below both branches). `BoardPlaySurface` (`:1151`):

```ts
        const menuKind = resolveFamilyCountKind(task, (id) => taskMap[id]);
        const amountActions = squareData.type === 'counting' && menuKind !== 'discrete'
          ? {
              kind: menuKind,
              amount: quickLogAmount(menuKind, boardSheetChips(menuKind, task.maxCount ?? 0), (menuSourceId ? taskMap[menuSourceId] : task)?.defaultLogAmount),
              unit: task.unit ?? '',
              onAdd: (a: number) => (menuSourceId ? void handleSharedCounterIncrement(menuSourceId, a, false) : void handleComplete(bt.id, { currentCount: quantizeCount(menuCurrentCount + a) })),
              onRemove: (a: number) => (menuSourceId ? void handleSharedCounterDecrement(menuSourceId, a, false) : void handleComplete(bt.id, { currentCount: Math.max(0, quantizeCount(menuCurrentCount - a)) })),
              onOpenCustom: () => setSelectedSquareId(bt.id),
              removeDisabled: isLinkedCounter || menuCurrentCount <= 0,
            }
          : undefined;
```

and `sharedAmountActions` is computed only when `menuKind === 'discrete'`.

- [ ] **Step 4: Run** tests PASS; `WEB_CHECK`; `node scripts/check-file-sizes.mjs` (within the caps); `xcodegen generate`. Append to `counter-kinds-logging.spec.ts`:

```ts
  test('right-click: + Add {last} unit', async ({ page }) => {
    const run = page.getByRole('button', { name: 'Run 26.2 mi' });
    await run.click({ button: 'right' });
    await page.getByRole('button', { name: '+ Add 6.6 mi' }).click(); // no default yet → the ¼ chip
    await expect(run).toContainText('6.6/26.2');
  });
```

Run `WEB_E2E e2e/counter-kinds-logging.spec.ts`.

- [ ] **Step 5: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): long-press / right-click menu adds and removes the last amount per kind; Custom amount opens the sheet (PR 4 Task 15)"
```

---

### Task 16: B3 — closed-board late log per kind

**Files:**
- Create: `apps/web/src/components/lateLog/lateLogCountingModel.ts`, `apps/web/src/components/lateLog/__tests__/lateLogCountingModel.test.ts` (new folder)
- Modify: `apps/web/src/components/lateLog/LateLogSheet.tsx:23-24` (delete `LATE_LOG_CHIP_AMOUNTS`), `:218-330` (`CountingBody` reads the model; custom entry → `GoalEntry`)
- Modify: `apps/ios/OYBC/Views/BoardsTab/LateLog/LateLogSheetView.swift:30-36` (`Kind.counting(current:max:unit:countKind:)`), `:96-102` (`sheetHeight`), `:156-192` (`countingBody`); add `enum LateLogCountingCopy` (pure, same file)
- Modify: `apps/ios/OYBC/Views/BoardsTab/BoardPlayView+LateLog.swift:118` (`countKind: resolveFamilyCountKind(task, lookup: { taskMap[$0] })`)
- Test: `apps/ios/OYBCTests/LateLogCountingCopyTests.swift` (create), `apps/ios/OYBCSnapshotTests/BoardCloseReopenSnapshotTests.swift` (+`testLateLogContinuous{Light,Dark}`, `testLateLogDurationLight`), `apps/web/e2e/late-log-counting.spec.ts` (+1 case)

**Interfaces:**
- Consumes: `lateLogChipAmounts`, `parseCountInput`, `formatCount`, `formatCountWithUnit` (Task 13 / Task 1).
- Produces:
  - web `lateLogCountingModel(args: { kind: CountKind; goal: number; count: number; unit: string; selected: number; customOpen: boolean; customDraft: string }): { chips: { amount: number; label: string }[]; readout: { count: string; max: string; unit: string }; amount: number | null; buttonLabel: string; canLog: boolean }` and `initialLateLogAmount(kind, goal): number` (the first chip)
  - iOS `enum LateLogCountingCopy { static func chips(kind:goal:) -> [CountValue]; static func chipLabel(_:kind:) -> String; static func readout(current:max:unit:kind:) -> String }`
  - Copy: chips `+{formatCount}` (`+6.6`, `+2h 38m`) then `Custom…`; web button `Log` for Discrete (unchanged) and `Log +{amount}{ unit}` for Continuous / Duration ("Log +4.9 mi", "Log +1h 30m"); readout `{count}/{max}` + unit (none for Duration).

- [ ] **Step 1: Failing tests.** `lateLogCountingModel.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { initialLateLogAmount, lateLogCountingModel } from '../lateLogCountingModel';

describe('lateLogCountingModel', () => {
  it('continuous: goal chips, readout, Log +amount unit', () => {
    const m = lateLogCountingModel({ kind: 'continuous', goal: 26.2, count: 21.3, unit: 'mi', selected: 6.6, customOpen: false, customDraft: '' });
    expect(m.chips.map((c) => c.label)).toEqual(['+6.6', '+13.1', '+26.2']);
    expect(m.readout).toEqual({ count: '21.3', max: '26.2', unit: 'mi' });
    expect(m.buttonLabel).toBe('Log +6.6 mi');
  });
  it('a custom 4.9 drives the label; an invalid custom blocks Log', () => {
    expect(lateLogCountingModel({ kind: 'continuous', goal: 26.2, count: 21.3, unit: 'mi', selected: 6.6, customOpen: true, customDraft: '4,9' }).buttonLabel).toBe('Log +4.9 mi');
    expect(lateLogCountingModel({ kind: 'continuous', goal: 26.2, count: 21.3, unit: 'mi', selected: 6.6, customOpen: true, customDraft: '4.999' }).canLog).toBe(false);
  });
  it('duration: no unit anywhere', () => {
    const m = lateLogCountingModel({ kind: 'duration', goal: 630, count: 540, unit: '', selected: 158, customOpen: true, customDraft: '1h 30m' });
    expect(m.chips[0].label).toBe('+2h 38m');
    expect(m.readout).toEqual({ count: '9h', max: '10h 30m', unit: '' });
    expect(m.buttonLabel).toBe('Log +1h 30m');
  });
  it('discrete is unchanged: +1 +2 +5 and a plain Log', () => {
    const m = lateLogCountingModel({ kind: 'discrete', goal: 5, count: 0, unit: 'mi', selected: 1, customOpen: false, customDraft: '' });
    expect(m.chips.map((c) => c.label)).toEqual(['+1', '+2', '+5']);
    expect(m.buttonLabel).toBe('Log');
    expect(initialLateLogAmount('discrete', 5)).toBe(1);
    expect(initialLateLogAmount('duration', 630)).toBe(158);
  });
});
```

`LateLogCountingCopyTests.swift`:

```swift
import XCTest
@testable import OYBC

final class LateLogCountingCopyTests: XCTestCase {
    func testChipsAndReadoutPerKind() {
        XCTAssertEqual(LateLogCountingCopy.chips(kind: .continuous, goal: 26.2), [6.6, 13.1, 26.2])
        XCTAssertEqual(LateLogCountingCopy.chips(kind: .discrete, goal: 5), [1, 2, 5])
        XCTAssertEqual(LateLogCountingCopy.chipLabel(158, kind: .duration), "+2h 38m")
        XCTAssertEqual(LateLogCountingCopy.readout(current: 21.3, max: 26.2, unit: "mi", kind: .continuous), "21.3/26.2 mi")
        XCTAssertEqual(LateLogCountingCopy.readout(current: 540, max: 630, unit: "", kind: .duration), "9h/10h 30m")
    }
}
```

- [ ] **Step 2: Run — FAIL.** `WEB_TEST lateLogCountingModel` / `IOS_TEST -only-testing:OYBCTests/LateLogCountingCopyTests`

- [ ] **Step 3: Implement web.** `lateLogCountingModel.ts`:

```ts
import { countUnitSuffix, formatCount, formatCountWithUnit, lateLogChipAmounts, parseCountInput, type CountKind } from '@oybc/shared';

/** The first chip — what the sheet opens on. */
export function initialLateLogAmount(kind: CountKind, goal: number): number {
  return lateLogChipAmounts(kind, goal)[0];
}

/** Everything the closed-board COUNTING body renders (docs/COUNTER_KINDS.md §5 B3). */
export function lateLogCountingModel(a: {
  kind: CountKind; goal: number; count: number; unit: string; selected: number; customOpen: boolean; customDraft: string;
}): { chips: { amount: number; label: string }[]; readout: { count: string; max: string; unit: string }; amount: number | null; buttonLabel: string; canLog: boolean } {
  const amount = a.customOpen ? parseCountInput(a.customDraft, a.kind) : a.selected;
  const unit = countUnitSuffix(a.kind, a.unit).trim();
  return {
    chips: lateLogChipAmounts(a.kind, a.goal).map((v) => ({ amount: v, label: `+${formatCount(v, a.kind)}` })),
    readout: { count: formatCount(a.count, a.kind), max: formatCount(a.goal, a.kind), unit },
    amount,
    buttonLabel: a.kind === 'discrete' || amount === null ? 'Log' : `Log +${formatCountWithUnit(amount, a.kind, a.unit)}`,
    canLog: amount !== null,
  };
}
```

`CountingBody`: `const kind = resolveCountKind(task); const [selected, setSelected] = useState<number>(() => initialLateLogAmount(kind, task.maxCount ?? 0));` and `const m = lateLogCountingModel({ kind, goal: max, count: state.count, unit: task.unit ?? '', selected, customOpen, customDraft });` (after the loading / null early returns — move the `useState` above them as today). Readout: `{m.readout.count}{max > 0 && <span className={styles.countMax}>/{m.readout.max}</span>}` and `{m.readout.unit && <span className={styles.unit}>{m.readout.unit}</span>}`; chips: `m.chips.map((c) => <RisoChip key={c.amount} on={!customOpen && selected === c.amount} onClick={() => { setCustomOpen(false); setSelected(c.amount); }}>{c.label}</RisoChip>)`; custom row → `<GoalEntry kind={kind} value={customDraft} onChange={setCustomDraft} aria-label="Custom amount" placeholder="Amount" dense />`; button `disabled={busy || !m.canLog}`, `onClick={() => { if (m.amount !== null) void handleLog(m.amount); }}`, label `{m.buttonLabel}`.

- [ ] **Step 4: Implement iOS.**

```swift
/// Pure copy for the closed-board counting body. Web twin: `lateLogCountingModel.ts`.
enum LateLogCountingCopy {
    static func chips(kind: CountKind, goal: CountValue) -> [CountValue] { CounterLogAmount.lateLogChipAmounts(kind: kind, goal: goal) }
    static func chipLabel(_ amount: CountValue, kind: CountKind) -> String { "+\(formatCount(amount, kind: kind))" }
    static func readout(current: CountValue, max: CountValue, unit: String, kind: CountKind) -> String {
        "\(formatCount(current, kind: kind))/\(formatCount(max, kind: kind))\(countUnitSuffix(kind, unit: unit))"
    }
}
```

`Kind.counting(current:max:unit:countKind:)`; `countingBody(current:max:unit:countKind:)`: readout `Text(LateLogCountingCopy.readout(…))`; `ForEach(LateLogCountingCopy.chips(kind: countKind, goal: max), id: \.self) { amount in RisoButton(title: LateLogCountingCopy.chipLabel(amount, kind: countKind), kind: .neutral, small: true) { perform { await onLogAmount(amount) } } }`; custom row `GoalEntryView(kind: countKind, text: $customAmountDraft, placeholder: "Amount", startsOpen: countKind == .duration)` with `CounterLogAmount.parseCustom(customAmountDraft, kind: countKind)` in both the Log action and its `.disabled`; `sheetHeight` `.counting(_, _, _, kind)` = `kind == .duration && customOpen ? 470 : 280`. `BoardPlayView+LateLog.swift:118` passes `countKind:`. Fix the snapshot test helper's `.counting(...)` call in `BoardCloseReopenSnapshotTests.swift:112-120` (add `countKind: .discrete` to the existing cases).

- [ ] **Step 5: Run** both tests PASS; `WEB_CHECK`. Add the three snapshot cases (`LateLogSheetView(windowLabel: "Mar 1 – 31", taskTitle: "Run 26.2 mi", kind: .counting(current: 21.3, max: 26.2, unit: "mi", countKind: .continuous))` at 393×300 light/dark; the Duration twin `(540, 630, "", .duration)` at 393×300 light); record; existing `BoardCloseReopenSnapshotTests` baselines stay green; read vs handoff B3. Append to `late-log-counting.spec.ts`:

```ts
  test('Continuous late log: +6.6 → "Log +6.6 mi"', async ({ page }) => {
    await seedTask(page, { id: TASK_ID, title: 'Run 26.2 mi', type: 'counting', action: 'Run', unit: 'mi', maxCount: 26.2, countKind: 'continuous' });
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByText('Run 26.2 mi').click();
    const sheet = page.getByRole('dialog', { name: /Run 26.2 mi/ });
    await sheet.getByRole('button', { name: '+6.6' }).click();
    await sheet.getByRole('button', { name: 'Log +6.6 mi' }).click();
    await expect(sheet).toHaveCount(0);
  });
```

(the `seedTask` call overwrites the `beforeEach` row — same id, `put` semantics). `WEB_E2E e2e/late-log-counting.spec.ts` — the discrete cases stay green.

- [ ] **Step 6: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): closed-board late log per kind — goal chips, decimal / h:m custom entry, Log +amount (PR 4 Task 16)"
```

---

### Task 17: B4 — hub ledger cards, Profile rows, "+ Log" pills

**Files:**
- Create: `apps/web/src/components/counters/ledgerPill.ts` (pure), `apps/web/src/components/counters/__tests__/ledgerPill.test.ts`
- Modify: `apps/web/src/components/counters/CounterLedgerCard.tsx:9-13` (`CounterLoggedEvent.kind`), `:61-190` (pill via `ledgerPill`; lifetime `formatCountTotal` — R7 `:65`; row values `formatCount` — R7 `:174-175`)
- Modify: `apps/web/src/pages/ProfilePage.tsx:338-416` (compact row: same pill + values — R7 `:392-393`, `:404`); delete #548 row 89 (the empty-state body `<p className={styles.countersEmptyBody}>` `:290-293`)
- Modify: `apps/web/src/pages/CountersHubPage.tsx:113-116` (delete row 85 intro `<p>`), `:177-179` (delete row 87 `emptySub` `<p>`); pass `kind` to `CounterLogToast`
- Modify: `apps/ios/OYBC/Views/ProfileTab/Components/SharedCounterLedgerCard.swift:51,81,100,107-118,136,189,236,270` (pill label + VoiceOver; R7 `.formatted()` ×3 → `formatCountTotal`; member values → `formatCount`)
- Modify: `apps/ios/OYBC/Views/ProfileTab/CountersHubView.swift:141-160` (`handleLog` opens Detail for a never-logged new-kind counter), `:232-236` (delete row 86 intro `Text`), `:300-303` (delete row 88 empty `Text`)
- Modify: `apps/ios/OYBC/Views/ProfileTab/ViewModels/ProfileHomeViewModel.swift:131-160` (+`static func pillAction(for:)`), `apps/ios/OYBC/Views/ProfileTab/ProfileView.swift:131` (`onLog` routes `.openDetail` to `navigateToCounterId`), `apps/ios/OYBC/Views/ProfileTab/Components/ProfileCountersSection.swift:107-110` (delete row 90 `Text`)
- Test: `apps/ios/OYBCTests/ProfileHomeViewModelTests.swift` (+1 case; create the file if absent), snapshots, `apps/web/e2e/counter-kinds-logging.spec.ts` (+1 case)
- Re-record (intentional): `CountersHubSnapshotTests/testHubPopulated{Light,Dark}` (row 86), `testHubEmpty{Light,Dark}` (row 88); `RisoProfileSnapshotTests/testEmptyStreakAndCounters{Light,Dark}` and `testDayOneHero{Light,Dark}` (both pass `counters: []` — row 90; a frame that crops the counters card stays green and is not re-recorded). Add `CountersHubSnapshotTests/testHubContinuousDuration{Light,Dark}` (handoff `ledgers[]`).

**Interfaces:**
- Consumes: `logPillLabel`, `logPillOpensDetail`, `formatCountTotal`, `formatCount`, `formatCountWithUnit`, `SharedCounterGroup.countKind` (Task 13).
- Produces: web `ledgerPill(group: Pick<SharedCounterGroup, 'name' | 'unit' | 'countKind' | 'defaultLogAmount'>): { label: string; ariaLabel: string; opensDetail: boolean; amount: number }`; `CounterLoggedEvent.kind: CountKind`; iOS `enum CounterPillAction: Equatable { case log(CountValue); case openDetail }`, `ProfileHomeViewModel.pillAction(for: SharedCounterGroup) -> CounterPillAction` (the hub uses the same static).
- Rows keep the green "met" fill (handoff `ledgers[].rows`); gold is cells / the web modal bar only.

- [ ] **Step 1: Failing tests.** `ledgerPill.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { ledgerPill } from '../ledgerPill';

describe('ledgerPill', () => {
  it('continuous with a remembered amount logs it', () => {
    expect(ledgerPill({ name: 'Miles', unit: 'mi', countKind: 'continuous', defaultLogAmount: 3.1 }))
      .toEqual({ label: '+ Log 3.1', ariaLabel: 'Log 3.1 mi for Miles', opensDetail: false, amount: 3.1 });
  });
  it('duration labels without a unit', () => {
    expect(ledgerPill({ name: 'Practice', unit: 'guitar', countKind: 'duration', defaultLogAmount: 30 }))
      .toMatchObject({ label: '+ Log 30m', ariaLabel: 'Log 30m for Practice' });
  });
  it('a never-logged continuous counter opens Counter Detail', () => {
    expect(ledgerPill({ name: 'Miles', unit: 'mi', countKind: 'continuous', defaultLogAmount: null }))
      .toMatchObject({ label: '+ Log', opensDetail: true, ariaLabel: 'Log Miles' });
  });
  it('discrete is unchanged', () => {
    expect(ledgerPill({ name: 'Push-ups', unit: 'push-ups', countKind: 'discrete', defaultLogAmount: null }))
      .toEqual({ label: '+ Log', ariaLabel: 'Log 1 push-ups for Push-ups', opensDetail: false, amount: 1 });
  });
});
```

iOS `ProfileHomeViewModelTests` (+case):

```swift
    func testPillActionPerKind() {
        func group(_ kind: CountKind, _ d: CountValue?) -> SharedCounterGroup {
            SharedCounterGroup(counterId: "c", name: "Miles", action: "Run", unit: "mi", lifetime: 148.6, defaultLogAmount: d,
                               tasks: [], taskCount: 0, boardCount: 0, activeTaskCount: 0, countKind: kind)
        }
        XCTAssertEqual(ProfileHomeViewModel.pillAction(for: group(.continuous, nil)), .openDetail)
        XCTAssertEqual(ProfileHomeViewModel.pillAction(for: group(.duration, 30)), .log(30))
        XCTAssertEqual(ProfileHomeViewModel.pillAction(for: group(.discrete, nil)), .log(1))
    }
```

(memberwise order of `SharedCounterGroup` — `SharedCounterGroups.swift:54-67` — with Task 13's `var countKind: CountKind = .discrete` declared LAST.)

- [ ] **Step 2: Run — FAIL.** `WEB_TEST ledgerPill` / `IOS_TEST -only-testing:OYBCTests/ProfileHomeViewModelTests`

- [ ] **Step 3: Implement web.** `ledgerPill.ts`:

```ts
import { formatCountWithUnit, logPillLabel, logPillOpensDetail, type SharedCounterGroup } from '@oybc/shared';

/** The "+ Log" pill's label, accessible name and action (docs/COUNTER_KINDS.md §5). */
export function ledgerPill(group: Pick<SharedCounterGroup, 'name' | 'unit' | 'countKind' | 'defaultLogAmount'>): {
  label: string; ariaLabel: string; opensDetail: boolean; amount: number;
} {
  const opensDetail = logPillOpensDetail(group.countKind, group.defaultLogAmount);
  const amount = group.defaultLogAmount ?? 1;
  return {
    label: logPillLabel(group.countKind, group.defaultLogAmount),
    ariaLabel: opensDetail ? `Log ${group.name}` : `Log ${formatCountWithUnit(amount, group.countKind, group.unit)} for ${group.name}`,
    opensDetail,
    amount,
  };
}
```

`CounterLedgerCard`: `const pill = ledgerPill(group); const lifetimeStr = formatCountTotal(group.lifetime, group.countKind);`; the pill button `onClick={() => (pill.opensDetail ? openDetail() : void handleLog())}`, `aria-label={pill.ariaLabel}`, text `{pill.label}`; `handleLog` logs `pill.amount` and reports `onLogged({ counterId, amount: pill.amount, unit: group.unit ?? '', kind: group.countKind })`; `LedgerTaskRow` gets `kind` and renders `formatCount(task.logged, kind)` / `formatCount(task.goal, kind)` (aria text via `formatCountWithUnit`). `ProfileCounterRow` mirrors: `const pill = ledgerPill(group); const navigate = useNavigate();` (ProfilePage is inside the router) — pill `onClick={() => (pill.opensDetail ? navigate(`/profile/counters/${group.counterId}`) : void handleLog())}`; member values and the `ALL-TIME` total use `formatCount` / `formatCountTotal` with `group.countKind`. `CountersHubPage` / `ProfilePage` toast renders pass `kind={toast.kind}` (store `kind` from the `CounterLoggedEvent`). Delete the three caption `<p>`s.

- [ ] **Step 4: Implement iOS.** `CounterLogAmount.swift` gains `enum CounterPillAction: Equatable { case log(CountValue); case openDetail }`; `ProfileHomeViewModel`:

```swift
    /// The "+ Log" pill's action (docs/COUNTER_KINDS.md §5) — shared by the hub.
    static func pillAction(for group: SharedCounterGroup) -> CounterPillAction {
        CounterLogAmount.pillOpensDetail(kind: group.countKind, defaultLogAmount: group.defaultLogAmount)
            ? .openDetail : .log(group.defaultLogAmount ?? 1)
    }
```

`ProfileView.swift:131` → `onLog: { group in if ProfileHomeViewModel.pillAction(for: group) == .openDetail { navigateToCounterId = group.counterId } else { handleLog(group) } }`; `CountersHubView.handleLog(group:)` starts with `if ProfileHomeViewModel.pillAction(for: group) == .openDetail { navigateToCounterId = group.counterId; return }`. `SharedCounterLedgerCard`: `Text(CounterLogAmount.pillLabel(kind: group.countKind, defaultLogAmount: group.defaultLogAmount))`; VoiceOver `"Log \(formatCountWithUnit(logAmount, kind: group.countKind, unit: group.unit)) for \(group.name)"`; `:81`, `:136` → `formatCountTotal(group.lifetime, kind: group.countKind)`; `:100`, `:189` a11y lifetime → `formatCountTotal`; `:236`, `:270` member values → `formatCount(…, kind: group.countKind)`. Toasts raised by the hub / Profile pass `kind: group.countKind` to `CounterLogToastView`. Delete the three caption `Text`s.

- [ ] **Step 5: Run** tests PASS; `WEB_CHECK`; snapshots per Files (read `testHubContinuousDuration*` vs handoff B4 ledgers: `148.6 ALL-TIME`, `+ Log 3.1`, `112h 15m`, `+ Log 30m`). Append to `counter-kinds-logging.spec.ts`:

```ts
  test('hub: a never-logged Continuous counter pill opens Counter Detail; a remembered one logs it', async ({ page }) => {
    await seedTask(page, { id: 'f2000000-0000-0000-0000-000000000001', title: 'Run miles', type: 'counting', action: 'Run', unit: 'miles', isCounter: true, countKind: 'continuous', currentCount: 148.6 });
    await page.goto('/profile/counters?__oybc_test_bypass=1');
    await page.getByRole('button', { name: 'Log Run miles', exact: true }).click(); // the pill, not the card's own open button
    await expect(page).toHaveURL(/\/profile\/counters\/f2000000-0000-0000-0000-000000000001/);
  });
```

`WEB_E2E e2e/profile-home.spec.ts e2e/counter-kinds-logging.spec.ts` (update any `profile-home` assertion on the removed empty-state body by deleting it).

- [ ] **Step 6: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): hub + Profile '+ Log' pills carry the amount per kind (never-logged opens Counter Detail); grouped totals (R7); drop hub/Profile counter captions (#548 85-90) (PR 4 Task 17)"
```

---

### Task 18: B4 — Counter Detail per kind (extract `CounterDetailLogCard`)

**Files:**
- Create: `apps/ios/OYBC/Views/ProfileTab/Components/CounterDetailLogCard.swift` — `CounterDetailLogCard` (view) + `CounterDetailLogCard.Model` (pure), moved out of `CounterDetailView.swift` (`selectedAmount`/`isCustomActive`/`customOpen`/`customDraft` state `:303-306`, `AmountChipOption`/`chips`/`selectedChipIndex` `:351-372`, chip actions `:374-395`, `logCard` `:597-638`, `chipRow` `:640-670`, `customInputRow` `:671-685`, `logActionsRow` `:686-730`)
- Modify: `apps/ios/OYBC/Views/ProfileTab/CounterDetailView.swift` — uses the card; R7 `.formatted()` at `:497`, `:548`, `:555-558`, `:572`, `:779`, `:819`, `:825`, `:884` → `formatCountTotal` / `formatCount` / `formatCountWithUnit` with `group.countKind`; kind-blind `:525`, `:806`; delete #548 rows 80 (`:426-430` explainer), 82 (`:875-876` member captions), 84 (`recentWeeksCard` `:832-842` — a stub whose only content is the caption; delete the card and its call site / section label). The file drops ~200 lines — below 1000, so Task 21 deletes its allow-list entry.
- Create: `apps/web/src/components/counters/counterDetailCaption.ts` (`buildTaskCardCaption`, moved out of `CounterDetailTaskCard.tsx:121-141`, kind-aware) + `__tests__/counterDetailCaption.test.ts`
- Modify: `apps/web/src/components/counters/CounterDetailTaskCard.tsx:60-120` (values `formatCount`; caption from the helper; delete #548 row 81 `:69-73` caption `<div>`)
- Modify: `apps/web/src/pages/CounterDetailPage.tsx:74-170` (chip state per kind), `:239-425` (hero `formatCountTotal` — R7 `:239`; daily/milestone/today stat — R7 `:310`, `:334-342`; chips `hubChips(group.countKind)`; custom input → `GoalEntry`; Add / Remove labels), delete rows 79 (`:430-433` explainer `<p>`) and 83 (`:456-462` history stub card)
- Test: `apps/ios/OYBCTests/CounterDetailLogCardTests.swift` (create), snapshots, `apps/web/e2e/counter-kinds-logging.spec.ts` (+1 case)
- Re-record (intentional — rows 80/82/84 and the card move): `CountersHubSnapshotTests/testDetailSingleMember{Light,Dark}`, `testDetailCustomChipActive{Light,Dark}`, `testDetailLoggingStateLight`. Add `testDetailContinuous{Light,Dark}`, `testDetailDurationLight` (handoff `logCards[]` / `detailCards[]`).

**Interfaces:**
- Consumes: `hubChips`, `initialLogSelection`, `customChipLabel`, `formatCountTotal`, `formatCountWithUnit`, `GoalEntry(View)`.
- Produces: iOS `struct CounterDetailLogCard.Model: Equatable { let kind: CountKind; let unit: String; let chips: [CounterLogAmount.LogChip]; var selectedAmount: CountValue; var isCustom: Bool; init(kind:unit:defaultLogAmount:initialAmount:initialCustom:); var selectedChipIndex: Int?; func chipLabel(at:) -> String; var addLabel: String; var removeA11y: String; mutating func select(_:); mutating func confirmCustom(_ draft: String) -> Bool }`; `CounterDetailLogCard(group:activeMemberCount:isLogging:logError:model:onLog:)`; web `buildTaskCardCaption(task: SharedCounterMemberTask, unit: string, kind: CountKind): string`.
- Counter Detail keeps its custom row + OK (handoff `logCards[].customOpen` draws "OK") — the one log surface where the fixed chips make the field secondary; Counter Detail logs ALWAYS persist the amount as the default (R2, unchanged).

- [ ] **Step 1: Failing tests.** `counterDetailCaption.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { buildTaskCardCaption } from '../counterDetailCaption';

const member = (o: object) => ({ taskId: 't', taskTitle: 'Run 26.2 mi', logged: 12.4, goal: 26.2, met: false, over: 0, window: undefined, ...o }) as never;

describe('buildTaskCardCaption', () => {
  it('continuous to go', () => expect(buildTaskCardCaption(member({}), 'mi', 'continuous')).toBe('13.8 mi to go'));
  it('continuous over', () => expect(buildTaskCardCaption(member({ logged: 28.4, met: true, over: 2.2 }), 'mi', 'continuous')).toBe('✓ Goal met · 2.2 over'));
  it('duration to go has no unit', () => expect(buildTaskCardCaption(member({ logged: 270, goal: 630 }), '', 'duration')).toBe('6h to go'));
  it('discrete unchanged', () => expect(buildTaskCardCaption(member({ logged: 3, goal: 10 }), 'pages', 'discrete')).toBe('7 pages to go'));
});
```

(`SharedCounterMemberTask`'s exact fields are in `packages/shared/src/algorithms/sharedCounterGroups.ts:46-80`; the cast keeps the fixture to the fields the caption reads.) `CounterDetailLogCardTests.swift`:

```swift
import XCTest
@testable import OYBC

final class CounterDetailLogCardTests: XCTestCase {
    func testContinuousCustomDefault() {
        let m = CounterDetailLogCard.Model(kind: .continuous, unit: "mi", defaultLogAmount: 3.1)
        XCTAssertEqual(m.chips.map(\.label), ["0.5", "1", "5", "#"])
        XCTAssertTrue(m.isCustom)
        XCTAssertEqual(m.selectedChipIndex, 3)
        XCTAssertEqual(m.chipLabel(at: 3), "#3.1")
        XCTAssertEqual(m.addLabel, "＋ Add 3.1 mi")
    }
    func testDurationPresetDefault() {
        let m = CounterDetailLogCard.Model(kind: .duration, unit: "guitar", defaultLogAmount: 30)
        XCTAssertEqual(m.chips.map(\.label), ["15m", "30m", "1h", "#"])
        XCTAssertEqual(m.selectedChipIndex, 1)
        XCTAssertEqual(m.addLabel, "＋ Add 30m")
    }
    func testConfirmCustomParsesAtTheKind() {
        var m = CounterDetailLogCard.Model(kind: .continuous, unit: "mi", defaultLogAmount: nil)
        XCTAssertFalse(m.confirmCustom("3.125"))
        XCTAssertTrue(m.confirmCustom("4,9"))
        XCTAssertEqual(m.selectedAmount, 4.9)
        XCTAssertTrue(m.isCustom)
    }
    func testDiscreteUnchanged() {
        let m = CounterDetailLogCard.Model(kind: .discrete, unit: "pages", defaultLogAmount: 10)
        XCTAssertEqual(m.chips.map(\.label), ["1", "10", "25", "#"])
        XCTAssertEqual(m.selectedChipIndex, 1)
        XCTAssertEqual(m.addLabel, "＋ Add 10")
    }
}
```

- [ ] **Step 2: Run — FAIL.** `WEB_TEST counterDetailCaption` / `IOS_TEST -only-testing:OYBCTests/CounterDetailLogCardTests`

- [ ] **Step 3: Pure move first (iOS).** Move the listed members verbatim into `CounterDetailLogCard.swift` (a `struct CounterDetailLogCard: View` taking `group`, `activeMemberCount`, `isLogging`, `logError`, `onLog`, plus the two snapshot seams `initialSelectedAmount` / `initialCustomActive` forwarded from `CounterDetailContent`'s init); `CounterDetailContent` renders `CounterDetailLogCard(…)` where `logCard` was. `xcodegen generate`; run `IOS_SNAP -only-testing:OYBCSnapshotTests/CountersHubSnapshotTests` before and after the move and compare the red SETS (CLAUDE.md: `CountersHub` carries standing reds) — no `testDetail*` may change state; a pure move renders identically. Commit nothing yet.

- [ ] **Step 4: Make it kind-aware (iOS).** Add the `Model`:

```swift
extension CounterDetailLogCard {
    /// Chips + selection for the Log card (docs/COUNTER_KINDS.md §5). Unit-tested.
    struct Model: Equatable {
        let kind: CountKind
        let unit: String
        let chips: [CounterLogAmount.LogChip]
        var selectedAmount: CountValue
        var isCustom: Bool

        init(kind: CountKind, unit: String, defaultLogAmount: CountValue?, initialAmount: CountValue? = nil, initialCustom: Bool = false) {
            self.kind = kind
            self.unit = unit
            chips = CounterLogAmount.hubChips(kind: kind)
            let sel = CounterLogAmount.initialSelection(kind: kind, chips: chips, defaultLogAmount: defaultLogAmount)
            selectedAmount = initialAmount ?? sel.amount
            isCustom = initialCustom || (initialAmount == nil && sel.isCustom)
        }

        var selectedChipIndex: Int? {
            isCustom ? chips.count - 1 : chips.firstIndex { $0.value == selectedAmount }
        }
        /// The selected `#` chip shows the custom amount: "#3.1" for the new
        /// kinds, the bare number for Discrete (today's Detail, `CounterDetailView.swift:651`).
        func chipLabel(at i: Int) -> String {
            guard chips[i].value == nil, i == selectedChipIndex else { return chips[i].label }
            return kind == .discrete ? formatCount(selectedAmount, kind: .discrete) : CounterLogAmount.customChipLabel(selectedAmount, kind: kind)
        }
        var addLabel: String {
            kind == .discrete ? "＋ Add \(formatCount(selectedAmount, kind: .discrete))" : "＋ Add \(formatCountWithUnit(selectedAmount, kind: kind, unit: unit))"
        }
        var removeA11y: String { "Remove \(formatCountWithUnit(selectedAmount, kind: kind, unit: unit))" }
        mutating func select(_ v: CountValue) { selectedAmount = v; isCustom = false }
        mutating func confirmCustom(_ draft: String) -> Bool {
            guard let v = CounterLogAmount.parseCustom(draft, kind: kind) else { return false }
            selectedAmount = v; isCustom = true
            return true
        }
    }
}
```

The card holds `@State private var model: Model` and `customOpen` / `customDraft`; chips iterate `model.chips` with `model.chipLabel(at:)`; the custom row is `GoalEntryView(kind: model.kind, text: $customDraft, placeholder: "Amount", suffix: model.unit.isEmpty || model.kind == .duration ? nil : model.unit)` + the existing OK (`if model.confirmCustom(customDraft) { customOpen = false }`; disabled while `CounterLogAmount.parseCustom(customDraft, kind: model.kind) == nil`); `logActionsRow` uses `model.selectedAmount`, `model.addLabel`, `model.removeA11y`. The header line `Log \(unitLabel)` keeps; `counts toward N active tasks` keeps (a value, not a mechanic). Then the `CounterDetailView` R7 / kind-blind sites (`formatCountTotal(group.lifetime, kind: group.countKind)` for the hero and its a11y; milestone `"\(formatCountWithUnit(remaining, kind: k, unit: unit)) to \(formatCountTotal(next, kind: k))"`; TODAY stat `formatCountTotal`; member values `formatCount`; captions `"\(formatCountWithUnit(remaining, kind: k, unit: unit)) to go"` and `"✓ Goal met · \(formatCount(member.over, kind: k)) over"`), and delete rows 80 / 82 / 84.

- [ ] **Step 5: Implement web.** `counterDetailCaption.ts`:

```ts
import { formatCount, formatCountWithUnit, type CountKind, type SharedCounterMemberTask } from '@oybc/shared';

/** A Counter Detail task card's caption (R2 order: remaining first, "ends {window}" last). */
export function buildTaskCardCaption(task: SharedCounterMemberTask, unit: string, kind: CountKind): string {
  if (task.met && task.over > 0) return `✓ Goal met · ${formatCount(task.over, kind)} over`;
  if (task.met) return '✓ Goal met this window';
  const base = `${formatCountWithUnit(Math.max(0, task.goal - task.logged), kind, unit)} to go`;
  return task.window ? `${base} · ends ${task.window}` : base;
}
```

`CounterDetailTaskCard` gets `kind` (from `group.countKind` at the call site), uses `buildTaskCardCaption(task, unitStr, kind)`, `formatCount(task.logged, kind)` / `formatCount(task.goal, kind)` and drops the `:69-73` caption. `CounterDetailPage`: `const kind = group?.countKind ?? 'discrete'; const chips = hubChips(kind);` replaces `buildAmountChipOptions()`; the seeding effect sets `const sel = initialLogSelection(kind, chips, group.defaultLogAmount); setSelectedAmount(sel.amount); setIsCustomActive(sel.isCustom);`; the custom input → `<GoalEntry kind={kind} value={customDraft} onChange={setCustomDraft} aria-label="Custom amount" placeholder="Amount" suffix={kind === 'duration' ? undefined : group?.unit} dense onEnter={confirmCustomInput} />`; `confirmCustomInput` parses with `parseCustomLogAmount(customDraft, kind)` and `openCustomInput` seeds `formatCountForInput(selectedAmount, kind)`; the selected `#` chip shows `customChipLabel(selectedAmount, kind)` for the new kinds (discrete keeps the bare number, as today); hero `formatCountTotal(group.lifetime, kind)`; milestone / today stat `formatCountTotal`; `＋ Add {kind === 'discrete' ? selectedAmount : formatCountWithUnit(selectedAmount, kind, unitStr)}`; Add / Remove aria via `formatCountWithUnit`; toasts carry `kind`. Delete the row 79 `<p>` and the row 83 history card.

- [ ] **Step 6: Run** `WEB_TEST counterDetailCaption CounterDetail amountChips` / `IOS_TEST -only-testing:OYBCTests/CounterDetailLogCardTests` — PASS; `WEB_CHECK`; snapshots per Files (read vs handoff `logCards[]`: Continuous hero `148.6`, chips `0.5 · 1 · 5 · #3.1`, `＋ Add 3.1 mi`; Duration hero `112h 15m`, `30m` selected). Append to `counter-kinds-logging.spec.ts`:

```ts
  test('Counter Detail: a Continuous counter logs 0.5', async ({ page }) => {
    await seedTask(page, { id: 'f3000000-0000-0000-0000-000000000001', title: 'Run miles', type: 'counting', action: 'Run', unit: 'miles', isCounter: true, countKind: 'continuous', currentCount: 148.6 });
    await page.goto('/profile/counters/f3000000-0000-0000-0000-000000000001?__oybc_test_bypass=1');
    await page.getByRole('group', { name: 'Log amount' }).getByRole('button', { name: '0.5', exact: true }).click();
    await page.getByRole('button', { name: 'Add 0.5 miles' }).click();
    await expect(page.getByText('149.1', { exact: true })).toBeVisible();
  });
```

- [ ] **Step 7: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): Counter Detail per kind — fixed chips per kind, decimal / h:m custom entry, kind-aware cards and milestone; extract CounterDetailLogCard; drop detail captions + history stub (#548 79-84) (PR 4 Task 18)"
```

---

### Task 19: C1 — board cells: fit tiers, ×goal tag, gold overshoot

**Files:**
- Modify: `apps/web/src/components/board/cellModel.ts:20-74` (`TaskCellModelInput.countKind?: CountKind`; `count: { cur, max, kind }`; `taskCellLabel` passes the kind to the title — the ONE edit of that function, Task 20 does not touch it; + `cellCountFit`)
- Modify: `apps/web/src/components/board/RisoBoardCell.tsx:5-60` (`BoardCellModel.count.kind`; `RisoBoardCellProps.cellSize?: number`, default 88), `:107-128` (tag, tier text, `.over`)
- Modify: `apps/web/src/components/board/RisoBoard.module.css:140-160` (`.cbar.over > i { background: var(--riso-gold); } .cbar.over > span { color: var(--riso-ink-static); }` — an overshoot bar is 100% gold, and adaptive `--riso-ink` turns cream on gold in dark mode, `reference_riso_adaptive_ink_fill_darkmode`)
- Modify: `apps/web/src/components/board/RisoBoard.tsx:52-56` (`<RisoBoardCell … cellSize={cellSize} />`), `apps/web/src/components/BoardPlaySurface.tsx:774-790` (`toBoardCellModel({ …, countKind: resolveFamilyCountKind(task, (id) => taskMap[id]) })` and `<RisoBoardCell … cellSize={90} />` — matches `RisoBoardGrid cellSize={90}` at `:670`; budget +2)
- Modify: `apps/web/src/components/board/risoBoardCells.ts:96-105`, `apps/web/src/hooks/useSquaresEditDraft.ts:249-260`, `apps/web/src/components/wizard/BoardWizardPreviewStep.tsx:101-106` (each passes `countKind: resolveFamilyCountKind(task, (id) => taskMap[id])`; R19 for the wizard preview — the pending linked task resolves its root through the preview's task map)
- Modify: `apps/ios/OYBC/Views/BoardsTab/Components/RisoBoardPlayCell.swift:37-38` (`var countKind: CountKind = .discrete` right after `maxCount`), `:146-160` (VoiceOver), `:245-255` (×tag), `:336-386` (three-tier `ViewThatFits`, gold overshoot)
- Modify: `apps/ios/OYBC/Views/BoardsTab/BoardPlayView.swift:1321-1332` (`countKind: resolveFamilyCountKind(t, lookup: { taskMap[$0] })` after `maxCount:`; budget +2), `apps/ios/OYBC/Views/BoardsTab/SquaresEditGrid.swift:277-287`, `apps/ios/OYBC/Views/BoardsTab/RearrangeGrid.swift:344-352` (the wizard preview renders through `RearrangeGrid`), each adding `countKind: task.map { resolveFamilyCountKind($0, lookup: { taskMap[$0] }) } ?? .discrete`
- Test: `apps/web/src/components/board/__tests__/cellModel.test.ts` (+`cellCountFit` table, +R19 case), `apps/web/src/components/board/__tests__/RisoBoardCell.test.ts` (+3 cases), `apps/ios/OYBCSnapshotTests/RisoBoardCellKindsSnapshotTests.swift` (create)
- Must stay GREEN (discrete, no overshoot): `RisoPlayBoardSnapshotTests/*`, `RisoBoardGridSnapshotTests/*`, `SquaresEditSnapshotTests/*`, `RearrangeGridSnapshotTests/*`, `WindowedCompletionSealingSnapshotTests/testSealedGrid*`, `WizardArrangePreviewSnapshotTests/*` — with ONE allowed exception: a discrete cell whose bar used to HIDE its count (too narrow for `cur/max`) now shows the `cur` tier. That is the designed change; re-record exactly those baselines and name each in the commit body. Any other diff is a regression to fix.

**Interfaces:**
- Consumes: `formatCount`, `resolveFamilyCountKind`.
- Produces: web `BoardCellModel.count?: { cur: number; max: number; kind: CountKind }`; `TaskCellModelInput.countKind?: CountKind` (absent → `resolveCountKind(task)`); `cellCountFit(cur: number, max: number, kind: CountKind, cellSize: number): { text: string; tier: 'full' | 'cur' | 'none' }` (inner width `cellSize − 25`, char width `9.5 × 0.56` px — the web bar's 9.5px head font; deterministic from the known cell size, never measured after paint); `RisoBoardCellProps.cellSize?: number`; iOS `RisoBoardPlayCell.countKind`.

- [ ] **Step 1: Failing tests.** `cellModel.test.ts`:

```ts
describe('cellCountFit (Review Focus 5)', () => {
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

it('R19: a pending linked task renders its root kind', () => {
  const root = task({ id: 'root', type: TaskType.COUNTING, action: 'Run', unit: 'mi', maxCount: 26.2, countKind: 'continuous' });
  const pending = task({ id: 'p', type: TaskType.COUNTING, action: 'Run', unit: 'mi', maxCount: 6.2, sharedCounterId: 'root', baseline: 0 });
  const model = toBoardCellModel({ key: 'p', task: pending, done: false, currentCount: 3.1,
    countKind: resolveFamilyCountKind(pending, (id) => ({ root } as Record<string, Task>)[id]) });
  expect(model.count).toEqual({ cur: 3.1, max: 6.2, kind: 'continuous' });
});
```

(`task(overrides)` is the file's builder, `cellModel.test.ts:5`; import `cellCountFit` and `resolveFamilyCountKind` beside the existing imports. Arithmetic: room = (90 − 25) / 5.32 = 12.2 chars, (58 − 25) / 5.32 = 6.2.) `RisoBoardCell.test.ts`:

```ts
const renderCell = (over: Partial<BoardCellModel>, cellSize: number) =>
  renderToStaticMarkup(React.createElement(RisoBoardCell, { cell: makeCell({ type: 'counting', ...over }), cellSize }));

it('an overshoot continuous cell keeps its real value, a gold bar and the ×goal tag', () => {
  const html = renderCell({ label: 'Run 26.2 mi', done: true, count: { cur: 28.4, max: 26.2, kind: 'continuous' } }, 90);
  expect(html).toContain('28.4/26.2');
  expect(html).toContain(`class="${styles.cbar} ${styles.over}"`);
  expect(html).toContain('×26.2');
});
it('a duration tag and the cur tier at 90px', () => {
  const html = renderCell({ label: 'Code 500h', count: { cur: 6735, max: 30000, kind: 'duration' } }, 90);
  expect(html).toContain('×500h');
  expect(html).toContain('>112h 15m<');
  expect(html).not.toContain('112h 15m/500h');
});
it('fill only when even cur does not fit', () => {
  const html = renderCell({ label: 'Code 500h', count: { cur: 6735, max: 30000, kind: 'duration' } }, 58);
  expect(html).not.toContain('112h');
});
```

(`makeCell` and `styles` are the file's own, `RisoBoardCell.test.ts:5,20`.) iOS `RisoBoardCellKindsSnapshotTests.swift`:

```swift
import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Handoff C1 worst cases at 3×3 (113pt), 4×4 (83pt), 5×5 (65pt) on a 393pt phone.
final class RisoBoardCellKindsSnapshotTests: XCTestCase {
    private let recordMode: SnapshotTestingConfiguration.Record? = .missing
    private struct Worst { let title: String; let kind: CountKind; let cur: CountValue; let max: CountValue; var done = false; var shared = false }
    private let worst: [Worst] = [
        .init(title: "Run 26.2 mi", kind: .continuous, cur: 12.75, max: 26.2),
        .init(title: "Swim 1000 m", kind: .continuous, cur: 128.5, max: 1000),
        .init(title: "Practice 10h", kind: .duration, cur: 270, max: 600),
        .init(title: "Code 500h", kind: .duration, cur: 6735, max: 30000),
        .init(title: "Run 26.2 mi", kind: .continuous, cur: 28.4, max: 26.2, done: true),
        .init(title: "Read 300 pages", kind: .discrete, cur: 120, max: 300, shared: true),
    ]
    private func grid(_ n: Int, cell: CGFloat) -> some View {
        let total = n * n
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: 6), count: n), spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                if i == total / 2 {
                    RisoBoardPlayCell(title: "FREE", taskType: .normal, isCompleted: false, isCenter: true)
                } else {
                    let w = worst[i % worst.count]
                    RisoBoardPlayCell(title: w.title, taskType: .counting, isCompleted: w.done,
                                      currentCount: w.cur, maxCount: w.max, countKind: w.kind, isSharedCounter: w.shared)
                }
            }
        }
        .frame(width: CGFloat(n) * cell + CGFloat(n - 1) * 6)
        .padding(12)
        .background(Color.risoPaper)
    }
    private func snap(_ n: Int, _ cell: CGFloat, dark: Bool, testName: String = #function, line: UInt = #line) {
        let side = CGFloat(n) * cell + CGFloat(n - 1) * 6 + 24
        assertSnapshot(of: grid(n, cell: cell), as: .image(layout: .fixed(width: side, height: side), traits: .init(userInterfaceStyle: dark ? .dark : .light)),
                       record: recordMode, testName: testName, line: line)
    }
    func testGrid3Light() { snap(3, 113, dark: false) }
    func testGrid3Dark() { snap(3, 113, dark: true) }
    func testGrid4Light() { snap(4, 83, dark: false) }
    func testGrid4Dark() { snap(4, 83, dark: true) }
    func testGrid5Light() { snap(5, 65, dark: false) }
    func testGrid5Dark() { snap(5, 65, dark: true) }
}
```

- [ ] **Step 2: Run — FAIL.** `WEB_TEST cellModel RisoBoardCell` / `IOS_SNAP -only-testing:OYBCSnapshotTests/RisoBoardCellKindsSnapshotTests` (build error: no `countKind`)

- [ ] **Step 3: Implement web.** `cellModel.ts`:

```ts
const BAR_CHAR_PX = 9.5 * 0.56;
const BAR_INSET_PX = 25;

/**
 * The counting bar's text tier (docs/COUNTER_KINDS.md §5): `cur/max`, else
 * `cur` (the ×tag already carries the goal), else nothing (fill only).
 * Deterministic from the known cell size — no measurement, no post-paint change.
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

`taskCellLabel` → `generateCounterTaskTitle(task.action ?? '', task.maxCount ?? 0, task.unit ?? '', undefined, resolveCountKind(task))`; `toBoardCellModel` → `count: type === 'counting' ? { cur: input.currentCount ?? 0, max: task.maxCount ?? 0, kind: input.countKind ?? resolveCountKind(task) } : undefined`. `RisoBoardCell` (`cellSize = 88` default prop):

```tsx
      {(cell.type === 'counting' || cell.type === 'compound') && (
        <span className={`${styles.tag} ${cell.type === 'counting' ? styles.counting : styles.compound}`}>
          {cell.type === 'counting' && cell.count ? `×${formatCount(cell.count.max, cell.count.kind)}` : '≡'}
        </span>
      )}
      <span className={styles.cellText}>{cell.label}</span>
      {cell.type === 'counting' && cell.count && (() => {
        const over = cell.count.max > 0 && cell.count.cur > cell.count.max;
        const fit = cellCountFit(cell.count.cur, cell.count.max, cell.count.kind, cellSize);
        return (
          <span className={[styles.cbar, over ? styles.over : ''].filter(Boolean).join(' ')}>
            <i style={{ width: `${cell.count.max > 0 ? Math.min(100, Math.round((cell.count.cur / cell.count.max) * 100)) : 0}%` }} />
            {fit.tier !== 'none' && <span>{fit.text}</span>}
          </span>
        );
      })()}
```

Wire `cellSize` / `countKind` at the listed call sites.

- [ ] **Step 4: Implement iOS.** `RisoBoardPlayCell`: `var countKind: CountKind = .discrete` after `maxCount`; `private var barKind: CountKind { taskType == .counting ? countKind : .discrete }`; VoiceOver `formatCount(…, kind: countKind)`; tag `Text("×\(formatCount(maxCount, kind: countKind))")`; `bottomProgressBar` — the fill colour `taskType == .counting && maxCount > 0 && currentCount > maxCount ? Color.risoGold : color`, and the text:

```swift
            ViewThatFits(in: [.horizontal, .vertical]) {
                barText("\(formatCount(cur, kind: barKind))/\(formatCount(max, kind: barKind))")
                barText(formatCount(cur, kind: barKind))
                Color.clear.frame(width: 0, height: 0)
            }
            .frame(maxWidth: .infinity)
```

with

```swift
    private func barText(_ s: String) -> some View {
        Text(s).font(.risoHead(9, .extraBold)).foregroundStyle(Color.risoInk).lineLimit(1).fixedSize()
    }
```

(`risoInk` on gold: in dark mode the adaptive ink is cream — use `Color.risoInkStatic` for the text when the fill is gold, `reference_riso_dark_mode_tokens`.) Wire `countKind:` at the three call sites.

- [ ] **Step 5: Run** web tests + `WEB_CHECK`; `IOS_SNAP` — record the six new baselines; run the must-stay-green classes; handle the `cur`-tier exception as stated; read all new PNGs vs handoff C1 (5×5 @65: `112h 15m` fill only; the overshoot cell's bar gold and full with `28.4/26.2` or `28.4`). `node scripts/check-file-sizes.mjs`.

- [ ] **Step 6: Playwright validation.** Seed a 5×5 board with the worst-case tasks (reuse `counter-kinds-logging.spec.ts`'s seeding pattern in a throwaway MCP session) → screenshot light/dark → `.playwright-mcp/task19-c1-5x5-{light,dark}.png` vs handoff C1 web (88px).

- [ ] **Step 7: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): board cells format per kind with cur/max → cur → fill tiers, ×goal tag, gold overshoot fill; previews resolve the family kind (R19) (PR 4 Task 19)"
```

---

### Task 20: C2 — rows, subtitles and library rows read the kind

**Files:**
- Create: `apps/web/src/components/counters/counterRowTitle.ts` — the ONE web helper the three counting-subtitle sites share (extract-at-three)
- Modify: `apps/web/src/pages/tasks/TaskRow.tsx:170-182` (`computeSubtitle`), `apps/web/src/components/wizard/TaskRow.tsx:83-89` (`buildTaskSubtitle`), `apps/web/src/components/compoundWizard/SubtaskCard.tsx:384-390` (`buildTaskSubtitle`)
- Modify: `apps/web/src/pages/tasks/taskCountDisplay.ts:55-64` (`computeStatusLabel` via `formatCount`)
- Modify: `apps/ios/OYBC/Helpers/TaskCountDisplay.swift:61-68` (`countingSubtitle`), `apps/ios/OYBC/Views/TasksTab/Components/RisoTaskRowView.swift:120-121`, `apps/ios/OYBC/Views/CreateTab/Components/RisoLibrarySheetView.swift:429-432`
- Test: `apps/web/src/components/counters/__tests__/counterRowTitle.test.ts` (create), `apps/web/src/pages/tasks/__tests__/taskCountDisplay.test.ts` (+3 cases; create the file if absent), `apps/ios/OYBCTests/TaskCountDisplayTests.swift` (+2 cases; create if absent)
- Add snapshots: `RisoTasksTabSnapshotTests/testRowContinuousLight`, `testRowDurationLight` (handoff `taskRows[]`); existing row baselines stay green

**Interfaces:**
- Consumes: `generateCounterTaskTitle(…, countKind)`, `formatCount`, `countUnitSuffix`, `resolveCountKind`.
- Produces: web `counterRowTitle(task: Pick<Task, 'action' | 'unit' | 'maxCount' | 'countKind'>): string | null` — the auto title from the task's own fields (`Run 26.2 miles`, `Practice 10h 30m`), or null when the fields cannot form one.

- [ ] **Step 1: Failing tests.** `counterRowTitle.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { counterRowTitle } from '../counterRowTitle';

describe('counterRowTitle', () => {
  it('continuous / duration / discrete', () => {
    expect(counterRowTitle({ action: 'Run', unit: 'miles', maxCount: 26.2, countKind: 'continuous' })).toBe('Run 26.2 miles');
    expect(counterRowTitle({ action: 'Practice', unit: '', maxCount: 630, countKind: 'duration' })).toBe('Practice 10h 30m');
    expect(counterRowTitle({ action: 'Read', unit: 'pages', maxCount: 300 })).toBe('Read 300 pages');
  });
  it('null when the fields cannot form a title', () => {
    expect(counterRowTitle({ action: 'Run', unit: '', maxCount: 5 })).toBeNull();
    expect(counterRowTitle({ action: '', unit: 'mi', maxCount: 5 })).toBeNull();
    expect(counterRowTitle({ action: 'Run', unit: 'mi' })).toBeNull();
  });
});
```

`taskCountDisplay.test.ts` (+cases; the module's `CountDisplayTask` slice):

```ts
it('status labels format per kind', () => {
  const base = { type: TaskType.COUNTING, sharedCounterId: null, baseline: null, isCompleted: false } as const;
  expect(computeStatusLabel({ ...base, currentCount: 12.4, maxCount: 26.2, countKind: 'continuous' })).toBe('12.4 / 26.2');
  expect(computeStatusLabel({ ...base, currentCount: 270, maxCount: 630, countKind: 'duration' })).toBe('4h 30m / 10h 30m');
  expect(computeStatusLabel({ ...base, currentCount: 6, maxCount: 10 })).toBe('6 / 10');
});
```

iOS `TaskCountDisplayTests` (+cases):

```swift
    func testCountingSubtitlePerKind() {
        var run = LinkedWindowKit.task("r", maxCount: 26.2, currentCount: 12.4); run.countKind = .continuous; run.unit = "mi"
        XCTAssertEqual(TaskCountDisplay.countingSubtitle(for: run), "Run · 12.4 / 26.2 mi")
        var practice = LinkedWindowKit.task("p", maxCount: 630, currentCount: 270); practice.countKind = .duration; practice.action = "Practice"; practice.unit = ""
        XCTAssertEqual(TaskCountDisplay.countingSubtitle(for: practice), "Practice · 4h 30m / 10h 30m")
    }
```

- [ ] **Step 2: Run — FAIL.** `WEB_TEST counterRowTitle taskCountDisplay` / `IOS_TEST -only-testing:OYBCTests/TaskCountDisplayTests`

- [ ] **Step 3: Implement.** `counterRowTitle.ts`:

```ts
import { countKindNeedsUnit, generateCounterTaskTitle, resolveCountKind, type Task } from '@oybc/shared';

/** The auto counting title from a task's own fields, or null when they cannot form one. */
export function counterRowTitle(task: Pick<Task, 'action' | 'unit' | 'maxCount' | 'countKind'>): string | null {
  const kind = resolveCountKind(task);
  const action = (task.action ?? '').trim();
  const unit = (task.unit ?? '').trim();
  if (!action || task.maxCount === undefined || task.maxCount === null) return null;
  if (countKindNeedsUnit(kind) && !unit) return null;
  return generateCounterTaskTitle(action, task.maxCount, unit, undefined, kind);
}
```

`computeSubtitle` (`TaskRow.tsx:179-181`) → `const t = counterRowTitle(task); if (t) return t;`; both `buildTaskSubtitle`s → `const derived = counterRowTitle(task); if (!derived) return ''; return derived.toLowerCase() === task.title.trim().toLowerCase() ? '' : derived;`. `computeStatusLabel`: `const kind = resolveCountKind(task); … return `${formatCount(current, kind)} / ${formatCount(max, kind)}`;`. iOS `countingSubtitle`:

```swift
    static func countingSubtitle(for task: Task) -> String? {
        let kind = resolveCountKind(task.countKind)
        guard let action = task.action, let max = task.maxCount, (task.unit != nil || kind == .duration) else { return nil }
        return "\(action) · \(formatCount(displayedCount(for: task), kind: kind)) / \(formatCount(max, kind: kind))\(countUnitSuffix(kind, unit: task.unit))"
    }
```

`RisoTaskRowView.subtitle` counting → `guard let action = task.action, let max = task.maxCount else { return nil }; let kind = resolveCountKind(task.countKind); guard countKindNeedsUnit(kind) ? !(task.unit ?? "").isEmpty : true else { return nil }; return "\(action) · goal \(formatCountWithUnit(max, kind: kind, unit: task.unit))"`; `RisoLibrarySheetView.buildSubtitle` counting the same with its `!a.isEmpty` guard kept.

- [ ] **Step 4: Run** tests PASS; `WEB_CHECK`; record the two `RisoTasksTabSnapshotTests` additions (rows `Run 26.2 mi · 12.4 / 26.2`, `Practice 10h 30m · 4h 30m / 10h 30m`); the standing `RisoTasksTab` reds stay the same SET.

- [ ] **Step 5: Commit**

```bash
git add apps/web apps/ios
git commit -m "feat(counters): task rows, library rows and status labels format per kind; one counting-subtitle helper on web (PR 4 Task 20)"
```

---

### Task 21: Kind-blind sweep, linked-counter row, count-formatting guard, caps

**Files:**
- Modify: `apps/web/src/pages/tasks/LinkedCounterCaptionView.tsx:26-55` + `apps/ios/OYBC/Views/TasksTab/Components/LinkedCounterCaptionView.swift:60-130` — #548 rows 91/92: the found state stays a navigation row WITHOUT the "Linked to" label (`{title}` · `{formatCountTotal(lifetime, kind)}{unit suffix}` · ›); the loading and not-found states render nothing (`null` / `EmptyView()`); R7 `:104` → `formatCountTotal`. `LinkedCounterSource` gains `kind: CountKind` (from the root task in `resolveSource`).
- Modify: `apps/web/src/pages/tasks/__tests__/LinkedCounterCaptionView.test.ts` (update to the new contract), `apps/ios/OYBCSnapshotTests/LinkedCounterCaptionSnapshotTests.swift` (re-record `testLinked{Light,Dark}`; `testSourceNotFound{Light,Dark}` become `testSourceNotFoundRendersNothing{Light,Dark}` — a 393×60 frame that must be blank paper; delete the two old PNGs)
- Create: `scripts/audit/check-count-formatting.mjs`, `scripts/audit/count-formatting-allowlist.json`; Modify: `.github/workflows/drift-guardrails.yml` (one step beside `check-file-sizes`)
- Modify: `scripts/audit/file-size-allowlist.json` — set `BoardPlaySurface.tsx`, `BoardPlayView.swift`, `BoardPlayViewModel.swift` to their measured `wc -l`; DELETE the `CounterDetailView.swift` entry (Task 18 took it under 1000)
- Docs: `docs/COUNTER_KINDS.md` Status ("PR 3 #NNN, PR 4 #MMM shipped — feature complete"), strike §7's carried items; `docs/TASK_SYSTEM.md` logging paragraph; CLAUDE.md §Drift guardrails table gains the `check-count-formatting` row

**Interfaces:** `node scripts/audit/check-count-formatting.mjs [--self-test]` — exit 0 clean, 1 on a new offender; allow-list entries are `"<repo-relative path>::<trimmed line>"` strings (a moved line still matches; an edited line re-flags).

- [ ] **Step 1: Failing guard self-test.** `node scripts/audit/check-count-formatting.mjs --self-test` → FAIL (script missing).

- [ ] **Step 2: Implement the guard.**

```js
#!/usr/bin/env node
/**
 * check-count-formatting.mjs — counter kinds drift guard (docs/COUNTER_KINDS.md §5).
 * Every count on screen goes through formatCount / formatCountTotal with the
 * task's REAL kind. Fails on a NEW hard-coded discrete kind or a raw
 * .formatted() / .toLocaleString() on a counting value. Known-intentional
 * sites live in count-formatting-allowlist.json as "path::trimmed line".
 * Run: node scripts/audit/check-count-formatting.mjs [--self-test]
 */
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const COUNT_NAMES = '(?:lifetime|logged|goal|currentCount|maxCount|remaining|todayTotal|over|next|previewCount|amount|selectedAmount)';
const RULES = [
  { ext: '.swift', re: /formatCount(?:ForInput)?\([^)]*kind:\s*\.discrete\)/ },
  { ext: '.swift', re: new RegExp(`\\b${COUNT_NAMES}\\.formatted\\(\\)`) },
  { ext: '.ts', re: /formatCount(?:ForInput)?\([^)]*'discrete'\)/ },
  { ext: '.ts', re: new RegExp(`\\b${COUNT_NAMES}\\)?\\.toLocaleString\\(\\)`) },
];

export function offenders(path, text) {
  const ext = path.endsWith('.swift') ? '.swift' : '.ts';
  return text.split('\n').flatMap((line) =>
    RULES.some((r) => r.ext === ext && r.re.test(line)) ? [`${path}::${line.trim()}`] : [],
  );
}

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) { if (!['node_modules', '__tests__', 'Fixtures'].includes(name)) walk(p, out); }
    else if (/\.(swift|ts|tsx)$/.test(name) && !/\.test\.tsx?$/.test(name)) out.push(p);
  }
  return out;
}

if (process.argv.includes('--self-test')) {
  const bad = offenders('x.swift', 'Text(formatCount(v, kind: .discrete))\nText(group.lifetime.formatted())');
  const good = offenders('x.ts', "formatCount(v, kind)\nconst n = (12).toFixed(2)");
  if (bad.length !== 2 || good.length !== 0) { console.error('self-test failed', { bad, good }); process.exit(1); }
  console.log('check-count-formatting self-test OK');
  process.exit(0);
}

const allow = new Set(JSON.parse(readFileSync(join(root, 'scripts/audit/count-formatting-allowlist.json'), 'utf8')).entries);
const found = [join(root, 'apps/ios/OYBC'), join(root, 'apps/web/src')]
  .flatMap((d) => walk(d))
  .flatMap((p) => offenders(relative(root, p), readFileSync(p, 'utf8')));
const fresh = found.filter((f) => !allow.has(f));
const stale = [...allow].filter((a) => !found.includes(a));
for (const s of stale) console.log(`note: stale allow-list entry (shrink it): ${s}`);
if (fresh.length) {
  console.error('Counts must render through formatCount / formatCountTotal with the task kind:\n' + fresh.map((f) => `  ${f}`).join('\n'));
  process.exit(1);
}
console.log(`check-count-formatting OK (${found.length} allow-listed)`);
```

`count-formatting-allowlist.json` = `{ "_comment": "Intentional discrete-only / non-count sites (docs/COUNTER_KINDS.md §5). Shrink, never grow to dodge a fix.", "entries": [] }` — then run the script, and for each reported line either fix it (a counting value → the task's kind) or, when it is genuinely discrete by definition (a member-count, a step index, Counter Detail's Discrete `#` chip label), add its `path::line` entry with that reason in the PR body.

- [ ] **Step 3: Run** `node scripts/audit/check-count-formatting.mjs --self-test` PASS, then the full run — fix every offender until it exits 0 with only reasoned allow-list entries.

- [ ] **Step 4: Linked-counter row.** Web test update (`LinkedCounterCaptionView.test.ts`): the found case expects `aria-label="Open Push-ups counter"`, `Push-ups`, `512 reps` and NOT `Linked to`; the not-found and loading cases expect `renderToStaticMarkup(...) === ''`; add a continuous root case (`countKind: 'continuous', currentCount: 1250.5, unit: 'miles'` → `1,250.5 miles`). Implement:

```tsx
export function LinkedCounterCaptionView({ sharedCounterId, sourceTask, onOpenCounter }: LinkedCounterCaptionViewProps): React.ReactElement | null {
  if (!sourceTask || !onOpenCounter) return null;
  const kind = resolveCountKind(sourceTask);
  return (
    <button type="button" className={`${styles.subtaskRow} ${styles.linkedCounterRow}`}
      aria-label={`Open ${sourceTask.title} counter`} onClick={() => onOpenCounter(sharedCounterId)}>
      <span className={styles.linkedCounterTitle}>{sourceTask.title}</span>
      <span className={styles.linkedCounterTotal}>
        {formatCountTotal(sourceTask.currentCount ?? 0, kind)}{countUnitSuffix(kind, sourceTask.unit)}
      </span>
      <span className={styles.linkedCounterChevron} aria-hidden="true">›</span>
    </button>
  );
}
```

(`isLoading` stays in the props type for the caller but is unused — drop it from the destructure; delete `.linkedCounterLabel` / `.linkedCounterCaption` CSS.) iOS: `LinkedCounterSource(title:lifetime:unit:kind:)` (from `resolveCountKind(task.countKind)`); `LinkedCounterCaptionLabel` found branch drops the `Text("Linked to")` and shows `Text(source.title)` + `Text("\(formatCountTotal(source.lifetime, kind: source.kind))\(countUnitSuffix(source.kind, unit: source.unit))")`; the else branch is `EmptyView()`. Re-record per Files and read.

- [ ] **Step 5: Caps + docs.** `wc -l` the three allow-listed files and write the numbers; delete the `CounterDetailView.swift` entry; `node scripts/check-file-sizes.mjs` exits 0 with no "stale" note. Update the docs listed under Files.

- [ ] **Step 6: Commit**

```bash
git add apps scripts .github docs CLAUDE.md
git commit -m "feat(counters): kind-blind sweep + count-formatting drift guard; linked-counter row shows the thing, not a caption (#548 91/92, R7); file-size caps shrunk to the new counts (PR 4 Task 21)"
```

### PR 4 gate

- [ ] Same checks as the PR 3 gate, plus `node scripts/audit/check-count-formatting.mjs`, plus `WEB_E2E e2e/counter-kinds-logging.spec.ts e2e/windowed-completion.spec.ts e2e/late-log-counting.spec.ts e2e/profile-home.spec.ts e2e/squares-editor.spec.ts`.
- [ ] `IOS_SNAP` red SET = the standing reds only; every re-recorded baseline is listed in the PR body with its reason; every #548 row closed in PR 4 (1–9, 79–92) is ticked.
- [ ] Owner device-test relay (CLAUDE.md — never drive the sim), numbered in the PR body: 1. Tasks → new Counting → Continuous "Run 26.2 miles"; 2. put it on a board, tap the square, tap 6.6, +; 3. type 3,1 in the field, +; 4. long-press → "+ Add 3.1 mi"; 5. Edit task → Discrete → the confirm shows "Run 26 miles" and the rounded logged total; 6. a Duration "Practice 10h 30m" on a 5×5 board shows `4h 30m/10h 30m`, `4h 30m`, or fill only, depending on the cell.

---

## Self-review

**Spec coverage** (`docs/COUNTER_KINDS.md` §5 + brief §3 + handoff decisions + owner overrides):

| Requirement | Task |
| --- | --- |
| Kind labels Discrete / Continuous / Duration; never "Amount" | 1 (`COUNT_KIND_LABELS`), 3 (`never says Amount`) |
| Picker states (create / Duration locked out / locked in / linked tag) | 1 (vectors), 2, 3 |
| Goal entry: number pad / decimal pad / h:m wheel / web h·m fields | 4 |
| Member-row steppers per kind, 0.1 / 1-minute steps (R8, R16) | 5 |
| A1 special panel + Tasks-tab quick-add; linked creates take the root kind (R19) | 6 |
| A2 compound sub-task create + edit; inline children carry `countKind` | 7 |
| Only Continuous → Discrete confirms; copy; family line; switch-then-guard once (U7) | 8 |
| A4 Task Detail edit | 9 |
| A3 Board Edit sheet (staged, atomic at Save) | 10 |
| A6 hub New counter | 11 |
| A5 pool row editor (staged) | 12 |
| Unit hidden for Duration; Duration titles "Practice 10h 30m"; Duration needs no unit in Zod | 1, 6, 7 |
| Tap opens the sheet on both platforms; web Discrete +1 tap removed | 14 |
| Continuous / Duration sheet: pinned field, no OK, ¼ · ½ · goal · # | 13, 14 |
| Chips without a goal per kind | 13, 18 |
| Last-used pre-selects, else #; Discrete keeps `initialChipAmount` | 13 (vectors incl. "discrete keeps … 25") |
| Long-press "+ Add {last} unit" / "− Remove" / Custom… | 15 |
| Late log | 16 |
| "+ Log {amount}" pills; never-logged opens Detail | 13, 17 |
| Toasts per kind | 13 |
| Counter Detail | 18 |
| Board cells: fit tiers, ×goal, gold overshoot | 19 |
| Rows / subtitles / library rows | 20 |
| Vary range precision ("21.0–31.4 miles"), Duration whole minutes | 1, 5 |
| Grouped lifetime totals (R7) | 1 (`formatCountTotal`), 11, 17, 18, 21 |
| Owner override: Duration 1-minute steps everywhere | 1 (`formatRange`, `varyRangeLabel` vectors), 5 (stepper), 13 (`goalChips` 158 / 315 / 630) |
| Owner override: Duration ships now | every task carries Duration |
| §7 carried items | numbered in `docs/COUNTER_KINDS.md` §7 |
| No explanatory copy; #548 rows on touched surfaces (U6) | 5, 6, 7, 10, 11, 12, 14, 17, 18, 21 |
| Kind-blind sweep + a guard so it stays fixed (R9) | 21 |

**Placeholder scan:** remaining "read the file / use the literal" notes name the exact file:line and symbol (e.g. `TasksPage.tsx:35,290`, `bypass.ts:425,602`, `CounterDeleteConfirmDialog.module.css`); no step defers a decision. Two instructions are deliberately empirical and say exactly how to resolve them: Task 19's `cur`-tier baseline exception (re-record only cells that previously hid their count) and Task 21's allow-list seeding (fix, or allow-list with a reason, every reported line).

**Type consistency:** `KindPickerLock`, `parseCountInput(raw, kind, { allowZero })` ↔ `parseCountInput(_:kind:allowZero:)`, `KindSwitchPreview` (same seven fields both platforms), `applyKindSwitchThenGoalGuard(taskId, to, maxCount, nowIso)` ↔ `applyKindSwitchThenGoalGuard(db:taskId:to:maxCount:now:)`, `useKindSwitchRequest({ subject, kind, goalText, setKind, onSwitched })`, `LogChip` ↔ `CounterLogAmount.LogChip`, `boardSheetChips(kind, goal)` ↔ `boardSheetChips(kind:goal:)`, `initialLogSelection` ↔ `initialSelection`, `SharedCounterGroup.countKind` (declared last on iOS), `SquareEditTaskSheet.Patch.countKind` / `StagedTaskOverride.countKind`, `EditTaskSheet.Patch.countKind` — used with the same names and parameter orders in every task that consumes them.

**Review Focus → owning tests:** 1, 2 → Tasks 1–2 vectors; 3 → Task 6 (web model test + two iOS save-path tests); 4 → Tasks 8 + 10 (guard rollback + real Board Edit Save path, both platforms); 5 → Task 19 (`cellCountFit` table, `RisoBoardCell` tests, iOS grid snapshots). None of these tests asserts its own input back (each drives the production path and reads the stored row or rendered markup).
