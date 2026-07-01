# @oybc/coming-soon

Standalone risograph-poster placeholder for the **`oybc.com`** apex domain. It
announces the app, holds the domain, and captures launch-notification emails.
It is deliberately **not** part of `apps/web` — see
[`docs/COMING_SOON.md`](../../docs/COMING_SOON.md) for the full spec and rationale.

Vite + vanilla TS + CSS. No React, no Firebase JS SDK, no app code.

## Develop

```bash
pnpm --filter @oybc/coming-soon dev       # http://localhost:5273
pnpm --filter @oybc/coming-soon build     # tsc --noEmit && vite build → dist/
pnpm --filter @oybc/coming-soon preview    # serve the built dist/
pnpm --filter @oybc/coming-soon lint
```

The email form POSTs to `/api/subscribe`. In production, Firebase Hosting
rewrites that to the `subscribe` Cloud Function (same-origin, no CORS). During
local `dev`/`preview` there is no such route, so a submit returns the inline
error state — that's expected. To exercise the success path locally, run the
Functions + Firestore emulators and proxy `/api` to them, or (for a quick visual
check) stub `window.fetch` to return `200`.

## Email capture

Submits land in Firestore at `signups/{lowercased-email}` via the `subscribe`
function (`functions/src/index.ts`). Re-submitting a known address is idempotent
and still shows success. `firestore.rules` is unchanged — the collection is
default-denied to clients; the Admin SDK in the function is the only writer.

**Deferred to launch** (not blocking the placeholder): double opt-in +
unsubscribe (needs a mail provider), per-IP rate limiting, and the consent line.

## Deploy (Firebase Hosting)

`firebase.json` already carries the `hosting` block (public =
`apps/coming-soon/dist`, `/api/subscribe` → the `subscribe` function, catch-all →
`/index.html`, and a `predeploy` that builds this package).

```bash
# from the repo root, with the Firebase project on the Blaze plan (functions):
firebase deploy --only functions:subscribe,hosting
```

### Custom domain, app relocation, and launch flip (ops checklist)

1. **Domain**: in the Firebase console → Hosting, add the custom domain
   `oybc.com` (and `www.oybc.com`) to this site and complete DNS verification.
2. **Only public route**: the catch-all rewrite already serves the placeholder
   for every path — do not deploy the app bundle to this site. Keep the app on a
   separate, unlinked host (e.g. `app.oybc.com`) behind auth and unannounced.
3. **Indexing**: this placeholder may be indexed (it has a title + description).
   Put `<meta name="robots" content="noindex,nofollow">` and a `Disallow: /`
   robots rule on the **app** host until launch.
4. **Multi-site (optional)**: if you host both the placeholder and the app under
   one Firebase project, split them into two Hosting sites with
   `firebase target:apply hosting <target> <site>` and give each its own
   `hosting` entry (this block becomes an array). Not required while the app
   lives elsewhere.
5. **Launch**: repoint `oybc.com` at the real app (or lift a launch flag) so
   go-live is one config flip. The placeholder intentionally has **no sign-in /
   get-started CTAs** — keep it that way until then.
