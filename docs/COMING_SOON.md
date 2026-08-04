# Coming Soon page (`oybc.com` placeholder)

Standalone risograph-poster placeholder for the `oybc.com` apex domain. It
announces the app, holds the domain, and captures launch-notification emails.
It is the **only** page that should be publicly reachable until the product
launches. Design handoff: `OYBC Coming Soon.zip` (gitignored at
`design_handoff_coming_soon/`).

## Why it's its own package (not part of `apps/web`)

The placeholder must ship to the apex domain **without** the app bundle. Keeping
it in `apps/web` would couple the two and risk exposing app routes on `oybc.com`.
So it lives in **`apps/coming-soon/`** — a tiny Vite + vanilla-TS static site with
**no React, no Firebase JS SDK, no app code**. The app stays on a separate,
unlinked host (e.g. `app.oybc.com`) behind auth until launch.

This is a deliberate, documented **web-only** surface (no iOS counterpart) — the
same rule-6 parity exception class as notifications / account-security. It is a
marketing page, not an app feature.

## Structure

```
apps/coming-soon/
  index.html        static shell: fonts, nav, hero, poster frame, beats, footer
  src/main.ts       board build + escalation, tap-to-play, theme toggle, email submit
  src/styles.css    self-contained Riso tokens (:root + .night) + base + all .cs-* rules
  vite.config.ts    build → dist/ (target es2020)
  tsconfig.json     strict, DOM lib, noEmit (vite transpiles)
  eslint.config.js  flat config (no React plugins)
  README.md         deploy + DNS + launch-flip instructions
```

### Tokens are self-contained (by design)

The Riso token **values** here are byte-identical to `packages/riso-tokens/riso.css`
(the handoff's unprefixed `--paper`/`--red`/… equal the app's `--riso-*`; the
tokens were extracted from `apps/web/src/styles/riso.css` into the
`@oybc/riso-tokens` workspace package — pure relocation, no value change). We
copy them (unprefixed, matching the handoff) rather than importing the package
so the placeholder has **zero dependency on the app build**. If the palette ever
changes, update both — but the palette is stable and this page is throwaway at
launch.

**CI drift-check:** `node scripts/check-coming-soon-tokens.mjs` (wired into
`.github/workflows/web.yml` after the Lint step) parses the light/dark custom
properties from both `packages/riso-tokens/riso.css` and this page's
`src/styles.css`, strips the `riso-` prefix, and fails the build if any token
present in both files has diverged in value. Tokens only one file has are
ignored. Run it locally with plain `node`, no dependencies.

## Locked production config (Tweaks panel stripped)

