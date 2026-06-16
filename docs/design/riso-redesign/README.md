# Handoff: OYBC "Riso" Design Overhaul

## Overview

A complete visual redesign of OYBC (bingo-board habit/goal tracker for iOS) in the **"Riso" direction**: a bold risograph-print poster aesthetic — cream paper, hard black keylines, hard offset shadows, halftone overprint texture, and a confident three-ink palette. The core design principle is **escalation**: the resting UI is quiet paper, and ink "detonates" as the user completes squares, hits bingos, and finally GREENLOGs a board. Loudness is earned, never ambient.

This package covers all four tabs (Boards, Tasks, Create, Profile), the 5×5 play board with win states, the reworked board-creation wizard (including the redesigned Tasks step), the first-run onboarding + sign-in, the GREENLOG share flow, edit-profile, and a full dark mode ("night press").

## About the Design Files

The files in this bundle are **design references created in HTML** (React + JSX prototypes). They show intended look and behavior — they are **not production code to copy directly**. The task is to **recreate these designs in the existing SwiftUI codebase** (`Views/` — BoardsTab, TasksTab, CreateTab, ProfileTab), reusing its established patterns: GRDB models, `WizardStep` flow, `TaskLibraryViewModel` filters, `CompositeSubtaskItem`, etc. The prototype was deliberately modeled on those view models, so most screens map 1:1 onto existing Swift files.

## Fidelity

**High-fidelity.** Colors, typography, spacing, radii, shadows, copy, and interactions are final design intent. Recreate pixel-perfectly in SwiftUI. Two exceptions, noted inline below: the Blip mascot is a placeholder built from shapes (final illustrated asset TBD — but its **motion spec is final**, see Assets), and iOS-native conventions (swipe actions, sheets, haptics) should be used where the web prototype substituted tap-based equivalents.

## Design Tokens

### Color — light ("day press", default)

| Token | Hex | Usage |
|---|---|---|
| `paper` | `#F1E9D9` | App background |
| `paper2` | `#FBF6EA` | Cards, cells, inputs, tab bar |
| `ink` | `#18120B` | Text, keylines, hard shadows |
| `muted` | `#7E7460` | Secondary text, placeholders |
| `blue` | `#2C44C9` | Counting type, active states, progress fills, GREENLOG bg |
| `red` | `#EB4D2E` | Primary buttons, done cells, danger |
| `green` | `#1F9B6B` | Compound type, success, completed badge |
| `gold` | `#FFC21F` | Bingo accents, FREE star, selection highlights, checkmarks |
| `achievement purple` | `#7A3FB0` | Achievement type badge/tag only |

### Color — dark ("night press")

| Token | Hex |
|---|---|
| `paper` | `#171310` (warm near-black) |
| `paper2` | `#221C15` |
| `ink` | `#F1E9D9` (cream — keylines/text flip to cream) |
| `muted` | `#A39781` |
| `blue` | `#6678F2` · `red` `#FF6A4A` · `green` `#3BCB92` (brightened to hold against dark) |
| achievement purple | `#9D6AD8` with dark text |

Gold stays `#FFC21F` in both modes. Night press also: scrim darkens to 60%, halftone overlay opacity drops .55→.4, FREE cell goes full black, paper grain flecks flip to cream at `screen` blend.

Alternative light palettes offered as user-selectable ink sets (kept in Tweaks): Ink & Tangerine `#1E2A78/#F2862E/#2FA36B`, Berry Press `#6B3FB0/#D6336C/#2E8B57`, Sea & Coral `#127C8A/#F0513C/#2E8B57`. Dark twins not yet designed.

### Typography

| Role | Font | Notes |
|---|---|---|
| Headings / display / buttons / labels | **Bricolage Grotesque** — 700/800 | Tight tracking (−.02 to −.03 em). H1 34px/0.92, H2 22px, card names 19px |
| Body / metadata | **Archivo** — 400–800 | 11–15px range; section labels 11px, 700, +.1em, uppercase |

(iOS: bundle both via Google Fonts licenses, or substitute closest SF-compatible pairing if bundling is undesirable — but the display face is a large part of the identity.)

### Shape & depth

