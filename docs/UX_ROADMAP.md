# OYBC UX Roadmap — Creation Flows & App-Wide

**Status:** Living strategy doc. Written 2026-06-08 from a creation-UX deep-dive
(3 parallel codebase explorations + 1 blast-radius scoping). Intended to steer the
upcoming large-scale UI overhaul. File:line references are accurate as of branch
`docs/ux-roadmap`; treat them as pointers, not pins.

> Companion docs: [`ARCHITECTURE.md`](ARCHITECTURE.md),
> [`TASK_SYSTEM.md`](TASK_SYSTEM.md). This doc is UX-strategy; those are
> technical-design. When a recommendation here is adopted, fold the *decision* into
> the relevant design doc and leave this as the rationale trail.

---

## 1. Executive summary

The single highest-leverage finding: **the creation UI never caught up with the
unified data model.** The task system was unified onto four types —
`NORMAL / COUNTING / COMPOUND / ACHIEVEMENT` (`packages/shared/src/constants/enums.ts:29-34`)
— but the task creator still asks users to choose between **five** buttons:
*Normal · Counting · Progress · Composite · Achievement*. "Progress" and
"Composite" are not real types; they are form-only sentinels that both produce a
`COMPOUND` task differing only by the `isOrdered` flag. Users are being asked to
make a distinction the system doesn't make — and given no help making it.

That mismatch is the root of most creation confusion, and it ripples outward into
filter chips, type badges, and the board wizard. It is also **safe to fix before
the overhaul**, because it corrects the conceptual model, not the visual design.

### Top 5 moves, ranked by impact × effort

| # | Move | Impact | Effort | Phase |
|---|------|--------|--------|-------|
| 1 | Merge user-facing Progress/Composite → one **Compound** type + "Ordered steps" toggle | High | Medium | A (now) |
| 2 | Explain Achievement jargon (Greenlog/Bingo) + stop the create-then-can't-place trap | High | Low | A (now) |
| 3 | Goal-first creation entry ("What are you tracking?") that picks the type for the user | High | High | B (overhaul) |
| 4 | Warm first-run: inline first-board CTA on empty states + one recurring timeframe on by default | High | Medium | B (overhaul) |
| 5 | Resolve Create-tab vs Tasks-tab "create" overlap (Create ≠ create-anything) | Medium | Medium | B (overhaul) |

