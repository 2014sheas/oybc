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

## Known render warns

None — validate exits clean with 0 warnings. Any warn on a future run is new.