- **Keylines**: 2px solid ink on interactive containers; 1.5px on dense rows/chips
- **Radii**: cards/inputs/buttons 7px (`--r-card`), board cells 6px, chips/pills 999px
- **Hard shadows** (no blur, ink color): cards `4px 4px 0`, buttons `3px 3px 0`, small elements `2px 2px 0`. Press state = translate by the shadow offset + shadow collapses to 0 (the "press into the paper" effect, ~80–120ms)
- **Paper grain**: 3px-tile dot grid at ~5% ink, multiply blend, across the whole background
- **Halftone overprint**: radial-gradient dot screen (7px tile, dot ≈26–28%, multiply, ~55% opacity) over **completed** cells only

### Spacing

Screen gutter 20px · card padding 13–16px · grid gap 7px (board cells) · list row gap 7px · section gaps 14–18px. Tab bar 2px top keyline, ~64px + safe area.

## Screens / Views

### 0. Onboarding & sign-in (`OnboardingView.swift` — new)

First-run only (gated on a persisted flag; cleared, it replays). Full-bleed paper, no tab bar.

- **Three intro slides** (horizontal, swipe or Next): each is centered art + left-aligned copy. (1) red-filled poster grid + kicker "Welcome to" / wordmark **OYBC** (64px) / "Own Your Bingo Card…"; (2) a board with one row + a diagonal lit, gold rings on the bingo line + kicker "The idea" / "Fill squares, score bingos."; (3) full red board + "The payoff" / "Clear it for a GREENLOG." Progress is a row of dots (active dot is a stretched red pill). **Skip** top-right on every slide; **Back** appears from slide 2.
- **Sign-in panel** (after slide 3 → "Get started"): centered Blip (happy), kicker "One last thing", "Save your streak.", body, then **Continue with Apple** (ink-fill pill, Apple glyph), **Continue with email** (keyline pill), and a muted **Maybe later**. All three dismiss onboarding into Boards home. Wire Apple to real Sign in with Apple; "Maybe later" = anonymous/local.
- Entrance: each slide slides in (transform only — never gate content on opacity, so first paint and reduced-motion always show it).
- Prototype: clears on the "Replay onboarding" tweak; hash `#onboard`.

### 1. Boards home (`BoardListView.swift`)

- **Header**: kicker "YOUR BOARDS" (12px, red, +.22em caps) over the display headline `BINGO, but make it your goals.` (3 lines, 34px). Gold 46px square icon-button (+) top-right, 2px keyline + hard shadow. Header scrolls away with content (not sticky).
- **Core timeframe strip — 2×2 grid** (locked decision): four cards (Daily / Weekly / Monthly / Yearly) in a 2-column grid, each with uppercase label + status word ("Ready" / "Active" / "Expiring") and an 8px status dot (green=active, gold=expiring, paper=empty). There is exactly **one core board per timeframe** — show status, never counts. Custom boards appear in the list only.
- **Filter chips**: All / Active / Completed / Draft — pill chips, 2px keyline, selected = ink fill, paper text.
- **Board cards**: name (19px Bricolage 800, single line, ellipsis), timeframe subtitle, status badge (pill, 2px keyline: Active=blue, Completed=green, Draft=paper/muted, Expiring=gold), 5×5 **mini-grid thumbnail** (46px wide, 1px keylines, red filled = done squares), 12px progress bar (2px keyline, red fill; green when completed), meta line "14/25 squares · ★ 1 bingo".
- **Empty state**: Blip mascot (calm mood), "Nothing here yet", body copy, red primary button.

### 2. Play board (`BoardPlayView.swift`) — the core screen

