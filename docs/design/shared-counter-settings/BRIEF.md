# Design brief — Shared counter settings, placement defaults, "counts toward"

**For:** Claude Design (claude.ai/design). Build on the OYBC Riso design-system
project `868cbd0e-dc0f-49ef-b0e2-f09eaf04b24c` (real Riso components + tokens).
**Platforms:** iOS (SwiftUI) **and** web (React) — one design, platform-idiomatic
where noted. Light + dark for every frame.
**Engineering spec:** `docs/SHARED_COUNTER_SETTINGS.md` (data model, rules and
decisions D1–D9 are locked; this brief covers the interface only). Background:
`docs/design/counter-kinds/BRIEF.md` (the kind picker, amount entry and cell
display you already designed — reuse those pieces as-is).

---

## 1. The problem

A **shared counter** is one running tally ("Books", "Miles", "Push-ups") that can
sit on many boards as a square, each square counting only its board's window
("12 books this year", "1 book this month"). Today:

- A counter has **no name of its own** — the hub shows a label derived from its
  verb + noun ("Run miles", "Push-ups"). You can change the verb and the noun;
  you can't give it a name.
- Every square title comes from **one formula**: `"{verb} {goal} {noun}"` →
  "Read 12 books", and for a goal of 1: "Read 1 books".
- **Putting a counter on a board is awkward.** You either find the existing
  counter and then edit the goal by hand for this board, or create a new counter
  task from scratch. There is no notion of "the usual goal for a week".

We're adding, per counter:

| Setting | What it is | Default at creation |
| --- | --- | --- |
| **Name** | the label the hub, pickers and Counter Detail show | the derived label ("Read books") |
| **Singular title** / **Plural title** | templates for square titles, with **`#N`** standing for the count | `"Read #N books"` for both (user edits the singular to `"Read #N book"`) |
| **Defaults** | a goal per core timeframe — Daily · Weekly · Monthly · Yearly | empty; unset ones can show a value derived from the one that is set |

and one new relationship:

> **Counts toward.** Any task can count toward one Discrete counter: when the
> task completes, the counter goes up by one (or a chosen amount). "Finish Dune"
> → +1 Books. The task can be a simple task, a counting task ("read 250
> pages") or a compound with sub-tasks — including an empty compound shell the
> user fills in later.

Title rendering is engineering's job (`#N` becomes `250`, `2.5`, or `1h 30m` by
kind; a template without `#N` is a fixed name). Your job is the controls.

---

## 2. Hard constraints

1. **No explanatory copy** (owner rule). Labels, values and controls only — no
   helper lines, no "Use #N for the count", no "Tip:", no provenance lines like
   "Counts toward Books" as a sentence. If `#N` isn't learnable from the field
   itself (its default value already contains it — that is the teaching), the
   control is wrong, not the copy. Allowed: validation errors, confirm-dialog
   consequence bodies, empty-state one-liners.
2. **Riso kit only** — RisoButton / Card / Chip / Segmented / SectionLabel /
   Badge and existing tokens. No new colors. Green is reserved for wins; compound
   is teal.
