# Riso — Web design pass

The web translation of the shipped iOS "Riso" design language (a risograph-print
poster aesthetic). This doc is the canonical reference for the web Riso pass —
the foundation, conventions, and phase roadmap. The iOS counterpart is
[`docs/RISO_UI_CHECKLIST.md`](RISO_UI_CHECKLIST.md); the (gitignored) source
prototypes live under `design_handoff_web/`.

> **Why this exists separately from iOS:** the Riso redesign shipped on iOS
> first. Web had no Riso styling at all — every web screen already *worked* but
> looked pre-Riso. This pass is a **visual re-skin of working screens** (plus a
> few net-new surfaces), done phase-by-phase. See CLAUDE.md
> [§Intentional platform divergences](../CLAUDE.md).

## The non-negotiables (same as iOS)

- **Earned escalation.** The resting UI is quiet cream paper; ink "detonates"
  only as the user completes squares, hits bingos, and clears a board. Don't
  start loud.
- **greenlog = the page goes green, the squares stay red.** The board-clear
  celebration is a green *field*; the board's red squares keep their true color.
  **Never recolor squares green.**
- **Mascot-agnostic.** Compose around the bingo-board motif, not a character.
  Web uses a monogram avatar, never a mascot.

## Foundation (Phase 0 — shipped)

### Token layer — `apps/web/src/styles/riso.css`

CSS custom properties, imported after `index.css` in `main.tsx`. Token **values**
are lifted verbatim from the iOS design system so the platforms stay in lockstep.

- **Names are `--riso-*`-prefixed** so they coexist with the app's pre-Riso
  generic vars (`--bg-primary`, `--text-primary`, …) during the rollout. As each
  screen is re-skinned it switches to `--riso-*`; the old vars are removed once
  every screen has migrated. This keeps un-reskinned screens visually intact.
- **Theme rides the app's existing mechanism:** `[data-theme='dark']` on `<html>`
  (set by `useAppliedTheme`), **not** the prototype's `.night` body class.

| Token | Light | Dark | Usage |
|---|---|---|---|
| `--riso-paper` | `#F1E9D9` | `#171310` | page background |
| `--riso-paper-2` | `#FBF6EA` | `#221C15` | cards, inputs, cells |
| `--riso-ink` | `#18120B` | `#F1E9D9` | text, keylines, shadows (flips to cream) |
| `--riso-muted` | `#7E7460` | `#A39781` | secondary text |
| `--riso-blue` | `#2C44C9` | `#6678F2` | counting, active states, progress |
| `--riso-red` | `#EB4D2E` | `#FF6A4A` | primary buttons, done cells, danger |
| `--riso-green` | `#1F9B6B` | `#3BCB92` | success, completed, greenlog field |
| `--riso-gold` | `#FFC21F` | `#FFC21F` | bingo accents, FREE star (unchanged) |
| `--riso-achievement` | `#7A3FB0` | `#9D6AD8` | achievement task type |
| `--riso-on-color` | `#FBF6EA` | `#FBF6EA` | content on a **dark** fill (red/blue/green) |
| `--riso-ink-static` | `#18120B` | `#18120B` | content on a **light** fill (gold) + halftone dots |

**The dark contract (matches iOS `risoInkStatic`):** content placed on a colored
fill must **not** flip with the theme — it reads against the fill, not the page.
Which static token depends on the fill's lightness: **dark** fills
(red/blue/green) carry `--riso-on-color` (static cream); the **light** gold fill
carries `--riso-ink-static` (static dark) — using adaptive `--riso-ink` on gold
would go cream-on-gold in dark mode and fail WCAG AA. Adaptive `--riso-ink` is
only for content on `--riso-paper`/`--riso-paper-2`.

### Shape & motion (also in `riso.css`)

- **Keylines:** `2px solid var(--riso-ink)` on interactive containers.
- **Radii:** `--riso-r-card: 8px` (cards/inputs/buttons), `--riso-r-cell: 7px`
  (board cells), `999px` (chips/pills).
- **Hard offset shadows — no blur, ink-colored:** cards `4px 4px 0`, buttons
  `3px 3px 0`, small `2px 2px 0`, hero `8px 8px 0`. Hover lifts −1px and grows
  the offset; **press translates by the offset and collapses the shadow to 0**
  (~90ms — "press into paper").
- **Paper grain** (`.riso-grain`): fixed full-page dot screen, `mix-blend-mode`
  multiply (light) / screen (dark). Scoped to Riso surfaces until the app shell
  is re-skinned (so un-reskinned screens stay clean).
- **Halftone** (`.riso-halftone`): dot overprint on **completed cells only**
  (Phase 3).
- **Keyframes:** `risoCellPop`, `risoToastDrop`, `risoGreenlogIn`,
  `risoConfettiFall` — all disabled under `prefers-reduced-motion`. Canonical
  duration+easing for the three deterministic ones live in `--riso-anim-cell-pop`
  / `--riso-anim-toast-drop` / `--riso-anim-greenlog-in` (consume via
  `animation: risoCellPop var(--riso-anim-cell-pop)`); confetti is per-particle
  (random duration/delay). Entrance animations must animate **from** a hidden
  state to a visible resting state, never leave content at `opacity:0` at rest.

### Typography

- **Head / display / buttons / labels:** Bricolage Grotesque (700/800), tight
  tracking. CSS var `--riso-font-head`.
- **Body / metadata:** Archivo (400–900). CSS var `--riso-font-body`.
- Loaded via Google Fonts in `index.html`.

### Primitive kit — `apps/web/src/components/riso/`

Reusable, CSS-Module components — the web mirror of iOS
`Views/Riso/RisoControls.swift`. Import from the barrel (`../components/riso`).