Phase A items ship now (see [§5](#5-phased-roadmap)); Phase B/C ride the overhaul.

---

## 2. Findings — Task-creation mental model

### 2.1 Progress vs Composite is a distinction without a difference — **Critical**
The type selector renders 5 options but the persisted enum has 4 types. "Progress"
= `COMPOUND` + `isOrdered:true`; "Composite" = `COMPOUND` + `isOrdered:false`.

- Web sentinels: `PROGRESS_TYPE` / `COMPOSITE_TYPE` / `TaskTypeOrComposite`
  (`apps/web/src/pages/createPage/useCreateFormState.ts:38-40`); option list
  `CreateNewTaskForm.tsx:19-26`.
- iOS sentinels: `CreateTaskType` cases `.progress` / `.composite`
  (`apps/ios/OYBC/Views/CreateTab/ViewModels/CreateFormViewModel.swift:30-65`).
- The two paths diverge only at submit: Progress → `createCompound({operator:AND, isOrdered:true})`
  (`useCreateFormState.ts:804-813`); Composite → wizard with `isOrdered` **hardcoded
  `false`** (`CompositeTaskWizard.tsx:320`, iOS `CompositeTaskWizardView.swift:319`).
  There is **no "ordered" toggle anywhere** today — ordered compounds are only
  reachable via the "Progress" button's inline step editor.

**Recommendation:** one **Compound** button → the composite wizard → an "Ordered
steps" toggle that drives `isOrdered`. Decouples the concept (a compound goal) from
the option (ordered or not). *This is Phase A, Fix 2.*

### 2.2 Achievement is a jargon trap — **Major**
Achievement creation surfaces the domain terms **Greenlog** and **Bingo** as
trigger choices with zero in-UI explanation (`CreateNewTaskForm.tsx:199-213`, iOS
`CreateNewTaskFormView.swift:258-266`). Worse, a user can create an Achievement on
the Tasks tab, then discover it is silently **absent from the board wizard's task
picker** (Achievements are cross-board watchers, never placed). Create-then-hunt is
a dead-end.

**Recommendation:** keep the domain terms verbatim (they are correct vocabulary)
but add a one-line explainer at the point of choice; and signal in the type picker
/ Tasks-tab chip that Achievement is a watcher/meta task, not a board square.
*Phase A, Fix 3.* Cycle-detection feedback (currently only on save failure) should
move inline — Phase B.

### 2.3 Counting label drift: "Max" vs "Goal" — **Minor**
Commit f318ef4 standardized counting on "Goal" but missed two live inputs:
`CreateNewTaskForm.tsx:286` and `CreateNewTaskFormView.swift:180` still say "Max".
Doc-comments in `CountingStepFields.tsx:29` / `CountingStepFieldsView.swift:3,11,15`
are also stale. *Phase A, Fix 1.*

### 2.4 Inline-subtask "progress" option is half-broken — **Minor**
The composite wizard's inline-subtask type picker still offers "progress"
(`SubtaskCard.tsx:23`, `CompositeSubtaskItem.swift:14-19`) but it falls back to
normal on build (`CompositeTaskWizard.tsx:291-312`). It promises something it
doesn't deliver. **Recommendation:** drop "progress" from the inline picker as part
of Fix 2, or wire it through honestly. Nested-compound inline creation remains a
documented TODO (`CompositeTaskWizard.tsx:243`) — leave for the overhaul.

### 2.5 Counting title auto-generation is invisible — **Nit**
Title is optional for counting and auto-generated via `generateCounterTaskTitle()`,
but the only cue is placeholder text. **Recommendation:** explicit "auto-generated
from Action + Goal + Unit if left blank" helper — Phase C.

### 2.6 M_OF_N threshold clamps silently — **Minor**
Deleting subtasks silently lowers a set threshold (iOS note
`CompositeWizardBuildStepView.swift:56`). **Recommendation:** surface the clamp
("Required count lowered to N") — Phase C.

---

## 3. Findings — Board wizard flow

### 3.1 Compound placement is opaque — **Major**
Compounds can't be placed on a board directly; only their leaf children can. Yet
the default "Group subtasks" toggle (ON) *hides* those children from the flat list
(`BoardWizardTasksStep.tsx`), so a user looking for a subtask may not find it, and
a user selecting a compound's leaves gets no visual tie-back to the parent.
**Recommendation:** rethink the compound row as an expandable group that makes
"these leaves go on the board" obvious — Phase B.

### 3.2 No inline compound creation in the wizard — **Major**
Creating a compound requires leaving to the Tasks tab and returning. The wizard's
"+ New task" sheet supports normal/counting/achievement but routes compound out.
**Recommendation:** allow inline compound creation (the deferred-persist plumbing
from Bug #85 already exists) — Phase B.

### 3.3 Center-task picking is a 3-step dance — **Minor**
In CHOSEN mode the star (☆/★) only appears *after* a task is selected, so the user
must select → re-find the row → tap the star. **Recommendation:** show the star
affordance for all rows in CHOSEN mode, or let a single tap both select and center
— Phase B.

### 3.4 Modal-in-modal-in-modal — **Minor**
Wizard → Tasks step → "+ New task" sheet is three nested layers
(`NewTaskSheet.tsx:58-81`); the cancel dialog can add a fourth. Cognitive load on
small screens. **Recommendation:** flatten in the overhaul (push navigation instead
of stacked sheets) — Phase B.

### 3.5 Smaller edges — **Nit**
Web custom-date range is a bare text/`<input type=date>` with no calendar
(`BoardSetupForm.tsx`); drafts never auto-save (explicit "Save as Draft" only);
stale drafts accumulate with no cleanup; size→center coupling silently clears the
center choice with no toast. All Phase C.

---

## 4. Findings — First-run, onboarding & app-wide IA

### 4.1 Cold first run — **Major**
A new user lands on an empty Boards tab with text-only copy: *"No boards yet. Head
to the Create tab…"* (`BoardsPage.tsx:79-94`, iOS `BoardListView.swift:102-105`).
No inline CTA, no sample board, no tutorial. The first 5 minutes don't teach the
core loop (board = grid of task squares; complete tasks to make bingos).
**Recommendation:** inline "Create your first board" button on the empty state +
an optional seeded sample board; dismissible first-run explainer — Phase B.

### 4.2 Recurring boards are hidden behind opt-in — **Major**
The Core Boards section only appears after a timeframe is toggled on, and that
toggle lives 3 taps deep in Profile → Board preferences. New users never see one of
the app's headline features. **Recommendation:** default one timeframe (daily) ON
for new accounts so the section is visible immediately — Phase B.

### 4.3 "Create" tab ≠ create-anything — **Major**
The Create tab is board-only; task quick-add moved to the Tasks tab (a deliberate
Phase 6.2 choice, `CreateHubPage.tsx:71-74`). Both surfaces show "+ Create task"
affordances in different places, and the split surprises users who expect "Create"
to be the hub for making anything. **Recommendation:** in the overhaul, either a
single global "+" affordance that branches (board / task), or rename the tab to
"Boards +"/"New board" so its scope is honest — Phase B.

### 4.4 Recurring-template creation is implicit — **Minor**
Saving a board as recurring *is* the template-create path, but nothing says so; the
Recurring Templates page (Profile → Recurring templates, 2 taps) has no create
affordance and an empty state that points back to the wizard. **Recommendation:**
post-create confirmation that names the template and links to it — Phase B.

### 4.5 Silent cross-tab jumps & passive "needs attention" — **Nit**
Tapping a board from Tasks silently switches tabs; template pool problems show only
a passive badge on a page users rarely visit. **Recommendation:** light transition
feedback; surface template problems where the user already is — Phase C.

---

## 5. Bold / structural proposals (rethink-freely, for the overhaul)

These are larger bets the overhaul should weigh. Captured here so the thinking
isn't lost; not built in Phase A.

1. **Goal-first creation.** Replace the type-picker-first flow with a "What are you
   tracking?" entry: the user describes the goal in plain language / picks an intent
   ("a one-off thing", "a number I want to hit", "a multi-part goal", "track another
   board"), and the system *chooses the type*. Type names (Compound, Achievement)
   become implementation detail, not a quiz. This subsumes findings 2.1, 2.2, 2.6.
2. **Unify the "+".** One creation affordance app-wide that branches to board vs
   task, killing the Create-tab/Tasks-tab overlap (4.3) and shortening the recurring
   path (4.2).
3. **Warm onboarding.** First-run seeds a sample board the user can play
   immediately, with a 3-beat explainer of the core loop; resolves 4.1.
4. **Compound as a first-class wizard citizen.** Inline creation (3.2) + a clearer
   placement model (3.1) so compounds aren't a Tasks-tab-only concept.
5. **Flatten wizard navigation.** Replace stacked sheets with pushed navigation
   (3.4) and bring validation (cycle detection 2.2, threshold clamp 2.6, dates 3.5)
   inline rather than on-submit.

---

## 6. Phased roadmap

### Phase A — ship now (overhaul-safe, this PR set)
Corrects mental model + terminology; survives any visual redesign.
- **Fix 1** — counting "Max" → "Goal" (resolves 2.3).
- **Fix 2** — merge Progress/Composite → unified Compound + "Ordered steps" toggle;
  merge filter chips/badges; drop half-broken inline "progress" (resolves 2.1, 2.4).
- **Fix 3** — Achievement Greenlog/Bingo explainers + watcher/meta signposting
  (resolves 2.2 jargon + trap).

### Phase B — overhaul-coupled (design + build with the redesign)
Goal-first creation (§5.1), unified "+" (§5.2), warm onboarding (§5.3, resolves 4.1),
default-on recurring timeframe (4.2), Create/Tasks IA resolution (4.3), inline
compound creation + placement model (3.1, 3.2), center-task picker redesign (3.3),
flattened wizard nav + inline validation (3.4, 2.2 cycle, 2.6), template-create
confirmation (4.4).

### Phase C — post-overhaul polish
Counting auto-title hint (2.5), threshold-clamp notice (2.6), web date picker,
draft auto-save + cleanup, size→center coupling toast, cross-tab transition
feedback, surfacing template problems contextually (4.5).

---

## 7. Severity legend
- **Critical** — corrupts the user's mental model app-wide / blocks the core task.
- **Major** — happy-path confusion, dead-end, or hidden headline feature.
- **Minor** — friction or inconsistency that slows a competent user.
- **Nit** — polish; correctness-neutral.
