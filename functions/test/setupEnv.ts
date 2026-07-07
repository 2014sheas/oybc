/**
 * Vitest `setupFiles` entry — runs before each test file's own imports are
 * evaluated. `firebase emulators:exec --project demo-oybc-functions-test`
 * already exports `GCLOUD_PROJECT` (and `FIRESTORE_EMULATOR_HOST`,
 * `FIREBASE_FUNCTIONS_EMULATOR_HOST` / equivalents) into this process, but we
 * set a matching fallback here too: `src/index.ts` calls the Admin SDK's
 * `initializeApp()` with NO arguments at module-load time (the same call
 * used in production), and that call resolves the project id from
 * `GCLOUD_PROJECT` / `GOOGLE_CLOUD_PROJECT`. If a test file were ever run
 * outside `emulators:exec` (e.g. directly under `vitest run` for a quick
 * collection-only check), this fallback keeps `initializeApp()` from
 * resolving to a real project id and reaching out over the network.
 */
process.env.GCLOUD_PROJECT ??= "demo-oybc-functions-test";
process.env.GOOGLE_CLOUD_PROJECT ??= process.env.GCLOUD_PROJECT;