- **Header**: back square button (40px, keyline + 2px shadow), kicker "WEEKLY BOARD" + board name, Active badge.
- **Stat bar** (3 cards): Squares `14/25` + mini progress bar · Left `4d` "to fill it" · **Bingos** card in solid gold with black star + count.
- **The grid**: 5 columns, 7px gaps, square cells:
  - **Resting (incomplete)**: paper2 bg, 1.5px keyline, 9px/700 Archivo centered label (3-line clamp). Quiet.
  - **Done**: ink fill by type (normal=red, counting=blue, compound=green), 2px keyline, 2.5px hard shadow + translate(−1,−1), halftone overlay, cream text, 15px gold check circle top-right. Completion animates: pop scale .9→1.12→1 (~340ms, springy ease).
  - **Counting cells**: `×8` type tag top-left (blue pill), bottom progress bar (9px, keyline, blue fill, "6/10" centered 6.5px). Tap → **stepper popover**: dimmed tap-away veil, ink label pill ("10k steps · 6/10 k"), pill stepper −/value/+ (38px buttons, gold press flash). In SwiftUI use a small sheet or popover anchored above the tab bar.
  - **Compound cells**: `C` green tag, green progress bar of completed subs.
  - **FREE (center)**: ink-black cell, gold star + "FREE" in gold caps. Night press: full black.
  - **Bingo-line cells**: 3px gold outer ring (`box-shadow: 0 0 0 3px gold` on top of the hard shadow), z-raised.
- **Bingo toast**: drops from top (translateY −90→+6→0 with slight rotate, ~500ms), blue card, 2px keyline, 4px hard shadow: Blip art (42px) + "BINGO!" 19px + subtitle + gold `×2` count 26px. Auto-dismiss ~2.8s.
- **GREENLOG overlay**: full-bleed blue takeover. Falling confetti (ink-keylined squares/circles in red/gold/green/paper, ~1.6–3.2s linear loops; count scales 16–88 with the celebration-intensity setting, default 7 → ~64). Blip (cheer mood, 108px), kicker "BOARD COMPLETE" (gold), "GREENLOG!" 52px/0.88, subtitle, three stat blocks (paper cards, keyline+shadow: 25/25 Squares · 5 Bingos · 7d Streak), red primary "Share my board" → **opens the Share sheet** + outlined-cream ghost "Start a new board".

### 2a. Share board sheet (`ShareBoardSheet.swift` — new)

Bottom sheet opened from GREENLOG's "Share my board" (prototype hash `#share`; tweak button). The GREENLOG stays underneath.

- **Shareable poster card**: blue card with halftone overprint, 2px keyline + 4px hard shadow. Top row: green **GREENLOG** badge + **OYBC** wordmark. Board name (22px). Full 5×5 mini grid (red done cells with halftone, gold FREE center). Optional stat trio (Squares / Bingos / Streak as paper cards). Footer caps "OWN YOUR BINGO CARD". This card is what gets rendered to an image for sharing.
- **Include stats toggle** (ink pill switch) shows/hides the stat trio on the card.
- **Copy link** row (keyline card + hard shadow): link icon + `oybc.app/b/…`; tap → turns green, icon → check, label → "Link copied".
- **Targets**: 4 keyline icon-squares (hard shadow, press-collapse) — Messages (green), Stories (red), Save image (ink), More (paper). Wire to the iOS share sheet / `UIActivityViewController`; "Save image" renders the poster card to Photos.

### 1 (cont.) Boards home

### 3. Create wizard (`BoardWizardView.swift` + steps)

Tab bar **stays visible** (Create is a tab, not a modal). Footer Cancel/Back + Next/Create buttons sit above it.

