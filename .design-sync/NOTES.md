# design-sync notes — OYBC Riso kit

Repo-specific gotchas for future syncs of `@oybc/web`'s Riso design system
(`apps/web/src/components/riso/`). Read before re-running.

## Setup that isn't obvious

- **`@oybc/web` is a Vite APP, not a component library** — `vite build` emits an
  app bundle, NOT importable component ESM. There is no `dist/` entry that exports
  the Riso components. So the converter bundles **directly from the barrel source**:
  `--entry ./apps/web/src/components/riso/index.ts` (esbuild bundles the `.tsx` +
  their `.module.css` from source). Keep this `--entry`; without it the converter
  sets `PKG_DIR = <nm>/@oybc/web`, which pnpm doesn't self-install → wrong root.
- **Components are pinned explicitly** via `cfg.componentSrcMap` (all 8). With
  `--entry` set the converter's discovery reads the shipped `.d.ts` tree (there
  is none for source `.tsx`), so it found ZERO components until they were pinned.
- **Props are hand-written** in `cfg.dtsPropsFor` (all 8). Same root cause: no
  shipped `.d.ts` tree → ts-morph auto-extraction produced `{ [key: string]:
  unknown }` stubs. The hand-written bodies mirror each component's real
  `*Props` interface. **⚠ Re-sync risk:** if a component's props change in
  source (`RisoButton.tsx` etc.), `dtsPropsFor` won't auto-update — re-read the
  source and update the config by hand.
- **Tokens ship via `cfg.cssEntry = src/styles/riso.css`**, NOT `tokensGlob`.
  `copyTokens` requires a separately-installed `tokensPkg`; OYBC's tokens are
  in-source in the same package, so `tokensGlob` alone was inert (empty
  `tokens/`). `cssEntry` appends riso.css (the `:root` + `[data-theme='dark']`
  token layer + `.riso-grain`/`.riso-halftone` utilities) into `_ds_bundle.css`,
  which is in the `styles.css` closure. This is what makes designs render styled.

## Fonts