3. **The counter sheet is the ONE counter editor.** The same sheet creates and
   edits a counter (today: Kind · "What are you counting?" · "Task verb" · "Start
   from" on create). The new fields join it; nothing counter-shaped appears in
   the task editor. A shared counter's **type** (Simple/Counting/Compound) is
   never editable anywhere; its **kind** uses the picker you designed.
4. **Same job, same interface.** The Defaults entry is the existing Goal entry
   control per kind (decimal for Continuous, h:m for Duration); the counter
   picker used for "counts toward" is the existing counter search; the "+ New"
   inside Counter Detail opens the normal new-task flow.
5. **Store only what the user changed.** Fields show their default values; a
   derived default (e.g. Monthly computed from Weekly) is shown **dimmed** and
   becomes solid only when the user types one. Design the dimmed/solid states.
6. **Overshoot is valid; windows rule.** Nothing here changes how squares count.

---

## 3. Surfaces to design

### A. The counter sheet — create and edit (both platforms)

Fields, in this order unless you find a better one: **Name** · **Kind** (your
picker) · **What are you counting?** (noun) · **Task verb** · **Singular title**
· **Plural title** · **Defaults** (Daily / Weekly / Monthly / Yearly) · **Start
from** (create only).

- Create mode shows every field prefilled with its default (D5: visible, not
  collapsed) — show how a user who only types a noun and a verb gets a complete,
  sensible counter without touching the rest.
- Edit mode (opened from Counter Detail's ⋯ → **Edit counter…**) — same sheet,
  title "Edit counter", button **Save**.
- The template fields: how `#N` reads inside a text field (monospace token? a
  chip-like inline mark? plain text?) — pick one and show it typed mid-sentence
  ("Finish #N chapters of the book"). Show the live-rendered example for the
  current goal next to or under the field **as a value**, not a sentence
  ("Read 1 book" / "Read 12 books").
- Defaults: four goal entries with the dimmed-derived state (constraint 5); a
  Duration counter shows h:m entries; a goal-less accumulator counter (no
  target at all) shows the row empty, not derived.
- Validation to show: empty noun; a template that renders empty.

### B. Putting a counter on a board (wizard Tasks step + Board Edit quick-add)

Today the quick-add row matches library tasks by text; picking a counter places a
square with the counter's own goal. New:

- Typing matches the counter's **name**, noun and verb. Show the match row for a
  counter: name, kind tag, and the goal **this board** will get (its timeframe's
  default — "Weekly · 2 books") so the user sees what they are placing.
- After placing: the row/square carries that goal; the user can still change it
  for this board (existing per-board goal control). Show the state where the
  counter has **no default** for this board's timeframe (custom-timeframe board,
  or nothing set) — today's behaviour is "ask"; propose the lightest version.
- The old "Derive smaller version…" menu item goes away.

### C. Counts toward

1. **Counter Detail → a "Counts toward" section** (only for Discrete counters):
   the list of tasks that count toward it — title, state (done / in progress /
   not started), the board it sits on if any — and a **"+ New"** that creates a
   task already pointed at this counter (opens the normal new-task flow; a
   compound here may start with zero sub-tasks — the owner's "empty shell").
   Design the empty state (one line) and a list of ~6 mixed tasks.
2. **Task editor → "Counts toward" row** (Task Detail / Tasks tab; and the Board
   Edit square sheet): a label + value row ("Counts toward · Books" / "None")
   that opens the existing counter picker filtered to Discrete counters; an
   optional **amount** stepper defaulting to 1 (most tasks never touch it — keep
   it secondary).
3. **Board cell for a contributing task**: the small linked-counter mark the
   cells already use for counter squares, so "Finish Dune" visibly feeds Books
   without a sentence. Show 3×3 / 4×4 / 5×5 at 393pt, light and dark.
4. **Completion moment**: when a contributing task completes on a board, the
   counter square(s) on other boards tick up. If you think a brief acknowledgement
   belongs on the completing cell (the existing toast pattern: "+1 Books · Undo"),
   show it; otherwise say why not.

### D. Titles everywhere (display check)

Square titles, hub rows and Counter Detail header with templated titles: a
fixed-name template ("Finish the book"), a singular ("Read 1 book"), a plural
("Read 12 books"), a Duration ("Practice 1h 30m"), and a long one truncating in a
3×3 cell. No new controls — just confirm the existing cell/row designs hold.

---

## 4. Deliverables

- Frames for A (create + edit, incl. dimmed-derived Defaults and the `#N`
  treatment), B (match row with the timeframe default; no-default state), C1–C4,
  and D — **iOS and web, light and dark**.
- The `#N` field treatment and the Defaults row as reusable pieces.
- A short decisions list: the `#N` presentation; the no-default placement
  behaviour; whether the completion moment gets an acknowledgement.
- Handoff as before (exported zip with a `README.md` mapping each frame to the
  surface names in §3).
