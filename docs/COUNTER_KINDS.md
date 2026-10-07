# Counter kinds — Discrete · Continuous · Duration

**Status:** PR 1 #551 and PR 2 #552 shipped (data + logic); interface pending the Claude Design handoff.
(brief: [`docs/design/counter-kinds/BRIEF.md`](design/counter-kinds/BRIEF.md)).
**Ships:** pre-launch, whole feature (owner decision 2026-10-06). Every PR lands
web + iOS together (CLAUDE.md rule 6).

## 1. Problem

Every counting task is an integer counter: `maxCount`, `currentCount`,
`TaskEvent.delta`, `baseline`, `defaultLogAmount` and member-rule `target` are
integers, enforced by Zod `.int()` (sync boundary), Swift `Int` / GRDB
`INTEGER` (iOS), whole-number input parsers, and `floor`/`ceil`/`round` in
member rules. Distance / weight / money / time goals can't be logged honestly.

Pre-launch timing matters: once App Store builds exist, a fractional value
synced from a new client breaks old clients (web pull skips it as malformed at
`pullApply.ts`; iOS decodes `Int?` from a REAL), forcing a two-release staged
rollout. Before launch the only clients are owner TestFlight builds.

## 2. Decisions (owner, 2026-10-06)

| # | Decision |
|---|---|
| D1 | A per-task **kind**: `discrete` (whole counts, today's behaviour), `continuous` (decimals), `duration` (hours + minutes — designed now, build decided after design review). These names are used verbatim in code, docs and design hand-offs; on-screen labels are a design decision, and "Amount" is ruled out (it is already the custom log-amount field's placeholder). |
| D2 | **Representation:** counts are real numbers quantized to **2 decimal places** at every write (not fixed-point integers, not parallel fields). Integers are exact doubles, so discrete counters are bit-identical to today. |
| D3 | **Precision fixed at 2dp** for `continuous`; display trims trailing zeros. |
| D4 | **Discrete ⇄ Continuous switches both ways; Duration never switches** (no switch into or out of `duration` — a raw number has no unit, so "5 hours" would read as 5 minutes). Events are never rewritten; a discrete task's window sum rounds half-up at read; switching to discrete rounds `maxCount` (min 1) as an ordinary authored edit; switching back restores exact values. |
| D5 | A shared-counter **family shares its root's kind**; linked/minted copies inherit it and follow a root switch (same cascade as a Goal edit). |
| D6 | `duration` is stored as **integer minutes** — it reuses the discrete logic branch exactly (all steps snap to 1 minute); only input + display differ. Live start/stop timers are out of scope. |
| D7 | The UI extends the **existing** counter interactions (tap/stepper sheet, chips, last-used amount, custom entry, late log, toast) per kind rather than inventing new ones; Claude Design adapts them. |

## 3. Data model + sync (PR 1 — inert)

