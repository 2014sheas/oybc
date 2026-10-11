# Design brief — Unit tasks of a Discrete counter (member model)

**For:** Claude Design (claude.ai/design). Build on the OYBC Riso design-system
project `868cbd0e-dc0f-49ef-b0e2-f09eaf04b24c` (real Riso components + tokens).
**Platforms:** iOS (SwiftUI) **and** web (React) — one design, platform-idiomatic
where noted. Light + dark for every frame.
**Engineering spec:** `docs/SHARED_COUNTER_SETTINGS.md` §3 (data model, credit
rules and the 2026-10-10 amendment are locked; this brief covers the interface
only). Background: `docs/design/shared-counter-settings/BRIEF.md` §C — the
Counter Detail section (C1), the contributing-cell mark (C3) and the credited
toast (C4) you designed **shipped and stay**; the task-editor row (C2) was
**retired** and must not come back in any form.

---

## 1. The problem

A **Discrete counter** ("Books", "Push-ups", "Workouts") is one running tally
that sits on many boards as a square, each square counting its board's window.
A **unit task** is a task that counts as **one** of that tally when it
completes: "Finish Dune" → +1 Books; "Read 300 pages" (a counting task) → +1
Books when its 300 is reached; "Book club night" (a compound: "Finish the
book" + "Show up") → +1 Books. The founding example is books and pages.

What is decided (owner rulings, 2026-10-10):

- **The counter owns its members.** A unit task is *created from* its counter's
  page. There is no "counts toward" control on any task form or task editor —
  that row shipped once, was a creation-form contract violation, and is gone.
  The only way a task becomes a unit task is Counter Detail's **"+ New"**.
- **A unit task may be Simple, Counting or Compound.** A compound unit task may
  start with **zero sub-tasks** (the owner's "empty shell", filled in later).
- **A unit task is a normal task otherwise.** It is searchable in the library
  separately from its counter, placeable on any board through every existing
  path (library sheet, square picker, quick-add match), editable in Task Detail
  like any task, and has its own completion history.
- **A unit task always credits exactly one.** There is no amount anywhere.
- **Deleting the counter keeps its unit tasks** and simply decouples them; they
  become ordinary tasks.
- **A unit task shows which counter it belongs to the way a linked counter
  copy does today**: the shared **two-dot mark** plus the **counter's name**.
  Today that treatment exists in the editors (the kind tag with dots +
  "Books · 12 all-time"), on Task Detail (a row: counter name · all-time
  total · chevron) and on board cells (the two-dot corner mark); list and
  picker rows carry nothing yet. Extending it to rows is yours. No sentence.

What is yours to design: the member list on Counter Detail (with removal), the
"+ New" moment and its shape choice, how a unit task reads everywhere a task is
listed or picked, and how it is told apart from a *linked copy* of the same
counter (see §3D).

Vocabulary for labels: **counter**, **unit task** (or simply the counter's name
as a tag). Never "contributor", "member", "flag", "hub-born" or "board-born" on
screen.

---

## 2. Hard constraints

1. **No explanatory copy** (owner rule). Labels, values and controls only — no
   helper lines, no "Completing this adds 1 to Books", no "Tip:", no provenance
   sentences. The relationship is shown by the two-dot mark + the counter's
   name, never explained. Allowed: validation errors, confirm-dialog consequence
   bodies, empty-state one-liners.
2. **Riso kit only** — RisoButton / Card / Chip / Segmented / SectionLabel /
   Badge / the existing type badges and existing tokens. No new colors. Green is
   reserved for wins; compound is teal.
3. **Nothing counter-shaped on task forms or task editors.** The quick-add row,
   the special-type panel, the compound fields, the Task Detail edit sheet and
   the Board Edit square sheet carry no counter picker, no "Counts toward" row,
   no toggle, no amount — not even for a task that already is a unit task. If a
   surface needs the relationship, it shows the mark + name as a **value**, and
   changing the relationship happens on Counter Detail.
4. **Same job, same interface.** "+ New" opens the **existing** new-task sheet
   (the Tasks tab's: a type control, then the fields of the chosen type; web's
   Compound opens its Setup → Build → Review mini-wizard, iOS builds the
   compound inline). Rows reuse the **existing** task row (type badge · title ·
   subtitle · usage) and extend the **existing** linked-counter treatment
   (two-dot mark + name) to them. Removal uses the platform's existing
   row-removal idiom.
5. **No amount, ever.** No stepper, no "+N" mark, no "×2" on rows. The only
   count-like thing on a row is the existing "× N" credit count for a repeating
   unit task completed in N windows (a weekly square done four weeks running).
6. **Overshoot is valid; windows rule.** Nothing here changes how squares count.

---

## 3. Surfaces to design

### A. Counter Detail → the unit-task section (both platforms)

Today (shipped C1): a "Counts toward · N tasks" section on a Discrete counter —
rows of type badge · title (done = muted + strikethrough) · primary board with
its timeframe dot · "× N" credits · status pill; a "+ New" button; the empty
one-liner "Nothing counts toward Books yet.". Keep what works; change:

- **Section name.** "Counts toward" was the retired field's name. Propose the
  heading for a list of the counter's unit tasks (the count stays in it).
- **Remove.** A unit task can be removed from the counter here (it survives as
  an ordinary task; its past credits are withdrawn). iOS: swipe action; web:
  propose (hover action, row ⋯, or an Edit mode). A confirm is allowed only if
  you think the withdrawal of credits warrants one — say which and why.
- **Row tap** → Task Detail (unchanged). Show the row for each shape: a Simple
  task, a Counting task mid-progress ("120/300 pages"), a Compound with zero
  sub-tasks (the unfilled shell — how does an empty compound read?), and a
  repeating weekly unit task with "× 4".
- **Ordering.** Propose (in progress first? most recently completed first?).
- **Empty state** one-liner (keep or reword) and the list at ~6 mixed tasks.
- **Adjacency.** Counter Detail already lists the counter's **linked copies**
  as cards ("Counting on N tasks" / "Not counting now") directly above this
  section. Show the full page so the two lists read as different things
  (see §D).
- **The counter delete confirm** gains one consequence line: unit tasks are
  kept (consequence bodies are allowed). Show the dialog.

### B. "+ New" — creating a unit task (both platforms)

Today: "+ New" opens the normal new-task sheet with nothing visible about the
counter; the created task silently belongs to it.

- Show the sheet as opened from Counter Detail. The user must be able to see
  **which counter this task will belong to** without a sentence — the counter's
  name + two-dot mark somewhere in the sheet's chrome (title? a tag under the
  title? a non-interactive chip?) — pick one and justify. It is **not** a
  control: there is nothing to change or clear here.
- The **shape choice**: the sheet's existing type control reads **Normal ·
  Counting · Compound · Achievement** today (the editors say "Simple" for the
  first — pick one label and say which). Opened from a counter it offers
  **three** shapes: Achievement is absent, not disabled. Show the Counting
  variant with its own kind picker, goal and unit ("Read · 300 · pages") and
  the Compound variant submitting with **zero** sub-tasks — this entry point
  already allows it; design how the empty shell reads in the web wizard's
  Build and Review steps and in iOS's inline compound fields.
- After create: the new row appears in A; show the return moment.
- The Counting variant has one trap: typing a verb + noun that matches an
  **existing counter** today auto-links the new task to that counter as a copy
  (the "Link / Don't link" hint). A unit task of Books that is itself a linked
  copy of another counter is **not allowed** — the hint must not appear or the
  create must refuse. Propose the lightest treatment.

### C. The unit task everywhere a task is listed or picked (both platforms)

The owner's rule: the row carries the two-dot mark + the counter's name, like a
linked copy. Design that treatment once and show it on:

1. **Tasks tab (library) row** — type badge · title · subtitle · usage. Where do
   the dots + "Books" go (in the subtitle slot? a trailing tag?) for each
   shape? A Counting unit task already has a subtitle ("300 pages"); show both
   together.
2. **Wizard Library sheet row** and **Board Edit square picker row** — the same
   row in a selection context (selected / unselected / center-pinned).
3. **Quick-add match row** (wizard Tasks step + Board Edit): typing "Dune"
   matches the unit task — show its match row. Typing "Books" matches the
   counter's own match row ("Weekly · 2 books"); decide whether the counter's
   match row should also surface its unit tasks beneath it or whether the
   unit tasks stand alone in the results (recommendation: stand alone — they
   are tasks, not goals).
4. **Pool editor row** (a unit task pulled into a pool).
5. **Task Detail** for a unit task — the row a linked copy shows today
   (counter name · all-time total · chevron → Counter Detail), reused as-is.
   No edit affordance for the relationship.
6. **Board cell** — unchanged (shipped C3: the two-dot mark on a not-done cell).
   Include one 4×4 frame for continuity only.

Also propose any **library filter or grouping** for unit tasks (a "Books" chip?
grouped under the counter in search results? nothing?). The owner flagged
"other visibility considerations" without ruling — give a recommendation with
one alternative.

### D. Unit task vs linked copy — the distinction (both platforms)

Two different things now carry dots + "Books":

| | What it is | Example | Counts |
| --- | --- | --- | --- |
| **Linked copy** | a square *of* the counter, with a per-board goal | "Read 2 books" (this week) | logs add to Books directly |
| **Unit task** | a task that *is one* Book when done | "Finish Dune", "Read 300 pages" | completion = +1 Books |

Both are legitimately "Books" to the user. Decide whether the row/tag treatment
should distinguish them (a different dot arrangement? the copy shows its goal,
the unit shows nothing? a "1" where the copy shows "2 books"?) or whether the
existing subtitle difference is enough. Show the two side by side in a library
list and in a 3×3 grid, light and dark. This is the one place a new mark is
permitted if you need it — argue for or against.

### E. Removal and deletion moments (both platforms)

- Removing a unit task from the counter (A): the row leaves the list; the task
  stays in the library without the mark. If a confirm is used, its body may
  state that its past credits are withdrawn.
- Deleting the unit task itself (Task Detail → Delete): the existing confirm;
  nothing new unless its credits warrant a line.
- Deleting the counter: unit tasks kept and decoupled (the confirm line in A).

---

## 4. Deliverables

- Frames for A (section with ~6 mixed rows incl. the empty compound shell and
  a "× 4" row; remove affordance; empty state; delete confirm), B (the sheet
  with the counter identity, the three shapes incl. the zero-sub-task
  compound, the auto-link conflict treatment, the return moment), C1–C5 (the
  row treatment on every list/picker, the match row decision, the Task Detail
  row, a library filter/grouping recommendation) and D (unit vs copy, side by
  side) — **iOS and web, light and dark**.
- The dots + counter-name **row tag** as one reusable piece (dense + regular).
- A short decisions list: the section heading; the first type label (Normal
  or Simple); where the counter identity sits in the "+ New" sheet; the
  removal idiom per platform and whether it confirms; whether unit tasks and
  linked copies are visually distinguished and how; whether unit tasks appear
  under the counter's match row or stand alone; the library visibility
  recommendation; the ordering of the list.
- Handoff as for the previous briefs: an exported zip with a `README.md`
  mapping each frame to the surface names in §3.
