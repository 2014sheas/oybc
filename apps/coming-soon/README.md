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

Submits land in Firestore at `signups/{sha256(email)}` via the `subscribe`
function (`functions/src/index.ts`). Re-submitting a known address is idempotent
and still shows success. `firestore.rules` is unchanged — the collection is
default-denied to clients; the Admin SDK in the function is the only writer.

On a **genuinely new** signup the function also sends a one-time "you're on the
board" confirmation email via [Resend](https://resend.com) (best-effort — a mail
failure never fails the signup; duplicates are not re-sent).

**Still deferred to launch** (not blocking the placeholder): double opt-in,
unsubscribe/list management, and per-IP rate limiting — these belong with the
bulk launch-announcement send.

## Set up Resend (one-time, before deploy)

The confirmation email needs a Resend account + a verified sending domain.

1. Create an account at [resend.com](https://resend.com).
2. **Add + verify the domain** `oybc.com`: Resend → Domains → Add Domain → copy
   the DNS records it shows (SPF `TXT`, DKIM `TXT`/`CNAME`, and often a
   `MX`/return-path) and add them at your DNS host (GoDaddy). Wait for Resend to
   mark the domain **Verified**. Until then, sends from `hello@oybc.com` fail
   (the signup still saves — the email is just skipped).
3. Create an **API key** (Resend → API Keys), then store it as a Functions
   secret (never commit it):
   ```bash
   firebase functions:secrets:set RESEND_API_KEY
   # paste the key when prompted
   ```
   To change the from-address later, edit `CONFIRM_FROM` in
   `functions/src/index.ts`.

## Deploy (Firebase Hosting)

> **DEPLOYED — LIVE ON `https://oybc.com` (2026-07-30).** First deploy of
> `subscribe` + hosting to `oybc-dev-e2668`; apex custom domain connected
> (GoDaddy nameservers repointed from Afternic to default GoDaddy, A
> `199.36.158.100` + verification TXT), SSL minted, signups persisting
> (required a one-time `roles/datastore.user` IAM grant to the default
> compute SA — gen-2 functions don't get Firestore access by default on
> newer projects). Still pending: `www.oybc.com` redirect (one console
> click), Resend domain verification (until Verified, confirmation emails
> skip gracefully — signups still save), and the `FIREBASE_SERVICE_ACCOUNT`
> Actions secret (issue #262) — deploys stay MANUAL until it's set.

`firebase.json` already carries the `hosting` block (public =
`apps/coming-soon/dist`, `/api/subscribe` → the `subscribe` function, catch-all →
`/index.html`, and a `predeploy` that builds this package).

```bash
# from the repo root, on the Blaze plan, with RESEND_API_KEY secret set:
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
