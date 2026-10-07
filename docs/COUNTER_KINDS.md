# Counter kinds — Discrete · Continuous · Duration

**Status:** PR 1 #551 and PR 2 #552 shipped (data + logic). Interface decided (Claude Design handoff
`design_handoff_counter_kinds/`, gitignored; brief: [`docs/design/counter-kinds/BRIEF.md`](design/counter-kinds/BRIEF.md)) —
PR 3 (authoring) and PR 4 (logging + display) are planned in [`docs/COUNTER_KINDS_UI_PLAN.md`](COUNTER_KINDS_UI_PLAN.md).
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

## 5. Interface (PR 3 authoring, PR 4 logging)

Decided from the Claude Design handoff (`design_handoff_counter_kinds/`, page
`Counter Kinds.dc.html`; surfaces named as in the brief §3). The handoff is
accepted except for the two owner overrides below.

**Owner overrides (2026-10-07) — these win over the handoff:**

1. **Duration steps are 1 minute everywhere.** Goals, wizard target steppers,
   ¼ / ½ chip amounts and vary ranges all snap to 1 minute (D6). The
   handoff's "wizard targets step 15m (5m under 2h), ranges round to 5m" and
   "Duration quarters round to 5 minutes" are rejected. Continuous keeps 0.1
   steps for targets, ranges and quarters.
2. **Duration ships in PR 3/4 with Continuous** (it is not deferred; train
   item 5 is folded in).

**Labels.** The kinds read **Discrete / Continuous / Duration** on screen
(never "Amount").

**Two reusable components (one per job, every surface):**

- **Kind picker** — a three-segment `RisoSegmented` (card) placed between
  Verb and Goal (first row on the hub New counter sheet). States: *new task*
  = all three live; *existing Discrete/Continuous* = Duration locked out;
  *existing Duration* = locked in (the selected segment carries the lock
  glyph). Locked segments are 45% opacity, not hit-testable, lock glyph — no
  sentence. A *linked* row (`sharedCounterId` set, or a create that is
  auto-linking to a counter) shows no picker: a kind tag + the shared dots +
  "{counter} · {all-time} all-time" — the family's kind (D5).
- **Goal entry** — the one amount field. Discrete: number pad / `inputmode=
  numeric`; Continuous: decimal pad / `inputmode=decimal` (2 dp, `.` or `,`);
  Duration: iOS a field + inline h / min wheel, web two fields `[h] h [m] m`.
  Duration hides the Unit field (the unit is time).

**Authoring surfaces (PR 3):** A1 special panel (wizard Tasks step + Tasks-tab
quick-add) · A2 compound sub-task (create + the edit editor's new sub-task;
an existing sub-task keeps its kind) · A3 Board Edit square sheet (staged,
applied at Save) · A4 Task Detail edit · A5 pool row editor (staged) · A6
Counters hub New counter ("Start from" uses Goal entry). Duration titles
generate as "Practice 10h 30m" (no unit).

**Switching (D4).** Only **Continuous → Discrete** confirms: title "Switch to
Discrete?", body rows "{title} → {rounded title}" and "{logged} logged →
{rounded} logged", consequence line "Switching back restores the exact
values." plus "Follows on N linked squares." when the root has a live
family; Cancel / Switch. Discrete → Continuous switches silently. Every
switch writes through `switchCounterKind` (root + family, one transaction);
staged surfaces apply it inside their Save transaction.

**Logging (PR 4).**

- **Square tap opens the stepper sheet on both platforms** for every counting
  square. **Web Discrete changes:** a tap no longer logs +1; it opens the
  DetailModal (the +1 lives on in the right-click menu as "+ Add 1"). The
  Discrete sheet/modal is otherwise unchanged.
- **Continuous / Duration sheet:** the same sheet with the amount field pinned
  open — chips set it, the decimal pad / h:m wheel edits it, − and + apply it
  (no OK). The last amount used pre-selects its chip, else `#` shows it.
