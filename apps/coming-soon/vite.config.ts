import { defineConfig } from 'vite';

// Standalone static site for oybc.com. No framework plugins — plain HTML + TS
// + CSS. Builds to dist/, which Firebase Hosting serves. See docs/COMING_SOON.md.
//
// Multi-page: the Coming Soon poster (index.html) plus the two legal pages.
// Each page is its own Rollup input — paths relative to this package, the cwd
// every build runs from (pnpm --filter, turbo and the firebase predeploy all
// run here; Vite's default root is that same cwd) — so it lands in dist/ as
// a real file: `privacy.html` / `terms.html` at the dist root, which
// firebase.json's `cleanUrls` serves at `/privacy` and `/terms` ahead of the
// `**` catch-all rewrite (Hosting matches static files before rewrites). The
// apps link to those exact URLs (`LEGAL_LINKS` in packages/shared ↔
// `LegalLinks.swift`).
export default defineConfig({
  build: {
    target: 'es2020',
    sourcemap: true,
    rollupOptions: {
      input: {
        main: 'index.html',
        privacy: 'privacy.html',
        terms: 'terms.html',
      },
    },
  },
  server: {
    port: 5273, // distinct from the app's 5173 so both can run at once
  },
});
