# OYBC — Riso design system

The web component kit for **OYBC (On Your Bingo Card)** — a risograph-print poster
aesthetic (hard offset shadows, paper fills, bold grotesque type, a light/dark
"day press / night press" contract). Eight primitives: `RisoButton`, `RisoCard`,
`RisoChip`, `RisoSegmented`, `RisoSectionLabel`, `RisoIcon`, `RisoBrandMark`,
`RisoBadge`. Compose screens from these + the tokens below — do not hand-roll
buttons/cards/badges.

## Setup — no provider, just tokens + a themed root

There is **no context provider**. The components are self-contained; they read
their look from CSS custom properties defined in `styles.css` (already loaded).
For a design to look on-brand, set these on the page root and inherit them:

```jsx
<div
  data-theme="light" /* or "dark" — flips the whole palette */
  style={{
    background: 'var(--riso-paper)',
    color: 'var(--riso-ink)',
    fontFamily: 'var(--riso-font-body)',
    minHeight: '100vh',
  }}
>
  {/* your screen */}
</div>
```

- **Dark mode**: set `data-theme="dark"` on an ancestor (`:root`/`<html>` in the
  real app). Paper, ink, and the accent colors all flip; gold and the on-color
  statics do not. Never hard-code hex — always use the tokens so both themes work.
- **Fonts** load via `@font-face` in the closure: **Bricolage Grotesque**
  (`--riso-font-head`, display/headlines) and **Archivo** (`--riso-font-body`, UI/body).

## Styling idiom — CSS custom properties (`var(--riso-*)`)

Style your own layout glue with these tokens (real names — all defined in
`styles.css`). Never invent color values.

| Group | Tokens |
|---|---|
| Surfaces | `--riso-paper` (page), `--riso-paper-2` (cards/inputs/cells) |
| Text | `--riso-ink` (primary), `--riso-muted` (secondary) |
| Accents | `--riso-blue` (counting/active/progress), `--riso-red` (primary/danger/done), `--riso-green` (success/greenlog), `--riso-gold` (bingo/FREE/highlights), `--riso-achievement` (achievement type) |
| On a fill | `--riso-on-color` (cream — for text on DARK fills: red/blue/green), `--riso-ink-static` (dark — for text on the GOLD fill) |
| Type | `--riso-font-head` (Bricolage), `--riso-font-body` (Archivo) |
| Shape | `--riso-r-card` (8px), `--riso-r-cell` (7px) |
| Lines/shadow | `--riso-hair` (dividers), `--riso-shadow-ink` (the hard offset shadow ink) |

**Dark contract (critical):** text placed on a *colored fill* must use a static
foreground so it does not flip in dark mode — `--riso-on-color` on red/blue/green
fills, `--riso-ink-static` on the gold fill. Adaptive `--riso-ink`/`--riso-muted`
are only for text/borders on paper.

**Texture utilities:** add `className="riso-grain"` to a paper surface for the
poster dot-screen; `riso-halftone` overlays a completed-cell halftone.

## Component notes

- `RisoButton` / `RisoChip` **do not accept `className`** — style via props
  (`kind`, `size`, `on`) only. `RisoCard`, `RisoIcon` **do** accept `className`.
- `RisoSegmented` is controlled (`value` + `onChange`) and **requires `aria-label`**.
- `RisoIcon` strokes inherit `currentColor` — set the parent's `color` (a token)
  to tint an icon.
- Read each component's `.d.ts` (props) and `.prompt.md` (usage) before composing.

## Real import path

In the OYBC codebase these are barrel-exported — engineers import from
`@/components/riso` (e.g. `import { RisoButton, RisoCard } from '@/components/riso'`).

## Idiomatic example

```jsx
import { RisoCard, RisoSectionLabel, RisoBadge, RisoButton } from '@/components/riso';

<RisoCard padded>
  <RisoSectionLabel variant="kicker">This week</RisoSectionLabel>
  <div style={{ fontFamily: 'var(--riso-font-head)', fontSize: 20, fontWeight: 700, margin: '6px 0' }}>
    Morning routine
  </div>
  <div style={{ display: 'flex', gap: 8, alignItems: 'center', marginBottom: 12 }}>
    <RisoBadge kind="active">Active</RisoBadge>
    <span style={{ color: 'var(--riso-muted)' }}>4 of 9 squares</span>
  </div>
  <RisoButton kind="primary" size="small">Open board</RisoButton>
</RisoCard>
```