- **Chips.** With a goal (board sheet, late log): ¼ · ½ · goal · # —
  Continuous rounds to 0.1, Duration to 1 minute. Without a goal (hub,
  Counter Detail): Discrete 1 · 10 · 25 · #, Continuous 0.5 · 1 · 5 · #,
  Duration 15m · 30m · 1h · #. Discrete board/late-log presets unchanged.
- **Long-press / right-click menu:** "+ Add {last} {unit}", "# Custom
  amount…" (opens the sheet), "− Remove {last} {unit}" for the new kinds;
  Discrete unchanged.
- **Late log:** ¼ · ½ · goal + Custom… with Goal entry; web button reads
  "Log +{amount} {unit}".
- **"+ Log" pills** (hub ledger card, Profile rows) carry the amount for the
  new kinds ("+ Log 3.1", "+ Log 30m"); with no amount logged yet the pill
  reads "+ Log" and opens Counter Detail. Discrete unchanged.
- **Toasts:** "Logged +3.1 mi · Undo", "Logged +1h 30m · Undo". Correcting a
  31-for-3.1 slip: Undo in the toast, else open the sheet — the field opens
  on the last amount and − removes exactly it.

**Display (PR 4).** Every count goes through `formatCount` (2 dp max, trailing
zeros trimmed, locale separator, Duration `Xh Ym` with zero parts dropped);
lifetime totals use the grouped `formatCountTotal`. Board cells fit the bar
text in tiers — `cur/max` → `cur` → fill only; the `×goal` tag always carries
the goal. Overshoot shows the real value with a **gold** bar fill (never
clamped). Vary ranges render both ends at the more precise end's precision
("21.0–31.4 miles"); Duration ranges are whole minutes ("8h 24m–12h 36m").

## 6. PR train

1. **Foundation** (inert): §3, both platforms. Largest mechanical diff (iOS
   `Int`→`Double` ripple, ~60 Swift sites). No user-visible change.
2. **Logic**: §4 + vectors.
3. **Authoring UI**: kind picker + Goal entry on every Goal surface.
4. **Logging + display UI**: tap, chips, entry sheet, late log, hub, cells.
5. ~~**Duration** input + display~~ — folded into 3/4 (owner, 2026-10-07).

## 7. Open items

- ~~Interface details in the brief §3B~~ — decided in §5 (handoff + owner overrides, 2026-10-07).

Carried to PR 3/4 (each closed by the named task in `docs/COUNTER_KINDS_UI_PLAN.md`):

- Member-row steppers are `Int` (R8); UI callers do not pass the kind (R16). → **Task 11**
- Kind-blind views format as discrete (R9). → **Tasks 13–22** (each surface's own task; Task 22 sweeps the remainder)
- `.formatted()` grouping at 5 lifetime sites (R7). → **Task 1** (`formatCountTotal`) + **Tasks 10, 18, 19, 22**
- `AutoCreateCompoundChild` lacks `countKind`. → **Task 1** (type + schema) + **Task 6** (both create paths)
- Previews of links to a continuous root must resolve the root's kind (R19). → **Task 5** (linked creates stamp the root kind) + **Task 21** (`resolveFamilyCountKind` in cell models)
- `varyRangeLabel` / `countingSummary` duration copy. → **Task 1** (`formatCountRange`) + **Task 11**
- iOS `switchCounterKind` cascades per row (perf). → **Task 7** (one family fetch, batched in the shared transaction)
- Digit/locale decision: counts use Latin digits (R10). → **Task 1** (parsers accept ASCII digits only; formatters stay `latn`)

## 8. Testing

Shared Jest + vectors for every kernel / member-rule / formatter change (80%
gate); iOS vector tests via the synced fixtures; web Vitest for parsers and
write paths (fractional deltas through `incrementSharedCounter`, `lateLog`,
`orchestration`); pull-path tests that a fractional remote row is accepted on
both platforms; snapshot baselines for every redesigned iOS surface.