The prototype's review-only "Tweaks" panel is **not** ported. These are hardcoded
constants in `main.ts` (from the handoff's "Locked production direction" table):

| Setting | Value |
|---|---|
| Layout | Split (copy left, board right; stacks < 940px) |
| Board loudness | Loud — resting inked set `[0,3,6,7,11,15,17,18,20,21,23]` |
| Board ink | Mixed — blue subset `{6,17,21}`, rest red |
| Headline | "We're filling / in the squares." (2nd line `--red`) |
| One-line pitch | Shown |
| How-it-works strip | Always shown |
| Theme | Day default, Night toggle (real feature — kept) |
| Season | "Fall 2026" |

On valid email submit: cells `10,11,13,14` ink red (with FREE `12` completes the
center row), `10–14` get the gold bingo ring, the green **SPOT SAVED** stamp pops,
and the form swaps to the confirmation card. Board play (tap empty cells to ink)
is purely delightful and not persisted. The board grid is `aria-hidden` (decorative —
avoids 25 junk tab stops); all conveyed text ("Launching Fall 2026", the loop) is
present as real copy elsewhere.

## Email capture — Firebase (Firestore via Cloud Function)

Decision: capture to **Firestore**, reusing the existing `functions/` codebase.

- The page POSTs **same-origin** to `/api/subscribe` (a plain `fetch`, no Firebase
  SDK). Firebase **Hosting rewrites** `/api/subscribe` → the `subscribe` v2
  `onRequest` function, so there is **no CORS** and the page stays dependency-free.
- `functions/src/index.ts` → **`subscribe`**: validates the email server-side
  (the client regex is a courtesy), checks the honeypot field, and writes
  `signups/{emailKey}` = `{ email, source, createdAt }` via the Admin SDK, where
  `emailKey` is a **SHA-256 of the lowercased email** — deterministic (so
  **re-submitting a known address is idempotent** — a `set(..., {merge:true})`
  overwrite that always returns success, never an error) and doc-id-safe (a raw
  email can contain `/`, which would break the Firestore path). The readable
  address is stored in the `email` field.
- `firestore.rules` is **UNCHANGED**: `signups` is default-denied to all clients
  (only `users/**` is allowed), and the Admin SDK bypasses rules. Do **not** add a
  client-writable `signups` rule — the function is the only writer.
- Honeypot: a visually-hidden `hp` field. If non-empty, the function returns
  `{ ok: true }` **without** writing (don't tip off bots) — no CAPTCHA.
- **Confirmation email (Resend)**: on a *genuinely new* signup (detected via a
  `get()` before the `set`) the function sends a one-time "you're on the board"
  email through [Resend](https://resend.com). It is **best-effort** — wrapped in
  its own try/catch so a send failure (or an unverified Resend domain pre-launch)
  never fails the request or drops the address. Re-submitting a known address is
  a no-op merge and does **not** re-send, so duplicates aren't spammed. The
  `RESEND_API_KEY` is a Cloud Functions **secret** (`defineSecret`, bound via
  `secrets:` on the function) — set it with
  `firebase functions:secrets:set RESEND_API_KEY` before deploying. The from
  address (`hello@oybc.com`) must be a Resend-**verified domain** or sends fail.
- **Unsubscribe (shipped)**: the confirmation email carries a footer
  `Unsubscribe` link to `oybc.com/unsubscribe?u=<sha256(email)>` (the
  `unsubscribe` function behind a hosting rewrite registered before the
  catch-all) plus RFC 8058 `List-Unsubscribe`/`List-Unsubscribe-Post` headers
  (Gmail/Apple Mail native affordance). GET renders a confirm page (scanner
  prefetch defense); POST marks `signups/{key}.unsubscribed = true` (doc kept
  — **the launch send MUST filter `unsubscribed != true`**); unknown tokens
  show success without creating docs (no membership oracle).
- **Still deferred to launch**: double opt-in and per-IP rate limiting —
  these belong with the bulk launch-announcement send, not the placeholder.
  Firestore holds the list for that send.

### Submit states (handoff)

idle → invalid (inline hint, no network) → submitting (button disabled) →
success / duplicate (both show the confirmation + bingo) / error ("Couldn't save
that — try again.", button re-enabled).

## Hosting — Firebase Hosting

> **LIVE (2026-07-30):** deployed to `oybc-dev-e2668` and serving on
> `https://oybc.com` (see `apps/coming-soon/README.md` §Deploy for the
> as-deployed record: DNS/nameserver notes, the compute-SA
> `roles/datastore.user` IAM grant the subscribe write path needs). The
> once-pending items are all resolved (2026-08-04): www redirect live, Resend
> domain Verified, and CI auto-deploys cover hosting (`hosting.yml`, #262
> closed) AND functions (`functions.yml` — see the README for the deployer-SA
> IAM set + Cloud Billing API enablement its first run required). The A4
> dev/prod project split remains pending: the
> apex intentionally points at the dev project until then.

`firebase.json` gains a `hosting` block:

```jsonc
"hosting": {
  "public": "apps/coming-soon/dist",
  "ignore": ["firebase.json", "**/.*", "**/node_modules/**"],
  "rewrites": [
    { "source": "/api/subscribe", "function": { "functionId": "subscribe", "region": "us-central1" } },
    { "source": "**", "destination": "/index.html" }
  ],
  "predeploy": ["pnpm --filter @oybc/coming-soon run build"]
}
```

The `/api/subscribe` rewrite is listed **before** the catch-all so it wins. The
catch-all serves the placeholder for every other path (the "only public route"
requirement). See `apps/coming-soon/README.md` for the custom-domain,
`app.oybc.com` relocation, robots/noindex, and launch-flip steps.

## CI

`apps/coming-soon/**` is added to `.github/workflows/web.yml` path filters. The
existing `pnpm -w build` / `pnpm -w lint` (Turbo) already build every `apps/*`
package, so the new package gets typecheck (`tsc`) + build + lint with no new job.