- `Task.countKind?: 'discrete' | 'continuous' | 'duration'` — absent = `discrete`.
  Forward-compatible decode (`Board.isCore` precedent); per-row LWW; GRDB v39
  adds one nullable TEXT column; no Dexie change (unindexed); no
  `firestore.rules` change (rules don't type-check count fields). Counting-only;
  ignored on other types.
- Number fields `maxCount`, `currentCount`, `baseline`, `lastSyncedCount`,
  `defaultLogAmount`, `TaskEvent.delta`, `BoardSource` member-rule `target`:
  Zod `.int()` → `isQuantized` (finite, equals its own 2dp quantization; positivity/
  non-zero refinements unchanged). iOS `Int?` → `Double?`. SQLite INTEGER
  affinity stores REAL losslessly → no table rebuild; existing rows decode
  unchanged. Verify `SyncService` raw upsert decodes a Firestore `Double`.
- Shared helpers (TS ↔ Swift twin, pinned by a new `countValueVectors.json`):
  `quantizeCount(x) = round(x·100)/100` (half away from zero, applied once per
  write); `resolveCountKind(task)`; `formatCount(value, kind)` (trim zeros,
  locale separator; `duration` → `Xh Ym`). Every display site goes through
  `formatCount`, every input through one shared amount-entry parser — the
  chokepoints that keep `duration` additive.
- `generateCounterTaskTitle`: drop `Math.floor` (TS) / `Int` (Swift) → "Run 26.2 miles".

## 4. Logic (PR 2)

- **Window kernels** (`resolveTaskWindowState`, derived / linked counter
  resolution, `windowSum`, shared-counter display): sum deltas → `quantizeCount`
  → if discrete/duration, round half-up → clamp ≥ 0 → complete on `count >= maxCount`.
  One rule gives D4 and kills float drift (`0.1+0.2`).
- **Kind switch** (Discrete ⇄ Continuous only; the kind picker locks Duration once a task exists, and locks every kind out of Duration): `updateTaskAndCascade` / `applyTaskEditPatch` path, cascaded
  across the family (D5); to-discrete rounds `maxCount` (min 1) and
  `defaultLogAmount`.
- **Member rules** (`memberRules.ts` ↔ `BoardSourceMemberRules.swift`), branch
  on kind; discrete branch and all existing vectors unchanged:
  - `continuous`: `autoTarget` = ceil to 0.1; `varyRange` bounds round to 0.1,
    floor 0.1; `rollTarget` uniform over the range in 0.1 steps (still ± around
    target, #545); `goalOf` no floor.
  - `duration`: discrete maths in minutes (1-minute steps).
- Add fractional cases to `taskWindowStateVectors`, `sharedCounterVectors`,
  `memberRuleVectors`, `taskTitleVectors` (remove its "iOS maxCount is Int" note);
  re-run `scripts/sync-fixtures-to-ios.js`.
- Unaffected: compound M-of-N thresholds (count child tasks), streaks, bingo detection.

## 5. Interface (PR 3 authoring, PR 4 logging) — PENDING DESIGN

Blocked on the Claude Design handoff for [the brief](design/counter-kinds/BRIEF.md).
Surfaces: kind picker on all six Goal surfaces; decimal / h:m entry (iOS
`RisoNumberField` `.numberPad` has no decimal key); square tap behaviour for
Continuous/Duration; per-kind chip presets (web `amountChips.ts` ↔ iOS
`CounterLogAmount.swift`); late-log sheet; hub/Profile "+ Log"; toasts; board
cell display at 3×3–5×5. Sections written after the handoff is approved.

## 6. PR train

1. **Foundation** (inert): §3, both platforms. Largest mechanical diff (iOS
   `Int`→`Double` ripple, ~60 Swift sites). No user-visible change.
2. **Logic**: §4 + vectors.
3. **Authoring UI**: kind picker + Goal entry on every Goal surface.
4. **Logging + display UI**: tap, chips, entry sheet, late log, hub, cells.
5. *(if not folded into 3/4)* **Duration** input + display.

## 7. Open items

- Interface details in the brief §3B (deliberated in Claude Design).

Carried to PR 3/4:

- Member-row steppers are `Int` (R8); UI callers do not pass the kind (R16).
- Kind-blind views format as discrete (R9).
- `.formatted()` grouping at 5 lifetime sites (R7).
- `AutoCreateCompoundChild` lacks `countKind`.
- Previews of links to a continuous root must resolve the root's kind (R19).
- `varyRangeLabel` / `countingSummary` duration copy.
- iOS `switchCounterKind` cascades per row (perf).
- Digit/locale decision: counts use Latin digits (R10).

## 8. Testing

Shared Jest + vectors for every kernel / member-rule / formatter change (80%
gate); iOS vector tests via the synced fixtures; web Vitest for parsers and
write paths (fractional deltas through `incrementSharedCounter`, `lateLog`,
`orchestration`); pull-path tests that a fractional remote row is accepted on
both platforms; snapshot baselines for every redesigned iOS surface.
