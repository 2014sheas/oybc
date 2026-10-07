# Design brief — Counter kinds (Count · Amount · Time)

**For:** Claude Design (claude.ai/design). Build on the OYBC Riso design-system
project `868cbd0e-dc0f-49ef-b0e2-f09eaf04b24c` (real Riso components + tokens).
**Platforms:** iOS (SwiftUI) **and** web (React) — one design, platform-idiomatic
where noted. Light + dark for every frame.
**Engineering spec:** `docs/COUNTER_KINDS.md` (data model and rules are decided;
this brief covers the interface only).

---

## 1. The problem

OYBC turns goals into bingo boards. A **counting task** is a square with an
action, a goal and a unit — "Run · 26 · miles", "Read · 300 · pages". Today
every counter is a **whole-number count**: you log +1, +10, or a custom whole
number. That works for pages and push-ups, and fails for distance, weight,
money, or time — a 3.1-mile run can't be logged honestly.

We're adding a **kind** to every counter:

| Kind (working label) | Logs | Example | Goal entry | Display |
|---|---|---|---|---|
| **Count** (today) | whole numbers | Read 300 pages | integer | `120/300` |
| **Amount** | decimals, up to 2 places | Run 26.2 miles | decimal | `12.4/26.2` |
| **Time** | hours + minutes | Practice 10 h guitar | h : m | `4h 30m/10h` |

Labels are working names — propose better ones if you have them. Time has no
user-entered unit (the unit *is* time). Count and Amount keep Action → Goal → Unit.

**Time is a sketched third option.** Design it fully enough that the kind picker
is genuinely three-way and we can see the h:m entry/chips/display; engineering
decides after review whether it ships with Amount or right after.

---

## 2. Hard constraints

1. **No explanatory copy** (owner rule). Labels, values and controls only — no
   helper lines under the kind picker, no "Decimals allowed", no "Tip:", no
   footnotes. If the kind is unclear without a sentence, the control is wrong.
   Allowed: validation errors, confirm-dialog consequence bodies, empty-state
   one-liners.
2. **Riso kit only** — RisoButton / Card / Chip / Segmented / SectionLabel /
   Badge and existing tokens. No new colors. Green is reserved for wins
   (bingo/greenlog); compound is teal.
3. **Overshoot is valid.** 28.4/26.2 is a real, celebrated state — never clamp.
4. **Same job, same interface.** The kind picker and the amount-entry control
   must be ONE component reused on every surface below, not a per-screen variant.
5. **Count ⇄ Amount switch both ways** on an existing counter. Amount → Count
   rounds the goal to a whole number (26.2 → 26) and the board's totals display
   rounded; nothing is lost (switching back restores exact values). Design the
   switch moment (a confirm dialog with a consequence body is allowed).
   **Time never switches** — once created, a Time counter stays Time, and a
   Count/Amount counter can't become Time. Show that as a locked state of the
   picker, not a sentence.
6. **A shared counter's kind belongs to the whole family** — every linked square
   follows the source. Linked squares never offer a kind choice.

---

## 3. Surfaces to design

### A. Choosing the kind (authoring) — every Goal surface

Today each shows Action → Goal → Unit with a whole-number Goal field
(iOS number pad, no decimal key).

1. **New task — special panel, Counting** (Tasks tab quick-add + wizard Tasks step).
2. **Compound sub-task, Counting** (create + edit).
3. **Board Edit → square sheet** (the "Goal" field; Simple ⇄ Counting already switches here).
4. **Task Detail → edit** ("Goal").
5. **Pool editor row** ("Goal").
6. **Counters hub → New counter** (name, "Start from").

Design: the kind picker (placement relative to Action/Goal/Unit), the Goal field
per kind (decimal keypad on iOS for Amount; h:m entry for Time), the switch
confirm and Time's locked state (constraint 5).

### B. Logging — the hard part

Today:
- **Board square tap**: web = +1 (or the counter's last-used amount for shared
  counters); iOS = opens a stepper sheet (− / + by a chosen amount, chips, custom).
- **Long-press / context menu**: "+ Add 1", "+ Add {last}", "# Custom amount…", "− Remove".
- **Amount chips**: hub/detail `1 · 10 · 25 · #`; board `+1 · +10 · #`;
  closed-board late log `+1 · +2 · +5 · Custom…`. The last amount used becomes the
  pre-selected chip.
- **Counters hub "+ Log" pill** and **Profile counter "+ Log"** — one tap logs the last amount.
- **Toast**: "Logged +N unit · Undo".

**Start from these existing interactions** — the answer for Amount and Time
is mostly "the same pattern, adapted per kind", not a new flow. Note the current
web/iOS divergence on square tap (web logs, iOS opens the sheet) and resolve it
if a kind needs one behaviour on both. Open questions:
- What does **tapping an Amount square** do? +1 mile is rarely right; a tap
  that always opens entry adds friction for a one-tap habit app. Options we see:
  tap logs last amount (with Undo), tap opens entry, or tap = last amount with an
  inline edit affordance. Pick and show it.
- **Chip presets per kind** (e.g. Amount `0.5 · 1 · 5 · #`? Time `+15m · +30m · +1h · #`?)
  — or derived from the goal.
- **The custom-amount entry** for Amount (decimal) and Time (h:m) — one sheet on
  iOS, one popover/modal on web, reused by board, hub, detail and late log.
- **Removing / correcting** a mistaken 31 instead of 3.1.

### C. Display — tight spaces

- **Board cells** at 3×3, 4×4 and 5×5 on a 393pt-wide phone: today `cur/max` +
  a progress bar + a `×max` tag. Show worst cases: `12.75/26.2`, `128.5/1000`,
  `4h 30m/10h`, `112h 15m/500h`, and an overshoot.
- **Counter rows / ledger cards / Counter Detail** ("logged/goal", "N to go",
  "✓ Goal met · N over", daily totals, milestones).
- **Task titles** auto-generate from Action + Goal + Unit ("Run 26.2 miles",
  "Practice 10 hours"?).
- **Board-wizard member rows** show targets with a ± "vary" dice range
  ("24.0–28.4 mi") and a target stepper — show the stepper for Amount and Time.

Number formatting: trim trailing zeros (`3.1`, `26.2`, `5`), locale decimal
separator; Time as `Xh Ym` (drop zero parts).

---

## 4. Deliverables

- Frames for A1, B (square tap → entry, chips, late log, hub "+ Log"), C board
  cells at all three sizes, and the switch-kind confirm — **iOS and web, light and dark**.
- The single kind-picker and amount-entry components as reusable pieces.
- A short decisions list answering the §3B open questions.
- Handoff as before (exported zip with a `README.md` mapping each frame to the
  surface names in §3).