| Component | API highlights | iOS counterpart |
|---|---|---|
| `RisoButton` | `kind` (neutral/primary/blue/green/gold/ghost/**dark**), `size` (default/large/small), `icon`, `fullWidth`. `dark` = the Apple sign-in slab, intentionally adaptive (black-on-light / white-on-dark). | `RisoButton` |
| `RisoCard` | `shadow` (small/default/large), `interactive`, `padded` | `.risoCard()` |
| `RisoChip` | `on` (selected → ink fill) | `RisoChip` |
| `RisoSegmented<T>` | generic single-select; `variant` card (blue active) / pill (ink active) | `RisoSegmented<T>` |
| `RisoSectionLabel` | `variant` section (muted) / kicker (red) | `risoSectionLabel` |
| `RisoIcon` | stroke-icon set (`name`, `size`); inherits `currentColor`; decorative unless given `aria-label` | SF Symbols |
| `RisoBrandMark` | 3×3 bingo-grid OYBC logo (`size`) — mascot-agnostic, markup not raster | (markup) |

The board cell, badge, toast, and greenlog overlay land with the play board
(Phase 3) — they're tied to bingo logic, not pure primitives.

### Verifying the kit

Dev-only showcase: `/playground` → "Riso Foundation — primitive kit (Phase 0)"
(`components/playground/RisoKitPlayground.tsx`) renders the real primitives with
a local day/night toggle. Use Playwright against it for visual checks.

## Phase 1 — Signed-out home (shipped)

The net-new marketing landing + auth, in `apps/web/src/components/signedOut/`:

- `SignedOutHome.tsx` — the poster landing (nav · hero with the rotated poster
  board · "How it works" 3-beat escalation · "Not just a checkbox" 4 type
  cards · red footer CTA). Owns its theme (pre-auth) and the auth-modal state.
- `SignInModal.tsx` — Apple / Google / email+password, wired to the **real**
  `useAuth()`. A password field was added vs the prototype's email-only stub;
  on success the AuthProvider's user flips non-null and `AuthGate` swaps the
  whole tree for the app, so the modal needs no explicit success callback.
- `SignedOutArt.tsx` — the static poster grids (hero / beat minis / modal art).
- `useSignedOutTheme.ts` — mirrors a light/dark choice to `[data-theme]` on
  `<html>` (the signed-out page can't use `useAppliedTheme`, which reads the
  signed-in user row); persisted to `localStorage`. `useAppliedTheme` takes over
  the attribute once signed in.

`AuthGate.tsx` now renders `SignedOutHome` when signed out (it replaced the old
inline login form). The "On Your Bingo Card" wordmark is the correct app-name
expansion — the handoff prototype's "Own Your Bingo Card" is a typo; don't copy it.

## Phase 2a — App shell + nav (in review)

The signed-in chrome, in `apps/web/src/components/appShell/`:

- `AppShell.tsx` — wraps the authenticated routes: `AppTopNav` (sticky) + paper
  canvas + `AppBottomNav` (fixed, mobile-only). Replaces the old bottom-only
  `TabBar` (deleted). Owns the single active-boards live query, passing the
  count to both nav bars.
- `AppTopNav.tsx` — brand mark + wordmark + primary tabs (Home · Boards · Tasks
  · You, ink-active pill) + theme toggle (`RisoSegmented` pill, writes the theme
  preference; displays the *resolved* theme via `useAppliedTheme` so it's
  correct under `system`) + New board (→/create) + avatar (→/profile). At ≤760px
  the tabs hide and the controls collapse to icons.
- `AppBottomNav.tsx` — the same `NAV_ITEMS` as a fixed bottom tab bar, shown only
  at ≤760px (a real per-breakpoint layout, not the prototype's CSS-reparenting).
- `navItems.ts` — shared tab defs + `isNavItemActive` (exact or `path + '/'`).
- New `/home` route → `HomePage` (Phase 2a ships a minimal greeting; the rich
  resume content is 2b). `/` and `*` now land on `/home`.

Theme note: the nav toggle is Day/Night only — the full System/Light/Dark
control stays on the Profile screen (Phase 5). Clicking it overwrites a `system`
preference with an explicit choice (by design; restore System from Profile).

## Phase roadmap

| Phase | Scope | Status |
|---|---|---|
| **0** | Token layer + fonts + grain/halftone/shadow utilities + primitive kit | **shipped** |
| **1** | Auth shell + signed-out marketing home (net-new) + sign-in modal | **shipped** |
| 2a | App shell + nav — top nav (→ mobile bottom tab bar) + minimal Home route | **in review** |
| 2b | Home/Resume landing — streak pill, resume panel w/ live poster, active-boards rail | planned |
| 3 | Play board + Boards (cell escalation, halftone, gold bingo line, greenlog, toast) | planned |
| 4 | Create wizard + Tasks library | planned |
| 5 | Profile + sub-pages (Streaks, prefs, templates, pools, Account & security, Sync sheet) | planned |

**Fold-ins for this pass** (pre-existing web follow-ups from CLAUDE.md): gate
`/playground` behind `import.meta.env.DEV`; replace the raw-error leak in web
`SyncStatusIndicator` with the iOS minimal three-state row; web draft-board
containment (`createdInWizard` hidden until active; drafts never playable).

## Conventions for re-skinning a screen

1. Build with the primitive kit and `--riso-*` tokens — no magic numbers, no
   ad-hoc button/card CSS.
2. Keep the screen's existing data/routing/logic; this is a visual pass.
3. Honor `prefers-reduced-motion` and the entrance-animation rule.
4. Mirror copy from the (gitignored) `design_handoff_web/` source files.
5. Web is single-platform here (iOS already has Riso) — no cross-platform mirror
   needed, but keep token/primitive names parallel to iOS.