- **Stepper**: 3 numbered dots (26px circles, 2px keyline) — active=red, done=green with check — joined by 2px lines at 25% ink, labels Setup / Tasks / Preview.
- **Step 1 Setup**: Board name input (2px keyline; focus = 3px hard shadow, no glow) · Timeframe segmented (Daily/Weekly/Monthly/Yearly, selected=blue) + dashed-keyline date note ("This week · Jun 8 – 14", one line) · Board size cards 3×3/4×4/5×5 (dot-matrix previews; selected = gold fill + hard shadow, dots turn red) · Center square segmented (Free Space / I'll choose / None).
- **Step 2 Tasks** — fully redesigned; the locked decisions:
  - **Pool header card**: "YOUR TASK POOL" + big `N/24` count, progress bar (blue), and the **pool model** note: short = "Add N more — extras later just shuffle into the mix"; met/exceeded = green "✓ Fills your board · N extra shuffle in each week".
  - **Quick add (A1)**: input + red Add button; **Enter also submits** (no visible hint). Creates Normal tasks.
  - **Special task panel** (collapsed dashed button "＋ Add a counting, compound or achievement task"): type chips Counting/Compound/Achievement, then type-specific fields:
    - **Counting**: Action / Goal / Unit; live preview "reads as **Run 5 km**" (title auto-generated).
    - **Compound**: Title · rule chips **All of / Any of / At least N (stepper) / In order** · sub-task builder. Sub input has **smart autocomplete** — typing surfaces matching library tasks inline ("↩ Drink water · 8 cups · reuse"); tap = pulled in as existing sub (dashed chip + type dot). "New sub: Normal / Counting" chip row beneath; Counting flips the input to **Action** + goal/unit row with live title preview. Min 2 subs to commit. New compound subs limited to Normal/Counting (no nested compounds in this flow).
    - **Achievement**: Title · Watch a… Specific board / Recurring template · target dropdown · Completes on **GREENLOG / First Bingo** · required-count stepper for templates.
  - **Library access — bottom sheet** (locked decision): dashed "⌕ Add from your library [N]" opens a sheet (76% height, scrim, grab handle, gold "Done · N" pill). Inside: search, filter chips All/Normal/Counting/Compound/**From a board…**, and rich rows: type letter badge (N/C/K), title, detail subtitle, **"N bds" usage count**, ＋/✓. **Tap row = toggle** add/remove (added = green left bar + ✓). Counting rows offer **"⇲ Derive smaller"** → inline stepper → adds a linked sub-counter (pool detail shows "↔ source"; ties into shared counters). Compound rows expand ("▸ 3 sub-tasks") to add children individually. "From a board…" lists boards → that board's tasks (pool rows tagged "from <board>").
  - **Pool list**: rows with grip, name, type-detail subtitle ("All of 3", "Run · goal 5 km", "Watch 26 Books in '26 · GREENLOG"), colored type tag, remove ✕.
- **Step 3 Preview**: centered board name + meta, mini board grid (keyline cells with task titles at thumbnail size, ink FREE cell with gold star), dashed note, "Create board ✦" primary.

### 4. Tasks tab (`TasksTabView.swift`)

- Header "Tasks" + gold +. Controls: search field, type chips (All/Normal/Counting/Compound/Achievement), sort chips **Recent / Most used / A–Z** + live count.
- **Rows**: type letter badge (N/C/K/A — A in achievement purple), title, subtitle (counting = "Action · goal N unit"; compound = "3 sub-tasks · all of 3"; achievement = "Watch <target> · GREENLOG"), right column **"N bds"** + green "N active".
- **Compound grouping**: chevron expands indented dashed child rows. **Search auto-expands** compounds whose children match, and keeps the parent in results (mirrors `effectiveExpanded` / `autoExpandCompoundIds`).
- **Detail bottom sheet** (tap row; in SwiftUI also keep swipe actions): big badge + title + type tag, Details line, Usage line ("On 4 boards · 3 active · used 23× all-time"), sub-task chips, **Edit** + **Delete with impact confirm** ("It's on 4 boards — squares using it will be cleared") per `TaskDeletionImpact`.
- **Edit mode** (in the same sheet, replaces its content): Title field, then type-specific fields — Counting: Action/Goal/Unit + live "reads as" preview · Compound: rule chips (tapping "At least N" again cycles N) + removable sub-task chips (min 2 to save) · Achievement: Completes-on chips (GREENLOG / First Bingo; target is fixed — recreate the task to change it). When placed, a dashed impact note: "Changes apply everywhere it's placed — updates N boards." Cancel / red Save (disabled until valid). Saving updates the library row and the open sheet in place.
- **+ → New task sheet**: quick-add composer + the same special-type panel. Note copy: tasks land in the library; placement happens in Create.

### 5. Profile tab (`ProfileView.swift`)

- Account card: circular keyline avatar (Blip placeholder), name + ✎ (**tap name/✎ → Edit profile sheet**), email.
- **App**: Theme row with **System / Light / Dark** segmented pill (drives night press app-wide) · Sync row with green status dot ("Synced · just now").
- **Preferences**: Board preferences · Recurring templates `[3]` · Default pools `[2]` — keyline icon squares, count pills, chevrons. Each pushes a sub-page (below).
- **Sign Out**: red row → inline dashed-red confirm (Cancel / solid-red Sign Out). **No Developer/Playground section** (removed by decision).
- Version footer line.

### 5a. Profile sub-pages (pushed screens, back square + "PROFILE" kicker + page title)

- **Board preferences** (`BoardPreferencesView` — new): three keyline cards.
  - *New boards*: Default size (3×3/4×4/5×5 segmented) · Center square (Free / Choose / None) · Week starts (Mon/Sun, hint "Sets when weekly boards reset and renew.").
  - *Playing*: **Celebration intensity** — a 10-tick tap strip (gold fill up to value; ticks 8–10 fill red), value caption "7 · Full press" (words: Whisper/Quiet/Steady/Full press/Loud/Detonate). This is the same app-global setting that scales confetti. · Haptics toggle.
  - *Housekeeping*: Expiring reminders toggle · Auto-archive completed toggle (hints under labels).
  - Toggles are keyline pill switches, knob slides, track turns green when on. Footer note: "Defaults apply to new boards — existing boards keep their settings."
- **Recurring templates**: caption "Templates press a fresh core board each cycle — same pool, reshuffled squares." Cards: name + timeframe tag (Daily=gold, Weekly=blue, Monthly=green, Yearly=red) + switch; meta line "3×3 board · 9-task pool · renews every morning". Off = paused: paper bg, name/meta dimmed, meta says "paused". **Tap a card to edit; dashed "＋ New template" to create — both open the template editor sheet (below).** Footer "Pausing a template keeps its pool — it just stops printing new boards."
  - **Template editor sheet** (`TemplateEditSheet` — new): Name field · Timeframe segmented (Daily/Weekly/Monthly/Yearly, selected tints to the timeframe color) · Board size (3×3/4×4/5×5) · context-dependent **Renews on** control — Weekly shows a 7-day picker (M–S), Monthly shows 1st/15th/last-day, Daily/Yearly are implicit (every morning / Jan 1) · **Deals from pool** selector (lists the default pools; pool's task count flows into the template) · Start-active toggle · a dashed live preview line ("5×5 board · 14-task pool · renews Mondays") · Cancel / red Save (disabled until named) · Delete (red, edit mode only).
- **Default pools**: caption "When a core board renews, its squares are dealt from these pools…". Cards: name + "feeds Weekly/Daily" tag, task chips + blue "+N more", meta "14 tasks · tap to edit". **Tap a card to edit; dashed "＋ New pool" to create — both open the pool editor sheet (below).** Templates and pools share one source of truth: a pool's task count drives the "N-task pool" shown on every template that deals from it.
  - **Pool editor sheet** (`PoolEditSheet` — new): Name field · **Feeds** timeframe segmented (sets the tag color) · **Tasks** list as removable chips (✕) with an "Add a task…" input (Enter or red Add) · dashed live preview ("Feeds Weekly boards · 14 tasks in the deck") · Cancel / red Save (disabled until named + ≥1 task) · Delete (edit mode only). (Pulling existing library tasks into a pool happens in Create → library; this sheet is for quick authoring.)
- Prototype URL hashes: `#prefs`, `#templates`, `#pools`.

### 5b. Edit profile sheet (`EditProfileSheet.swift` — new)

Bottom sheet from the account card's name/✎.

- Large circular Blip avatar preview (keyline + hard shadow) reflecting the chosen mood.
- **Blip mood** picker: three keyline cards (Happy / Cheer / Calm), each a small live Blip; selected = gold fill + hard shadow. (Blip is the avatar until the illustrated asset ships; mood is the user's avatar style.)
- **Display name** text field (live-updates the avatar preview's label on save).
- **Email** field shown disabled with hint "Change your email from Account security."
- Red **Save profile** (disabled until name non-empty) → writes back to the account card (name + avatar mood). Done dismisses.

## Interactions & Behavior (summary of timings)

- Button/card press: translate(shadow offset) + shadow→0, 80–120ms
- Cell completion pop: ~340ms spring; bingo-line gold ring appears with the recompute
- Bingo toast: ~500ms drop-in, ~2.8s dwell
- GREENLOG: fires ~520ms after the 25th square (let the cell pop land first); confetti loops while visible
- Bottom sheets: ~280ms slide-up w/ slight overshoot; scrim tap or Done dismisses
- Bingo detection: rows + columns + 2 diagonals; count increase (not just any change) triggers the toast

## State Management

Maps onto existing view models — no new architecture needed. Key points: board cell state recomputes line-membership set on every toggle; wizard pool is a simple ordered array (new items prepended); library sheet toggling adds/removes by case-insensitive title match; theme preference is app-global (existing theme setting); celebration intensity (1–10, default 7) scales confetti count only.

## Assets

- **Screenshots** (`screenshots/`): visual reference for every screen, light + dark — `01` Boards home · `02` Play board · `03` Wizard Setup · `04` Wizard Tasks step · `05` Tasks tab · `06` Profile · `07` GREENLOG celebration · `08` Board preferences · `09` Recurring templates · `10` Default pools · `11` Task edit sheet · `12` Onboarding intro · `13` Onboarding sign-in · `14` Share board sheet · `15` Edit profile sheet · `16` Template editor · `17` Pool editor (08–17 light only). Note: these are DOM re-renders — entrance animations are frozen at frame 0 by the capture tool, so a couple were shot with motion suppressed; the live prototype is the source of truth.

- **Fonts**: Bricolage Grotesque, Archivo (Google Fonts)
- **Blip mascot** (placeholder): overprint sticker character — red circle (multiply) behind blue halftone circle body, cream/ink eyes, gold grin, gold star spark; moods: happy/cheer/calm. Built entirely from shapes in `components.jsx` — **final illustrated asset to be commissioned**; keep the overprint/halftone language.
- **Blip motion** (final spec; user toggle "Animated Blip", default on, and respect Reduce Motion):
  - *Idle*: whole character bobs ±3px, 3.4s ease-in-out loop (5s for calm mood); eyes blink (scaleY → .12 for ~90ms every ~4.6s); star spark pulses scale 1→1.22 with 16° rotate, same 3.4s period.
  - *Cheer* (GREENLOG): squash-and-stretch hop on top of the bob — 0.9s loop, sink to scale(1.07,.9), hop −7px at scale(.95,1.08), settle; spark spins continuously (1.8s/turn).
  - *Bingo toast*: one ±7° wiggle (~0.65s) as the toast lands, then back to idle.
  - Mouth morphs between moods with a .25s ease (animate the shape, don't crossfade).
- **Icons**: simple 2px-stroke line icons (boards grid, tasks list, create ⊕, profile) — use SF Symbols equivalents at matching weights.
- No raster images anywhere.

## Files

| File | Contents |
|---|---|
| `OYBC Riso Prototype.html` | Entry point — load order, fonts, page scaling |
| `proto/riso.css` | **The design system** — all tokens, every component style, night-press overrides |
| `proto/app.jsx` | App state, navigation, bingo/GREENLOG triggers, theme switching, Tweaks |
| `proto/screens.jsx` | Boards home, play board, GREENLOG overlay, board cards |
| `proto/extras.jsx` | Onboarding (intro + sign-in), Share board sheet, Edit profile sheet |
| `proto/wizard.jsx` | 3-step wizard shell |
| `proto/taskstep.jsx` | Tasks step: pool, quick-add, special-type panel (counting/compound/achievement) |
| `proto/library.jsx` | Library browser + bottom sheet, derive, From-a-board |
| `proto/tabs.jsx` | Tasks tab (incl. task edit sheet) + Profile tab |
| `proto/profilepages.jsx` | Profile sub-pages: Board preferences, Recurring templates (+ editor), Default pools (+ editor) |
| `proto/components.jsx` | Blip mascot (incl. motion structure), icons, confetti |
| `proto/data.js` | Sample data shapes (boards, library, watch targets) |
| `proto/ios-frame.jsx`, `proto/tweaks-panel.jsx` | Prototype scaffolding only — ignore for implementation |

Open the HTML in a browser to interact with everything; URL hashes `#board`, `#wiz`, `#tasks`, `#profile`, `#prefs`, `#templates`, `#pools`, `#gl` (GREENLOG), `#share`, `#onboard` jump to specific states.