- Bricolage Grotesque + Archivo are **Google-hosted** (loaded via a `<link>` in
  the real app's `index.html`). Shipped here via `cfg.extraFonts =
  ["../../.design-sync/fonts/riso-webfonts.css"]` — a committed CSS with 30
  `@font-face` rules whose `src` are **remote gstatic URLs** (extractFonts leaves
  `https:` urls as-is). Chromium loads them at render, same as the real app.
- The path is **package-relative** (`cfgPath` resolves against `PKG_DIR = apps/web`),
  hence the `../../` up to the repo-root `.design-sync/`. A bare
  `.design-sync/...` resolves to `apps/web/.design-sync/...` → "not found".
- `riso-webfonts.css` was fetched from the CSS2 API (weight-only; the app's
  `opsz` optical-size axis was dropped because Google returns 400 for the
  `opsz,wght@12..96,500;...` mixed range+list selector). Regenerate with:
  `curl -A "<Chrome UA>" "https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:wght@500;600;700;800&family=Archivo:wght@400;500;600;700;800;900&display=swap"`.

## Build / verify commands

```sh
# build
node .ds-sync/package-build.mjs --config .design-sync/config.json \
  --node-modules apps/web/node_modules \
  --entry ./apps/web/src/components/riso/index.ts --out ./ds-bundle
# validate (needs playwright+chromium; installed under .ds-sync/node_modules + ~/Library/Caches/ms-playwright)
node .ds-sync/package-validate.mjs ./ds-bundle
```

- The `.ds-sync/` npm install must use a scratch `--cache` dir — `~/.npm` has a
  permission problem on this machine (`sudo chown -R 501:20 ~/.npm` would fix it
  permanently; the scratch cache sidesteps it).
- `.d.ts` parse check is skipped in validate ("typescript not in node_modules") —
  harmless; the emitted `.d.ts` come from `dtsPropsFor`, not a TS parse.

## Re-sync risks (what can silently go stale)

- **`dtsPropsFor` drift** — hand-written; won't track source prop changes (above).
- **New Riso components** — the kit grows (board cell, toast, etc. are planned per
  `docs/RISO_WEB.md`). A new `Riso*.tsx` in the barrel is NOT auto-picked-up: add
  it to `componentSrcMap` + `dtsPropsFor`, and author a `previews/<Name>.tsx`.
- **Token/util renames** in `riso.css` would invalidate the conventions header —
  the header enumerates real token names; re-validate them against `_ds_bundle.css`
  on any riso.css change.
- **Remote fonts** — `riso-webfonts.css` pins gstatic URLs; if Google rotates the
  woff2 hashes the old URLs 404 (fonts fall back). Re-fetch if previews go serif.

## 2026-09-26 re-sync (11 components)

- Pinned the three kit components added since July — `DiceButton`,
  `RisoMiniBoardArt`, `RisoTypeBadge` — in `componentSrcMap` + `dtsPropsFor`,
  authored `previews/<Name>.tsx` for each. `RisoIcon` gained the `lock` glyph and
  `RisoSegmented` a `size: 'default' | 'compact'` prop; both `dtsPropsFor` bodies
  were updated by hand (the re-sync risk above bit exactly as predicted).
- `cfg.overrides.DiceButton` / `.RisoTypeBadge` = `{"cardMode": "column"}` —
  their row-composition stories render wider than a grid cell (`[GRID_OVERFLOW]`).
- `RisoTypeBadge` imports `TaskType` from `@oybc/shared` — the shared package
  must be BUILT (`pnpm --filter @oybc/shared build`) before the converter bundles
  from the barrel, or esbuild can't resolve it.
- Converter deps this run: `playwright@1.62.0` (matches the repo's pin and the
  cached `chromium-1234` build) + esbuild, ts-morph, @types/react, installed with
  `npm i --cache <scratch>` (the `~/.npm` permission issue is still present).
- `conventions.md` intro now says eleven primitives and names the three new
  ones; every token/class it enumerates re-verified against
  `ds-bundle/tokens/riso.css` (note: tokens land in `tokens/riso.css`, not
  `_ds_bundle.css` — validate the header against that file).
- The project also carries a hand-authored `templates/lock-a-square/` (the
  per-square lock spec for Board Edit). It is NOT produced by this sync and must
  never be listed in a plan's `deletes`.

## Known render warns

None — validate exits clean with 0 warnings. Any warn on a future run is new.

## 2026-09-30 re-sync (teal + prop drift)

- Trigger: compound task type went green → teal (#522; an orange step in #520
  was rejected), and props drifted since #509. `dtsPropsFor` updated by hand:
  `RisoButton.kind` + `'teal'` (compound-type submit CTA), `RisoSegmented` +
  `fullWidth?: boolean`, `RisoIcon.name` + `'shuffle'`, `RisoTypeBadge` doc
  compound → K (teal). Previews: `RisoButton` kinds sweep + Teal;
  `RisoSegmented` + `FullWidth` story (five equal segments at 353px).
- `cfg.overrides.RisoSegmented = {"cardMode": "column"}` — the FullWidth story
  trips `[GRID_OVERFLOW]` (wider than a grid cell), same remedy as DiceButton.
- `conventions.md` accents row + on-fill rows now name `--riso-teal` (dark fill
  → `--riso-on-color`); re-verified every token against `ds-bundle/tokens/riso.css`.
- Build the shared package WITH its deps before the converter:
  `pnpm -F "@oybc/shared..." build` (a bare `--filter @oybc/shared build` fails
  with tsc exit 2 because `@oybc/bingo-core` has no dist in a fresh worktree).
- `.ds-sync/` staging needs its own `package.json` before `npm i` (the skill's
  `echo '{"name":"ds-sync-deps",...}'` line) or the install lands nowhere; deps
  this run: esbuild, ts-morph, @types/react, playwright@1.62.0 (cached
  `chromium_headless_shell-1234`).
- Review-sheet trap: sheets are rendered scaled down in the Read tool, so a
  353px full-width story LOOKS like natural-width segments. Measure with
  playwright (`getBoundingClientRect`) before grading `needs-work`.
- Driver verdict: 9 verified-by-upload, 2 re-graded (RisoButton, RisoSegmented),
  4 uploaded (+ RisoIcon/RisoTypeBadge doc-only), 0 deletes. Atomic path.
