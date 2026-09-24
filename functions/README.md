# OYBC Cloud Functions

Server-side code for OYBC (TypeScript, Node 22). See the repo `CLAUDE.md`
§Cloud Functions and `docs/MONETIZATION.md` for what each function does.

```bash
npm ci && npm run build          # type-check + esbuild bundle to lib/index.js
# emulator-backed tests (needs Java for the Firestore emulator); from the REPO ROOT:
REVENUECAT_WEBHOOK_AUTH=test-rc-webhook-secret firebase emulators:exec \
  --only functions,firestore --project demo-oybc-functions-test \
  "npm --prefix functions run test:run"
```

## Params (non-secret config) — per-project dotenv files

Non-secret params (`defineString`) are resolved from `functions/.env.<projectId>`
at deploy time and in the emulator. A param with no value in a dotenv file makes
`firebase deploy --non-interactive` (CI) **fail** and makes the emulator
**prompt** — so every project we deploy or emulate needs its file committed.
Secrets never go here (they use `defineSecret` / Secret Manager; `.env*.local`
is gitignored for local overrides).

| Param | `.env.oybc-dev-e2668` / `.env.demo-oybc-functions-test` | Prod project |
| --- | --- | --- |
| `REVENUECAT_ALLOWED_ENVIRONMENTS` | `PRODUCTION,SANDBOX` | **`PRODUCTION`** |

**`REVENUECAT_ALLOWED_ENVIRONMENTS`** — comma-separated RevenueCat event
`environment` values the `revenueCatWebhook` accepts; anything else is
acknowledged with `200 {ok:true, ignored:'environment'}` and writes nothing.
The dev project accepts `SANDBOX` so test purchases work. **When the prod
Firebase project is created (ROADMAP Track A4), add
`functions/.env.<prod-project-id>` containing
`REVENUECAT_ALLOWED_ENVIRONMENTS=PRODUCTION`** — otherwise a free sandbox
purchase would grant real Pro in production.
